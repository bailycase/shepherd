import Darwin
import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Mission runtime", .mainActorExclusive)
@MainActor
struct MissionRuntimeTests {
    // Executable replacement is process-wide, so every scenario runs in its own isolated child.
    @Test func twoRepositoriesReachReviewAndOnlyExplicitPublishPushesTheirPRs() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.publishScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func rejectingValidatorExhaustsTheDefaultRetryLimitWithoutPublishing() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.retryScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aRevisedMapWaitsAsAPatchUntilTheOwnerAppliesOrRejectsIt() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.patchScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func theMergeTrainMergesInOrderAndPausesOnRedCIOrACodeConflict() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.trainScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aMissionWaitsForPathsAnotherHoldsAndAWorkerWritingElsewherePauses() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.locksScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aFinishedMissionSavesAsATemplateHereOrThroughAPRAndANewMissionStartsFromIt() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.templateScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func stopKillsAnInFlightHostCheckAndItsChildWithoutAcceptingLateEvidence() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.stopScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func pausedMissionSurvivesRestartWithoutLaunchingAnyAgentOrCommand() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.restartScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func changedReviewBytesCannotBeCommittedOrPublishedWithAnOldFingerprint() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.staleScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func selectedNoncurrentBranchesForkNewWorktreesWithoutTouchingDirtyPrimaryCheckouts() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.selectedBranchesScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func launchAndExplicitRevalidationCannotReuseEvidenceForChangedReviewContent() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.freshValidationScenario() }
        }
        expectScenarioCompleted(result)
    }

    @Test func failedPRCreationRetainsThePushedCommitAndRetriesOnlyAuthorizedPublication() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.partialPublicationScenario() }
        }
        expectScenarioCompleted(result)
    }

    static func selectedBranchesScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        var branches: [SpaceID: String] = [:], chosenHeads: [String] = []
        var dirtyStatus: [String] = [], staged: [String] = [], unstaged: [String] = []
        for (index, repo) in fixture.repos.enumerated() {
            let branch = "selected/lane-\(index)"
            try git(["switch", "-c", branch], in: repo)
            try Data("selected lane \(index)\n".utf8).write(to: repo.appendingPathComponent("result.txt"))
            try git(["commit", "-am", "chosen branch content"], in: repo)
            chosenHeads.append(try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines))
            try git(["push", "origin", branch], in: repo)
            try git(["switch", "main"], in: repo)
            // Exercise both supported full-ref forms, neither equal to the current branch.
            branches[fixture.spaces[index].id] = (index == 0 ? "refs/heads/" : "refs/remotes/origin/") + branch
            try Data("owner staged \(index)\n".utf8).write(to: repo.appendingPathComponent("result.txt"))
            try git(["add", "result.txt"], in: repo)
            try Data("owner unstaged \(index)\n".utf8).write(to: repo.appendingPathComponent("result.txt"))
            try Data("owner untracked\n".utf8).write(to: repo.appendingPathComponent("owner-notes.txt"))
            dirtyStatus.append(try git(["status", "--porcelain"], in: repo))
            staged.append(try git(["diff", "--cached", "--binary"], in: repo))
            unstaged.append(try git(["diff", "--binary"], in: repo))
            #expect(try git(["worktree", "list", "--porcelain"], in: repo).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 1)
        }
        try await fixture.start()
        let id = try await fixture.create(branches: branches)
        let mission = try fixture.controller.record(id)
        let run = try #require(mission.run)
        #expect(run.checkouts.count == 2 && run.attempts.count == 1)
        #expect(mission.approvedPlanRevision == nil)
        for (index, repo) in fixture.repos.enumerated() {
            let space = fixture.spaces[index].id
            let checkout = try #require(run.checkouts.first { $0.spaceID == space })
            let path = URL(fileURLWithPath: checkout.path)
            #expect(mission.draft.plan?.lanes.first { $0.spaceID == space }?.baseBranch == branches[space])
            #expect(checkout.base == "selected/lane-\(index)")
            #expect(checkout.head == chosenHeads[index] && checkout.head != fixture.initialHeads[index])
            #expect(checkout.path != repo.path)
            #expect(checkout.branch.hasPrefix("mission/"))
            #expect(try git(["rev-parse", "HEAD"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == chosenHeads[index])
            #expect(try git(["branch", "--show-current"], in: path).trimmingCharacters(in: .whitespacesAndNewlines) == checkout.branch)
            #expect(try String(contentsOf: path.appendingPathComponent(".git"), encoding: .utf8).hasPrefix("gitdir: "))
            #expect(try String(contentsOf: path.appendingPathComponent("result.txt"), encoding: .utf8) == "selected lane \(index)\n")
            #expect(try git(["status", "--porcelain"], in: path).isEmpty)
            #expect(!FileManager.default.fileExists(atPath: path.appendingPathComponent("owner-notes.txt").path))
            #expect(try git(["worktree", "list", "--porcelain"], in: repo).split(separator: "\n").filter { $0.hasPrefix("worktree ") }.count == 2)
            #expect(try git(["symbolic-ref", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) == "refs/heads/main")
            #expect(try git(["rev-parse", "HEAD"], in: repo).trimmingCharacters(in: .whitespacesAndNewlines) == fixture.initialHeads[index])
            #expect(try git(["status", "--porcelain"], in: repo) == dirtyStatus[index])
            #expect(try git(["diff", "--cached", "--binary"], in: repo) == staged[index])
            #expect(try git(["diff", "--binary"], in: repo) == unstaged[index])
            #expect(try String(contentsOf: repo.appendingPathComponent("result.txt"), encoding: .utf8) == "owner unstaged \(index)\n")
            #expect(try String(contentsOf: repo.appendingPathComponent("owner-notes.txt"), encoding: .utf8) == "owner untracked\n")
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.ghLog.path))
    }

    static func freshValidationScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        let planned = try fixture.controller.record(id)
        var draft = planned.draft
        // Owner authorizes enough attempts for a repair and two distinct revalidation rounds.
        draft.plan?.limits.retries = 4
        try await fixture.controller.saveDraft(id: id, revision: planned.revision, draft: draft)
        try await fixture.review(id)
        let reviewed = try fixture.controller.record(id)
        let original = try #require(reviewed.run)
        let stations = try #require(reviewed.draft.plan?.stations)
        let validators = stations.filter { $0.kind == .validator }
        try #require(validators.count == 2)
        let checkout = try #require(original.checkouts.first)
        let file = URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt")
        try Data("edited after successful review\n".utf8).write(to: file)
        try await fixture.launch(id)
        try await fixture.wait(id, phase: .review)
        let relaunched = try #require(fixture.controller.record(id).run)
        for validator in validators {
            let old = try #require(original.latest(validator.id))
            let fresh = try #require(relaunched.latest(validator.id))
            #expect(fresh.status == .succeeded && fresh.id != old.id)
            #expect(fresh.agentID != old.agentID && fresh.sessionID != old.sessionID)
            #expect(relaunched.attempts.first { $0.id == old.id }?.status == .superseded)
        }
        #expect(relaunched.attempts.contains { $0.exitCode != nil && $0.exitCode != 0 })
        #expect(try String(contentsOf: file, encoding: .utf8) == "after\n") // real check failed, worker repaired
        let beforeRevalidation = try fixture.controller.record(id)
        try await fixture.controller.revalidate(id: id, revision: beforeRevalidation.revision)
        try await fixture.wait(id, phase: .review)
        let validated = try fixture.controller.record(id)
        let freshRun = try #require(validated.run)
        let actual = try await fixture.controller.collectReviews(id)
        let fingerprints = Dictionary(uniqueKeysWithValues: actual.map { ($0.spaceID.rawValue, $0.fingerprint) })
        for station in stations where station.kind == .check || station.kind == .validator {
            let previous = try #require(relaunched.latest(station.id))
            let fresh = try #require(freshRun.latest(station.id))
            #expect(fresh.status == .succeeded && fresh.id != previous.id)
            #expect(freshRun.attempts.first { $0.id == previous.id }?.status == .superseded)
            let inputs = try #require(fresh.inputFingerprints)
            #expect(!inputs.isEmpty && inputs.allSatisfy { fingerprints[$0.key] == $0.value })
            if station.kind == .validator {
                #expect(fresh.agentID != previous.agentID && fresh.sessionID != previous.sessionID)
                #expect(inputs == fingerprints)
            } else { #expect(fresh.exitCode == 0 && fresh.output.contains("HOST_CHECK_OK")) }
        }
        for worker in stations where worker.kind == .worker {
            #expect(freshRun.latest(worker.id)?.id == relaunched.latest(worker.id)?.id)
        }
        let fingerprint = try #require(freshRun.reviewFingerprint)
        #expect(try fixture.controller.reviewFingerprint(validated, reviews: actual) == fingerprint)
        try fixture.expectUnpublished(id)
        // Even newly accepted evidence authorizes only these exact final bytes.
        try Data("edited after explicit revalidation\n".utf8).write(to: file)
        try await fixture.controller.publish(id: id, revision: validated.revision, fingerprint: fingerprint)
        try await fixture.wait(id, phase: .paused)
        #expect(try fixture.controller.record(id).run?.notice?.contains("changed after review") == true)
        try fixture.expectUnpublished(id)
    }

    @Test func publicationNeverPushesOntoABranchOriginAlreadyHas() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.foreignBranchScenario() }
        }
        expectScenarioCompleted(result)
    }

    /// A Spec Kit feature branch name (001-x) isn't unique to the mission. If origin already has that name, nothing is
    /// committed or pushed.
    static func foreignBranchScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        try await fixture.review(id)
        let reviewed = try fixture.controller.record(id)
        let checkout = try #require(reviewed.run?.checkouts.first)
        let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
        let main = try git(["rev-parse", "refs/heads/main"], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-ref", "refs/heads/" + checkout.branch, main], in: fixture.remotes[index])
        try await fixture.controller.publish(id: id, revision: reviewed.revision, fingerprint: try #require(reviewed.run?.reviewFingerprint))
        try await fixture.wait(id, phase: .paused)
        let paused = try #require(fixture.controller.record(id).run)
        #expect(paused.notice?.contains("origin already has a branch named") == true, "\(paused.notice ?? "")")
        #expect(paused.checkouts.allSatisfy { $0.publishedHead == nil && $0.prURL == nil }, "nothing committed or pushed")
        #expect(try git(["rev-parse", "refs/heads/" + checkout.branch], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == main)
    }

    static func partialPublicationScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        try await fixture.review(id)
        let reviewed = try fixture.controller.record(id)
        let original = try #require(reviewed.run)
        let fingerprint = try #require(original.reviewFingerprint)
        let calls = try Data(contentsOf: fixture.calls)
        try fixture.expectUnpublished(id)
        try fixture.failFirstPRCreate()
        try await fixture.controller.publish(id: id, revision: reviewed.revision, fingerprint: fingerprint)
        try await fixture.wait(id, phase: .paused)
        let paused = try fixture.controller.record(id)
        let partial = try #require(paused.run)
        #expect(partial.publicationApproval == fingerprint && partial.reviewFingerprint == fingerprint)
        #expect(partial.notice?.contains("opening the pull request failed") == true)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("fail-first-pr-create").path))
        #expect(partial.checkouts.filter { $0.publishedHead != nil }.count == 1)
        #expect(partial.checkouts.allSatisfy { $0.prURL == nil })
        let committed = try #require(partial.checkouts.first { $0.publishedHead != nil })
        let firstIndex = try #require(fixture.spaces.firstIndex { $0.id == committed.spaceID })
        let fullHead = try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: committed.path)).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(fullHead.hasPrefix(try #require(committed.publishedHead)))
        #expect(try git(["rev-parse", "refs/heads/" + committed.branch], in: fixture.remotes[firstIndex]).trimmingCharacters(in: .whitespacesAndNewlines) == fullHead)
        for checkout in partial.checkouts where checkout.spaceID != committed.spaceID {
            let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
            #expect(try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: checkout.path)).trimmingCharacters(in: .whitespacesAndNewlines) == checkout.head)
            #expect(try git(["for-each-ref", "--format=%(refname)", "refs/heads/mission/"], in: fixture.remotes[index]).isEmpty)
        }
        do {
            try await fixture.launch(id)
            Issue.record("Launch reran workers after authorized publication")
        } catch let error as MissionError { #expect(error.code == "mission_published") }
        do {
            try await fixture.controller.plan(id: id, feedback: "Try the worker again")
            Issue.record("Planning replaced partially published work")
        } catch let error as MissionError { #expect(error.code == "mission_published") }
        do {
            try await fixture.controller.revalidate(id: id, revision: paused.revision)
            Issue.record("Revalidation replaced partially published work")
        } catch let error as MissionError { #expect(error.code == "mission_published") }
        #expect(try fixture.controller.record(id) == paused)
        try await fixture.controller.stop(id: id, revision: paused.revision)
        let stopped = try fixture.controller.record(id)
        #expect(stopped.run?.phase == .stopped && stopped.run?.publicationApproval == fingerprint)
        try await fixture.controller.publish(id: id, revision: stopped.revision, fingerprint: fingerprint)
        try await fixture.wait(id, phase: .done)
        let done = try #require(fixture.controller.record(id).run)
        #expect(done.publicationApproval == fingerprint && done.reviewFingerprint == fingerprint)
        #expect(done.checkouts.map(\.branch) == original.checkouts.map(\.branch))
        #expect(done.checkouts.map(\.path) == original.checkouts.map(\.path))
        #expect(done.attempts == original.attempts)
        #expect(try Data(contentsOf: fixture.calls) == calls) // no planner, worker or validator replay
        let gh = try String(contentsOf: fixture.ghLog, encoding: .utf8)
        for checkout in done.checkouts {
            let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
            let head = try git(["rev-parse", "HEAD"], in: URL(fileURLWithPath: checkout.path)).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(checkout.prURL == "https://github.invalid/fixture/repo/pull/1")
            #expect(head.hasPrefix(try #require(checkout.publishedHead)))
            #expect(try git(["rev-parse", "refs/heads/" + checkout.branch], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == head)
            #expect(try git(["rev-list", "--count", checkout.head + ".." + head], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
            #expect(try git(["show", head + ":result.txt"], in: fixture.remotes[index]) == "after\n")
            if checkout.spaceID == committed.spaceID { #expect(head == fullHead) }
            // Push uses a full SHA refspec; gh must still receive the original branch name.
            #expect(gh.contains("pr create --head \(checkout.branch) --base \(checkout.base) "))
        }
        #expect(gh.contains("pr list --state all --head \(committed.branch) --base \(committed.base) --json url,state"))
        #expect(gh.split(separator: "\n").filter { $0.hasPrefix("pr create ") }.count == 3)
        try fixture.expectSourcesUnchanged()
    }

    static func publishScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        let planned = try fixture.controller.record(id)
        let planning = try #require(planned.run)
        #expect(planning.checkouts.count == 2)
        #expect(planning.attempts.count == 1)
        #expect(planning.attempts.first?.stationID == nil)
        #expect(planning.attempts.first?.status == .succeeded)
        #expect(planning.attempts.first?.sessionID != nil && planning.attempts.first?.generation != nil)
        #expect(planned.approvedPlanRevision == nil)
        for checkout in planning.checkouts {
            #expect(checkout.path != checkout.repo)
            #expect(try String(contentsOf: URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt"), encoding: .utf8) == "before\n")
            #expect(try git(["branch", "--show-current"], in: URL(fileURLWithPath: checkout.path)).trimmingCharacters(in: .whitespacesAndNewlines) == checkout.branch)
        }
        try fixture.expectUnpublished(id)
        try await fixture.review(id)
        let mission = try fixture.controller.record(id)
        let run = try #require(mission.run)
        let plan = try #require(mission.draft.plan)
        #expect(mission.approvedPlanRevision != nil)
        #expect(run.attempts.count == 7) // planner + two workers + two real checks + two independent validators
        let agents = run.attempts.compactMap(\.agentID)
        #expect(agents.count == 5 && Set(agents).count == 5)
        for station in plan.stations {
            let attempt = try #require(run.latest(station.id))
            #expect(attempt.status == .succeeded)
            #expect(attempt.fingerprint != nil)
            if station.kind == .check {
                #expect(attempt.agentID == nil)
                #expect(attempt.exitCode == 0)
                #expect(attempt.output.contains("HOST_CHECK_OK"))
            } else {
                #expect(attempt.sessionID != nil && attempt.generation != nil)
                #expect(attempt.tokens > 0)
                if station.kind == .validator { #expect(attempt.output.contains("Read actual result.txt")) }
            }
        }
        let artifacts = try #require(fixture.controller.reviews[id])
        #expect(artifacts.count == 2)
        #expect(artifacts.allSatisfy { !$0.files.isEmpty })
        for checkout in run.checkouts {
            #expect(try String(contentsOf: URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt"), encoding: .utf8) == "after\n")
        }
        #expect(fixture.app.vm.destination == .missions)
        try fixture.expectUnpublished(id)
        let fingerprint = try #require(run.reviewFingerprint)
        try await fixture.controller.publish(id: id, revision: mission.revision, fingerprint: fingerprint)
        try await fixture.wait(id, phase: .done)
        let published = try #require(fixture.controller.record(id).run)
        #expect(published.publicationApproval == fingerprint)
        for checkout in published.checkouts {
            let index = try #require(fixture.spaces.firstIndex { $0.id == checkout.spaceID })
            let head = try #require(checkout.publishedHead)
            #expect(checkout.prURL == "https://github.invalid/fixture/repo/pull/1")
            let pushed = try git(["rev-parse", "refs/heads/" + checkout.branch], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(pushed.hasPrefix(head))
            #expect(try git(["show", pushed + ":result.txt"], in: fixture.remotes[index]) == "after\n")
            #expect(try git(["rev-parse", pushed + "^"], in: fixture.remotes[index]).trimmingCharacters(in: .whitespacesAndNewlines) == fixture.initialHeads[index])
            #expect(try git(["status", "--porcelain"], in: URL(fileURLWithPath: checkout.path)).isEmpty)
        }
        let gh = try String(contentsOf: fixture.ghLog, encoding: .utf8)
        #expect(gh.split(separator: "\n").filter { $0.hasPrefix("pr create ") }.count == 2)
        try fixture.expectSourcesUnchanged()
    }

    static func patchScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        let controller = fixture.controller!
        let first = try controller.record(id).draft

        // Feedback on a drawn map: the revision waits beside it; nothing about the map changes.
        try await controller.plan(id: id, feedback: "Keep the same shape.")
        try await fixture.wait(id, phase: .map)
        let held = try controller.record(id)
        let patch = try #require(held.run?.patch)
        #expect(held.draft == first)
        #expect(patch.applies(to: first) && !patch.clearsFog)
        #expect(held.pill.label == "Patch ready")
        try await controller.rejectPatch(id: id, revision: held.revision, patchID: patch.id)
        #expect(try controller.record(id).run?.patch == nil)
        #expect(try controller.record(id).draft == first)

        // Applying makes it the map and clears any approval; an edit after the proposal makes it stale.
        try await controller.plan(id: id, feedback: "Again.")
        try await fixture.wait(id, phase: .map)
        var mission = try controller.record(id)
        let second = try #require(mission.run?.patch)
        var edited = mission.draft
        edited.title = "Renamed by the owner"
        try await controller.saveDraft(id: id, revision: mission.revision, draft: edited)
        mission = try controller.record(id)
        await #expect(throws: MissionError.self) { try await controller.applyPatch(id: id, revision: mission.revision, patchID: second.id) }
        try await controller.rejectPatch(id: id, revision: mission.revision, patchID: second.id)
        try await controller.plan(id: id, feedback: "Once more.")
        try await fixture.wait(id, phase: .map)
        mission = try controller.record(id)
        let third = try #require(mission.run?.patch)
        try await controller.applyPatch(id: id, revision: mission.revision, patchID: third.id)
        mission = try controller.record(id)
        #expect(mission.draft == third.draft && mission.run?.patch == nil && mission.approvedPlanRevision == nil)

        // With auto-apply on, a patch that settles your answer and fits the budget applies on its own.
        try await controller.setAutoApplyPatches(id: id, revision: mission.revision, on: true)
        try fixture.askClarification()
        try await controller.plan(id: id, feedback: "One more question?")
        try await fixture.wait(id, phase: .map)
        mission = try controller.record(id)
        #expect(mission.run?.pendingQuestion != nil)
        try await controller.answer(id: id, revision: mission.revision, text: "Yes, the same format.")
        try await fixture.wait(id, phase: .map)
        mission = try controller.record(id)
        #expect(mission.run?.patch == nil)
        #expect(mission.run?.decisions?.last?.answer == "Yes, the same format.")
        #expect(mission.draft.plan?.estimate == MissionEstimate(tokens: 20_000, seconds: 600))
        try fixture.expectUnpublished(id)
    }

    static func trainScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        MissionController.trainPoll = .milliseconds(50)
        let controller = fixture.controller!
        let id = try await fixture.create()
        try await fixture.review(id)
        var mission = try controller.record(id)
        try await controller.publish(id: id, revision: mission.revision, fingerprint: try #require(mission.run?.reviewFingerprint))
        try await fixture.wait(id, phase: .done)
        mission = try controller.record(id)
        let lanes = fixture.spaces.map(\.id)
        let log = fixture.ghLog

        // A conflict with lockfiles on "pause and ask" stops at the first car's update.
        try fixture.mark("conflict-once")
        try await controller.startTrain(id: id, revision: mission.revision, order: lanes, rules: MissionTrain.Rules(between: .soak, soakMinutes: 0, lockfiles: .pause))
        try await eventuallyOnMain("a conflict pauses the train", timeout: .seconds(30)) { (try? controller.record(id).run?.train?.status) == .paused && controller.trainJobs[id] == nil }
        var train = try #require(controller.record(id).run?.train)
        #expect(train.cars[0].steps[0].status == .failed && train.notice?.contains("conflicts") == true)

        // Red CI pauses at CI, before anything merges.
        try fixture.mark("red-ci")
        try await controller.resumeTrain(id: id, revision: controller.record(id).revision)
        try await eventuallyOnMain("red CI pauses the train", timeout: .seconds(30)) { (try? controller.record(id).run?.train?.status) == .paused && controller.trainJobs[id] == nil }
        train = try #require(controller.record(id).run?.train)
        #expect(train.merged == 0 && train.notice?.contains("CI failed") == true)
        #expect(try !String(contentsOf: log, encoding: .utf8).contains("pr merge"))
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("red-ci"))

        // A second start is refused; Resume merges both in order through the soak.
        await #expect(throws: MissionError.self) {
            try await controller.startTrain(id: id, revision: controller.record(id).revision, order: lanes, rules: MissionTrain.Rules())
        }
        try await controller.resumeTrain(id: id, revision: controller.record(id).revision)
        try await eventuallyOnMain("train finishes", timeout: .seconds(30)) { (try? controller.record(id).run?.train?.status) == .done }
        train = try #require(controller.record(id).run?.train)
        #expect(train.merged == 2 && train.cars.allSatisfy(\.finished))
        #expect(train.log.contains { $0.text == "merged" } && train.log.last?.text == "all 2 merged")
        let calls = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").filter { $0.hasPrefix("pr merge") }
        #expect(calls.count == 2)
        #expect(try controller.record(id).pill.label == "Merged")
    }

    static func locksScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        MissionController.lockPoll = .milliseconds(50)
        let controller = fixture.controller!
        // A holds result.txt in both repositories while its first check runs.
        let a = try await fixture.create()
        try await fixture.holdFirstCheck(a)
        try await fixture.launch(a)
        _ = try await fixture.waitForCommand()
        let b = try await fixture.create()
        try await fixture.launch(b)
        try await eventuallyOnMain("B waits for both repositories", timeout: .seconds(30)) {
            (try? controller.record(b).run?.held?.count) == 2
        }
        var waiting = try controller.record(b)
        #expect(waiting.run?.held?.values.allSatisfy { $0.holder == a && $0.overlap == ["result.txt"] && $0.blocks } == true)
        #expect(waiting.stationAttempts.isEmpty, "a held repository starts nothing")
        #expect(waiting.pill.label == "Running · 2 lanes held")
        #expect(controller.records.queue(fixture.spaces[0].id, paths: ["result.txt"]).map(\.mission.id) == [a, b])

        // A stops: its paths are free, and B runs to review.
        try await controller.stop(id: a, revision: controller.record(a).revision)
        try await fixture.wait(b, phase: .review)
        waiting = try controller.record(b)
        #expect(waiting.run?.held == nil)

        // A worker that writes outside its declared paths pauses the mission.
        let c = try await fixture.create()
        var mission = try controller.record(c)
        var draft = mission.draft
        for index in draft.plan!.stations.indices where draft.plan!.stations[index].kind == .worker { draft.plan!.stations[index].paths = ["docs/**"] }
        try await controller.saveDraft(id: c, revision: mission.revision, draft: draft)
        try await fixture.launch(c)
        try await fixture.wait(c, phase: .paused)
        mission = try controller.record(c)
        #expect(mission.run?.notice?.contains("wrote outside the paths") == true)
    }

    static func templateScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let controller = fixture.controller!
        let id = try await fixture.create()
        try await fixture.review(id)
        var mission = try controller.record(id)
        try await controller.publish(id: id, revision: mission.revision, fingerprint: try #require(mission.run?.reviewFingerprint))
        try await fixture.wait(id, phase: .done)

        // Just me: a file on this Mac, listed with one run.
        try await controller.saveTemplate(id: id, name: "Update result files", summary: "Both repositories write after.", team: nil)
        let local = try #require(controller.templates.first { $0.id == "update-result-files" })
        #expect(local.team == nil && local.runs == 1 && local.plan.stations.count == 6)
        #expect(FileManager.default.fileExists(atPath: MissionController.localTemplates.appendingPathComponent("update-result-files.json").path))

        // Team: a branch with .shepherd/maps/<id>.yml pushed to origin and a PR; Shepherd's worktree for it goes.
        try await controller.saveTemplate(id: id, name: "Team result files", summary: "", team: fixture.spaces[0].id)
        let pushed = try git(["show", "refs/heads/shepherd/map-team-result-files:.shepherd/maps/team-result-files.yml"], in: fixture.remotes[0])
        #expect(try JSONDecoder().decode(MissionTemplate.self, from: Data(pushed.utf8)).name == "Team result files")
        #expect(try String(contentsOf: fixture.ghLog, encoding: .utf8).contains("pr create --base main --head shepherd/map-team-result-files"))
        try await eventuallyOnMain("the template's worktree goes") {
            !((try? git(["worktree", "list"], in: fixture.repos[0])) ?? "").contains("shepherd/map-team-result-files")
        }
        // Once it merges, it's listed from the repository.
        try git(["push", fixture.remotes[0].path, "refs/heads/shepherd/map-team-result-files:refs/heads/main"], in: fixture.remotes[0])
        try git(["fetch", "origin"], in: fixture.repos[0])
        await controller.loadTemplates()
        #expect(controller.templates.first { $0.id == "team-result-files" }?.team == fixture.spaces[0].name)

        // Starting from a template: the mission names it and the planner reads it.
        controller.startTemplate = local
        let next = try await fixture.create()
        mission = try controller.record(next)
        #expect(mission.draft.template == local.id && controller.startTemplate == nil)
        // calls.jsonl holds the prompt JSON-escaped.
        #expect(try String(contentsOf: fixture.calls, encoding: .utf8).contains("mission template \\\"Update result files\\\""))
    }

    static func retryScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        try fixture.setValidationFailure()
        let id = try await fixture.create()
        let limit = try #require(fixture.controller.record(id).draft.plan?.limits.retries)
        #expect(limit == MissionLimits().retries) // hit the shipped bound, not a test-only reduced limit
        try await fixture.launch(id)
        try await fixture.wait(id, phase: .paused)
        let mission = try fixture.controller.record(id)
        let run = try #require(mission.run)
        let stations = try #require(mission.draft.plan?.stations)
        #expect(run.notice?.contains("retry limit") == true)
        let counts = stations.filter { $0.kind == .worker }.map { worker in run.attempts.filter { $0.stationID == worker.id }.count }
        #expect(counts.contains(limit + 1))
        #expect(counts.allSatisfy { $0 <= limit + 1 })
        #expect(run.attempts.contains { $0.status == .superseded })
        #expect(stations.contains { $0.kind == .validator && run.latest($0.id)?.status == .failed })
        #expect(run.reviewFingerprint == nil)
        #expect(fixture.controller.reviews[id] == nil)
        try fixture.expectUnpublished(id)
        // Explicit Launch cannot reset an exhausted station's approved-plan attempt count.
        let count = run.attempts.count
        try await fixture.launch(id)
        try await fixture.wait(id, phase: .paused)
        #expect(try fixture.controller.record(id).run?.attempts.count == count)
        try fixture.expectUnpublished(id)
    }

    static func stopScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        try await fixture.holdFirstCheck(id)
        try await fixture.launch(id)
        let (parent, child) = try await fixture.waitForCommand()
        try await fixture.controller.stop(id: id, revision: fixture.controller.record(id).revision)
        try await fixture.wait(id, phase: .stopped)
        try await eventuallyOnMain("host command process group terminated") { kill(parent, 0) != 0 && kill(child, 0) != 0 }
        let run = try #require(fixture.controller.record(id).run)
        #expect(run.attempts.contains { $0.agentID == nil && $0.status == .interrupted })
        #expect(!run.attempts.contains { $0.status == .running })
        #expect(run.reviewFingerprint == nil)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("command-finished").path))
        try fixture.expectUnpublished(id)
    }

    static func restartScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        try await fixture.holdFirstCheck(id)
        try await fixture.launch(id)
        let (parent, child) = try await fixture.waitForCommand()
        try await fixture.controller.pause(id: id, revision: fixture.controller.record(id).revision)
        try await fixture.wait(id, phase: .paused)
        try await eventuallyOnMain("paused host check stopped") { kill(parent, 0) != 0 && kill(child, 0) != 0 }
        let before = try fixture.controller.record(id)
        let calls = try Data(contentsOf: fixture.calls)
        fixture.app.scratch.stop(keepFiles: true)
        let restarted = try AppHarness(directory: fixture.app.dir, modelCatalog: { .init(models: [MissionRuntimeFixture.model], defaultModel: MissionRuntimeFixture.model) })
        defer { restarted.stop() }
        let vm = try await restarted.start(restoringAgents: true)
        let controller = vm.missions
        let retained = try controller.record(id)
        #expect(retained.run?.phase == .paused)
        #expect(retained.run?.checkouts == before.run?.checkouts)
        #expect(retained.run?.attempts == before.run?.attempts)
        #expect(controller.jobs.isEmpty)
        #expect(await restarted.server.listSessions().isEmpty)
        #expect(try Data(contentsOf: fixture.calls) == calls)
        #expect(!FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("command-finished").path))
        try fixture.expectSourcesUnchanged()
    }

    static func staleScenario() async throws {
        let fixture = try MissionRuntimeFixture(); defer { fixture.stop() }
        try await fixture.start()
        let id = try await fixture.create()
        try await fixture.review(id)
        let mission = try fixture.controller.record(id)
        let run = try #require(mission.run)
        let fingerprint = try #require(run.reviewFingerprint)
        // A stale owner revision is refused before scheduling anything.
        do {
            try await fixture.controller.publish(id: id, revision: mission.revision - 1, fingerprint: fingerprint)
            Issue.record("Stale revision unexpectedly approved publication")
        } catch let error as MissionError { #expect(error.code == "mission_stale_review") }
        try fixture.expectUnpublished(id)
        let checkout = try #require(run.checkouts.first)
        try Data("changed after review\n".utf8).write(to: URL(fileURLWithPath: checkout.path).appendingPathComponent("result.txt"))
        // Same revision and old fingerprint are insufficient: publication must reread actual bytes.
        try await fixture.controller.publish(id: id, revision: mission.revision, fingerprint: fingerprint)
        try await fixture.wait(id, phase: .paused)
        #expect(try fixture.controller.record(id).run?.notice?.contains("changed after review") == true)
        try fixture.expectUnpublished(id)
    }
}
