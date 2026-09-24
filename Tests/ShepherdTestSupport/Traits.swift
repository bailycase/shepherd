import Testing

/// A happy path takes seconds and no wait is longer than a minute, so a test still running after
/// two minutes is hung: it fails by name instead of stalling the whole run.
private let integrationMinutes = 2

extension Trait where Self == TimeLimitTrait {
    /// The bound on each test of an integration suite that does not carry `.mainActorExclusive`
    /// (which takes the same bound, counted from the test's turn).
    public static var integrationTimeLimit: Self { .timeLimit(.minutes(integrationMinutes)) }
}

/// Runs each test alone among all tests carrying the trait, whatever suite they are in (unlike
/// `.serialized`, which orders only the tests inside one suite).
///
/// Tests that drive the app run on the one main thread. Run concurrently they cannot go faster,
/// only contend: every test's synchronous work and 10 ms main-actor polls queue behind every
/// other's, and a run of the app suites took longer in parallel than serially while waits hit
/// their timeouts. Suites keep running in parallel with everything that lacks the trait.
///
/// The trait also bounds each test, counting from when it gets its turn. Do not add a
/// `.timeLimit` beside it: that clock also runs while the test waits behind every gated test
/// queued ahead of it, tens of seconds here and minutes on a slower runner, so tests late in the
/// queue would fail without having hung.
public struct MainActorExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
    public let timeLimit: Swift.Duration

    public var isRecursive: Bool { true }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainActorExclusiveGate.shared.enter()
        do {
            try await run(function, sourceLocation: test.sourceLocation)
        } catch {
            await MainActorExclusiveGate.shared.leave()
            throw error
        }
        await MainActorExclusiveGate.shared.leave()
    }

    /// `function` within `timeLimit`. Past it, the test gets an issue and is cancelled; the gate
    /// passes on once it stops.
    private func run(_ function: @Sendable () async throws -> Void, sourceLocation: SourceLocation) async throws {
        let limit = timeLimit
        try await withoutActuallyEscaping(function) { function in
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Returning rather than throwing CancellationError means the test outlasted it.
                    try await Task.sleep(for: limit)
                    Issue.record("Time limit was exceeded: \(limit) after the test got its turn", sourceLocation: sourceLocation)
                }
                group.addTask { try await function() }
                defer { group.cancelAll() }
                try await group.next()
            }
        }
    }
}

extension Trait where Self == MainActorExclusiveTrait {
    /// See `MainActorExclusiveTrait`: two minutes per test, like `.integrationTimeLimit`.
    public static var mainActorExclusive: Self { Self(timeLimit: .seconds(integrationMinutes * 60)) }

    /// See `MainActorExclusiveTrait`, for a suite whose tests legitimately run longer.
    public static func mainActorExclusive(timeLimit: Swift.Duration) -> Self { Self(timeLimit: timeLimit) }
}

/// A first-come, first-served async lock.
private actor MainActorExclusiveGate {
    static let shared = MainActorExclusiveGate()

    private var held = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() async {
        guard held else {
            held = true
            return
        }
        await withCheckedContinuation { waiting.append($0) }
    }

    func leave() {
        if waiting.isEmpty {
            held = false
        } else {
            waiting.removeFirst().resume()
        }
    }
}
