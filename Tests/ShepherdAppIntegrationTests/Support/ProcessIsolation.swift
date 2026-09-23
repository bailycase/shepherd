import Testing

/// `PTYSession` starts shells with `forkpty` and does not close the file descriptors it
/// inherits, so a long-lived shell or `cat` keeps a copy of every pipe that was open anywhere
/// in the process at that moment. Whoever then reads such a pipe to EOF (git output, a login
/// shell probe) waits for that shell to exit — observed as a hung `git` in an unrelated test.
///
/// Until that is fixed in `PTYSession`, tests that fork PTYs run alone: `.forksPTYs` takes an
/// exclusive gate, every other suite in this target takes it shared (`.runsProcesses`).
struct ProcessIsolation: SuiteTrait, TestTrait, TestScoping {
    let exclusive: Bool

    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void) async throws {
        // Scope each test case, not the suite around them (that would hold the gate while
        // waiting for its own cases).
        guard testCase != nil else { return try await function() }
        await ProcessGate.shared.enter(exclusive: exclusive)
        do {
            try await function()
        } catch {
            await ProcessGate.shared.leave(exclusive: exclusive)
            throw error
        }
        await ProcessGate.shared.leave(exclusive: exclusive)
    }
}

extension Trait where Self == ProcessIsolation {
    /// Runs alone: forks PTY children that would inherit other tests' pipes.
    static var forksPTYs: Self { ProcessIsolation(exclusive: true) }
    /// Runs alongside other tests, but never while a PTY-forking test runs.
    static var runsProcesses: Self { ProcessIsolation(exclusive: false) }
}

/// A writer-preferring readers–writer gate.
private actor ProcessGate {
    static let shared = ProcessGate()
    private var readers = 0
    private var writing = false
    private var waitingWriters: [CheckedContinuation<Void, Never>] = []
    private var waitingReaders: [CheckedContinuation<Void, Never>] = []

    func enter(exclusive: Bool) async {
        if exclusive {
            if writing || readers > 0 || !waitingWriters.isEmpty {
                await withCheckedContinuation { waitingWriters.append($0) }
            } else {
                writing = true
            }
        } else {
            if writing || !waitingWriters.isEmpty {
                await withCheckedContinuation { waitingReaders.append($0) }
            } else {
                readers += 1
            }
        }
    }

    func leave(exclusive: Bool) {
        if exclusive { writing = false } else { readers -= 1 }
        guard !writing, readers == 0 else { return }
        if !waitingWriters.isEmpty {
            writing = true
            waitingWriters.removeFirst().resume()
        } else {
            readers += waitingReaders.count
            for reader in waitingReaders { reader.resume() }
            waitingReaders.removeAll()
        }
    }
}
