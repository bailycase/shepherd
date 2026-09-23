import Testing

extension Trait where Self == TimeLimitTrait {
    /// The bound on each test of an integration or preview suite. A happy path takes seconds and
    /// the longest waits are 30 s, so a test still running after two minutes is hung: it fails
    /// by name instead of stalling the whole run.
    public static var integrationTimeLimit: Self { .timeLimit(.minutes(2)) }
}

/// Runs each test alone among all tests carrying the trait, whatever suite they are in (unlike
/// `.serialized`, which orders only the tests inside one suite).
///
/// Tests that drive the app run on the one main thread. Run concurrently they cannot go faster,
/// only contend: every test's synchronous work and 10 ms main-actor polls queue behind every
/// other's, and a run of the app suites took longer in parallel than serially while waits hit
/// their timeouts. Suites keep running in parallel with everything that lacks the trait.
public struct MainActorExclusiveTrait: SuiteTrait, TestTrait, TestScoping {
    public var isRecursive: Bool { true }

    public func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        testCase == nil ? nil : self
    }

    public func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        await MainActorExclusiveGate.shared.enter()
        do {
            try await function()
        } catch {
            await MainActorExclusiveGate.shared.leave()
            throw error
        }
        await MainActorExclusiveGate.shared.leave()
    }
}

extension Trait where Self == MainActorExclusiveTrait {
    /// See `MainActorExclusiveTrait`.
    public static var mainActorExclusive: Self { Self() }
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
