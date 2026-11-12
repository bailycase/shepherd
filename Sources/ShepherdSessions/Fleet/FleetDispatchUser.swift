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
        guard membership() else {
            return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil)))
        }
        let id = thread.dispatchID
        // A retry of a send that already went answers what it made.
        if let existing = outbound[id] { return reply(.success(existing.summary)) }
        let task = thread.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.utf8.count <= FleetDispatchProtocol.maxTaskBytes else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or longer than \(FleetDispatchProtocol.maxTaskBytes / 1024) KiB.")))
        }
        let requested = FleetPlacement.isAuto(thread.host) ? nil : thread.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Named for this very Mac: nothing to send.
        if let requested, requested.lowercased() == hostName().lowercased() || requested.lowercased() == hostID.uuidString.lowercased() {
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
        var record = FleetDispatchRecord(
            id: id, kind: .userThread, parentHostID: hostID, parentHostName: hostName(), requestedHost: requested, state: .placing,
            title: Self.title(thread.title, task: task), task: task, repoKey: space.repoKey ?? "", model: thread.model?.fleetNonEmpty,
            thinking: thread.thinking?.fleetNonEmpty, spaceID: space.id, createdAt: now)
        record.updatedAt = record.createdAt
        outbound[id] = record
        firstPlacements.insert(id)
        save()
        // Like a thread's dispatch, it starts from what this Mac has: the space's checkout at its commit, with its edits, unpushed commits and
        // ignored files as the snapshot carries them. The pin, the origin and the key are read off the queue (git runs).
        let folder = (space.path as NSString).expandingTildeInPath
        let known = space.repoKey
        let prefetching = indexService != nil && (host.settings()?.fleetUncommitted ?? .sendThem) == .sendThem
        Task.detached { [weak self] in
            let pinned = FleetDispatchGit.pin(cwd: folder, prefetchingTree: prefetching)
            let origin = FleetDispatchGit.origin(cwd: folder)
            // A repository with no origin is named by its first commit: another Mac can't clone it, so it is sent the repository itself.
            let key = known ?? FleetRepoKeys.localKey(folder: folder)
            self?.queue.async {
                guard let self, self.outbound[id] != nil else { return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "No such dispatch."))) }
                guard let key, case .success(let pin) = pinned else {
                    self.outbound[id] = nil
                    self.firstPlacements.remove(id)
                    self.save()
                    return unsendable("This space's folder isn't a git repository with commits, so no other Mac can find it.")
                }
                self.pins[id] = pin
                self.outbound[id]?.repoKey = key
                self.outbound[id]?.commitSHA = pin.sha
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
        guard membership() else { return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil))) }
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
