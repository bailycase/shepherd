import SwiftUI

/// Counts how often the rows of long lists evaluate their `body`, so tests can pin that opening,
/// scrolling, hovering, or moving a highlight renders only the rows it has to. It records only
/// while a test turns it on, and release builds compile it out.
///
///     var body: some View {
///         let _ = NWRenderProbe.tick("sidebar.row")
///         …
///     }
@MainActor
public enum NWRenderProbe {
    #if DEBUG
    public static var isRecording = false
    public private(set) static var counts: [String: Int] = [:]

    /// Clears the counts and starts recording.
    public static func start() {
        counts = [:]
        isRecording = true
    }

    /// Stops recording and returns what was counted since `start()`.
    @discardableResult
    public static func stop() -> [String: Int] {
        isRecording = false
        return counts
    }

    public static func count(_ key: String) -> Int { counts[key, default: 0] }
    #endif

    /// Counts one body evaluation under `key`.
    @inline(__always)
    public static func tick(_ key: StaticString) {
        #if DEBUG
        if isRecording { counts[key.description, default: 0] += 1 }
        #endif
    }
}
