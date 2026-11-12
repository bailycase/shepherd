import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The snapshot half of a dispatch (slice 4c, `fleet.snapshot.v1`). The sender works its snapshot out once the target is known and
/// pushes it over the open link: the manifest in parts, then the contents the target says it lacks. The receiver collects the parts,
/// finds what it already holds, asks for the rest in its acknowledgements, builds the worktree when everything is in
/// (`FleetSnapshotApply`) and only then starts the thread. Every piece of state here belongs to the server queue; reading files,
/// hashing, git and cloning run off it.
extension FleetDispatch {
    struct SnapshotLink: Sendable {
        var part: @Sendable (FleetSnapshotPart) async throws -> FleetSnapshotAck
        var blob: @Sendable (FleetBlobChunk) async throws -> FleetSnapshotAck
    }

    // MARK: Sender

    /// Whether this dispatch carries a snapshot: one a thread sent from a checkout, with the setting on.
    func wantsSnapshot(_ record: FleetDispatchRecord) -> Bool {
        record.kind == .agentDispatch && record.commitSHA != nil && pins[record.id] != nil && indexService != nil
            && (host.settings()?.fleetUncommitted ?? .sendThem) == .sendThem
    }

    /// Works out `id`'s snapshot off the queue (from the warm index when this host has one for the checkout, else from a scan of
    /// it) and keeps it for the transfer and for a resend. `done` runs on the queue.
    func buildSnapshot(_ id: UUID, done: @escaping (Result<Void, FleetDispatchRefusal>) -> Void) {
        guard let record = outbound[id], let pin = pins[id], let service = indexService, let target = record.targetHostID, let commit = record.commitSHA else {
            return done(.failure(.init(code: FleetDispatchCode.snapshotFailed, message: "There is no checkout to send.", detail: "no checkout")))
        }
        // A thread's worktree this host hasn't been told of yet starts being indexed now.
        service.reconcile()
        let source = service.snapshotSource(folder: pin.root)
        let held = target == hostID ? service.localManifest(repo: record.repoKey) : service.manifest(of: target, repo: record.repoKey)
        let state = host.state()
        let spaceID = record.parentAgentID.flatMap { agent in state.agents.first { $0.id == agent }?.spaceID }
        let excludes = spaceID.flatMap { host.settings()?.fleetSnapshotExcludes[FleetSnapshotExcludes.settingKey(spaceID: $0.rawValue)] } ?? FleetSnapshotExcludes()
        let outgoing = directory.appendingPathComponent("outgoing", isDirectory: true)
        let classifier = service.classifier
        let caps = self.caps
        let began = ContinuousClock.now
        Task.detached { [weak self] in
            var temporary: FleetContentIndex?
            let index: FleetContentIndex
            if let source {
                index = source.index
                // A checkout still on its first scan: wait for it, as long as a scan takes.
                let deadline = ContinuousClock.now + .seconds(300)
                while index.queue.sync(execute: { index.state }) != .ready, ContinuousClock.now < deadline {
                    let state = index.queue.sync { index.state }
                    if state == .tooLarge || state == .notGit { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
            } else {
                // This host doesn't keep an index of that checkout (a thread's worktree it hasn't been told of yet): scan it now.
                let overrides = FleetExclusions.Overrides(excluded: excludes.excluded, included: excludes.included)
                let scratch = FleetContentIndex(root: pin.root, storage: outgoing.appendingPathComponent("index-\(id.uuidString.lowercased())", isDirectory: true),
                                                exclusions: FleetExclusions(overrides: overrides), classifier: classifier, latency: 0.05)
                scratch.queue.sync { scratch.start() }
                temporary = scratch
                index = scratch
            }
            defer { if let temporary { temporary.requestStop(); temporary.queue.sync { temporary.erase() } } }
            do {
                let sender = FleetSnapshotSender(index: index, root: pin.root, commit: commit, target: held, directory: outgoing, warnAbove: caps.warn, refuseAbove: caps.refuse)
                let built = try sender.build(id: id, unpushed: pin.unpushed)
                let millis = Int((ContinuousClock.now - began) / .milliseconds(1))
                self?.queue.async { self?.timings[id] = (millis, 0); self?.snapshotBuilt(id, built, done: done) }
            } catch let failure as FleetSnapshotSender.Failure {
                let refusal: FleetDispatchRefusal
                switch failure {
                case .tooLarge(let bytes, let biggest):
                    refusal = FleetDispatchRefusal(code: FleetDispatchCode.snapshotTooLarge,
                                                   message: "This checkout is \(FleetSnapshotSizes.text(bytes)) to send, over the \(FleetSnapshotSizes.text(FleetSnapshotCap.refuseAbove)) limit.",
                                                   detail: ([String(bytes)] + biggest).joined(separator: ";"))
                case .notIndexed(let state):
                    refusal = FleetDispatchRefusal(code: FleetDispatchCode.snapshotFailed, message: "This checkout can't be indexed to send (\(state)).", detail: "not indexed: \(state)")
                case .notARepository:
                    refusal = FleetDispatchRefusal(code: FleetDispatchCode.repoMissing, message: "This thread's folder isn't a git checkout.", detail: nil)
                case .git(let what):
                    refusal = FleetDispatchRefusal(code: FleetDispatchCode.snapshotFailed, message: "Couldn't read the checkout (\(what)).", detail: what)
                }
                self?.queue.async { done(.failure(refusal)) }
            } catch {
                self?.queue.async { done(.failure(.init(code: FleetDispatchCode.snapshotFailed, message: "Couldn't read the checkout.", detail: String(describing: error).prefix(160).description))) }
            }
        }
    }

    private func snapshotBuilt(_ id: UUID, _ built: FleetSnapshotSender.Built, done: (Result<Void, FleetDispatchRefusal>) -> Void) {
        guard outbound[id]?.state.isLive == true else {
            if let bundle = built.bundle { try? FileManager.default.removeItem(at: bundle.url) }
            return done(.failure(.init(code: FleetDispatchCode.invalid, message: "The dispatch ended.")))
        }
        snapshots[id] = built
        outbound[id]?.snapshotBytes = built.header.bytes
        outbound[id]?.snapshotProgress = 0
        outbound[id]?.snapshotFiles = built.header.files + built.header.directories
        outbound[id]?.sendWarning = built.warning
        outbound[id]?.updatedAt = now
        save()
        done(.success(()))
    }

    /// The snapshot couldn't be made: the dispatch ends with the code and nothing was sent.
    func snapshotFailed(_ id: UUID, _ refusal: FleetDispatchRefusal, completion: ((Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void)?) {
        guard var record = outbound[id], record.state.isLive else { return completion?(.failure(refusal)) ?? () }
        record.state = .failed
        record.failure = refusal.code
        record.failureDetail = refusal.detail
        record.updatedAt = now
        outbound[id] = record
        releaseSnapshot(id: id)
        save()
        completion?(.failure(refusal))
    }

    /// The pieces of a snapshot the sender holds go when the dispatch is past needing them.
    func releaseSnapshot(id: UUID) {
        if let built = snapshots.removeValue(forKey: id), let bundle = built.bundle { try? FileManager.default.removeItem(at: bundle.url) }
        pins[id] = nil
        transferring.remove(id)
    }

    private func snapshotLink(id: UUID, target: UUID) -> SnapshotLink? {
        if target == hostID {
            func local(_ body: @escaping @Sendable (@escaping (Result<FleetSnapshotAck, FleetDispatchRefusal>) -> Void) -> Void) async throws -> FleetSnapshotAck {
                try await withCheckedThrowingContinuation { continuation in
                    queue.async {
                        body { result in
                            switch result {
                            case .success(let ack): continuation.resume(returning: ack)
                            case .failure(let refusal): continuation.resume(throwing: RemoteHostClientError.rejected(code: refusal.code, message: refusal.message))
                            }
                        }
                    }
                }
            }
            let me = hostID
            return SnapshotLink(
                part: { [weak self] part in try await local { done in self?.receiveSnapshotPart(id, part, from: me, reply: done) } },
                blob: { [weak self] chunk in try await local { done in self?.receiveBlobPush(id, chunk, from: me, reply: done) } })
        }
        guard let link = client(target) else { return nil }
        return SnapshotLink(part: { try await link.fleetSnapshotPart(id, $0) }, blob: { try await link.fleetBlobPush(id, $0) })
    }

    /// Pushes `id`'s snapshot: where the receiver stands, the parts it lacks, then the contents it says it lacks. Resumes from what it
    /// holds, so a link that dropped costs only what hadn't arrived.
    func transfer(_ id: UUID) {
        guard let built = snapshots[id], let record = outbound[id], let target = record.targetHostID, record.state == .preparing,
              !transferring.contains(id), let link = snapshotLink(id: id, target: target) else { return }
        transferring.insert(id)
        let wire = self.wire
        let began = ContinuousClock.now
        Task.detached { [weak self] in
            do {
                try await Self.push(built, over: link, wire: wire,
                                    live: { await self?.onQueue { self?.outbound[id]?.state == .preparing } ?? false },
                                    progress: { sent in self?.queue.async { self?.progressed(id, sent) } })
                let millis = Int((ContinuousClock.now - began) / .milliseconds(1))
                self?.queue.async { self?.transferring.remove(id); self?.timings[id]?.transfer = millis }
            } catch {
                self?.queue.async { self?.transferFailed(id, error) }
            }
        }
    }

    static func push(_ built: FleetSnapshotSender.Built, over link: SnapshotLink, wire: (@Sendable (FleetBlobChunk) async throws -> FleetBlobChunk)?,
                     live: @escaping @Sendable () async -> Bool, progress: @escaping @Sendable (UInt64) -> Void) async throws {
        var ack = try await link.part(FleetSnapshotPart(index: -1))
        var next = ack.parts
        while next < built.parts.count {
            guard await live() else { return }
            ack = try await link.part(built.parts[next])
            next = max(next + 1, ack.parts)
        }
        let links = Set(built.plan.manifest.files.filter { $0.kind == .symlink }.map(\.hash))
        var sent: UInt64 = 0
        for _ in 0..<8 {
            ack = try await link.part(FleetSnapshotPart(index: -1, wantsNeeds: true))
            if ack.needsCount == 0 { return }
            for hash in ack.needs {
                guard await live() else { return }
                let path: String
                if let bundle = built.bundle, bundle.ref.hash == hash { path = bundle.url.path }
                else if let source = built.plan.sources[hash] { path = built.root + "/" + source }
                else { throw RemoteHostClientError.rejected(code: FleetDispatchCode.snapshotFailed, message: "The target asked for a content this checkout doesn't have.") }
                try await FleetSnapshotReader.chunks(path: path, hash: hash, link: links.contains(hash)) { chunk in
                    var chunk = chunk
                    if let wire { chunk = try await wire(chunk) }
                    _ = try await link.blob(chunk)
                    sent += UInt64(chunk.data.count)
                    progress(sent)
                }
            }
        }
        throw RemoteHostClientError.rejected(code: FleetDispatchCode.snapshotFailed, message: "The target kept asking for contents.")
    }

    private func progressed(_ id: UUID, _ sent: UInt64) {
        guard outbound[id]?.state == .preparing, let total = outbound[id]?.snapshotBytes else { return }
        outbound[id]?.snapshotProgress = min(sent, total)
        if now - progressSavedAt > 500 { progressSavedAt = now; save() } else { onChange?() }
    }

    private func transferFailed(_ id: UUID, _ error: Error) {
        transferring.remove(id)
        guard var record = outbound[id], record.state == .preparing else { return }
        var code = FleetDispatchCode.snapshotFailed
        var detail: String?
        if case RemoteHostClientError.rejected(let rejected, let message) = error {
            if Self.transportCodes.contains(rejected) {
                // The link went, not the dispatch: it waits on that Mac and the next create carries on from what arrived.
                record.state = .waitingWake
                record.updatedAt = now
                outbound[id] = record
                save()
                return scheduleEvaluation()
            }
            code = [FleetDispatchCode.snapshotMismatch, FleetDispatchCode.commitUnreachable, FleetDispatchCode.repoMissing, FleetDispatchCode.repoAmbiguous,
                    FleetDispatchCode.snapshotFailed, FleetDispatchCode.snapshotTooLarge].contains(rejected) ? rejected : FleetDispatchCode.snapshotFailed
            detail = String(message.prefix(200))
            // A manifest that claimed a directory the Mac no longer holds is dropped, so its next step is answered with a request for everything.
            if code == FleetDispatchCode.snapshotMismatch, message.contains("stale manifest"), let target = record.targetHostID {
                indexService?.dropPeerCopy(peer: target, repo: record.repoKey)
            }
        } else if error is FleetSnapshotReader.Failure {
            detail = "a file changed while it was being sent"
        } else {
            detail = String(describing: error).prefix(160).description
        }
        record.state = .failed
        record.failure = code
        record.failureDetail = detail
        record.updatedAt = now
        outbound[id] = record
        releaseSnapshot(id: id)
        save()
        // The target stops waiting for the rest (when it can be told).
        if let target = record.targetHostID, target != hostID, let link = client(target) { Task { _ = try? await link.fleetDispatchControl(id, .cancel) } }
        else if record.targetHostID == hostID { queue.async { [weak self] in self?.control(id, .cancel, from: self?.hostID ?? UUID()) { _ in } } }
    }

    // MARK: Receiver

    private func ack(_ snap: SnapshotIn, id: UUID, withNeeds: Bool = false, complete: Bool = false) -> FleetSnapshotAck {
        let left = snap.needOrder.filter { snap.needs?.contains($0) == true }
        return FleetSnapshotAck(dispatchID: id, parts: snap.held, needs: withNeeds ? Array(left.prefix(FleetSnapshotTransfer.maxNeeds)) : [],
                                needsCount: left.count, complete: complete)
    }

    private func arriving(_ id: UUID, from sender: UUID) -> Result<SnapshotIn, FleetDispatchRefusal> {
        guard membership() else { return .failure(Self.refusal(FleetDispatchCode.fleetOff, nil)) }
        guard let entry = inbound[id], entry.record.parentHostID == sender, let snap = snapshotsIn[id] else {
            return .failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That Mac has no snapshot arriving for that dispatch."))
        }
        guard entry.record.state == .preparing else {
            return .failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "That dispatch isn't waiting for a snapshot (it is \(entry.record.state.rawValue))."))
        }
        return .success(snap)
    }

    /// `fleetSnapshotPart`: keeps the part, and once the manifest is whole says what this Mac still lacks.
    func receiveSnapshotPart(_ id: UUID, _ part: FleetSnapshotPart, from sender: UUID, reply: @escaping (Result<FleetSnapshotAck, FleetDispatchRefusal>) -> Void) {
        let snap: SnapshotIn
        switch arriving(id, from: sender) {
        case .failure(let refusal): return reply(.failure(refusal))
        case .success(let found): snap = found
        }
        if part.index >= 0 {
            guard part.index < snap.header.parts, part.entryCount <= FleetSnapshotTransfer.entriesPerPart * 2 else {
                return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That part isn't one of the snapshot's.")))
            }
            if snap.parts[part.index] == nil {
                snap.parts[part.index] = part
                snap.needs = nil
            }
        }
        guard snap.held == snap.header.parts else { return reply(.success(ack(snap, id: id))) }
        // The manifest is whole: what this Mac lacks of it.
        refreshNeeds(id, snap) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let refusal): reply(.failure(refusal))
            case .success: reply(.success(self.ack(snap, id: id, withNeeds: part.wantsNeeds, complete: snap.needs?.isEmpty == true)))
            }
        }
    }

    /// Works out the manifest and the contents still lacking, off the queue; kept on `snap` until the parts change.
    func refreshNeeds(_ id: UUID, _ snap: SnapshotIn, done: @escaping (Result<Void, FleetDispatchRefusal>) -> Void) {
        if snap.needs != nil { return done(.success(())) }
        let parts = snap.parts, header = snap.header, blobs = self.blobs
        Task.detached { [weak self] in
            guard let self else { return }
            let indexes = await self.onQueue { self.indexService?.indexes() ?? [] }
            let outcome = Self.assemble(parts: parts, header: header, blobs: blobs, indexes: indexes)
            self.queue.async {
                switch outcome {
                case .failure(let failure):
                    self.failInbound(id, failure.code, failure.detail)
                    done(.failure(Self.refusal(failure.code, failure.detail)))
                case .success(let (manifest, needs)):
                    snap.manifest = manifest
                    snap.needOrder = needs
                    snap.needs = Set(needs)
                    done(.success(()))
                    if needs.isEmpty { self.startBuild(id) }
                }
            }
        }
    }

    /// The manifest the parts make, checked against the header, and the contents this Mac doesn't hold. Off the queue.
    static func assemble(parts: [Int: FleetSnapshotPart], header: FleetSnapshotHeader, blobs: FleetSnapshotBlobs, indexes: [FleetContentIndex])
        -> Result<(FleetSnapshotManifest, [FleetHash]), FleetSnapshotApply.Failure> {
        func bad(_ detail: String) -> Result<(FleetSnapshotManifest, [FleetHash]), FleetSnapshotApply.Failure> {
            .failure(.init(code: FleetDispatchCode.snapshotMismatch, detail: detail))
        }
        let ordered = parts.keys.sorted().compactMap { parts[$0] }
        let manifest = FleetSnapshotManifest(commit: header.commit, files: ordered.flatMap(\.files), directories: ordered.flatMap(\.directories),
                                             deletions: ordered.flatMap(\.deletions), rootHash: header.rootHash)
        guard manifest.files.count == header.files, manifest.directories.count == header.directories, manifest.deletions.count == header.deletions else {
            return bad("the parts don't add up")
        }
        if let problem = manifest.problem { return bad(problem) }
        guard manifest.digest == header.digest else { return bad("digest") }
        let wantedFiles = Set(manifest.files.map(\.hash))
        let wantedDirectories = Set(manifest.directories.map(\.hash))
        var files: [FleetHash: FleetContentIndex.Located] = [:], directories: [FleetHash: FleetContentIndex.Located] = [:]
        for index in indexes {
            let found = index.queue.sync {
                index.locate(files: wantedFiles.filter { files[$0] == nil && !blobs.has($0) }, directories: wantedDirectories.filter { directories[$0] == nil }, gitIDs: [])
            }
            files.merge(found.files) { first, _ in first }
            directories.merge(found.directories) { first, _ in first }
        }
        for directory in manifest.directories where directories[directory.hash] == nil { return bad("stale manifest: directory \(directory.path.prefix(80))") }
        var needs: [FleetHash] = []
        var seen = Set<FleetHash>()
        for file in manifest.files where seen.insert(file.hash).inserted {
            if blobs.has(file.hash) { blobs.touch(file.hash); continue }
            if let held = files[file.hash], FleetSnapshotApply.unchanged(held, size: file.size) { continue }
            needs.append(file.hash)
        }
        if let bundle = header.bundle, !blobs.has(bundle.hash) { needs.append(bundle.hash) }
        return .success((manifest, needs))
    }

    /// `fleetBlobPush`: a piece of a content this Mac asked for.
    func receiveBlobPush(_ id: UUID, _ chunk: FleetBlobChunk, from sender: UUID, reply: @escaping (Result<FleetSnapshotAck, FleetDispatchRefusal>) -> Void) {
        let snap: SnapshotIn
        switch arriving(id, from: sender) {
        case .failure(let refusal): return reply(.failure(refusal))
        case .success(let found): snap = found
        }
        guard chunk.isValid, snap.needs?.contains(chunk.hash) == true else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That content isn't one this Mac asked for.")))
        }
        let blobs = self.blobs
        Task.detached { [weak self] in
            do {
                let complete = try blobs.receive(chunk)
                self?.queue.async {
                    guard let self else { return }
                    if complete { snap.needs?.remove(chunk.hash) }
                    let left = snap.needs?.count ?? 0
                    reply(.success(FleetSnapshotAck(dispatchID: id, parts: snap.held, needsCount: left, complete: left == 0)))
                    if complete, left == 0 { self.startBuild(id) }
                }
            } catch FleetSnapshotBlobs.Failure.mismatch {
                self?.queue.async {
                    self?.failInbound(id, FleetDispatchCode.snapshotMismatch, "a content doesn't match its hash")
                    reply(.failure(Self.refusal(FleetDispatchCode.snapshotMismatch, "a content doesn't match its hash")))
                }
            } catch {
                self?.queue.async { reply(.failure(.init(code: FleetDispatchCode.snapshotFailed, message: "This Mac couldn't keep that content."))) }
            }
        }
    }

    /// Everything is in: build the worktree (once).
    func startBuild(_ id: UUID) {
        guard let snap = snapshotsIn[id], !snap.building, inbound[id]?.record.state == .preparing else { return }
        snap.building = true
        prepare(id, space: snap.space, requestedBranch: snap.requestedBranch)
    }

    /// Fleet is on and the spaces may have changed: each repository's spare is brought to its base tip in the background.
    func refreshSpares(_ spaces: [Space]) {
        var seen = Set<String>()
        let repos = spaces.compactMap { space -> (String, String?)? in
            guard space.repoKey != nil, Self.folderExists(space.path) else { return nil }
            let path = PiHome.canonical(space.path)
            return seen.insert(path).inserted ? (path, space.worktreeBase) : nil
        }
        let spares = self.spares
        Task.detached(priority: .utility) {
            for (repo, base) in repos { spares.refresh(repo: repo, base: base) }
        }
    }
}

/// Sizes in the words a refusal and a card use.
enum FleetSnapshotSizes {
    static func text(_ bytes: UInt64) -> String {
        let gib = Double(bytes) / Double(1 << 30)
        if gib >= 1 { return String(format: "%.1f GiB", gib) }
        let mib = Double(bytes) / Double(1 << 20)
        return mib >= 1 ? String(format: "%.1f MiB", mib) : "\(max(bytes / 1024, 1)) KiB"
    }
}
