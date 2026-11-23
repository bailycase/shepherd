import Darwin
import Foundation
import Testing

/// Why a wait gave up: what was awaited, so a failing integration test says what never happened.
public struct WaitTimeout: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "timed out waiting for \(what)" }
}

/// How long a wait gives a condition by default. The happy path returns as soon as it holds;
/// the bound is for a process started on a loaded 3-core CI runner, where a stub pi took about
/// ten seconds to answer.
public let defaultWaitTimeout: Duration = .seconds(30)

/// Wait for `condition` to hold, polling quickly. Integration tests use this only where no
/// callback exists to await; it never sleeps a fixed amount. Throws `WaitTimeout` naming `what`.
public func eventually(
    _ what: String,
    timeout: Duration = defaultWaitTimeout,
    poll: Duration = .milliseconds(10),
    _ condition: () async throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try await condition() { return }
        try await Task.sleep(for: poll)
    }
    if try await condition() { return }
    throw WaitTimeout(what: what)
}

/// Main-actor form for view-model state.
@MainActor
public func eventuallyOnMain(
    _ what: String,
    timeout: Duration = defaultWaitTimeout,
    poll: Duration = .milliseconds(10),
    _ condition: @MainActor () throws -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if try condition() { return }
        try await Task.sleep(for: poll)
    }
    if try condition() { return }
    throw WaitTimeout(what: what)
}

/// Keeps the main thread busy, as a long frame does, until `condition` holds: everything queued for the main
/// queue waits behind the spin. It neither runs the run loop nor awaits, and never sleeps a fixed amount.
/// Throws `WaitTimeout` naming `what` when the condition does not come.
@MainActor
public func holdingMain(until what: String, timeout: Duration = .seconds(10), _ condition: () -> Bool) throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else { throw WaitTimeout(what: what) }
        sched_yield()
    }
}

/// Runs the body of an exit test (`#expect(processExitsWith:)`), recording what it throws as an
/// issue. An error that escapes the body kills the child process with SIGTRAP ("Error raised at
/// top level"), and the parent reports only the signal; recorded, a wait that timed out fails
/// the test by what it waited for. A failed `#require` has already recorded its own issue.
public func recordingErrors(sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void) async {
    do {
        try await body()
    } catch is ExpectationFailedError {
    } catch {
        Issue.record(error, sourceLocation: sourceLocation)
    }
}

/// What `completingScenario` writes to the child's stdout once its body has returned.
private let scenarioCompleteLine = "SHEPHERD-SCENARIO-COMPLETE\n"

/// `recordingErrors`, then a sentinel on stdout after the body's last statement. `processExitsWith: .success` also counts a child that
/// exited early with status 0 (a menu's `cancelTracking()` did that), so a scenario that must reach its end is checked with
/// `expectScenarioCompleted`:
///
///     let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
///         await completingScenario { try await Self.pausing() }
///     }
///     expectScenarioCompleted(result)
public func completingScenario(sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void) async {
    var completed = false
    await recordingErrors(sourceLocation: sourceLocation) {
        try await body()
        completed = true
    }
    if completed { FileHandle.standardOutput.write(Data(scenarioCompleteLine.utf8)) }
}

/// Records an issue unless the child printed the sentinel, i.e. ran its body to the end without an early exit.
public func expectScenarioCompleted(_ result: ExitTest.Result?, sourceLocation: SourceLocation = #_sourceLocation) {
    let output = String(decoding: result?.standardOutputContent ?? [], as: UTF8.self)
    #expect(output.contains(scenarioCompleteLine), "the scenario exited before its last statement", sourceLocation: sourceLocation)
}

/// One-shot event a fake opens and a test awaits: no polls, no fixed sleeps. A `wait` that starts
/// after `open` returns at once, so a signal is never missed. Cancellation-aware: cancelling a
/// waiter resumes it at once, so `bounded` throws `GateTimeout` instead of hanging.
public final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    public init() {}

    public func open() {
        let resume = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for waiter in resume { waiter.resume() }
    }

    public func wait() async {
        let id = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                let resumeNow = lock.withLock { () -> Bool in
                    if isOpen { return true }
                    if Task.isCancelled { return true }
                    waiters[id] = continuation
                    return false
                }
                if resumeNow { continuation.resume() }
            }
        } onCancel: {
            let resume = lock.withLock { () -> CheckedContinuation<Void, Never>? in
                waiters.removeValue(forKey: id)
            }
            resume?.resume()
        }
    }
}

/// What a bounded wait gave up on.
public struct GateTimeout: Error, CustomStringConvertible {
    public let what: String
    public var description: String { "timed out waiting for \(what)" }
}

/// Runs the event-driven `wait` (which returns the moment its signal arrives), giving up after
/// `timeout` with a `GateTimeout`. The clock only fires on the failure path; the happy path waits
/// on events alone, with no sleeps or polls. Only fails if `wait` honors cancellation: a closure
/// that ignores it keeps the group from returning, so pass a `Gate.wait` or another
/// cancellation-aware wait.
public func bounded<T: Sendable>(
    _ what: String,
    timeout: Duration = .seconds(10),
    _ wait: @escaping @Sendable () async -> T
) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { await wait() }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw GateTimeout(what: what)
        }
        guard let first = try await group.next() else { throw GateTimeout(what: what) }
        group.cancelAll()
        return first
    }
}
