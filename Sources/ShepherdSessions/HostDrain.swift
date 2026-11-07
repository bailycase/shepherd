import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdRemote

/// The background host's handoff to another build: once its bundle on disk changes (an update, a
/// downgrade, or the app moved to the Trash) or a newer app asks (`drain`), the host keeps
/// serving and running turns, and exits once no agent is working, blocked or starting, or at the
/// cap. launchd's KeepAlive then starts the bundle that is there now; interrupted interactive
/// turns resume there through `AgentRecoveryStore`.
@MainActor
public final class HostDrain {
    /// How long a drain waits for agents before the host exits anyway (plan #460, C5).
    public nonisolated static let cap: Duration = .seconds(2 * 60 * 60)

    public private(set) var draining = false
    private let server: SessionServer
    private let cap: Duration
    private let poll: Duration
    private let exit: @MainActor () -> Void
    private var task: Task<Void, Never>?

    /// `exit` ends the host (stop the server, exit the process); tests pass their own.
    public init(server: SessionServer, cap: Duration = HostDrain.cap, poll: Duration = .seconds(5),
                exit: @escaping @MainActor () -> Void) {
        self.server = server
        self.cap = cap
        self.poll = poll
        self.exit = exit
    }

    /// Starts draining; a second call changes nothing.
    public func begin(_ reason: String) {
        guard !draining else { return }
        draining = true
        ShepherdLog.info("host draining: \(reason)")
        let deadline = ContinuousClock.now.advanced(by: cap)
        // ponytail: polls every few seconds; a state observer if exits need to be prompter.
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                if self.server.quietForDrain {
                    ShepherdLog.info("host drained")
                    return self.exit()
                }
                if ContinuousClock.now >= deadline {
                    ShepherdLog.warning("host drain reached its cap; exiting with agents still busy")
                    return self.exit()
                }
                try? await Task.sleep(for: self.poll)
            }
        }
    }
}

extension SessionServer {
    /// No agent working, blocked or starting: what a draining host waits for.
    @MainActor var quietForDrain: Bool {
        spawningAgents == 0 && startingAutomationRuns.isEmpty
            && !state.agents.contains { $0.status == .working || $0.status == .blocked }
    }
}

/// Watches a bundle's `CFBundleVersion` on disk: on a file-system event on the bundle folder and
/// every `every`, read fresh (never through `Bundle`, which caches). `changed` runs once, on main,
/// with the version now there (nil when the bundle is gone or unreadable).
public final class BundleVersionWatch: @unchecked Sendable {
    private let bundle: URL
    private let running: String?
    private let changed: @MainActor (String?) -> Void
    private let queue = DispatchQueue(label: "shepherd.bundle-watch")
    private var source: DispatchSourceFileSystemObject?
    private var timer: DispatchSourceTimer?
    private var fired = false

    public init(bundle: URL, running: String?, every: DispatchTimeInterval = .seconds(5 * 60),
                changed: @escaping @MainActor (String?) -> Void) {
        self.bundle = bundle
        self.running = running
        self.changed = changed
        queue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now() + every, repeating: every)
            timer.setEventHandler { [weak self] in self?.check() }
            timer.activate()
            self.timer = timer
            // Watch, then read: a change before the source opened is caught by the read.
            self.watch()
            self.check()
        }
    }

    public static func version(of bundle: URL) -> String? {
        NSDictionary(contentsOf: bundle.appendingPathComponent("Contents/Info.plist"))?["CFBundleVersion"] as? String
    }

    public func cancel() {
        queue.async {
            self.source?.cancel()
            self.timer?.cancel()
        }
    }

    /// (Re)opens the event source on whatever is at the bundle's path now: a replaced bundle is a
    /// new folder, and the old descriptor follows the old one.
    private func watch() {
        source?.cancel()
        source = nil
        let fd = open(bundle.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .delete, .rename, .attrib, .link, .revoke], queue: queue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.check()
            if !self.fired { self.watch() }
        }
        source.setCancelHandler { close(fd) }
        source.activate()
        self.source = source
    }

    private func check() {
        guard !fired else { return }
        let now = Self.version(of: bundle)
        guard now != running else { return }
        fired = true
        source?.cancel()
        timer?.cancel()
        let changed = changed
        DispatchQueue.main.async { MainActor.assumeIsolated { changed(now) } }
    }
}
