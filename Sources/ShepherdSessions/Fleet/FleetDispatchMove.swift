import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// What a move reads of a thread on the Mac it leaves (`FleetDispatchHost.moveSource`).
struct FleetMoveSource: Sendable {
    /// The pi session the thread is in now.
    var sessionID: String
    /// The session file, when pi has written one.
    var transcript: URL?
    /// The folder pi runs in: the thread's worktree, or its subfolder.
    var cwd: String
}

/// Moving a thread to another Mac (`fleet.move.v1`, `FleetMoveWire.swift`), the sending side. A move is a dispatch of `kind: .move`
/// whose snapshot is the thread's worktree and whose transcript is its conversation. The thread's pi is stopped for it, the other Mac
/// builds the worktree and holds it (`FleetMoveStage.staged`), and only then does this Mac write its tombstone (`Agent.movedTo`) and
/// tell the other to start the thread. Until the tombstone is written this Mac's copy is the thread and any failure leaves it so; once
/// it is, no code path starts it again. Every piece of state here belongs to the server queue.
extension FleetDispatch {
    /// Whether a move has `agent` and hasn't handed it over: its pi starts no more, and nothing is sent to it.
    func isMoving(_ agent: AgentID) -> Bool {
        outbound.values.contains { $0.kind == .move && $0.move?.agentID == agent && $0.state.isLive && $0.move?.committed != true }
    }

    /// The move of `agent` that is under way, if any.
    func liveMove(of agent: AgentID) -> FleetDispatchRecord? {
        outbound.values.first { $0.kind == .move && $0.move?.agentID == agent && $0.state.isLive }
    }

    /// Why `agent` can't move, or nil: a project's coordinator or worker, a design's agent and an automation run belong to this Mac.
    static func moveProblem(for agent: Agent, in state: ShepherdState, unattended: Set<AgentID>) -> String? {
        if agent.movedTo != nil { return "This thread already moved to another Mac." }
        if state.isProjectWorker(agent.id) || state.isProjectCoordinator(agent) { return "A project's threads stay on the Mac that runs the project." }
        if state.isDesignAgent(agent) { return "A design's agent stays on this Mac." }
        if unattended.contains(agent.id) { return "An automation run stays on this Mac." }
        return nil
    }

    // MARK: Asking

    /// `FleetAction.moveThread`. Answers once the move is accepted (the record, `waitingTurn` or `preparing`) or refused; what follows is read
    /// from the record. Idempotent on the move id.
    func moveThread(_ request: FleetMoveRequest, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        if let existing = outbound[request.moveID] { return reply(.success(existing.summary)) }
        func refuse(_ code: String, _ message: String, _ detail: String? = nil) { reply(.failure(.init(code: code, message: message, detail: detail))) }
        let state = host.state()
        guard let agent = state.agents.first(where: { $0.id == request.agentID }) else {
            return refuse(FleetDispatchCode.moveRefused, "That thread isn't on this Mac.")
        }
        if let problem = Self.moveProblem(for: agent, in: state, unattended: host.unattended()) { return refuse(FleetDispatchCode.moveRefused, problem) }
        guard liveMove(of: agent.id) == nil else { return refuse(FleetDispatchCode.moveRefused, "This thread is already moving.") }
        guard !outbound.values.contains(where: { $0.kind == .agentDispatch && $0.parentAgentID == agent.id && $0.state.isLive }) else {
            return refuse(FleetDispatchCode.hasDispatches, "This thread has work running on other Macs. Wait for it, or stop it, before moving the thread.")
        }
        guard let space = state.spaces.first(where: { $0.id == agent.spaceID }), !space.hidden || space.holdsThreads else {
            return refuse(FleetDispatchCode.repoMissing, "This thread's folder isn't a repository another Mac can find.")
        }
        // The Mac, by id or name, and everything about it that a move needs before this thread is touched.
        let probe = FleetDispatchRecord(parentHostID: hostID, parentHostName: hostName(), title: "", task: "", repoKey: space.repoKey ?? "", spaceID: space.id, createdAt: now)
        let macs = placementMacs(for: probe)
        guard let target = FleetPlacement.named(request.host, in: macs) else { return refuse(FleetDispatchCode.noSuchHost, "No Mac named \(request.host) is in the fleet.", request.host) }
        guard !target.isLocal else { return refuse(FleetDispatchCode.moveRefused, "That thread already runs on this Mac.") }
        guard target.connected else { return refuse(FleetDispatchCode.hostNotReady, "\(target.name) isn't answering. Move the thread when it is back.", "unreachable") }
        guard capabilities(of: target.hostID)?.contains(RemoteProtocol.fleetMoveCapability) == true else {
            return refuse(FleetDispatchCode.targetOld, "\(target.name) runs a Shepherd that can't take a thread yet. Update it.")
        }
        if let problem = target.problems(needsXcode: needsXcode(probe)).first {
            return refuse(FleetDispatchCode.hostNotReady, "\(target.name) isn't ready: \(problem) isn't installed.", problem)
        }
        // A thread another Mac sent work to follows its sender, which has to know how.
        if let from = agent.dispatchedFrom, from.hostID != hostID, from.hostID != target.hostID,
           let senderCapabilities = capabilities(of: from.hostID), !senderCapabilities.contains(RemoteProtocol.fleetMoveCapability) {
            return refuse(FleetDispatchCode.senderOld, "\(from.hostName) sent this thread and runs a Shepherd that can't follow it to another Mac. Update it.")
        }
        var record = FleetDispatchRecord(
            id: request.moveID, kind: .move, parentHostID: hostID, parentHostName: hostName(), targetHostID: target.hostID, targetHostName: target.name,
            requestedHost: target.hostID.uuidString, state: .waitingTurn, title: agent.name, task: "", repoKey: space.repoKey ?? "", spaceID: space.id,
            move: FleetMoveInfo(agentID: agent.id, stage: .waitingTurn, sessionID: agent.effectivePiSessionID, whenDone: request.when == .whenDone), createdAt: now)
        record.updatedAt = record.createdAt
        outbound[request.moveID] = record
        save()
        reply(.success(record.summary))
        advanceMove(request.moveID)
    }

