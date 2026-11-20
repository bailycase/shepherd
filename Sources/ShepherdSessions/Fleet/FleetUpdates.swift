import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The updates this host carries out on Macs of its fleet (`fleet.update.v1`, `FleetAction.update`). A job asks the Mac's own updater what its feed
/// offers (`RemoteHostUpdateRequest.check`), then to install it when the Mac's threads are idle (`installWhenIdle`) or at once (`install`), and
/// follows the Mac's own `HostUpdateStatus` until it came back on another build. Each Mac installs only what its own Sparkle feed offers, signature
/// checked; nothing is copied between Macs.
///
/// The job lives here, not on the client that asked: a phone locks and an app quits, and a Mac that is asleep is started when its link comes back. It
/// is memory only (a restart of this host drops it: nothing that acts on its own comes back), ends after `maxAge`, and Cancel ends it. A client
/// reads it from `FleetSnapshot.updates`. Every property belongs to the server queue.
final class FleetUpdates: @unchecked Sendable {
    /// How a Mac is reached right now.
    enum Reach: Sendable {
        case notInFleet
        /// No link: the Mac is asleep, or its network is away.
        case offline
        /// The link is up and the Mac lacks `fleet.update.v1`: its person updates it there.
        case old
        case ready(@Sendable (RemoteHostUpdateRequest) async throws -> HostUpdateStatus)
    }

    private final class Job: @unchecked Sendable {
        var status: FleetUpdateStatus
        var task: Task<Void, Never>?
        var finishedAt: Date?
        init(status: FleetUpdateStatus) { self.status = status }
    }

    private let queue: DispatchQueue
    private let clock: @Sendable () -> Date
    private var jobs: [UUID: Job] = [:]

    /// Server queue: how `hostID` is reached now.
    var reach: ((UUID) -> Reach)?
    /// Server queue: what the Mac is called in words that say what to do ("Open Shepherd on mini to update it").
    var name: ((UUID) -> String)?
    /// Server queue: a job's status changed.
    var onChange: (() -> Void)?
    /// Server queue: the Mac came back on another build, so Check looks at it again.
    var onUpdated: ((UUID) -> Void)?

    /// Between two looks at a Mac's status.
    var interval: Duration = .seconds(2)
    /// A job gives up after this long, however it is waiting: nothing installs unattended days later.
    var maxAge: TimeInterval = 12 * 3600
    /// A Mac that went to install is given this long to come back.
    var relaunchPatience: TimeInterval = 10 * 60
    /// An ended job stays in the snapshot this long, so the panel can say how it ended.
    var keepEnded: TimeInterval = 30 * 60
    var keepUpdated: TimeInterval = 30
    /// A Mac is asked to install this many times, once per look, before the job says nothing started.
    static let installAttempts = 3
    /// A Mac that lost what it was asked (the app that held it quit, or its host restarted) is asked again from the check this many times.
    static let restartAttempts = 2
    /// More than this between two looks means this host was suspended (asleep): what the Mac did meanwhile wasn't seen, so it isn't lack of progress.
    static let suspension: TimeInterval = 60

    init(queue: DispatchQueue, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.queue = queue
        self.clock = clock
    }

    // MARK: Server queue

    /// The jobs a client may draw: running ones and ones that ended lately.
    func statuses() -> [FleetUpdateStatus] {
        let now = clock()
        return jobs.values.compactMap { job -> FleetUpdateStatus? in
            if let ended = job.finishedAt, now.timeIntervalSince(ended) > (job.status.stage == .updated ? keepUpdated : keepEnded) { return nil }
            return job.status
        }.sorted { ($0.startedAt, $0.hostID.uuidString) < ($1.startedAt, $1.hostID.uuidString) }
    }

