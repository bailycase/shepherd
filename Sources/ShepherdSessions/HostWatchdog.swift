import Dispatch
import Foundation

/// Notices a hung queue in the background host: every `interval` it posts a probe to each watched
/// queue, and one still unanswered after `limit` calls `hung` with the queue's name, once. Nothing
/// it does waits on a watched queue. The host exits on it and launchd starts a fresh one
/// (`KeepAlive`), which respawns the agents with unfinished work, as after any crash.
public final class HostWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private let watched: [(name: String, queue: DispatchQueue)]
    /// When each queue's unanswered probe went out, by name.
    private var waiting: [String: DispatchTime] = [:]
    private var answered = 0
    private var fired = false
    private let timer: DispatchSourceTimer

    public init(_ watched: [(name: String, queue: DispatchQueue)], interval: DispatchTimeInterval = .seconds(10),
                limit: DispatchTimeInterval = .seconds(90), hung: @escaping @Sendable (String) -> Void) {
        self.watched = watched
        timer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "shepherd.host.watchdog"))
        timer.schedule(deadline: .now() + interval, repeating: interval)
        timer.setEventHandler { [weak self] in
            guard let self, let name = self.tick(limit: limit) else { return }
            hung(name)
        }
        timer.activate()
    }

    deinit { timer.cancel() }

    /// Probes answered so far (tests).
    var probesAnswered: Int { lock.withLock { answered } }

    /// One round: the first queue past `limit` (once ever), else a probe to each idle queue.
    private func tick(limit: DispatchTimeInterval) -> String? {
        let now = DispatchTime.now()
        let (late, idle): (String?, [(name: String, queue: DispatchQueue)]) = lock.withLock {
            guard !fired else { return (nil, []) }
            if let late = watched.first(where: { waiting[$0.name].map { $0 + limit < now } ?? false }) {
                fired = true
                return (late.name, [])
            }
            let idle = watched.filter { waiting[$0.name] == nil }
            for queue in idle { waiting[queue.name] = now }
            return (nil, idle)
        }
        for (name, queue) in idle {
            queue.async { [weak self] in
                self?.lock.withLock {
                    self?.waiting[name] = nil
                    self?.answered += 1
                }
            }
        }
        return late
    }
}