    /// What the link to a Mac says it can do; nil while it isn't up. Tests stand in for a Mac on an older Shepherd with `capabilityOverride`.
    func capabilities(of peer: UUID) -> Set<String>? {
        capabilityOverride?(peer) ?? client(peer)?.capabilities
    }

    /// The sender's record of work this Mac runs in `agent`, while it hasn't returned its result.
    func liveInboundDispatch(of agent: AgentID) -> Inbound? {
        inbound.values.first { $0.record.remoteAgentID == agent && $0.record.state.isLive && $0.record.kind != .move }
    }

    // MARK: Waiting for the turn, stopping it

    /// Takes a move as far as it can go now: waits for a running turn when it was asked to ("Move when it's done"), otherwise stops the
    /// turn and the thread's pi.
    func advanceMove(_ id: UUID) {
        guard var record = outbound[id], record.kind == .move, var info = record.move, record.state.isLive, !info.committed else { return }
        guard let agent = host.state().agents.first(where: { $0.id == info.agentID }) else { return failMove(id, FleetDispatchCode.moveRefused, "The thread is gone.") }
        let running = agent.status == .working || agent.status == .blocked
        switch info.stage {
        case .waitingTurn:
            if running && info.whenDone { return }
            // A dispatched thread's own result isn't sent for the turn that is cut short here: the sender is told it moved on instead.
            for key in inbound.keys where inbound[key]?.record.remoteAgentID == agent.id && inbound[key]?.record.kind != .move { inbound[key]?.expectsResult = false }
            info.stage = .stopping
            stopStarted[id] = .now
            record.move = info
            record.state = .preparing
            record.updatedAt = now
            outbound[id] = record
            save()
            if running { host.stopThread(agent.id) }
            continueStop(id)
        case .stopping:
            continueStop(id)
        default:
            return
        }
    }

    /// The turn ended, or its grace ran out: the thread's pi stops and the move reads what it holds.
    func continueStop(_ id: UUID) {
        guard let record = outbound[id], record.kind == .move, record.move?.stage == .stopping, !placing.contains(id),
              let agent = host.state().agents.first(where: { $0.id == record.move?.agentID }) else { return }
        // The grace is real time: the clock this engine stamps records with is a test's to move.
        if agent.status == .working || agent.status == .blocked, let began = stopStarted[id], ContinuousClock.now - began < .seconds(moveStopGrace) {
            scheduleEvaluation()
            return
        }
        placing.insert(id)
        let stop = host.stopPiForMove
        let agentID = agent.id
        Task.detached { [weak self] in
            await stop(agentID)
            self?.queue.async { self?.prepareMove(id) }
        }
    }