    /// Starts updating `hostID`; a job that is running is left as it is. Returns why not, if so.
    func start(_ hostID: UUID, when: FleetUpdateWhen) -> (code: String, message: String)? {
        if let job = jobs[hostID], job.finishedAt == nil { return nil }
        guard let reach else { return ("unsupported", "This Mac can't update Shepherd on another Mac.") }
        let who = name?(hostID) ?? "that Mac"
        let stage: FleetUpdateStatus.Stage
        switch reach(hostID) {
        case .notInFleet: return (FleetProtocol.Code.invalid, "That Mac isn't in the fleet.")
        case .old: return ("unsupported", "\(who) runs a Shepherd that can't be updated from here. Update it there.")
        case .offline: stage = .waitingToWake
        case .ready: stage = .checking
        }
        let now = nowMilliseconds
        let job = Job(status: FleetUpdateStatus(hostID: hostID, stage: stage, when: when, startedAt: now, updatedAt: now))
        jobs[hostID] = job
        job.task = Task { [weak self, weak job] in
            guard let self, let job else { return }
            await self.run(job)
        }
        onChange?()
        return nil
    }

    /// Stops the job on `hostID`, or puts away its result. What the Mac holds (an offer waiting for its threads, a download) is let go, if it answers.
    func cancel(_ hostID: UUID) {
        guard let job = jobs.removeValue(forKey: hostID) else { return }
        job.task?.cancel()
        onChange?()
        guard job.finishedAt == nil, let reach, case .ready(let send) = reach(hostID) else { return }
        Task { _ = try? await send(.cancel) }
    }

    /// The host stops: nothing continues.
    func stop() {
        for job in jobs.values { job.task?.cancel() }
        jobs = [:]
    }

    private var nowMilliseconds: Double { (clock().timeIntervalSince1970 * 1000).rounded() }

    // MARK: The job

    private struct Progress {
        var installAsked = false
        var installRequests = 0
        /// The Mac said it is installing, or went away after it began to download.
        var leaving = false
        var checks = 0
        /// Times the Mac was asked to look again because its updater hadn't begun.
        var lookAgain = 0
        var restarts = 0
        var failures = 0
        var wentAwayAt: Date?
        /// The install waits for the Mac's threads, and no installer has it yet (an app that quits now was closed, not installing).
        var waitingForThreads = false
        var lastLook: Date?

