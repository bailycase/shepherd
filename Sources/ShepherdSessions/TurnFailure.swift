/// A turn that ended in a provider error (pi's `stopReason: "error"`), rather than one that
/// finished or that the user stopped. It comes with the `done` report that ends the turn.
public struct TurnFailure: Equatable, Sendable {
    /// pi's error message, when it gave one.
    public let message: String?

    public init(message: String?) {
        self.message = message
    }
}
