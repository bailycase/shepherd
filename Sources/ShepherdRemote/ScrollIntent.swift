#if DEBUG
/// Capture only. Native adapters supply motion and attribute displacement; this signal writes nothing.
public struct ScrollIntent {
    public enum State: String, Encodable, Sendable {
        case idle, touching, coasting, programmatic
    }

    private var pendingReaderInput = false

    public init() {}

    /// A discrete key or wheel event can finish between two display frames.
    public mutating func readerInput() { pendingReaderInput = true }

    public mutating func sample(touching: Bool = false, coasting: Bool = false, programmatic: Bool = false,
                                unexplainedDisplacement: Bool = false) -> State {
        defer { pendingReaderInput = false }
        if touching || pendingReaderInput { return .touching }
        if coasting { return .coasting }
        if programmatic { return .programmatic }
        return unexplainedDisplacement ? .touching : .idle
    }
}
#endif