    /// A thread's status changed (server queue): a move waiting for the turn goes on when it ends; one that stopped it goes on at once.
    func moveAgentStatusChanged(_ agentID: AgentID, _ status: AgentStatus) {
        guard status != .working, status != .blocked, let record = liveMove(of: agentID), record.move?.committed != true else { return }
        advanceMove(record.id)
    }

    // MARK: Reading what goes

    /// The thread's pi is stopped: its commit, its checkout's changes and its conversation are read (off the queue), and the move is placed.
    private func prepareMove(_ id: UUID) {
        placing.remove(id)
        guard let record = outbound[id], record.kind == .move, var info = record.move, record.state.isLive, !info.committed else { return }
        let state = host.state()
        guard let agent = state.agents.first(where: { $0.id == info.agentID }), let source = host.moveSource(agent.id),
              let space = state.spaces.first(where: { $0.id == agent.spaceID }) else {
            return failMove(id, FleetDispatchCode.moveRefused, "The thread is gone.")
        }
        info.sessionID = source.sessionID
        let (folder, known, cwd) = (space.path, space.repoKey, (source.cwd as NSString).expandingTildeInPath)
        let prefetching = indexService != nil
        let outgoing = directory.appendingPathComponent("outgoing", isDirectory: true)
        placing.insert(id)
        Task.detached { [weak self] in
            let pinned = FleetDispatchGit.pin(cwd: cwd, prefetchingTree: prefetching)
            let origin = FleetDispatchGit.origin(cwd: (folder as NSString).expandingTildeInPath)
            let key = known ?? FleetRepoKeys.localKey(folder: (folder as NSString).expandingTildeInPath)
            let branch = FleetDispatchGit.run(["branch", "--show-current"], in: cwd)
            let status = FleetDispatchGit.run(["status", "--porcelain", "--untracked-files=all"], in: cwd)
            let unpushed = FleetDispatchGit.run(["rev-list", "--count", "HEAD", "--not", "--remotes"], in: cwd)
            var copy: (ref: FleetBlobRef, url: URL, messages: Int)?
            var copyFailed = false
            if let file = source.transcript {
                do { copy = try Self.copyTranscript(file, id: id, into: outgoing) } catch { copyFailed = true }
            }
            let read = MoveRead(pin: pinned, key: key, branch: branch, status: status, unpushed: unpushed, transcript: copy, transcriptFailed: copyFailed)
            self?.queue.async { self?.moveRead(id, info: info, origin: origin, read) }
        }
    }

    /// What a move read of the thread's checkout and conversation, off the queue.
    struct MoveRead: @unchecked Sendable {
        var pin: Result<FleetDispatchGit.Pin, FleetDispatchGit.PinFailure>
        var key: String?
        var branch: (status: Int32, output: String)?
        var status: (status: Int32, output: String)?
        var unpushed: (status: Int32, output: String)?
        var transcript: (ref: FleetBlobRef, url: URL, messages: Int)?
        var transcriptFailed: Bool
    }

    private func moveRead(_ id: UUID, info: FleetMoveInfo, origin: String?, _ read: MoveRead) {
        placing.remove(id)
        guard var record = outbound[id], record.state.isLive, !(record.move?.committed ?? false) else {
            if let copy = read.transcript { try? FileManager.default.removeItem(at: copy.url) }
            return
        }
        guard !read.transcriptFailed else { return failMove(id, FleetDispatchCode.snapshotFailed, "The conversation couldn't be read.") }
        guard let key = read.key, case .success(let pin) = read.pin else {
            if let copy = read.transcript { try? FileManager.default.removeItem(at: copy.url) }
            return failMove(id, FleetDispatchCode.repoMissing, "This thread's folder isn't a git repository with commits, so no other Mac can find it.")
        }
        var info = info
        info.stage = .conversation
        info.messages = read.transcript?.messages
        info.transcriptBytes = read.transcript?.ref.size
        info.uncommittedFiles = read.status.map { $0.output.split(separator: "\n").count } ?? 0
        info.unpushedCommits = read.unpushed.flatMap { Int($0.output) } ?? 0
        record.move = info
        record.state = .placing
        record.repoKey = key
        record.commitSHA = pin.sha
        record.subdir = pin.subdir
        record.origin = origin
        // The branch the thread is on: the name the other Mac gives its worktree when it can.
        record.branch = read.branch.flatMap { $0.status == 0 && !$0.output.isEmpty ? $0.output : nil } ?? host.state().agents.first { $0.id == info.agentID }?.worktreeBranch
        record.updatedAt = now
        outbound[id] = record
        pins[id] = pin
        if let copy = read.transcript { moveTranscripts[id] = (copy.ref, copy.url) }
        save()
        // A move is placed on the Mac the person named: a refusal ends it, and the thread stays.
        place(id) { [weak self] result in
            if case .failure(let refusal) = result, self?.outbound[id]?.state.isLive == true { self?.failMove(id, refusal.code, refusal.detail ?? refusal.message) }
        }
    }

