import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The Mac that runs a dispatch (server queue): it resolves the repo against its own spaces, fetches
/// origin, makes a fresh worktree at the pinned commit on its own `fleet/<title>` branch and starts a
/// thread there with the task as its first message. Its copy of the record is the idempotency index:
/// a create that arrives again returns the thread it already made. What happens next goes back to the
/// sending Mac as pushes; the host only reads and reports the branch, the thread commits and pushes
/// itself with this Mac's own git sign-in.
extension FleetDispatch {
    // MARK: Create

    /// `fleetDispatchCreate` from `sender` (a Mac in the fleet, or this one). Answers at once with the
    /// record: `preparing` while the fetch, worktree and thread come, `waitingRoom` when this Mac is full
    /// and kept nothing, or a refusal with a code.
    func receiveCreate(_ create: FleetDispatchCreate, from sender: UUID, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard membership() else { return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil))) }
        guard create.from.hostID == sender else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "A dispatch can only come from the Mac that sends it.")))
        }
        if let known = inbound[create.dispatchID] {
            guard known.record.parentHostID == sender else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That dispatch belongs to another Mac.")))
            }
            return reply(.success(known.record))
        }
        guard !create.task.isEmpty, create.task.utf8.count <= FleetDispatchProtocol.maxTaskBytes else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or too long.")))
        }
        if let sha = create.commitSHA, !FleetDispatchGit.isCommit(sha) {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That isn't a commit id.")))
        }
        if create.kind == .agentDispatch, create.commitSHA == nil {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "A dispatch from a thread names the commit it starts from.")))
        }
        if let subdir = create.subdir, !FleetDispatchGit.isSafeSubdirectory(subdir) {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That folder isn't inside the repository.")))
        }
        let running = inbound.values.filter { [.preparing, .running].contains($0.record.state) }.count
        guard running < FleetDispatchProtocol.admissionLimit else {
            // Full: nothing is kept; the sender decides again when anything changes.
            var full = FleetDispatchRecord(id: create.dispatchID, kind: create.kind, parentAgentID: create.from.agentID, parentHostID: sender,
                                           parentHostName: create.from.hostName, state: .waitingRoom, title: create.title, task: "",
                                           repoKey: create.repoKey, createdAt: now)
            full.targetHostID = hostID
            return reply(.success(full))
        }
        // The repo: the spaces here that are this repository, by their origin.
        let matches = host.state().spaces.filter { space in
            !space.hidden && space.repoKey == create.repoKey && Self.folderExists(space.path)
        }
        let checkouts = Dictionary(grouping: matches) { PiHome.canonical($0.path) }
        guard let space = matches.first else {
            return reply(.failure(Self.refusal(FleetDispatchCode.repoMissing, hostName())))
        }
        guard checkouts.count == 1 else {
            return reply(.failure(Self.refusal(FleetDispatchCode.repoAmbiguous, matches.map(\.name).sorted().joined(separator: ", "))))
        }
        var record = FleetDispatchRecord(
            id: create.dispatchID, kind: create.kind, parentAgentID: create.from.agentID, parentHostID: sender, parentHostName: create.from.hostName,
            parentTitle: create.from.agentTitle, targetHostID: hostID, targetHostName: hostName(), state: .preparing,
            title: Self.title(create.title, task: create.task), task: create.task, repoKey: create.repoKey, commitSHA: create.commitSHA,
            subdir: create.subdir, branch: nil, model: create.model, thinking: create.thinking, createdAt: now)
        record.updatedAt = record.createdAt
        inbound[record.id] = Inbound(record: record, acceptedAt: now)
        save()
        reply(.success(record))
        prepare(record.id, space: space, requestedBranch: create.branch)
    }

    /// Fetch, the branch, the worktree and the thread: off the server queue, with each step's outcome
    /// written to the record and pushed to the sender.
    private func prepare(_ id: UUID, space: Space, requestedBranch: String?) {
        guard let entry = inbound[id] else { return }
        let record = entry.record
        let repo = space.path
        Task.detached { [weak self] in
            // The commit has to be here: origin's, or already in the repo.
            if let sha = record.commitSHA, !FleetDispatchGit.hasCommit(sha, in: repo) {
                self?.queue.async { self?.failInbound(id, FleetDispatchCode.commitUnreachable, nil) }
                return
            }
            guard let self else { return }
            let branch = self.claimedBranches.claim {
                FleetDispatchGit.branchName(title: record.title, requested: requestedBranch, dispatchID: id, repo: repo, claimed: $0)
            }
            defer { self.claimedBranches.release(branch) }
            // Written before the worktree exists, so a retry agrees on the name.
            self.queue.async { self.named(id, branch: branch) }
            let request = await self.onQueue { self.threadRequest(for: record, branch: branch, space: space) }
            let outcome = await self.host.createThread(request)
            self.queue.async { self.prepared(id, outcome) }
        }
    }

    private func named(_ id: UUID, branch: String) {
        guard inbound[id]?.record.state == .preparing else { return }
        inbound[id]?.record.branch = branch
        save()
    }

    private func threadRequest(for record: FleetDispatchRecord, branch: String, space: Space) -> RemoteCreateAgentRequest {
        var request = RemoteCreateAgentRequest(
            spaceID: space.id, cwd: space.path, model: record.model, thinking: record.thinking.flatMap(ThinkingLevel.init(rawValue:)),
            initialPrompt: Self.prompt(for: record, branch: branch), worktreeBranch: branch, worktreeBase: record.commitSHA,
            // A thread from a thread starts at its pinned commit; one the person started starts where this Mac's
            // Settings ▸ Worktrees say (the space's base, fetched first when that is on).
            worktreeFetchFirst: record.commitSHA == nil ? nil : false)
        request.name = record.title
        request.subdirectory = record.subdir
        request.dispatchedFrom = DispatchedFrom(hostID: record.parentHostID, hostName: record.parentHostName, agentID: record.parentAgentID,
                                                agentTitle: record.parentTitle, dispatchID: record.id, at: record.createdAt)
        return request
    }

    /// What the thread is asked: the task, and where its work goes.
    static func prompt(for record: FleetDispatchRecord, branch: String) -> String {
        let sender = record.kind == .userThread || record.parentTitle.isEmpty ? "the person" : record.parentTitle
        let tail = record.kind == .userThread ? "" : " Your last message goes back to whoever sent you."
        return record.task + FleetDispatchProtocol.promptSeparator + "\(sender) on \(record.parentHostName) to do the task above. "
            + "Your branch is \(branch). Commit your work there and push it with git push -u origin \(branch)." + tail
    }

    private func prepared(_ id: UUID, _ outcome: Result<AgentID, RemoteCreateAgentError>) {
        guard var entry = inbound[id], entry.record.state == .preparing else {
            // Cancelled while it was being made: the thread that came out of it is stopped.
            if case .success(let agent) = outcome { host.stopThread(agent) }
            return
        }
        switch outcome {
        case .success(let agent):
            entry.record.remoteAgentID = agent
            entry.record.state = .running
            entry.worktree = host.state().agents.first { $0.id == agent }?.worktreePath
            entry.acceptedAt = now
        case .failure(let error):
            entry.record.state = .failed
            entry.record.failure = FleetDispatchCode.snapshotFailed
            entry.record.failureDetail = String(error.message.prefix(300))
        }
        entry.record.updatedAt = now
        entry.unsent = true
        inbound[id] = entry
        save()
        pushPending()
    }

    private func failInbound(_ id: UUID, _ code: String, _ detail: String?) {
        guard var entry = inbound[id], entry.record.state == .preparing else { return }
        entry.record.state = .failed
        entry.record.failure = code
        entry.record.failureDetail = detail
        entry.record.updatedAt = now
        entry.unsent = true
        inbound[id] = entry
        save()
        pushPending()
    }

    static func folderExists(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: (path as NSString).expandingTildeInPath, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    // MARK: Control

    /// `fleetDispatchControl` from `sender`, which must be the Mac that sent the dispatch.
    func control(_ id: UUID, _ control: FleetDispatchControl, from sender: UUID,
                 reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard membership() else { return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil))) }
        guard var entry = inbound[id], entry.record.parentHostID == sender else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no such dispatch.")))
        }
        refreshActivity(&entry)
        switch control {
        case .status:
            inbound[id] = entry
            reply(.success(entry.record))
        case .cancel:
            guard entry.record.state.isLive else { return reply(.success(entry.record)) }
            entry.record.state = .cancelled
            entry.record.updatedAt = now
            entry.expectsResult = false
            entry.unsent = true
            inbound[id] = entry
            if let agent = entry.record.remoteAgentID { host.stopThread(agent) }
            save()
            reply(.success(entry.record))
            pushPending()
        case .message(let text, let delivery):
            guard let agent = entry.record.remoteAgentID, [.running, .delivering, .done].contains(entry.record.state),
                  host.threadFacts(agent) != nil else {
                return reply(.failure(.init(code: "not_running", message: "That dispatch has no thread to message (it is \(entry.record.state.rawValue)).")))
            }
            let message = host.messageThread
            Task.detached { [weak self] in
                let sent = await message(agent, text, delivery == .steer ? .steer : .followUp)
                self?.queue.async {
                    guard let self, var entry = self.inbound[id] else { return }
                    guard sent else {
                        return reply(.failure(.init(code: "not_running", message: "The thread didn't take the message.")))
                    }
                    // A finished dispatch starts a new run on the same thread, and that run's end is a new result.
                    entry.record.state = .running
                    entry.expectsResult = true
                    entry.startedWorking = false
                    entry.acceptedAt = self.now
                    entry.record.resultText = nil
                    entry.record.resultBranchFacts = nil
                    entry.record.updatedAt = self.now
                    entry.unsent = true
                    self.inbound[id] = entry
                    self.save()
                    reply(.success(entry.record))
                    self.pushPending()
                }
            }
        }
    }

    private func refreshActivity(_ entry: inout Inbound) {
        guard let agent = entry.record.remoteAgentID, let facts = host.threadFacts(agent) else { return }
        entry.record.activity = Self.activity(facts)
    }

    static func activity(_ facts: FleetThreadFacts) -> String {
        switch facts.status {
        case .working: "working"
        case .blocked: facts.waitingOn.map { "waiting on you: \($0)" } ?? "waiting on you"
        case .idle, .done: "idle"
        }
    }

    // MARK: The thread

    /// A thread's status changed. A dispatched thread that finishes its first run (or the run a message started)
    /// with nothing queued has a result to send back.
    func agentStatusChanged(_ agentID: AgentID, _ status: AgentStatus) {
        guard let (id, found) = inbound.first(where: { $0.value.record.remoteAgentID == agentID && $0.value.record.state.isLive }) else { return }
        var entry = found
        if status == .done, entry.expectsResult, entry.startedWorking {
            entry.expectsResult = false
            inbound[id] = entry
            return finishRun(id)
        }
        if status == .working { entry.startedWorking = true }
        if let facts = host.threadFacts(agentID) { entry.record.activity = Self.activity(facts) }
        guard entry != found else { return }
        entry.record.updatedAt = now
        entry.unsent = entry.unsent || entry.record.activity != found.record.activity
        inbound[id] = entry
        save()
        pushPending()
    }

    /// The thread settled: read its last message and its branch, keep them on the record, and push them.
    private func finishRun(_ id: UUID) {
        guard let entry = inbound[id], let agent = entry.record.remoteAgentID else { return }
        let text = host.threadFacts(agent)?.lastText ?? ""
        let worktree = entry.worktree ?? host.state().agents.first { $0.id == agent }?.worktreePath
        let branch = entry.record.branch ?? ""
        let start = entry.record.commitSHA
        Task.detached { [weak self] in
            let facts = worktree.map { FleetDispatchGit.branchFacts(worktree: $0, branch: branch, start: start) }
            self?.queue.async {
                guard let self, var entry = self.inbound[id], entry.record.state.isLive else { return }
                entry.record.resultText = String(text.prefix(FleetDispatchProtocol.maxResultBytes))
                entry.record.resultBranchFacts = facts
                entry.record.state = .delivering
                entry.record.activity = "idle"
                entry.record.updatedAt = self.now
                entry.unsent = true
                self.inbound[id] = entry
                self.save()
                self.pushPending()
            }
        }
    }

    /// A dispatched thread was deleted here: its dispatch ends.
    func agentRemoved(_ agentID: AgentID) {
        guard let (id, found) = inbound.first(where: { $0.value.record.remoteAgentID == agentID && $0.value.record.state.isLive }) else { return }
        var entry = found
        entry.record.state = .cancelled
        entry.record.updatedAt = now
        entry.expectsResult = false
        entry.unsent = true
        inbound[id] = entry
        save()
        pushPending()
    }

    // MARK: Telling the sender

    /// Pushes what each Mac hasn't heard: a change of state, and a result it has to acknowledge. What can't go
    /// now goes when the link is back (`linkChanged`).
    func pushPending() {
        guard !stopped else { return }
        for (id, entry) in inbound where entry.unsent || entry.record.state == .delivering {
            guard !pushing.contains(id) else { continue }
            let sender = entry.record.parentHostID
            let record = entry.record
            let finish: @Sendable (Bool) -> Void = { [weak self] delivered in
                self?.queue.async {
                    guard let self else { return }
                    self.pushing.remove(id)
                    guard delivered, var current = self.inbound[id] else { return self.scheduleEvaluation() }
                    // What was sent is what the sender knows now; a change that came meanwhile is still owed.
                    if current.record.updatedAt == record.updatedAt { current.unsent = false }
                    if record.state == .delivering, current.record.state == .delivering { current.record.state = .done }
                    self.inbound[id] = current
                    self.save()
                }
            }
            if sender == hostID {
                pushing.insert(id)
                queue.async { [weak self] in
                    guard let self else { return }
                    let accepted = self.receivePush(record, from: self.hostID)
                    finish(accepted)
                }
            } else if let link = client(sender) {
                pushing.insert(id)
                Task {
                    do {
                        if record.state == .delivering, let text = record.resultText {
                            try await link.fleetDispatchResult(id, text: text, branchFacts: record.resultBranchFacts)
                        } else {
                            try await link.fleetDispatchChanged(record)
                        }
                        finish(true)
                    } catch {
                        finish(false)
                    }
                }
            }
        }
        scheduleEvaluation()
    }

    /// A push to this very Mac (a dispatch that stayed here): the sender side takes it as a peer's.
    private func receivePush(_ record: FleetDispatchRecord, from peer: UUID) -> Bool {
        if record.state == .delivering, let text = record.resultText {
            return result(record.id, text: text, facts: record.resultBranchFacts, from: peer)
        }
        return changed(record, from: peer)
    }
}
