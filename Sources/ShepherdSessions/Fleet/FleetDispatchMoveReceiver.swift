import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// Moving a thread to another Mac, the receiving side (`FleetMoveWire.swift`). The create, the snapshot and the checks are a dispatch's:
/// this Mac finds or makes the checkout, builds the worktree on the thread's branch and holds it (`FleetMoveStage.staged`). No thread
/// exists until the sending Mac says it handed over (`FleetDispatchControl.commit`), and then the thread is made with the sender's own id,
/// its conversation installed where pi will find it, and pi resumes it there. A restart in between keeps what was built; the sender
/// decides what becomes of it (a commit, or a cancel that takes it away). Server queue.
extension FleetDispatch {
    /// The checks a move's create has to pass, or the refusal.
    func moveCreateProblem(_ create: FleetDispatchCreate) -> FleetDispatchRefusal? {
        guard let handoff = create.move, handoff.isValid, create.commitSHA != nil, let header = create.snapshot, header.isValid else {
            return .init(code: FleetDispatchCode.invalid, message: "A move carries the thread, its commit and a snapshot of its worktree.")
        }
        // One live copy: this Mac refuses a thread it already holds.
        if let existing = host.state().agents.first(where: { $0.id == handoff.agentID }), existing.movedTo == nil {
            return .init(code: FleetDispatchCode.alreadyHere, message: "This Mac already runs that thread.")
        }
        return nil
    }

    /// The worktree is built and passed the sender's digest: it waits for the sender (`staged`), and the sender is told.
    func staged(_ id: UUID, space: Space, worktree: String, branch: String, madeRef: Bool) {
        dropSnapshot(id)
        guard var entry = inbound[id], entry.record.state == .preparing, entry.record.kind == .move else {
            // Cancelled while it was being built: what it made goes.
            Task.detached { FleetSnapshotApply.discard(repo: space.path, worktree: worktree, branch: branch, ref: madeRef ? id : nil) }
            return
        }
        entry.worktree = worktree
        entry.spaceID = space.id
        entry.madeRef = madeRef
        entry.record.branch = branch
        entry.record.clone = nil
        entry.record.move?.stage = .staged
        entry.record.updatedAt = now
        entry.unsent = true
        inbound[id] = entry
        save()
        pushPending()
    }