    /// Copies the conversation to a file of this move's own and names it by its hash and size, off the queue. Pi is stopped, so the file
    /// is whole; a line cut by the stop (no newline at its end) is left out.
    static func copyTranscript(_ file: URL, id: UUID, into directory: URL) throws -> (ref: FleetBlobRef, url: URL, messages: Int) {
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("transcript-\(id.uuidString.lowercased()).jsonl")
        try? manager.removeItem(at: url)
        guard manager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        let input = try FileHandle(forReadingFrom: file)
        let output = try FileHandle(forWritingTo: url)
        defer { try? input.close(); try? output.close() }
        var messages = 0
        var size: UInt64 = 0
        var carry = Data()
        while let chunk = try input.read(upToCount: 1 << 20), !chunk.isEmpty {
            carry.append(chunk)
            // Everything up to the last newline is whole lines.
            guard let last = carry.lastIndex(of: UInt8(ascii: "\n")) else { continue }
            let whole = carry[..<carry.index(after: last)]
            messages += whole.split(separator: UInt8(ascii: "\n")).count { $0.starts(with: Array(#"{"type":"message""#.utf8)) }
            try output.write(contentsOf: whole)
            size += UInt64(whole.count)
            carry = Data(carry[carry.index(after: last)...])
        }
        // A last line with no newline is whole when it parses.
        if !carry.isEmpty, (try? JSONSerialization.jsonObject(with: carry)) != nil {
            try output.write(contentsOf: carry + Data("\n".utf8))
            size += UInt64(carry.count + 1)
            if carry.starts(with: Array(#"{"type":"message""#.utf8)) { messages += 1 }
        }
        try output.synchronize()
        guard let hash = FleetSnapshotBlobs.hash(of: url) else { throw CocoaError(.fileReadUnknown) }
        return (FleetBlobRef(hash: hash, size: size), url, messages)
    }

    /// What this move tells the other Mac the thread is.
    func handoff(for record: FleetDispatchRecord) -> FleetMoveHandoff? {
        guard let info = record.move, let agent = host.state().agents.first(where: { $0.id == info.agentID }) else { return nil }
        return FleetMoveHandoff(
            agentID: agent.id, sessionID: info.sessionID, name: agent.name, nameIsFinal: agent.nameIsFinal, model: agent.model,
            thinking: agent.thinkingLevel?.rawValue, serviceTier: agent.serviceTier == .standard ? nil : agent.serviceTier.rawValue,
            pushMuted: agent.pushMuted, dispatchedFrom: agent.dispatchedFrom, dispatch: liveInboundDispatch(of: agent.id)?.record,
            branch: record.branch, worktreeBase: agent.worktreeBase, lastActiveAt: agent.lastActiveAt, movedAt: now, messages: info.messages ?? 0,
            uncommittedFiles: info.uncommittedFiles ?? 0, unpushedCommits: info.unpushedCommits ?? 0)
    }

    // MARK: Progress and the hand over

    /// Bytes pushed so far: the conversation goes first, so the card moves on to the worktree once it is all there.
    func moveProgressed(_ id: UUID, _ sent: UInt64) {
        guard var info = outbound[id]?.move, info.stage == .conversation, sent >= (info.transcriptBytes ?? 0) else { return }
        info.stage = .worktree
        outbound[id]?.move = info
    }

    /// The other Mac took everything and built the worktree; it waits for this Mac to hand the thread over. The tombstone is written first
    /// (this is the commit point), then the other Mac is told to start the thread, again and again until it answers.
    func commitMove(_ id: UUID) {
        guard var record = outbound[id], record.kind == .move, var info = record.move, record.state == .preparing, !info.committed,
              let target = record.targetHostID, let agent = host.state().agents.first(where: { $0.id == info.agentID }) else { return }
        guard agent.movedTo == nil, !holdCommit else { return }
        let moved = MovedTo(hostID: target, hostName: record.targetHostName ?? "", at: now, moveID: id)
        guard host.tombstone(agent.id, moved) else {
            failMove(id, FleetDispatchCode.moveRefused, "This Mac couldn't save the move, so the thread stays here.")
            return
        }
        info.committed = true
        info.stage = .starting
        info.movedAt = moved.at
        record.move = info
        record.updatedAt = now
        outbound[id] = record
        save()
        sendCommit(id)
    }

    /// Tells the other Mac to start the thread. Safe to repeat: it answers the same record.
    func sendCommit(_ id: UUID) {
        guard let record = outbound[id], record.kind == .move, record.move?.committed == true, record.state == .preparing,
              let target = record.targetHostID, !sending.contains(id) else { return }
        guard !holdHandover, let link = client(target) else { return }
        sending.insert(id)
        let finish: @Sendable (Result<FleetDispatchRecord, Error>) -> Void = { [weak self] result in
            self?.queue.async { self?.committed(id, result) }
        }
        Task { do { finish(.success(try await link.fleetDispatchControl(id, .commit))) } catch { finish(.failure(error)) } }
    }

    func committed(_ id: UUID, _ result: Result<FleetDispatchRecord, Error>) {
        sending.remove(id)
        guard var record = outbound[id], record.kind == .move, record.state == .preparing, var info = record.move, info.committed else { return }
        switch result {
        case .success(let theirs):
            guard theirs.state == .done, theirs.move?.stage == .moved else {
                if theirs.state == .failed || theirs.state == .cancelled { return failMove(id, theirs.failure ?? FleetDispatchCode.refused, theirs.failureDetail) }
                // Still starting there: asked again by the next evaluation.
                return scheduleEvaluation()
            }
            info.stage = .moved
            record.move = info
            record.state = .done
            record.remoteAgentID = theirs.remoteAgentID ?? info.agentID
            record.branch = theirs.branch ?? record.branch
            record.updatedAt = now
            outbound[id] = record
            releaseSnapshot(id: id)
            save()
            handOffInbound(of: info.agentID, to: record.targetHostID, name: record.targetHostName ?? "")
        case .failure(let error):
            // The other Mac answered that it didn't start the thread, or never heard of the move: no copy is live there, so this one is again.
            if case RemoteHostClientError.rejected(let code, let message) = error, !Self.transportCodes.contains(code) {
                return failMove(id, code == FleetDispatchProtocol.Code.unknownDispatch ? FleetDispatchCode.peerGone : code, String(message.prefix(200)))
            }
            scheduleEvaluation()
        }
    }

    /// The thread moved on: the Mac that sent it work hears where it runs now, so its result still comes back to the sender.
    private func handOffInbound(of agent: AgentID, to target: UUID?, name: String) {
        guard let target else { return }
        for (key, entry) in inbound where entry.record.remoteAgentID == agent && entry.record.state.isLive && entry.record.kind != .move {
            var moved = entry
            moved.record.movedOn = FleetMovedOn(hostID: target, hostName: name)
            moved.expectsResult = false
            moved.unsent = true
            moved.record.updatedAt = now
            inbound[key] = moved
        }
        save()
        pushPending()
    }

    // MARK: What the other Mac says

    /// Takes what the other Mac reports of a move (`merge`): its worktree is built and waits (this Mac hands the thread over), it failed, it
    /// was cancelled, or the thread runs there. Whatever changes the move itself happens after the caller has stored the record.
    func mergeMove(_ theirs: FleetDispatchRecord, into record: inout FleetDispatchRecord) {
        let id = record.id
        record.branch = theirs.branch ?? record.branch
        record.targetHostName = record.targetHostName ?? theirs.targetHostName
        record.clone = theirs.state == .preparing ? theirs.clone : nil
        let committed = record.move?.committed == true
        switch theirs.state {
        case .failed:
            let (code, detail) = (theirs.failure ?? FleetDispatchCode.refused, theirs.failureDetail)
            queue.async { [weak self] in self?.failMove(id, code, detail) }
        case .cancelled:
            queue.async { [weak self] in self?.failMove(id, "cancelled", nil, as: .cancelled) }
        case .done where theirs.move?.stage == .moved && committed:
            queue.async { [weak self] in self?.committed(id, .success(theirs)) }
        case .preparing where theirs.move?.stage == .staged && !committed:
            record.move?.stage = .staged
            queue.async { [weak self] in self?.commitMove(id) }
        default: break
        }
        record.updatedAt = now
    }

    // MARK: Ending

    /// The move ended without handing the thread over (or the other Mac refused it): this Mac's copy is the thread, as it was.
    func failMove(_ id: UUID, _ code: String, _ detail: String?, as ended: FleetDispatchState = .failed) {
        guard var record = outbound[id], record.kind == .move, record.state.isLive else { return }
        let wasCommitted = record.move?.committed == true
        let target = record.targetHostID
        record.state = ended
        record.failure = ended == .failed ? code : nil
        record.failureDetail = ended == .failed ? detail : nil
        record.updatedAt = now
        if var info = record.move {
            info.committed = false
            info.cancelPending = target != nil && !wasCommitted
            record.move = info
        }
        outbound[id] = record
        placing.remove(id)
        releaseSnapshot(id: id)
        // The other Mac told us it holds no live copy: ours is the thread again.
        if wasCommitted, let agent = record.move?.agentID { _ = host.untombstone(agent, id) }
        restoreInboundResults(of: record.move?.agentID)
        save()
        if !wasCommitted { sendMoveCancel(id) }
    }

    /// A move that ended before it handed over leaves a dispatched thread owing the result it still owed.
    private func restoreInboundResults(of agent: AgentID?) {
        guard let agent else { return }
        for key in inbound.keys where inbound[key]?.record.remoteAgentID == agent && inbound[key]?.record.state.isLive == true && inbound[key]?.record.kind != .move {
            inbound[key]?.expectsResult = true
            inbound[key]?.startedWorking = false
        }
    }

    /// Tells the other Mac to drop what it holds for a move that did not happen (until it answers, or never heard of it).
    func sendMoveCancel(_ id: UUID) {
        guard let record = outbound[id], record.kind == .move, record.move?.cancelPending == true, let target = record.targetHostID,
              !sending.contains(id), let link = client(target) else { return }
        sending.insert(id)
        Task { [weak self] in
            var settled = false
            do { _ = try await link.fleetDispatchControl(id, .cancel); settled = true }
            catch RemoteHostClientError.rejected(let code, _) where !Self.transportCodes.contains(code) { settled = true }
            catch {}
            self?.queue.async {
                guard let self else { return }
                self.sending.remove(id)
                if settled, var info = self.outbound[id]?.move {
                    info.cancelPending = false
                    self.outbound[id]?.move = info
                    self.save()
                }
            }
        }
    }

    /// Every look at what waits (`evaluate`) and after a link comes up (`reconcile`): a move that handed over repeats its hand over until
    /// it is answered, one a restart cut short tells the other Mac to drop what it holds, a turn that is ending is waited for.
    func evaluateMoves() {
        for record in outbound.values where record.kind == .move {
            switch record.state {
            case .waitingTurn: advanceMove(record.id)
            case .preparing:
                if record.move?.committed == true { sendCommit(record.id) } else if record.move?.stage == .stopping { continueStop(record.id) }
            case .failed where record.move?.cancelPending == true: sendMoveCancel(record.id)
            default: break
            }
        }
    }

    /// A thread was deleted here while it was moving: the move ends, and the other Mac drops what it holds.
    func moveAgentRemoved(_ agent: AgentID) {
        guard let record = liveMove(of: agent), record.move?.committed != true else { return }
        failMove(record.id, FleetDispatchCode.moveRefused, "The thread was deleted.")
    }

    /// The person cancelled a move (`cancelDispatch`): before the hand over it ends and the thread stays; after it, it is the other Mac's.
    func cancelMove(_ id: UUID) {
        guard let record = outbound[id], record.kind == .move, record.state.isLive, record.move?.committed != true else { return }
        failMove(id, "cancelled", nil, as: .cancelled)
    }

    /// A restart of this Mac, as the sender: a move that hadn't handed over ends (the thread stays), and the other Mac is told when it can be.
    func settleMovesAfterRestart() {
        var changed = false
        for (id, record) in outbound where record.kind == .move && record.state.isLive && record.move?.committed != true {
            outbound[id]?.state = .failed
            outbound[id]?.failure = FleetDispatchCode.restarted
            outbound[id]?.move?.cancelPending = record.targetHostID != nil && record.move?.stage != .waitingTurn
            outbound[id]?.updatedAt = now
            changed = true
        }
        if changed { save() }
    }
}
