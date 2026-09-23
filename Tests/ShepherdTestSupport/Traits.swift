import Testing

extension Trait where Self == TimeLimitTrait {
    /// The bound on each test of an integration or preview suite. A happy path takes seconds and
    /// the longest waits are 30 s, so a test still running after two minutes is hung: it fails
    /// by name instead of stalling the whole run.
    public static var integrationTimeLimit: Self { .timeLimit(.minutes(2)) }
}
