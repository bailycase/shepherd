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
        guard create.from.hostID == sender else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "A dispatch can only come from the Mac that sends it.")))
        }
        if let known = inbound[create.dispatchID] {
            guard known.record.parentHostID == sender else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That dispatch belongs to another Mac.")))
            }
            // A clone that failed asked for the repository itself: this create carries it, and replaces the failed attempt.
            if known.record.state == .failed, [FleetDispatchCode.cloneFailed, FleetDispatchCode.commitUnreachable].contains(known.record.failure ?? ""),
               create.snapshot.map({ $0.repoBundle || $0.repoOnly }) == true {
                inbound[create.dispatchID] = nil
            } else {
                return reply(.success(known.record))
            }
        }
        guard create.kind == .move || (!create.task.isEmpty && create.task.utf8.count <= FleetDispatchProtocol.maxTaskBytes) else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or too long.")))
        }
        if create.kind == .move, let refusal = moveCreateProblem(create) { return reply(.failure(refusal)) }
        if let sha = create.commitSHA, !FleetDispatchGit.isCommit(sha) {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That isn't a commit id.")))
        }
        if create.kind == .agentDispatch, create.commitSHA == nil {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "A dispatch from a thread names the commit it starts from.")))
        }
        // The sender holds its threads to the depth limit; a second wall here.
        if create.kind == .agentDispatch, let depth = create.from.depth, depth >= StartedBy.maxDepth {
            return reply(.failure(.init(code: FleetDispatchCode.tooDeep, message: FleetDispatch.tooDeep)))
        }
        if let subdir = create.subdir, !FleetDispatchGit.isSafeSubdirectory(subdir) {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That folder isn't inside the repository.")))
        }
        // Every dispatch worktree (including a move) lives on the local support volume. Admit
        // only before beginning transfer, clone or creation; named placement can't bypass this.
        if let free = freeWorktreeBytes(directory.deletingLastPathComponent().path), free < Self.worktreeDiskFloor {
            return reply(.failure(Self.refusal(FleetDispatchCode.diskLow, nil)))
        }
        let occupied = inbound.values.filter { [.preparing, .running].contains($0.record.state) }
        guard occupied.count < FleetDispatchProtocol.admissionLimit else {
            // Full: nothing is kept; the sender decides again when anything changes. Preparing
            // dispatches take admission slots, but only running ones are included in the report.
            var full = FleetDispatchRecord(id: create.dispatchID, kind: create.kind, parentAgentID: create.from.agentID, parentHostID: sender,
                                           parentHostName: create.from.hostName, targetHostID: hostID, targetHostName: hostName(),
                                           state: .waitingRoom, title: create.title, task: "", repoKey: create.repoKey, createdAt: now)
            full.hostRunningDispatches = occupied.count { $0.record.state == .running }
            return reply(.success(full))
        }
        // The repo: the spaces here that are this repository, by their origin.
        let matches = host.state().spaces.filter { space in
            !space.hidden && space.repoKey == create.repoKey && Self.folderExists(space.path)
        }
        let checkouts = Dictionary(grouping: matches) { PiHome.canonical($0.path) }
        guard checkouts.count <= 1 else {
            return reply(.failure(Self.refusal(FleetDispatchCode.repoAmbiguous, matches.map(\.name).sorted().joined(separator: ", "))))
        }
        var space = matches.first
        // No space here is that repository: a checkout this Mac already has binds to it (slice 4f), else it is cloned.
        if space == nil, let found = finder.locate(create.repoKey) {
            space = bindCheckout(found.path, create)
        }
        // A sender that names no origin (an older build) can't be cloned from: refused as before, with the Mac's name.
        if space == nil, create.repo == nil {
            return reply(.failure(Self.refusal(FleetDispatchCode.repoMissing, hostName())))
        }
        var record = FleetDispatchRecord(
            id: create.dispatchID, kind: create.kind, parentAgentID: create.from.agentID, parentHostID: sender, parentHostName: create.from.hostName,
            parentTitle: create.from.agentTitle, targetHostID: hostID, targetHostName: hostName(), state: .preparing,
            title: Self.title(create.title, task: create.task), task: create.task, repoKey: create.repoKey, commitSHA: create.commitSHA,
            subdir: create.subdir, branch: nil, model: create.model, thinking: create.thinking, start: create.start,
            move: create.move.map { FleetMoveInfo(agentID: $0.agentID, stage: .conversation, sessionID: $0.sessionID, messages: $0.messages,
                                                  uncommittedFiles: $0.uncommittedFiles, unpushedCommits: $0.unpushedCommits) }, createdAt: now)
        record.updatedAt = record.createdAt
        record.parentDepth = create.from.depth
        record.comparisonBranch = create.comparisonBranch
        // A name the person gave the branch, or the branch they chose, is the name here; a thread's own dispatch gets `fleet/<title>`.
        let exact = create.start?.branch != nil || create.kind == .move
        // No checkout yet: the Mac gets one first, and says where that stands (the card "Cloning acme-web on Mac mini").
        if space == nil {
            record.clone = FleetCloneProgress(name: FleetRepoClone.folderName(repoKey: create.repoKey, name: create.repo?.name), source: create.snapshot?.repoBundle == true ? create.from.hostName : create.repoKey,
                                              viaBundle: create.snapshot?.repoBundle == true)
        }
        if let header = create.snapshot {
            guard header.isValid, header.commit == create.commitSHA else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That snapshot doesn't belong to that commit.")))
            }
            record.snapshotBytes = header.bytes
            record.snapshotProgress = 0
            record.snapshotFiles = header.files + header.directories
            // The pieces come over the link next (`fleetSnapshotPart`, `fleetBlobPush`); the worktree is built when they are all here.
            let snap = SnapshotIn(header: header, space: space, requestedBranch: create.branch)
            snap.repo = create.repo
            if let space {
                let (id, title, repo, requested, claims) = (record.id, record.title, space.path, create.branch, claimedBranches)
                snap.branch = Task.detached { claims.claim { FleetDispatchGit.branchName(title: title, requested: requested, dispatchID: id, repo: repo, claimed: $0, exact: exact) } }
            }
            snapshotsIn[record.id] = snap
            inbound[record.id] = Inbound(record: record, acceptedAt: now, handoff: create.move, transcript: header.transcript)
            save()
            reply(.success(record))
            if space == nil { acquireRepo(record.id, create) }
            return
        }
        inbound[record.id] = Inbound(record: record, acceptedAt: now)
        save()
        reply(.success(record))
        if let space { prepare(record.id, space: space, requestedBranch: create.branch) } else { acquireRepo(record.id, create) }
    }

    /// Fetch, the branch, the worktree and the thread: off the server queue, with each step's outcome
    /// written to the record and pushed to the sender.
    func prepare(_ id: UUID, space: Space, requestedBranch: String?) {
        guard let entry = inbound[id] else { return }
        let record = entry.record
        let repo = space.path
        let snapshot = snapshotsIn[id]
        // A transfer that was only the repository carries no edits: the worktree is made as for a dispatch with none.
        let carried = snapshot?.header.repoOnly == true ? nil : snapshot
        let bundleFile = snapshot?.header.repoOnly == true ? snapshot?.header.bundle.map { blobs.url($0.hash).path } : nil
        let exact = record.start?.branch != nil || record.kind == .move
        Task.detached { [weak self] in
            // A thread started on `origin/<base>` starts at that ref as this Mac has it once it has asked origin for it (a thread started from a
            // local branch, or whose base this Mac can't see, starts at the commit the sender had).
            var startPoint = record.commitSHA
            var baseResolved = false
            if record.kind == .userThread, record.start?.place == .newWorktree, let base = record.start?.base, base.hasPrefix("origin/") {
                GitWorktree.fetchPicked(repo: repo, base: base, fetchFirst: true)
                if FleetDispatchGit.run(["rev-parse", "--verify", "--quiet", "\(base)^{commit}"], in: repo)?.status == 0 { startPoint = base; baseResolved = true }
            }
            // The commit has to be here: origin's, already in the repo, or in the bundle that came for it. (A snapshot's own steps make it
            // present, from its bundle too.)
            var madeRefs = false
            if carried == nil, !baseResolved, let sha = record.commitSHA {
                var has = FleetDispatchGit.hasCommit(sha, in: repo)
                if !has, let bundleFile {
                    madeRefs = true
                    FleetRepoClone.fetchBundle(bundleFile, into: repo, id: id)
                    has = FleetDispatchGit.hasCommit(sha, in: repo, fetching: false)
                }
                if !has {
                    if madeRefs { FleetRepoClone.dropBundleRefs(from: repo, id: id) }
                    self?.queue.async { self?.failInbound(id, FleetDispatchCode.commitUnreachable, nil) }
                    return
                }
            }
            defer { if madeRefs { FleetRepoClone.dropBundleRefs(from: repo, id: id) } }
            guard let self else { return }
            let branch: String
            if let early = snapshot?.branch {
                branch = await early.value
            } else {
                branch = self.claimedBranches.claim {
                    FleetDispatchGit.branchName(title: record.title, requested: requestedBranch, dispatchID: id, repo: repo, claimed: $0, exact: exact)
                }
            }
            defer { self.claimedBranches.release(branch) }
            // Written before the worktree exists, so a retry agrees on the name.
            self.queue.async { self.named(id, branch: branch) }
            // The snapshot's worktree is built and checked against the sender's digest here; nothing starts in it before that.
            var built: FleetSnapshotApply.Applied?
            if let snapshot = carried, let manifest = snapshot.manifest {
                let indexes = await self.onQueue { self.indexService?.indexes() ?? [] }
                var apply = FleetSnapshotApply(.init(id: id, repo: repo, base: space.worktreeBase, branch: branch, header: snapshot.header, manifest: manifest,
                                                     blobs: self.blobs, spares: self.spares, indexes: indexes, began: snapshot.began, prelude: snapshot.events))
                switch apply.run() {
                case .failure(let failure):
                    self.queue.async { self.failInbound(id, failure.code, failure.detail) }
                    return
                case .success(let applied):
                    built = applied
                    await self.onQueue { self.applied(id, applied) }
                }
            }
            // A move starts no thread: the worktree waits for the sender to hand the thread over.
            if record.kind == .move {
                guard let built else {
                    self.queue.async { self.failInbound(id, FleetDispatchCode.snapshotFailed, "a move carries a worktree") }
                    return
                }
                self.queue.async { self.staged(id, space: space, worktree: built.path, branch: branch, madeRef: built.madeRef) }
                return
            }
            let path = built?.path ?? GitWorktree.destination(repo: repo, branch: branch)
            let candidates = FleetDispatchGit.buildOutputNames.filter {
                !FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).appendingPathComponent($0).path)
            }
            let request = await self.onQueue {
                self.inbound[id]?.cleanupCandidates = candidates
                return self.threadRequest(for: record, branch: branch, space: space, worktree: built?.path, startPoint: startPoint)
            }
            // Stopped while the worktree was being built: no thread starts, and the worktree goes.
            if let built, await self.onQueue({ self.inbound[id]?.record.state != .preparing }) {
                FleetSnapshotApply.discard(repo: repo, worktree: built.path, branch: branch, ref: built.madeRef ? id : nil)
                return
            }
            let outcome = await self.host.createThread(request)
            if let built, case .failure = outcome {
                FleetSnapshotApply.discard(repo: repo, worktree: built.path, branch: branch, ref: built.madeRef ? id : nil)
            }
            self.queue.async { self.prepared(id, outcome) }
        }
    }

    /// The worktree passed its digest: how long the file part took, and what it did.
    private func applied(_ id: UUID, _ applied: FleetSnapshotApply.Applied) {
        guard inbound[id]?.record.state == .preparing else { return }
        inbound[id]?.record.fileMillis = applied.fileMillis
        applyStats[id] = applied.stats
        save()
    }

    private func named(_ id: UUID, branch: String) {
        guard inbound[id]?.record.state == .preparing else { return }
        inbound[id]?.record.branch = branch
        save()
    }

    private func threadRequest(for record: FleetDispatchRecord, branch: String, space: Space, worktree: String? = nil, startPoint: String? = nil) -> RemoteCreateAgentRequest {
        var request = RemoteCreateAgentRequest(
            spaceID: space.id, cwd: space.path, model: record.model, thinking: record.thinking.flatMap(ThinkingLevel.init(rawValue:)),
            initialPrompt: Self.prompt(for: record, branch: branch), worktreeBranch: branch, worktreeBase: startPoint ?? record.commitSHA,
            // It starts at its pinned commit, or at the base ref the person chose (already fetched); one from an older sender, with no
            // commit, starts where this Mac's Settings ▸ Worktrees say.
            worktreeFetchFirst: (startPoint ?? record.commitSHA) == nil ? nil : false)
        // A snapshot's worktree is already made: the thread works in it.
        request.worktreePath = worktree
        request.name = record.title
        request.subdirectory = record.subdir
        request.dispatchedFrom = DispatchedFrom(hostID: record.parentHostID, hostName: record.parentHostName, agentID: record.parentAgentID,
                                                agentTitle: record.parentTitle, dispatchID: record.id, at: record.createdAt,
                                                depth: record.parentAgentID == nil ? 0 : (record.parentDepth ?? 0) + 1)
        return request
    }

    /// What the thread is asked and where it starts.
    static func prompt(for record: FleetDispatchRecord, branch: String) -> String {
        let sender = record.kind == .userThread || record.parentTitle.isEmpty ? "the person" : record.parentTitle
        let tail = record.kind == .userThread ? "" : " Your last message goes back to whoever sent you."
        return record.task + FleetDispatchProtocol.promptSeparator + "\(sender) on \(record.parentHostName) to do the task above. "
            + "You start on \(branch); commit and push (git push -u origin \(branch)) unless the task names another branch." + tail
    }

    private func prepared(_ id: UUID, _ outcome: Result<AgentID, RemoteCreateAgentError>) {
        snapshotsIn[id] = nil
        var settledAgent: AgentID?
        guard var entry = inbound[id], entry.record.state == .preparing else {
            // Cancelled while it was being made: the thread that came out of it is stopped.
            if case .success(let agent) = outcome { host.terminateThread(agent) }
            return
        }
        switch outcome {
        case .success(let agent):
            entry.record.remoteAgentID = agent
            entry.record.clone = nil
            entry.record.state = .running
            if let facts = host.threadFacts(agent) {
                entry.worktree = facts.worktree
                // Creating a thread doesn't wait for pi to serve. Its exit can precede this callback.
                if let problem = facts.stopProblem { return failStoppedRun(id, entry, problem: problem) }
                entry.record.activity = Self.activity(facts)
                // Opening pi can report a turn before createThread returns its agent ID.
                entry.startedWorking = facts.status != .idle
                if facts.status == .done { settledAgent = agent }
            }
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
        if let settledAgent { agentStatusChanged(settledAgent, .done) }
    }

    func failInbound(_ id: UUID, _ code: String, _ detail: String?) {
        dropSnapshot(id)
        guard var entry = inbound[id], entry.record.state == .preparing else { return }
        entry.record.clone = nil
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
        guard var entry = inbound[id], entry.record.parentHostID == sender else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no such dispatch.")))
        }
        switch control {
        case .status:
            // Polling must not write the inbound log or mask the next status push.
            if entry.record.state == .running, let agent = entry.record.remoteAgentID, let facts = host.threadFacts(agent) {
                entry.record.activity = Self.activity(facts)
                entry.record.lastThreadEventAt = facts.lastThreadEventAt
            }
            reply(.success(entry.record))
        case .commit:
            commitInbound(id, from: sender, reply: reply)
        case .close:
            closeInbound(id, entry, reply: reply)
        case .rename(let name):
            if entry.record.state == .preparing { return reply(.failure(.init(code: "starting", message: "The dispatch is still being prepared."))) }
            guard entry.record.kind == .agentDispatch, entry.record.closeReport == nil,
                  !closingThreads.contains(id), let agent = entry.record.remoteAgentID else {
                return reply(.failure(.init(code: "not_running", message: "That dispatch has no thread to rename.")))
            }
            if entry.record.movedOn != nil || host.state().agents.contains(where: { $0.id == agent && $0.movedTo != nil }) {
                return reply(.failure(.init(code: "not_running", message: "That dispatch's thread has moved to another Mac.")))
            }
            host.renameThread(agent, name) { [weak self] result in
                switch result {
                case .failure(let refusal): reply(.failure(refusal))
                case .success(let name):
                    guard let self, var current = self.inbound[id] else {
                        return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no such dispatch.")))
                    }
                    current.record.title = name
                    current.record.titleRevision = (current.record.titleRevision ?? 0) &+ 1
                    current.record.updatedAt = self.now
                    current.unsent = true
                    self.inbound[id] = current
                    self.save()
                    reply(.success(current.record))
                    self.pushPending()
                }
            }
        case .cancel:
            guard entry.record.state.isLive else { return reply(.success(entry.record)) }
            // A move whose thread is starting is the sender's to finish: it handed over, so a cancel can only be a stale one.
            if entry.record.kind == .move, entry.record.move?.stage == .starting { return reply(.success(entry.record)) }
            if entry.record.kind == .move { discardStaged(entry) }
            entry.record.state = .cancelled
            entry.record.updatedAt = now
            entry.expectsResult = false
            entry.unsent = true
            entry.record.clone = nil
            inbound[id] = entry
            dropSnapshot(id)
            // A clone that is running ends and takes its folder with it (`cloneEnded`).
            clones[id]?.cancel()
            if let agent = entry.record.remoteAgentID { host.terminateThread(agent) }
            save()
            reply(.success(entry.record))
            pushPending()
        case .message(let text, let delivery):
            if entry.record.state == .preparing { return reply(.failure(.init(code: "starting", message: "The dispatch is still being prepared."))) }
            guard !closingThreads.contains(id), entry.record.closeReport == nil,
                  let agent = entry.record.remoteAgentID, [.running, .delivering, .done].contains(entry.record.state),
                  let before = host.threadFacts(agent) else {
                return reply(.failure(.init(code: "not_running", message: "That dispatch has no thread to message (it is \(entry.record.state.rawValue)).")))
            }
            let message = host.messageThread
            Task.detached { [weak self] in
                let sent = await message(agent, text, delivery == .steer ? .steer : .followUp)
                self?.queue.async {
                    guard let self, var entry = self.inbound[id] else { return }
                    guard !self.closingThreads.contains(id), entry.record.state != .cancelled, sent != .refused else {
                        return reply(.failure(.init(code: "not_running", message: "The thread didn't take the message.")))
                    }
                    if sent == .starting {
                        return reply(.failure(.init(code: "starting", message: "The thread is still starting. Send it again in a moment.")))
                    }
                    // A finished dispatch starts a new run on the same thread, and that run's end is a new result.
                    entry.record.state = .running
                    entry.expectsResult = true
                    entry.finishingRun = nil
                    let current = self.host.threadFacts(agent)
                    entry.record.activity = current.map(Self.activity)
                    entry.startedWorking = current?.status == .working || current?.status == .blocked
                    entry.acceptedAt = self.now
                    entry.record.resultText = nil
                    entry.record.resultBranchFacts = nil
                    entry.record.updatedAt = self.now
                    entry.unsent = true
                    let settled = current?.completedAt != nil && current?.completedAt != before.completedAt
                    if let problem = current?.stopProblem, !settled {
                        self.failStoppedRun(id, entry, problem: problem)
                        // A running acknowledgement reopens the sender's old result. Its existing
                        // status read then picks up the failure, even if the push arrived first.
                        return reply(.success(entry.record))
                    }
                    self.inbound[id] = entry
                    self.save()
                    reply(.success(entry.record))
                    self.pushPending()
                    if let current, settled && (current.status == .done || current.stopProblem != nil) {
                        self.finishRun(id, entry, facts: current)
                    }
                }
            }
        }
    }

    private func closeInbound(_ id: UUID, _ entry: Inbound, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        if entry.record.closeReport != nil { return reply(.success(entry.record)) }
        guard entry.record.kind == .agentDispatch, !entry.record.state.isLive, entry.record.movedOn == nil,
              let agent = entry.record.remoteAgentID, host.threadFacts(agent) != nil else {
            return reply(.failure(.init(code: "not_settled", message: "No settled dispatch thread to close on this Mac.")))
        }
        guard closingThreads.insert(id).inserted else {
            return reply(.failure(.init(code: "closing", message: "Close is already in progress. Try again to check.")))
        }
        let path = entry.worktree
        let branch = entry.record.branch
        // Older records cannot prove which build folders arrived in a snapshot; close the thread but keep those files.
        let candidates = entry.cleanupCandidates ?? []
        let close = host.closeThread
        Task.detached { [weak self] in
            let result: Result<String, FleetDispatchRefusal>
            do {
                let stopped = try await close(agent, id)
                let cleaned = stopped.allowsBuildCleanup ? path.flatMap { path in branch.map { FleetDispatchGit.cleanBuildOutput(worktree: path, branch: $0, names: candidates) } } : nil
                let processes = stopped.summary + (stopped.allowsBuildCleanup ? "" : " Build output kept.")
                let bytes = cleaned?.bytes ?? 0
                let detail = cleaned.flatMap { $0.removed.isEmpty ? nil : " Removed \($0.removed.joined(separator: ", "))." } ?? ""
                let count = path.flatMap { FleetDispatchGit.uncommittedFiles(worktree: $0) }.map { $0.modified + $0.untracked }
                result = .success("Thread removed. \(processes) \(bytes) allocated bytes freed from build output.\(detail) \(Self.closeCheckoutReport(count))")
            } catch let refusal as FleetDispatchRefusal {
                result = .failure(refusal)
            } catch {
                result = .failure(.init(code: "close_failed", message: error.localizedDescription))
            }
            self?.queue.async {
                guard let self else { return }
                self.closingThreads.remove(id)
                switch result {
                case .failure(let refusal): reply(.failure(refusal))
                case .success(let report):
                    guard var current = self.inbound[id] else {
                        return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no such dispatch.")))
                    }
                    current.record.closeReport = report
                    current.record.remoteAgentID = nil
                    self.inbound[id] = current
                    self.save()
                    reply(.success(current.record))
                }
            }
        }
    }

    static func closeCheckoutReport(_ count: Int?) -> String {
        let kept = "Kept the checkout, branches, and saved conversation"
        let output = "unverified output was left alone."
        guard let count else { return "\(kept); \(output) Could not check the checkout for uncommitted work." }
        guard count > 0 else { return "\(kept); \(output)" }
        return "\(kept), including \(count) uncommitted \(count == 1 ? "file" : "files") in the checkout; \(output) Counts include any edits sent with the dispatch."
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
        moveAgentStatusChanged(agentID, status)
        guard let (id, found) = inbound.first(where: { $0.value.record.remoteAgentID == agentID && $0.value.record.state == .running }) else { return }
        var entry = found
        if status == .done, entry.expectsResult, entry.startedWorking {
            return finishRun(id, entry, facts: host.threadFacts(agentID))
        }
        if status == .working || status == .blocked { entry.startedWorking = true }
        if let facts = host.threadFacts(agentID) { entry.record.activity = Self.activity(facts) }
        guard entry != found else { return }
        entry.record.updatedAt = now
        entry.unsent = entry.unsent || entry.record.activity != found.record.activity
        inbound[id] = entry
        save()
        pushPending()
    }

    /// The thread settled: read its last message and its branch, keep them on the record, and push them.
    private func finishRun(_ id: UUID, _ found: Inbound, facts: FleetThreadFacts?) {
        if let failure = facts?.failure { return failRun(id, found, message: failure.message) }
        var entry = found
        entry.expectsResult = false
        let token = UUID()
        entry.finishingRun = token
        inbound[id] = entry
        let text = entry.record.remoteAgentID.flatMap(host.threadResult) ?? ""
        let worktree = facts?.worktree ?? entry.worktree
        let branch = entry.record.branch
        let start = entry.record.commitSHA
        let comparison = entry.record.comparisonBranch ?? entry.record.start?.base.flatMap { base in
            base.hasPrefix("origin/") ? String(base.dropFirst("origin/".count)) : nil
        }
        Task.detached { [weak self] in
            let summary = branch.map { FleetDispatchGit.branchFacts(worktree: worktree, branch: $0, start: start, comparison: comparison) }
            self?.queue.async {
                guard let self, var entry = self.inbound[id], entry.record.state == .running, entry.finishingRun == token else { return }
                entry.finishingRun = nil
                entry.record.resultText = String(text.prefix(FleetDispatchProtocol.maxResultBytes))
                entry.record.resultBranchFacts = summary
                entry.record.state = .delivering
                entry.record.activity = nil
                entry.record.updatedAt = self.now
                entry.unsent = true
                self.inbound[id] = entry
                self.save()
                self.pushPending()
            }
        }
    }

    /// Unexpected exit is not idle work: the retained thread needs attention on its receiving Mac.
    func agentStopped(_ agent: AgentID, problem: NativeStartProblem) {
        guard let (id, found) = inbound.first(where: { $0.value.record.remoteAgentID == agent && $0.value.record.state == .running && $0.value.expectsResult }) else { return }
        failStoppedRun(id, found, problem: problem)
    }

    private func failStoppedRun(_ id: UUID, _ entry: Inbound, problem: NativeStartProblem) {
        let message: String
        if let model = entry.record.model, problem.kind == .notSignedIn {
            message = "The model \(model) is not available on \(hostName())."
        } else if problem.lines.contains(where: { $0.contains("ENOSPC:") || $0.localizedCaseInsensitiveContains("no space left on device") }) {
            message = "No space left on device (ENOSPC)."
        } else {
            message = problem.title
        }
        failRun(id, entry, message: message.split(whereSeparator: \.isNewline).joined(separator: " "))
    }

    private func failRun(_ id: UUID, _ found: Inbound, message: String?) {
        var entry = found
        entry.expectsResult = false
        entry.record.state = .failed
        entry.record.failure = FleetDispatchCode.turnFailed
        entry.record.failureDetail = message.map { String($0.prefix(300)) }
        entry.record.activity = nil
        entry.record.updatedAt = now
        entry.unsent = true
        inbound[id] = entry
        save()
        pushPending()
    }

    /// A dispatched thread was deleted here: its dispatch ends.
    func agentRemoved(_ agentID: AgentID) {
        moveAgentRemoved(agentID)
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
                    // An acknowledgment covers the record we sent, not a later update with the same timestamp.
                    if current.record == record {
                        // The result frame carries no title. Follow it with the renamed record.
                        current.unsent = record.state == .delivering && record.titleRevision != nil
                        if record.state == .delivering { current.record.state = .done }
                    }
                    // A thread that moved on is reported to its sender once, and this Mac has nothing more to follow.
                    if record.movedOn != nil, current.record.movedOn != nil { current.record.state = .done }
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
