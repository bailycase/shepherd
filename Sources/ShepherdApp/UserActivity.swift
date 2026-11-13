import AppKit

/// Whether the person is at work in the app: typing, scrolling, or watching the thread on screen stream. Work the app does
/// for no one in particular (letting hidden threads' rows go, `NativeThreadStores`) waits for a moment without it, so that
/// none of it lands in the middle of a keystroke, a scroll or a streamed reply.
@MainActor
final class UserActivity {
    private var monitor: Any?
    private var lastEvent: ContinuousClock.Instant?

    init() {
        // Only this app's events: another app's typing is no reason for this one to wait.
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .scrollWheel, .leftMouseDragged]) { [weak self] event in
            MainActor.assumeIsolated { self?.noteEvent() }
            return event
        }
    }

    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }

    /// A key, a scroll or a drag has just come. The monitor's word, and a test's for the person typing.
    func noteEvent() { lastEvent = .now }

    /// A key, a scroll or a drag came within `AppLayout.inputRecentWindow`.
    var inputRecent: Bool {
        guard let lastEvent else { return false }
        return lastEvent.duration(to: .now) < AppLayout.inputRecentWindow
    }

    /// Tells whether a thread on screen changed between one look and the next (a reply streaming in). One per looker.
    final class Stream {
        private var versions: [ObjectIdentifier: Int] = [:]

        /// `versions` is the content version of each thread on screen now, by store (`NativeThreadStores.shownVersions`). True when
        /// one that was on screen at the last look too has a different version. A thread that came on screen is a first look.
        func changed(_ versions: [ObjectIdentifier: Int]) -> Bool {
            defer { self.versions = versions }
            return versions.contains { id, version in self.versions[id].map { $0 != version } ?? false }
        }
    }
}
