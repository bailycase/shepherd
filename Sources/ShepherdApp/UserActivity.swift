import AppKit

/// Whether the person is at work in the app: typing, scrolling, or watching the thread on screen stream. Work the app does
/// for no one in particular (letting hidden threads' rows go, `NativeThreadStores`) waits for a moment without it, so that
/// none of it lands in the middle of a keystroke, a scroll or a streamed reply.
@MainActor
final class UserActivity {
    /// How long after a key or a scroll the person still counts as at work.
    static let window: Duration = .milliseconds(750)

    private var monitor: Any?
    private var lastEvent: ContinuousClock.Instant?

    init() {
        // Only this app's events: another app's typing is no reason for this one to wait.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.lastEvent = .now }
            return event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// A key, a scroll or a drag came within `window`.
    var inputRecent: Bool {
        guard let lastEvent else { return false }
        return lastEvent.duration(to: .now) < Self.window
    }

    /// Tells whether the thread on screen changed between one look and the next (a reply streaming in). One per looker.
    final class Stream {
        private var version: Int?

        /// `version` is the shown thread's content version now (nil: nothing is shown). True when it differs from the last look's.
        func changed(_ version: Int?) -> Bool {
            defer { self.version = version }
            guard let version, let last = self.version else { return false }
            return version != last
        }
    }
}
