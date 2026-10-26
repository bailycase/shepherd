import Synchronization

/// Counts how often the rows of long lists evaluate their `body`, so tests can pin that opening,
/// scrolling, hovering, or moving a highlight renders only the rows it has to. It records only
/// while a test turns it on, and release builds compile it out.
///
///     var body: some View {
///         let _ = SHRenderProbe.tick("sidebar.row")
///         …
///     }
public enum SHRenderProbe {
    #if DEBUG
    private struct Recording: Sendable {
        var active = false
        var counts: [String: Int] = [:]
    }
    private static let recording = Mutex(Recording())

    public static var isRecording: Bool {
        get { recording.withLock { $0.active } }
        set { recording.withLock { $0.active = newValue } }
    }
    public static var counts: [String: Int] { recording.withLock { $0.counts } }

    /// Clears the counts and starts recording.
    public static func start() {
        recording.withLock { $0 = Recording(active: true) }
    }

    /// Stops recording and returns what was counted since `start()`.
    @discardableResult
    public static func stop() -> [String: Int] {
        recording.withLock {
            $0.active = false
            return $0.counts
        }
    }

    public static func count(_ key: String) -> Int { recording.withLock { $0.counts[key, default: 0] } }
    #else
    // Release builds record nothing, but keep the API so the test targets build for the
    // release benchmarks (their timings); every count reads zero there.
    public static let isRecording = false
    public static let counts: [String: Int] = [:]
    public static func start() {}
    @discardableResult public static func stop() -> [String: Int] { [:] }
    public static func count(_ key: String) -> Int { 0 }
    #endif

    /// Counts one render or layout pass, including SwiftUI's background layout work.
    @inline(__always)
    public static func tick(_ key: StaticString) {
        #if DEBUG
        recording.withLock {
            if $0.active { $0.counts[key.description, default: 0] += 1 }
        }
        #endif
    }
}
