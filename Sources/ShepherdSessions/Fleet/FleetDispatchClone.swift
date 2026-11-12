import Foundation
import ShepherdCore
import ShepherdProtocol

/// A Mac with no checkout of a dispatch's repository gets one (slice 4f): it binds a checkout it already has to the space, else it
/// clones from the sender's origin with its own git sign-in, else it clones from a bundle the sender made. The dispatch stays
/// `preparing` meanwhile, its record says where the clone stands, and Stop ends the clone and removes what it made. Every piece of
/// state belongs to the server queue; git runs off it.
///
/// What this writes (docs/rules.md, "Only these paths mutate repositories"): a new checkout at a folder that did not exist,
/// `~/Developer/<repo>` or under `<support>/fleet/repos/`, and a space bound to it. It never writes into an existing checkout.
extension FleetDispatch {
    /// Puts the checkout at `path` in the workspace as a space for `create`'s repository: the sender's space when it named one.
    func bindCheckout(_ path: String, _ create: FleetDispatchCreate) -> Space? {
        host.bindSpace(FleetSpaceBinding(
            id: create.repo?.spaceID, name: create.repo?.name?.fleetNonEmpty ?? FleetRepoClone.folderName(repoKey: create.repoKey), path: path,
            repoKey: create.repoKey, worktreeBase: create.repo?.worktreeBase))
    }

