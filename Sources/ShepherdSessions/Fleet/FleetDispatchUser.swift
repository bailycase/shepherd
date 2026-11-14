import Foundation
import ShepherdCore
import ShepherdProtocol

/// What the person does about dispatches from this Mac's app (`FleetAction.sendThread`, `retryDispatch`,
/// `cancelDispatch`; server queue): start a thread on the Mac Auto picks, and decide what becomes of a dispatch that
/// waits, is held or wasn't sent. A thread the person starts is a `userThread` dispatch: no parent thread, its result
/// is the thread, and it shows in the Dispatches log as "sent by you".
extension FleetDispatch {
    /// The code a first placement answers with when the work stays on this Mac: not a failure, the app starts the thread.
    static let keptHere = "kept_here"

    /// Sends a thread from New thread. Answers once the target took it (or was found unable to), at once when it waits, or
    /// with `nil` when the work stays on this Mac (named or chosen by Auto), which the app starts itself as it always did.
    func dispatchUserThread(_ thread: FleetUserThread, reply: @escaping (Result<FleetDispatchRecord?, FleetDispatchRefusal>) -> Void) {
        let id = thread.dispatchID
        // A retry of a send that already went answers what it made.
        if let existing = outbound[id] { return reply(.success(existing.summary)) }
        let task = thread.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.utf8.count <= FleetDispatchProtocol.maxTaskBytes else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or longer than \(FleetDispatchProtocol.maxTaskBytes / 1024) KiB.")))
        }
        let requested = FleetPlacement.isAuto(thread.host) ? nil : thread.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Named for this very Mac: nothing to send, unless the provider of its model is limited and the thread has to wait for that: a
        // dispatch to this Mac holds it as it would hold one to any other.
        let limited = FleetPlacement.provider(ofModel: thread.model?.fleetNonEmpty ?? host.defaultModel()).flatMap { pressure.limitRemaining($0) } != nil
        if let requested, requested.lowercased() == hostName().lowercased() || requested.lowercased() == hostID.uuidString.lowercased(), !limited {
            return reply(.success(nil))
        }
        // A space that isn't one of this Mac's, or whose folder is no repository another Mac could find, stays here when Auto chose it and is
        // refused when a Mac was named.
        func unsendable(_ message: String) {
            if requested == nil { reply(.success(nil)) } else { reply(.failure(.init(code: FleetDispatchCode.repoMissing, message: message))) }
        }
        guard let space = host.state().spaces.first(where: { $0.id == thread.spaceID }) else {
            return unsendable("This space is gone.")
        }
        // Where it begins is what the same form would have done here: a new worktree from a base (the project's, when the form says nothing), a
        // new worktree on a branch that exists, or the space's own checkout.
        let start = thread.start ?? FleetThreadStart(place: .newWorktree, base: space.worktreeBase?.fleetNonEmpty)
        var record = FleetDispatchRecord(
            id: id, kind: .userThread, parentHostID: hostID, parentHostName: hostName(), requestedHost: requested, state: .placing,
            title: Self.title(thread.title, task: task), task: task, repoKey: space.repoKey ?? "", model: thread.model?.fleetNonEmpty,
            thinking: thread.thinking?.fleetNonEmpty, spaceID: space.id, start: start, fixes: thread.fixes, createdAt: now)
        record.updatedAt = record.createdAt
        outbound[id] = record
        firstPlacements.insert(id)
        save()
        // The commit it starts at is pinned: the base's, the branch's, or the checkout's HEAD; only the last carries the checkout's edits,
        // unpushed commits and ignored files as a snapshot (a local thread there would see them; one on a base or a branch would not). The pin,
        // the origin and the key are read off the queue (git runs).
        let folder = (space.path as NSString).expandingTildeInPath
        let known = space.repoKey
        let prefetching = start.place == .checkout && indexService != nil && (host.settings()?.fleetUncommitted ?? .sendThem) == .sendThem
        Task.detached { [weak self] in
            var rev = "HEAD"
            switch start.place {
            case .checkout: break
            case .newWorktree: rev = start.base?.fleetNonEmpty ?? "HEAD"
            case .existingBranch:
                let name = start.branch?.fleetNonEmpty ?? ""
                let remote = name.hasPrefix("origin/")
                let candidates = remote ? ["refs/remotes/" + name] : ["refs/heads/" + name, "refs/remotes/origin/" + name]
                rev = candidates.first { FleetDispatchGit.run(["show-ref", "--verify", "--quiet", $0], in: folder)?.status == 0 } ?? name
            }
            let pinned = FleetDispatchGit.pin(cwd: folder, rev: rev, prefetchingTree: prefetching)
            let origin = FleetDispatchGit.origin(cwd: folder)
            // A repository with no origin is named by its first commit: another Mac can't clone it, so it is sent the repository itself.
            let key = known ?? FleetRepoKeys.localKey(folder: folder)
            self?.queue.async {
                guard let self, self.outbound[id] != nil else { return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "No such dispatch."))) }
                guard let key, case .success(let pin) = pinned else {
                    self.outbound[id] = nil
                    self.firstPlacements.remove(id)
                    self.save()
                    if case .failure(.unknownRevision) = pinned {
                        return unsendable("\(start.place == .existingBranch ? start.branch ?? "That branch" : start.base ?? "That base") isn't in this Mac's checkout.")
                    }
                    return unsendable("This space's folder isn't a git repository with commits, so no other Mac can find it.")
                }
                self.pins[id] = pin
                self.outbound[id]?.repoKey = key
                self.outbound[id]?.commitSHA = pin.sha
                if start.place == .checkout { self.outbound[id]?.subdir = pin.subdir }
                self.outbound[id]?.origin = origin
                self.save()
                self.place(id) { [weak self] result in
                    self?.firstPlacements.remove(id)
                    switch result {
                    case .success(let record): reply(.success(record.summary))
                    case .failure(let refusal) where refusal.code == Self.keptHere: reply(.success(nil))
                    case .failure(let refusal): reply(.failure(refusal))
                    }
                }
            }
        }
    }

    /// Sends a dispatch that waits, is held or wasn't sent, to `target` (a Mac's id, this one included) or as it was
    /// asked. A record that failed starts again under a new id: the Mac that refused it may hold its copy of the first
    /// try, which would answer for the second.
    func retry(_ id: UUID, host target: UUID?, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard var record = outbound[id] else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "This Mac has no such dispatch.")))
        }
        guard [.waitingRoom, .waitingWake, .heldLimit, .heldRestart, .failed].contains(record.state), !placing.contains(id), !sending.contains(id) else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That dispatch isn't waiting for anything (it is \(record.state.rawValue)).")))
        }
        if record.state == .failed {
            outbound[id] = nil
            record.id = UUID()
        }
        record.state = .placing
        record.failure = nil
        record.failureDetail = nil
        record.targetHostID = nil
        record.targetHostName = nil
        record.remoteAgentID = nil
        record.reasonCodes = []
        record.activity = nil
        if let target { record.requestedHost = target.uuidString }
        record.updatedAt = now
        let next = record.id
        outbound[next] = record
        save()
        guard canStart(record) else {
            outbound[next]?.state = .heldLimit
            save()
            return reply(.success((outbound[next] ?? record).summary))
        }
        place(next) { result in reply(result.map(\.summary)) }
    }
}