    /// `fleetDispatchControl(.commit)`: the sender wrote its tombstone, so the thread starts here. Answers once it is started (the record,
    /// `done` at `moved`), or refuses and leaves no thread. A repeat answers the same.
    func commitInbound(_ id: UUID, from sender: UUID, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard var entry = inbound[id], entry.record.kind == .move, entry.record.parentHostID == sender, entry.handoff != nil else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no such move.")))
        }
        switch entry.record.move?.stage {
        case .moved?:
            reply(.success(entry.record))
        case .starting?:
            commitWaiters[id, default: []].append(reply)
        case .staged?:
            commitWaiters[id, default: []].append(reply)
            entry.record.move?.stage = .starting
            entry.record.updatedAt = now
            inbound[id] = entry
            save()
            startMoved(id)
        default:
            reply(.failure(.init(code: "not_staged", message: "That move hasn't arrived here yet (it is \(entry.record.state.rawValue)).")))
        }
    }

    private func startMoved(_ id: UUID) {
        guard let entry = inbound[id], let handoff = entry.handoff, let spaceID = entry.spaceID, let worktree = entry.worktree,
              let space = host.state().spaces.first(where: { $0.id == spaceID }) else {
            return movedStarted(id, .failure(RemoteCreateAgentError("This Mac no longer holds what the move built.")))
        }
        var request = RemoteCreateAgentRequest(
            spaceID: space.id, cwd: space.path, model: handoff.model, thinking: handoff.thinking.flatMap(ThinkingLevel.init(rawValue:)), initialPrompt: nil,
            worktreeBranch: entry.record.branch, worktreeBase: handoff.worktreeBase)
        request.serviceTier = handoff.serviceTier.flatMap(ServiceTier.init(rawValue:))
        request.agentID = handoff.agentID
        request.piSessionID = handoff.sessionID == handoff.agentID.rawValue ? nil : handoff.sessionID
        request.name = handoff.name
        request.worktreePath = worktree
        request.subdirectory = entry.record.subdir
        request.dispatchedFrom = handoff.dispatchedFrom
        let moved = MovedFrom(hostID: entry.record.parentHostID, hostName: entry.record.parentHostName, at: handoff.movedAt, moveID: id,
                              branch: entry.record.branch, uncommittedFiles: handoff.uncommittedFiles)
        request.moved = RemoteCreateAgentRequest.Moved(
            transcript: entry.transcript.map { blobs.url($0.hash) }, from: moved, nameIsFinal: handoff.nameIsFinal, pushMuted: handoff.pushMuted,
            lastActiveAt: handoff.lastActiveAt, unpushedCommits: handoff.unpushedCommits, note: Self.moveNote(moved, to: hostName()))
        let create = host.createThread
        Task.detached { [weak self] in
            let outcome = await create(request)
            self?.queue.async { self?.movedStarted(id, outcome) }
        }
    }

    private func movedStarted(_ id: UUID, _ outcome: Result<AgentID, RemoteCreateAgentError>) {
        let waiting = commitWaiters.removeValue(forKey: id) ?? []
        guard var entry = inbound[id] else { return waiting.forEach { $0(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "No such move."))) } }
        switch outcome {
        case .success(let agent):
            entry.record.state = .done
            entry.record.move?.stage = .moved
            entry.record.move?.movedAt = now
            entry.record.remoteAgentID = agent
            entry.record.updatedAt = now
            entry.unsent = false
            inbound[id] = entry
            // Work the thread was sent here for goes on being reported to whoever sent it, from this Mac now.
            if var dispatched = entry.handoff?.dispatch, dispatched.state.isLive, inbound[dispatched.id] == nil {
                dispatched.targetHostID = hostID
                dispatched.targetHostName = hostName()
                dispatched.remoteAgentID = agent
                dispatched.state = .running
                dispatched.movedOn = nil
                dispatched.updatedAt = now
                inbound[dispatched.id] = Inbound(record: dispatched, expectsResult: true, startedWorking: false, unsent: true,
                                                 worktree: entry.worktree, acceptedAt: now)
            }
            save()
            waiting.forEach { $0(.success(entry.record)) }
            pushPending()
        case .failure(let error):
            // No thread started here: the sender takes its copy back, and what this Mac built goes.
            entry.record.state = .failed
            entry.record.failure = FleetDispatchCode.snapshotFailed
            entry.record.failureDetail = String(error.message.prefix(300))
            entry.record.updatedAt = now
            entry.unsent = false
            inbound[id] = entry
            discardStaged(entry)
            save()
            waiting.forEach { $0(.failure(.init(code: FleetDispatchCode.snapshotFailed, message: error.message))) }
        }
    }

    /// Takes away what a move built here and never started: the worktree, its branch and the fleet ref.
    func discardStaged(_ entry: Inbound) {
        guard entry.record.kind == .move, let spaceID = entry.spaceID, let space = host.state().spaces.first(where: { $0.id == spaceID }),
              let branch = entry.record.branch else { return }
        let (repo, worktree, ref) = (space.path, entry.worktree, entry.madeRef ? entry.record.id : nil)
        Task.detached { FleetSnapshotApply.discard(repo: repo, worktree: worktree, branch: branch, ref: ref) }
    }

    /// "Moved to Mac mini · 14:02 · branch perf/checkout-ci, 3 uncommitted files": the line the thread draws where it moved, and what the agent
    /// reads of it (pi keeps it as a message).
    static func moveNote(_ from: MovedFrom, to name: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        let time = formatter.string(from: Date(timeIntervalSince1970: from.at / 1000))
        let files = from.uncommittedFiles == 0 ? "nothing uncommitted"
            : "\(from.uncommittedFiles) uncommitted \(from.uncommittedFiles == 1 ? "file" : "files")"
        let branch = from.branch.map { "branch \($0), " } ?? ""
        return "Moved to \(name) · \(time) · \(branch)\(files)"
    }
}