    /// Removes a folder a clone was made in: only ever one this host made for it.
    static func discardClone(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    // MARK: Finding or cloning

    /// The first thing a create with no checkout does: look at the places this Mac knows for one (never a walk of the disk), then clone.
    func acquireRepo(_ id: UUID, _ create: FleetDispatchCreate) {
        let places = host.repoPlaces()
        let finder = self.finder
        let key = create.repoKey
        let viaBundle = create.snapshot?.repoBundle == true
        Task.detached(priority: .utility) { [weak self] in
            finder.refresh(places)
            if let found = finder.locate(key) {
                self?.queue.async { self?.acquired(id, create, path: found.path, made: false) }
                return
            }
            guard let self else { return }
            // The repository is in the snapshot, a bundle to clone from once it has all arrived (`startBuild`).
            if viaBundle {
                self.queue.async {
                    guard let snap = self.snapshotsIn[id] else { return }
                    snap.lookedUp = true
                    if snap.pendingBuild { snap.pendingBuild = false; self.startBuild(id) }
                }
                return
            }
            guard let origin = create.repo?.origin else {
                // A repository with no origin: it can only come from the sender, when there is a snapshot to carry it.
                let canAsk = create.snapshot != nil
                self.queue.async { self.failInbound(id, canAsk ? FleetDispatchCode.cloneFailed : FleetDispatchCode.repoMissing, "this Mac has no checkout of it, and it has no origin to clone from") }
                return
            }
            await self.clone(id, create, source: origin, bundle: false)
        }
    }

    /// Clones `source` (origin's URL, or a bundle's path) into a new folder and reports it. Runs off the queue.
    func clone(_ id: UUID, _ create: FleetDispatchCreate, source: String, bundle: Bool) async {
        let developer = developerFolder
        let repos = directory.appendingPathComponent("repos", isDirectory: true)
        guard let destination = FleetRepoClone.claim(repoKey: create.repoKey, name: create.repo?.name, dispatchID: id, developer: developer, repos: repos) else {
            return queue.async { [weak self] in
                self?.cloneEnded(id, create, nil, .failed("this Mac couldn't make a folder to clone into"), bundle: bundle)
            }
        }
        let job = FleetRepoClone(source: source, destination: destination.path)
        // Registered before it starts, so a Stop that comes in first ends it and the folder goes.
        let registered = await onQueue { [self] in beginClone(id, job, destination.path) }
        guard registered else { return Self.discardClone(destination.path) }
        let origin = create.repo?.origin
        let outcome = job.run { [weak self] update in
            self?.queue.async { self?.cloneProgress(id, update) }
        }
        if bundle, outcome == .done { FleetRepoClone.fixOrigin(at: destination.path, to: origin) }
        queue.async { [weak self] in self?.cloneEnded(id, create, destination.path, outcome, bundle: bundle) }
    }

    private func beginClone(_ id: UUID, _ job: FleetRepoClone, _ folder: String) -> Bool {
        guard inbound[id]?.record.state == .preparing else { return false }
        clones[id] = job
        cloneCount += 1
        inbound[id]?.cloneDirectory = folder
        save()
        return true
    }

    /// git said how far it is: kept on the record, and pushed to the sender at most twice a second.
    private func cloneProgress(_ id: UUID, _ update: FleetRepoClone.Update) {
        guard var entry = inbound[id], entry.record.state == .preparing, var clone = entry.record.clone else { return }
        clone.phase = update.phase
        clone.fraction = update.fraction
        entry.record.clone = clone
        entry.record.activity = "cloning \(clone.name): \(update.phase)"
        inbound[id] = entry
        guard now - (clonePushedAt[id] ?? 0) >= 500 else { return }
        clonePushedAt[id] = now
        inbound[id]?.record.updatedAt = now
        inbound[id]?.unsent = true
        pushPending()
    }

    /// A clone ended. A finished one is bound to the space; a stopped or failed one is removed, and nothing is registered.
    func cloneEnded(_ id: UUID, _ create: FleetDispatchCreate, _ folder: String?, _ outcome: FleetRepoClone.Outcome, bundle: Bool) {
        clones[id] = nil
        clonePushedAt[id] = nil
        inbound[id]?.cloneDirectory = nil
        switch outcome {
        case .done:
            guard let folder else { return }
            acquired(id, create, path: folder, made: true)
        case .cancelled:
            if let folder { Self.discardClone(folder) }
            save()
        case .failed(let why):
            if let folder { Self.discardClone(folder) }
            // From origin, with a snapshot to carry it: ask the sender for the repository itself. Otherwise nothing more can be tried.
            let canAsk = !bundle && create.snapshot != nil && create.snapshot?.repoBundle != true
            failInbound(id, canAsk ? FleetDispatchCode.cloneFailed : FleetDispatchCode.repoMissing, why.isEmpty ? "git couldn't clone it" : why)
        }
    }

    /// This Mac has a checkout now (one it already had, or one just made): it becomes the space, and the work goes on to its worktree.
    func acquired(_ id: UUID, _ create: FleetDispatchCreate, path: String, made: Bool) {
        guard inbound[id]?.record.state == .preparing else {
            // Stopped while it was being found or made: a clone this dispatch made goes; one that was already here stays.
            if made { Self.discardClone(path) }
            return save()
        }
        guard let space = bindCheckout(path, create) else {
            if made { Self.discardClone(path) }
            return failInbound(id, FleetDispatchCode.snapshotFailed, "this Mac couldn't add the repository as a space")
        }
        inbound[id]?.record.clone = nil
        inbound[id]?.record.activity = nil
        inbound[id]?.record.updatedAt = now
        inbound[id]?.unsent = true
        save()
        if let snap = snapshotsIn[id] {
            snap.space = space
            snap.lookedUp = true
            if snap.pendingBuild {
                snap.pendingBuild = false
                startBuild(id)
            } else if snap.building {
                // The clone was of the bundle, made once everything had arrived.
                prepare(id, space: space, requestedBranch: snap.requestedBranch)
            }
        } else {
            prepare(id, space: space, requestedBranch: create.branch)
        }
        pushPending()
    }

    /// The snapshot is all here and carries the repository: clone from its bundle.
    func cloneBundle(_ id: UUID, _ snap: SnapshotIn, _ bundle: FleetBlobRef) {
        guard let entry = inbound[id] else { return }
        let record = entry.record
        let create = FleetDispatchCreate(
            dispatchID: id, kind: record.kind, task: "", title: record.title, repoKey: record.repoKey, commitSHA: record.commitSHA, branch: snap.requestedBranch,
            from: FleetDispatchSender(hostID: record.parentHostID, hostName: record.parentHostName, agentID: record.parentAgentID, agentTitle: record.parentTitle),
            snapshot: snap.header, repo: snap.repo)
        let path = blobs.url(bundle.hash).path
        Task.detached(priority: .utility) { [weak self] in await self?.clone(id, create, source: path, bundle: true) }
    }
}