        /// A look at the Mac: more than `suspension` since the last one means this host slept, and that time wasn't seen.
        mutating func look(at now: Date) {
            if let last = lastLook, now.timeIntervalSince(last) > FleetUpdates.suspension {
                phaseSince = now
                if wentAwayAt != nil { wentAwayAt = now }
            }
            lastLook = now
        }
        /// What the Mac last said it was doing, and since when: a Mac that began to install and says the same for `relaunchPatience` is stuck.
        var phase: HostUpdateStatus.Phase?
        var phaseSince = Date.distantFuture
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in queue.async { continuation.resume(returning: body()) } }
    }

    private func run(_ job: Job) async {
        var progress = Progress()
        let began = clock()
        let hostID = job.status.hostID
        while !Task.isCancelled {
            if clock().timeIntervalSince(began) > maxAge {
                return await end(job, .failed, "Gave up after \(Int(maxAge / 3600)) hours. Start it again to try once more.")
            }
            progress.look(at: clock())
            let reached = await onQueue { self.reach?(hostID) ?? .notInFleet }
            switch reached {
            case .notInFleet:
                return await end(job, .failed, "That Mac left the fleet.")
            case .old:
                return await end(job, .failed, "That Mac runs a Shepherd that can't be updated from here.")
            case .offline:
                let wentAway = progress.wentAwayAt ?? clock()
                progress.wentAwayAt = wentAway
                if progress.leaving, clock().timeIntervalSince(wentAway) > relaunchPatience {
                    let who = await onQueue { self.name?(hostID) ?? "That Mac" }
                    return await end(job, .failed, "\(who) didn't come back after it began to update.")
                }
                await set(job, progress.leaving ? .relaunching : .waitingToWake)
            case .ready(let send):
                progress.wentAwayAt = nil
                do {
                    let request: RemoteHostUpdateRequest = progress.checks == 0 ? .check : .status
                    let status = try await send(request)
                    progress.checks += 1
                    progress.failures = 0
                    if try await advance(job, status, &progress, send: send) { return }
                } catch is CancellationError {
                    return
                } catch RemoteHostClientError.rejected(let code, let message) where code == "unsupported" {
                    return await end(job, .failed, message)
                } catch {
                    // The link dropped, or the Mac was busy or slow: look again. A Mac that went away after it was asked to install is relaunching,
                    // unless the install is still held for its threads: no installer has it, so that is a Mac to look at again, not one that left.
                    // This host may have slept during the request, so its clock is read first, or the time asleep counts against the Mac.
                    progress.look(at: clock())
                    progress.failures += 1
                    if Self.droppedLink(error), progress.installAsked, !progress.waitingForThreads {
                        progress.leaving = true
                        progress.wentAwayAt = progress.wentAwayAt ?? clock()
                        await set(job, .relaunching)
                    } else if progress.failures > 8, !progress.leaving {
                        return await end(job, .failed, "\(Self.words(error)) Check that it is awake and try again.")
                    }
                    if await stalledOut(job, progress) { return }
                }
            }
            try? await Task.sleep(for: interval)
        }
    }

    /// Reads the Mac's status and moves the job; true when the job has ended.
    private func advance(_ job: Job, _ first: HostUpdateStatus, _ progress: inout Progress, send: @escaping @Sendable (RemoteHostUpdateRequest) async throws -> HostUpdateStatus) async throws -> Bool {
        var status = first
        let hostID = job.status.hostID
        progress.look(at: clock())
        if status.phase != progress.phase { (progress.phase, progress.phaseSince) = (status.phase, clock()) }
        let build = status.build
        if job.status.fromBuild == nil, !build.isEmpty { await mutate(job) { $0.fromBuild = build } }
        let from = job.status.fromBuild
        // Back on another build: done, whatever the updater says of itself just after it relaunched.
        if progress.installAsked, let from, !status.build.isEmpty, status.build != from {
            await end(job, .updated, nil)
            await onQueue { self.onUpdated?(hostID) }
            return true
        }
        let (threads, offered) = (status.busyThreads, status.offeredVersion)
        if threads != nil || offered != nil {
            await mutate(job) { $0.threads = threads; $0.offered = offered ?? $0.offered }
        }
        let when = job.status.when
        // Read just now: a Mac that finished while this host slept is caught above, before it is called stuck.
        if await stalledOut(job, progress) { return true }
        let who = await onQueue { self.name?(hostID) ?? "That Mac" }
        switch status.phase {
        case .unsupported:
            let message = status.error == SessionServer.hostUpdateWindowClosed ? "Open Shepherd on \(who) to update it." : (status.error ?? "\(who) can't update itself.")
            // Seen handed over: the wait is over for good, so a host that restarts after this (and forgets) can't turn it into a closed app.
            if status.installHandedOff == true { progress.waitingForThreads = false }
            if progress.waitingForThreads, status.installHandedOff == false {
                // The host says it sent no install to the updater (it holds it for threads that work, or its wait is gone): the app that held the
                // offer was closed, not installing. Let the wait go. A host that says nothing (an older one) isn't asked: the build is looked at.
                _ = try? await send(.cancel)
                await end(job, .needsApp, message)
                return true
            }
            if progress.leaving || progress.installAsked {
                // The host is up before its app is (or while it quits to install, once it sent the install it was given or held for idle
                // threads): the app comes back with it, or after a look at the build above.
                progress.leaving = true
                await set(job, .relaunching)
                return false
            }
            await end(job, .needsApp, message)
            return true
        case .checking:
            await set(job, .checking)
        case .idle, .upToDate:
            if progress.installAsked {
                // It came back on the same build with nothing under way: what was asked was lost with the app that held it.
                return await askAgain(job, &progress, "\(who) came back on the same build.")
            } else if status.phase == .upToDate {
                await end(job, .upToDate, "\(who)'s update feed offers nothing newer than it runs.")
                return true
            } else {
                // The check hasn't begun (the updater was busy): ask again, a few times.
                progress.lookAgain += 1
                guard progress.lookAgain <= 4 else {
                    await end(job, .failed, status.error ?? "\(who) couldn't ask its update feed.")
                    return true
                }
                progress.checks = 0
                await set(job, .checking)
            }
        case .available:
            if status.waitingForIdle {
                progress.installAsked = true
                progress.waitingForThreads = true
                await set(job, .waitingForThreads)
            } else if status.canInstall, let offer = status.offerID, progress.installRequests < Self.installAttempts {
                // Asked, or asked again: a Mac that lost what it held (its host restarted) still has the offer.
                progress.installRequests += 1
                progress.installAsked = true
                // Asked to wait: until a status says the install is under way, the host may or may not have the offer held, so the link dropping is not a relaunch.
                if when == .idle { progress.waitingForThreads = true }
                status = try await send(when == .idle ? .installWhenIdle(offerID: offer, authorized: true) : .install(offerID: offer, authorized: true))
                // The same offer, still open to install: the Mac may not have begun yet. Look again at the next poll, not at once.
                if status.phase == .available, status.canInstall, status.offerID == offer { return false }
                return try await advance(job, status, &progress, send: send)
            } else if let error = status.error {
                // The Mac can't install now (a question waits for an answer, a Project runs) and said why.
                await end(job, .failed, error)
                return true
            } else if progress.installRequests >= Self.installAttempts {
                // It took the install each time and the offer is still there: nothing started.
                await end(job, .failed, "\(who) didn't start installing the update. Try again.")
                return true
            } else if progress.waitingForThreads {
                // The app holds the offer but this host's wait for the threads is gone (its host restarted): look at the offer again.
                return await askAgain(job, &progress, "\(who) restarted while waiting for its threads and lost the update. Try again.")
            } else {
                await set(job, .checking)
            }
        case .downloading:
            progress.installAsked = true
            progress.waitingForThreads = false
            progress.leaving = true
            await set(job, .downloading)
        case .installing:
            progress.installAsked = true
            progress.waitingForThreads = false
            progress.leaving = true
            await set(job, .installing)
        case .failed:
            await end(job, .failed, status.error ?? "\(who) couldn't update.")
            return true
        }
        return false
    }

    /// What was asked was lost with the app or host that held it: ask again from the check, a few times, then say so.
    private func askAgain(_ job: Job, _ progress: inout Progress, _ lost: String) async -> Bool {
        progress.restarts += 1
        guard progress.restarts <= Self.restartAttempts else {
            await end(job, .failed, lost)
            return true
        }
        progress = Progress(restarts: progress.restarts)
        await set(job, .checking)
        return false
    }

    /// A Mac that began to install and, as last seen, says the same thing for `relaunchPatience` is stuck. Called after it was asked just now.
    private func stalledOut(_ job: Job, _ progress: Progress) async -> Bool {
        guard progress.leaving, clock().timeIntervalSince(progress.phaseSince) > relaunchPatience else { return false }
        let who = await onQueue { self.name?(job.status.hostID) ?? "That Mac" }
        await end(job, .failed, "\(who) didn't finish updating. Open Shepherd there and try again.")
        return true
    }

    // MARK: Status changes

    private func mutate(_ job: Job, _ change: @escaping @Sendable (inout FleetUpdateStatus) -> Void) async {
        await onQueue { [self] in
            let before = job.status
            change(&job.status)
            if job.status != before {
                job.status.updatedAt = nowMilliseconds
                onChange?()
            }
        }
    }

    private func set(_ job: Job, _ stage: FleetUpdateStatus.Stage) async {
        await onQueue { [self] in
            guard job.finishedAt == nil, job.status.stage != stage else { return }
            job.status.stage = stage
            job.status.updatedAt = nowMilliseconds
            onChange?()
        }
    }

    private func end(_ job: Job, _ stage: FleetUpdateStatus.Stage, _ message: String?) async {
        await onQueue { [self] in
            guard job.finishedAt == nil, !(job.task?.isCancelled ?? false) else { return }
            job.status.stage = stage
            job.status.message = message
            job.status.updatedAt = nowMilliseconds
            job.finishedAt = clock()
            onChange?()
        }
    }

    private static func droppedLink(_ error: Error) -> Bool {
        switch error {
        case RemoteHostClientError.disconnected, RemoteHostClientError.outcomeUnknown: true
        default: false
        }
    }

    private static func words(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return "The Mac didn't answer."
    }
}
