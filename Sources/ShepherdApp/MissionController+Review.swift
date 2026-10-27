import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

extension MissionController {
    nonisolated static func digest(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

    func collectReviews(_ id: MissionID) async throws -> [MissionRepositoryReview] {
        let mission = try record(id)
        guard let run = mission.run else { return [] }
        var values: [MissionRepositoryReview] = [], infos: [SpaceID: RemoteCommitInfo] = [:]
        for checkout in run.checkouts {
            let task = Task.detached { try GitWorktree.verifyIdentity(worktree: checkout.path, repo: checkout.repo, branch: checkout.branch) }
            try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
            let info = try await ReviewCommitGit.info(cwd: checkout.path, agentWorking: false, draftsMessage: false,
                                                    runner: { await Self.command($0, cwd: $1) })
            guard info.branch == checkout.branch, info.blocked == nil else { throw MissionError("mission_checkout", "A mission worktree changed branch or is blocked. \(info.blocked ?? "")") }
            let origin = await Self.command("git remote get-url --push origin", cwd: checkout.path)
            let originFingerprint = origin.status == 0 ? Self.digest(origin.stdout) : nil
            guard originFingerprint == checkout.originFingerprint else { throw MissionError("mission_remote", "The repository's publication destination changed. Nothing will be pushed to a different remote.") }
            let snapshotTask = Task.detached {
                let branchFiles = try GitDiff.load(cwd: checkout.path, reference: checkout.head)
                let localFiles = try GitDiff.load(cwd: checkout.path, reference: nil)
                let known = Set(branchFiles.map(\.id))
                let files = branchFiles + localFiles.filter { !known.contains($0.id) }
                let receipts = reviewCommitFiles(files) { _ in "" }.map { file in
                    var file = file
                    file.fingerprint = ReviewCommitGit.fingerprint(root: checkout.path, paths: file.paths)
                    return file
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(receipts.sorted { $0.path < $1.path })
                let diff = String(decoding: try encoder.encode(files), as: UTF8.self)
                let fingerprint = Self.digest(checkout.branch + "\n" + checkout.head + "\n" + (originFingerprint ?? "") + "\n" + String(decoding: data, as: UTF8.self) + "\n" + diff)
                return (files, fingerprint)
            }
            let snapshot = try await withTaskCancellationHandler { try await snapshotTask.value } onCancel: { snapshotTask.cancel() }
            try Task.checkCancellation()
            // Commits the mission's own Spec Kit turns made are its work (`observedHead`); anything past them is not.
            let base = checkout.observedHead ?? checkout.head
            if info.head != base {
                let parent = await Self.command("git rev-parse HEAD^", cwd: checkout.path)
                let knownCommit = checkout.publishedHead.map { info.head.hasPrefix($0) } ?? true
                guard run.publicationApproval != nil, knownCommit, info.files.isEmpty,
                      parent.status == 0, parent.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == base,
                      checkout.fingerprint == snapshot.1 else {
                    throw MissionError("mission_unexpected_commit", "The mission branch contains an unapproved commit or changed published content. Inspect it before continuing; nothing was pushed.")
                }
            }
            infos[checkout.spaceID] = info
            let name = mission.draft.plan?.lanes.first { $0.spaceID == checkout.spaceID }?.name ?? checkout.branch
            values.append(.init(spaceID: checkout.spaceID, name: name, path: checkout.path, branch: checkout.branch,
                                head: info.head, fingerprint: snapshot.1, files: snapshot.0))
        }
        reviewInfo[id] = infos
        return values
    }

    func reviewFingerprint(_ mission: Mission, reviews: [MissionRepositoryReview]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let contract = String(decoding: try encoder.encode(mission.draft), as: UTF8.self)
        return Self.digest(contract + "\n" + reviews.sorted { $0.spaceID.rawValue < $1.spaceID.rawValue }.map { $0.spaceID.rawValue + ":" + $0.fingerprint }.joined(separator: "\n"))
    }

    func staleValidation(_ mission: Mission, reviews: [MissionRepositoryReview]) -> Set<MissionStationID> {
        let fingerprints = Dictionary(uniqueKeysWithValues: reviews.map { ($0.spaceID.rawValue, $0.fingerprint) })
        return Set((mission.draft.plan?.stations ?? []).filter { station in
            guard station.kind == .check || station.kind == .validator else { return false }
            guard let receipt = mission.run?.latest(station.id), receipt.status == .succeeded,
                  let inputs = receipt.inputFingerprints, !inputs.isEmpty else { return true }
            return inputs.contains { fingerprints[$0.key] != $0.value }
        }.map(\.id))
    }

    func prepareReview(_ id: MissionID, runID: UUID) async throws {
        let mission = try record(id, runID: runID)
        let collected = try await collectReviews(id)
        guard collected.contains(where: { !$0.files.isEmpty }) else { throw MissionError("mission_no_changes", "There are no file changes to publish. Inspect the evidence before closing this mission.") }
        guard staleValidation(mission, reviews: collected).isEmpty else { throw MissionError("mission_stale_evidence", "Content changed after validation. Revalidate the current files before review.") }
        let fingerprint = try reviewFingerprint(mission, reviews: collected)
        _ = try await server.updateMissionRun(id: id, runID: runID) { run in
            for index in run.checkouts.indices { run.checkouts[index].fingerprint = collected.first { $0.spaceID == run.checkouts[index].spaceID }?.fingerprint }
            run.reviewFingerprint = fingerprint
            run.transition(to: .review, at: Self.now, notice: "Validation finished. Review the actual changes, then approve publication. No branch has been pushed.")
        }
        reviews[id] = collected
    }

    func refreshReview(id: MissionID) async throws { reviews[id] = try await collectReviews(id) }

    func publish(id: MissionID, revision: UInt64, fingerprint: String) async throws {
        let mission = try record(id)
        guard mission.revision == revision, var run = mission.run, jobs[id] == nil,
              ([.review, .paused].contains(run.phase) || (run.phase == .stopped && run.publicationApproval != nil)), run.reviewFingerprint == fingerprint,
              let plan = mission.draft.plan, !plan.stations.isEmpty,
              run.specKit != nil ? specKitReadyToPublish(mission) : plan.stations.allSatisfy({ run.latest($0.id)?.status == .succeeded }) else {
            throw MissionError("mission_stale_review", "Review the current validated changes before publishing.")
        }
        run.id = UUID(); run.transition(to: .publishing, at: Self.now)
        _ = try await server.setMissionRun(id: id, expectedRevision: revision, run: run)
        schedule(id: id, runID: run.id) { try await self.publishApproved(id, runID: run.id, fingerprint: fingerprint) }
    }

    func publishApproved(_ id: MissionID, runID: UUID, fingerprint: String) async throws {
        var mission = try record(id, runID: runID)
        let collected = try await collectReviews(id)
        guard try reviewFingerprint(mission, reviews: collected) == fingerprint else {
            throw MissionError("mission_stale_review", "Files or the validation contract changed after review. Revalidate before publishing; nothing was pushed.")
        }
        guard let vm, let run = mission.run else { throw CancellationError() }
        let paths = Set(run.checkouts.map { PiHome.canonical($0.path) })
        guard paths.isDisjoint(with: vm.hostBusyWorktrees) else { throw MissionError("mission_busy", "A checkout operation is already running.") }
        vm.hostBusyWorktrees.formUnion(paths)
        defer { vm.hostBusyWorktrees.subtract(paths) }
        for checkout in run.checkouts {
            guard let info = reviewInfo[id]?[checkout.spaceID], info.pushRemote == "origin",
                  info.upstream == nil || info.upstream == "origin/" + checkout.branch, checkout.originFingerprint != nil else {
                throw MissionError("mission_publish_setup", "Each repository needs an unchanged origin and default branch. Mission branches may track only their matching branch on origin.")
            }
            let base = await Self.command("git ls-remote --exit-code --heads origin \(shellQuoted("refs/heads/" + checkout.base))", cwd: checkout.path)
            guard base.status == 0 else { throw MissionError("mission_publish_base", "The selected PR base \(checkout.base) is not available on origin. Publish that base yourself or start from another branch; no mission commits were made.") }
            // The branch is the mission's own on origin: absent, or exactly what this mission already pushed. A Spec Kit
            // feature branch name (001-…) is not unique to the mission, and a push must never land on someone else's.
            let remote = await Self.command("git ls-remote --heads origin \(shellQuoted("refs/heads/" + checkout.branch))", cwd: checkout.path)
            let remoteHead = remote.stdout.split(separator: "\t").first.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
            guard remote.status == 0, remoteHead.isEmpty || (checkout.publishedHead.map { remoteHead.hasPrefix($0) || $0.hasPrefix(remoteHead) } ?? false) else {
                throw MissionError("mission_publish_branch", "origin already has a branch named \(checkout.branch) that this mission didn't push. Nothing was pushed; rename or remove that branch on origin, then publish again.")
            }
        }
        let auth = await Self.command("gh auth status >/dev/null 2>&1", cwd: run.checkouts.first?.path)
        guard auth.status == 0 else { throw MissionError("mission_github", "Sign in to GitHub CLI (gh) before publishing. No commits or pushes were made.") }
        mission = try await server.updateMissionRun(id: id, runID: runID) { $0.publicationApproval = fingerprint }
        for original in run.checkouts {
            _ = try record(id, runID: runID)
            let fresh = try await collectReviews(id)
            guard try reviewFingerprint(mission, reviews: fresh) == fingerprint,
                  let checkout = try record(id).run?.checkouts.first(where: { $0.spaceID == original.spaceID }),
                  let info = reviewInfo[id]?[original.spaceID] else {
                throw MissionError("mission_stale_review", "Reviewed files changed while publishing. Publication stopped; existing receipts are retained.")
            }
            if checkout.prURL != nil { continue }
            if fresh.first(where: { $0.spaceID == checkout.spaceID })?.files.isEmpty != false { continue }
            let title = Self.safeText(mission.draft.title, bytes: 200)
            let body = Self.safeText(mission.draft.goal + "\n\nAcceptance conditions\n" + mission.draft.requirements.map { "- " + $0 }.joined(separator: "\n"), bytes: 16_000)
            // Reviewed changes still uncommitted: commit them on top of the mission's own commits. Everything already
            // committed by its turns (or a retained approved commit) is pushed as it is.
            if info.head == (checkout.observedHead ?? checkout.head), !info.files.isEmpty {
                let committer = ReviewCommitter()
                committer.runner = { script, cwd in
                    guard let current = try? self.record(id, runID: runID), let run = current.run else {
                        return .init(status: 130, stdout: "", stderr: "Mission stopped. No further publication step was started.")
                    }
                    var command = script
                    if script.hasPrefix("git push ") {
                        do {
                            let committed = try await self.collectReviews(id)
                            guard try self.reviewFingerprint(current, reviews: committed) == fingerprint,
                                  let head = committed.first(where: { $0.spaceID == checkout.spaceID })?.head else {
                                throw MissionError("mission_stale_commit", "A commit hook changed the reviewed files. Nothing was pushed.")
                            }
                            command = "git push origin \(shellQuoted(head + ":refs/heads/" + checkout.branch))"
                        } catch { return .init(status: 1, stdout: "", stderr: Self.safeText(String(describing: error))) }
                    }
                    return await Self.command(command, cwd: cwd, timeout: min(60, current.draft.limits.seconds - run.elapsed(at: Self.now)))
                }
                await committer.run(.init(head: info.head, files: info.files, title: title, body: body, push: .pullRequest), cwd: checkout.path, pullRequestBase: checkout.base)
                try await savePublicationReceipt(id, runID: runID, space: checkout.spaceID, head: committer.commitID, url: committer.prURL)
                guard committer.phase == .succeeded, committer.prURL != nil else {
                    throw MissionError("mission_publish_failed", Self.safeText(committer.failure ?? "GitHub did not return a PR URL. Inspect the retained commit before retrying."))
                }
            } else {
                // A previous push/PR failure or app exit left the exact approved single commit, or the mission's own
                // turns committed everything. collectReviews verified the history and payload. Nothing is recommitted.
                try await savePublicationReceipt(id, runID: runID, space: checkout.spaceID, head: info.head, url: nil)
                let push = await Self.command("git push -u origin \(shellQuoted(info.head + ":refs/heads/" + checkout.branch))", cwd: checkout.path)
                guard push.status == 0 else { throw MissionError("mission_push", Self.safeText(push.stderr)) }
                _ = try record(id, runID: runID)
                let existing = await Self.command("gh pr list --state all --head \(shellQuoted(checkout.branch)) --base \(shellQuoted(checkout.base)) --json url,state,headRefOid", cwd: checkout.path)
                struct PR: Decodable { var url: String; var state: String; var headRefOid: String? }
                guard existing.status == 0, let prs = try? JSONDecoder().decode([PR].self, from: Data(existing.stdout.utf8)) else {
                    throw MissionError("mission_pr_lookup", "The branch was pushed, but GitHub could not confirm whether its PR exists. Retry publication after checking GitHub.")
                }
                let url: String?
                if let pr = prs.first {
                    guard pr.headRefOid == nil || pr.headRefOid == info.head else {
                        throw MissionError("mission_pr_foreign", "A PR for \(checkout.branch) already exists on another commit; it isn't this mission's. Nothing was reused.")
                    }
                    guard pr.state == "OPEN" else { throw MissionError("mission_pr_closed", "This branch's PR is already closed or merged. It will not be reopened automatically.") }
                    url = pr.url
                } else {
                    let created = await Self.command("gh pr create --head \(shellQuoted(checkout.branch)) --base \(shellQuoted(checkout.base)) --title \(shellQuoted(title)) --body \(shellQuoted(body))", cwd: checkout.path)
                    guard created.status == 0 else { throw MissionError("mission_pr_create", Self.safeText(created.stderr)) }
                    url = created.stdout.split(separator: "\n").map(String.init).last { $0.hasPrefix("https://") }
                }
                guard let url else { throw MissionError("mission_pr_create", "GitHub did not return the PR URL.") }
                try await savePublicationReceipt(id, runID: runID, space: checkout.spaceID, head: info.head, url: url)
            }
        }
        _ = try await server.updateMissionRun(id: id, runID: runID) {
            $0.transition(to: .done, at: Self.now, notice: "PRs published. Nothing was merged, deployed, tagged or rolled back. Review and CI continue on GitHub.")
        }
    }

    /// Receipt writes may finish after Stop. They never reactivate a run or authorize another side effect.
    func savePublicationReceipt(_ id: MissionID, runID: UUID, space: SpaceID, head: String?, url: String?) async throws {
        let mission = try record(id)
        guard var run = mission.run, run.id == runID, run.publicationApproval != nil,
              let index = run.checkouts.firstIndex(where: { $0.spaceID == space }) else { throw CancellationError() }
        if let head { run.checkouts[index].publishedHead = head }
        if let url {
            guard let parsed = URL(string: url), parsed.scheme == "https", parsed.host != nil else { throw MissionError("mission_pr_url", "GitHub returned an invalid PR link.") }
            run.checkouts[index].prURL = url
        }
        _ = try await server.setMissionRun(id: id, expectedRevision: mission.revision, run: run)
    }
}
