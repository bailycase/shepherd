import Foundation
import ShepherdCore
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Mission Spec Kit runtime", .mainActorExclusive, .serialized)
@MainActor
struct MissionSpecKitRuntimeTests {
    // The stub engine replaces a process-wide executable, so the journey runs in its own child.
    @Test func stockCommandsRunPerRepositoryWithConsentFollowUpsSteersAndOwnerGates() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.journey() }
        }
        expectScenarioCompleted(result)
    }

    @Test func ownerTalksAndThePlannerRunsStockStepsWithBoundedClarification() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.conversation() }
        }
        expectScenarioCompleted(result)
    }

    @Test func planningBoundsHoldAcrossOwnerActions() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.bounds() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aFreshProjectGetsItsConstitutionAndCriticalAnalysisWaitsForYou() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.wholeFlow() }
        }
        expectScenarioCompleted(result)
    }

    /// The owner never types a Spec Kit command: a fresh project's template constitution is written first, and
    /// /speckit.analyze checks the artifacts after tasks, stopping once on CRITICAL findings until you answer.
    static func wholeFlow() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        for repo in fixture.repos {
            try Data("# [PROJECT_NAME] Constitution\n### [PRINCIPLE_1_NAME]\n".utf8).write(to: repo.appendingPathComponent(".specify/memory/constitution.md"))
            let commit = await MissionController.command("git add -A && git -c user.name=t -c user.email=t@e commit -qm template", cwd: repo.path)
            try #require(commit.status == 0, "\(commit.stderr)")
        }
        try Data().write(to: fixture.root.appendingPathComponent("critical-once"))
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint,
                                                     continuePlanning: index == fixture.spaces.count - 1)
        }
        try await fixture.wait(id, phase: .map)
        let firstPass = try prompts(fixture)
        #expect(firstPass.count == 5 && firstPass.first?.hasPrefix("/speckit.constitution Infer the principles") == true, "\(firstPass)")
        #expect(Array(firstPass.dropFirst()) == ["/speckit.specify Change result.txt to after.", "/speckit.plan", "/speckit.tasks", "/speckit.analyze"])
        var run = try #require(try controller.record(id).run)
        #expect(run.pendingQuestion?.contains("CRITICAL") == true, "critical findings wait for you before Launch")
        await #expect(throws: MissionError.self) { try await controller.launch(id: id, revision: try fixture.revision(id)) }
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "Go ahead.")
        try await fixture.wait(id, phase: .map)
        run = try #require(try controller.record(id).run)
        #expect(run.pendingQuestion == nil && run.notice?.contains("map is ready") == true, "\(run.notice ?? "")")
        #expect(Array(try prompts(fixture).dropFirst(5)).map { $0.split(separator: " ").first.map(String.init) ?? "" }
                == ["Go", "/speckit.constitution", "/speckit.specify", "/speckit.plan", "/speckit.tasks", "/speckit.analyze"],
                "the answer accepts repository 1's analysis; repository 2 runs the whole flow")
        for checkout in run.checkouts {
            let text = try String(contentsOf: URL(fileURLWithPath: checkout.path).appendingPathComponent(".specify/memory/constitution.md"), encoding: .utf8)
            #expect(!SpecKit.constitutionNeedsWriting(text))
        }
    }

    @Test func aCriticalAnalysisStillStopsAfterYouAnsweredAnEarlierQuestion() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.criticalAfterAnswer() }
        }
        expectScenarioCompleted(result)
    }

    static func criticalAfterAnswer() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("ask"))
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint,
                                                     continuePlanning: index == fixture.spaces.count - 1)
        }
        try await fixture.wait(id, phase: .map)
        #expect(try controller.record(id).run?.pendingQuestion?.contains("Which format") == true)
        // Answering clarify is not consent to an analysis nobody has seen yet.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ask"))
        try Data().write(to: fixture.root.appendingPathComponent("critical-once"))
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "plain")
        try await fixture.wait(id, phase: .map)
        #expect(try controller.record(id).run?.pendingQuestion?.contains("CRITICAL") == true)
        await #expect(throws: MissionError.self) { try await controller.launch(id: id, revision: try fixture.revision(id)) }
    }

    // MARK: Edge cases: what you approved and what Git says stay the mission's own

    @Test func aRewrittenPlanReplansAndAnOutsideCommitStopsTheNextTurn() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.outsideChanges() }
        }
        expectScenarioCompleted(result)
    }

    @Test func implementCannotRewriteWhatYouApproved() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.implementScope() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aPausedImplementResumesFromItsOwnPartialOutput() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pausedImplement() }
        }
        expectScenarioCompleted(result)
    }

    @Test func aBranchThatAlreadyExistedIsNeverAdopted() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.existingBranch() }
        }
        expectScenarioCompleted(result)
    }

    /// Consent for every repository, then planning to the ready map.
    static func planned(_ fixture: MissionSpecKitFixture) async throws -> MissionID {
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint,
                                                     continuePlanning: index == fixture.spaces.count - 1)
        }
        try await fixture.wait(id, phase: .map)
        return id
    }

    static func outsideChanges() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        let id = try await planned(fixture)
        let controller = try #require(fixture.controller)
        // A reply that rewrites plan.md (not just creates it) makes the tasks and their analysis stale.
        let asked = try #require(try controller.record(id).run?.messages.last { $0.role == .assistant && $0.spaceID == fixture.spaces[0].id })
        let before = try prompts(fixture).count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "CHANGE-PLAN use a file lock", replyTo: asked.id)
        try await fixture.wait(id, phase: .map)
        #expect(Array(try prompts(fixture).dropFirst(before)) == ["CHANGE-PLAN use a file lock", "/speckit.tasks", "/speckit.analyze"])
        // A commit made in a worktree between the mission's turns is not its work: nothing more is sent.
        let worktree = try #require(try controller.record(id).run?.checkouts.first?.path)
        let commit = await MissionController.command("git -c user.name=t -c user.email=t@e commit -q --allow-empty -m outside", cwd: worktree)
        try #require(commit.status == 0)
        let sent = try prompts(fixture).count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "Keep it short.")
        try await fixture.wait(id, phase: .paused)
        #expect(try controller.record(id).run?.notice?.contains("moved outside the mission's turns") == true)
        #expect(try prompts(fixture).count == sent)
    }

    static func implementScope() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("implement-edits-spec"))
        let id = try await planned(fixture)
        let controller = try #require(fixture.controller)
        try await controller.launch(id: id, revision: try fixture.revision(id))
        try await fixture.wait(id, phase: .paused)
        let notice = try controller.record(id).run?.notice ?? ""
        #expect(notice.contains("changed what you approved") && notice.contains("spec.md"), "\(notice)")
        #expect(try prompts(fixture).contains("/speckit.converge") == false, "converge never assesses against a weakened spec")
    }

    static func pausedImplement() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("hold-after-contracts"))
        let id = try await planned(fixture)
        let controller = try #require(fixture.controller)
        try await controller.launch(id: id, revision: try fixture.revision(id))
        try await eventuallyOnMain("implement wrote part of its output", timeout: .seconds(60)) {
            FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("implement-held").path)
        }
        try await controller.pause(id: id, revision: try fixture.revision(id))
        try await fixture.wait(id, phase: .paused)
        // Relaunch continues from implement's own partial output instead of calling it an outside change.
        try await controller.launch(id: id, revision: try fixture.revision(id))
        for _ in fixture.spaces {
            try await fixture.wait(id, phase: .map)
            guard let lane = try controller.record(id).run?.specKit?.lanes.first(where: { $0.convergence?.accepted == false }) else { break }
            try await controller.acceptConvergence(id: id, revision: try fixture.revision(id), attemptID: lane.convergence!.attemptID)
        }
        try await fixture.wait(id, phase: .review)
    }

    static func existingBranch() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        for repo in fixture.repos {
            try #require(await MissionController.command("git branch existing", cwd: repo.path).status == 0)
        }
        try Data().write(to: fixture.root.appendingPathComponent("checkout-existing"))
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint,
                                                     continuePlanning: index == fixture.spaces.count - 1)
        }
        try await fixture.wait(id, phase: .paused)
        let notice = try controller.record(id).run?.notice ?? ""
        #expect(notice.contains("isn't a new branch"), "\(notice)")
        #expect(try controller.record(id).run?.checkouts.allSatisfy { $0.branch.hasPrefix("mission/") } == true, "never adopted")
    }

    @Test func theGitExtensionsFeatureBranchIsAdoptedThroughReview() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.featureBranch() }
        }
        expectScenarioCompleted(result)
    }

    /// Stock projects with the git extension switch the worktree to a numbered feature branch in /speckit.specify
    /// and may commit after implement. The mission keeps working on that branch, counts its own turns' commits as its
    /// work, and reviews everything since the starting commit, as stock tooling would publish it.
    static func featureBranch() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("git-feature"))
        try Data().write(to: fixture.root.appendingPathComponent("commit-implement"))
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint,
                                                     continuePlanning: index == fixture.spaces.count - 1)
        }
        try await fixture.wait(id, phase: .map)
        var mission = try controller.record(id)
        for checkout in mission.run?.checkouts ?? [] {
            #expect(checkout.branch == "001-result", "adopted the hook's branch")
            let current = await MissionController.command("git branch --show-current", cwd: checkout.path)
            #expect(current.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "001-result")
        }
        try await controller.launch(id: id, revision: try fixture.revision(id))
        for _ in fixture.spaces {
            try await fixture.wait(id, phase: .map)
            guard let lane = try controller.record(id).run?.specKit?.lanes.first(where: { $0.convergence?.accepted == false }) else { break }
            try await controller.acceptConvergence(id: id, revision: try fixture.revision(id), attemptID: lane.convergence!.attemptID)
        }
        try await fixture.wait(id, phase: .review)
        mission = try controller.record(id)
        #expect(mission.run?.checkouts.allSatisfy { $0.branch == "001-result" && $0.observedHead != nil && $0.observedHead != $0.head } == true,
                "implement's commit is the mission's own work")
        #expect(controller.reviews[id]?.allSatisfy { $0.branch == "001-result" && $0.files.contains { $0.displayPath == "result.txt" } } == true)
    }

    static func prepared(_ fixture: MissionSpecKitFixture) async throws -> (MissionID, [SpaceID: SpecKitPreflight]) {
        try await fixture.start()
        let controller = try #require(fixture.controller)
        let branches = Dictionary(uniqueKeysWithValues: fixture.spaces.map { ($0.id, "refs/heads/main") })
        let id = try await controller.create(goal: "Change result.txt to after.", spaces: fixture.spaces.map(\.id),
                                             model: MissionSpecKitFixture.model, branches: branches)
        try await fixture.wait(id, phase: .map)
        return (id, try #require(controller.specKitReports[id]))
    }

    static func prompts(_ fixture: MissionSpecKitFixture) throws -> [String] { try fixture.loggedCalls().compactMap { $0["prompt"] as? String } }

    static func conversation() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("ask"))
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        let (first, second) = (fixture.spaces[0].id, fixture.spaces[1].id)
        // Consent alone sends nothing; the last grant with "and continue planning" starts it.
        try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: first, fingerprint: reports[first]!.consentFingerprint)
        #expect(try controller.record(id).run?.phase.active == false && (try fixture.loggedCalls()).isEmpty)
        try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: second, fingerprint: reports[second]!.consentFingerprint,
                                                 continuePlanning: true)
        try await fixture.wait(id, phase: .map)
        // The first repository's spec marks a question: clarify asks it, and planning stops on that real reply.
        var run = try #require(try controller.record(id).run)
        #expect(try prompts(fixture) == ["/speckit.specify Change result.txt to after.", "/speckit.clarify"])
        let question = try #require(run.messages.last { $0.question != nil })
        #expect(run.pendingQuestion?.contains("Which format") == true && question.spaceID == first)
        await #expect(throws: MissionError.self, "map approval waits for the answer") { try await controller.launch(id: id, revision: try fixture.revision(id)) }
        await #expect(throws: MissionError.self, "a reply must bind the outstanding question") {
            try await controller.answer(id: id, revision: try fixture.revision(id), text: "plain", replyTo: UUID())
        }
        await #expect(throws: MissionError.self, "a stale revision is refused") {
            try await controller.answer(id: id, revision: try fixture.revision(id) - 1, text: "plain")
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("ask"))
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "plain", replyTo: question.id)
        try await fixture.wait(id, phase: .map)
        run = try #require(try controller.record(id).run)
        #expect(run.pendingQuestion == nil && run.notice?.contains("map is ready") == true, "\(run.notice ?? "")")
        let calls = try fixture.loggedCalls()
        #expect(calls.compactMap { $0["prompt"] as? String }.dropFirst(2).elementsEqual(["plain", "/speckit.plan", "/speckit.tasks", "/speckit.analyze", "/speckit.specify Change result.txt to after.", "/speckit.plan", "/speckit.tasks", "/speckit.analyze"]))
        #expect(calls[2]["agent"] as? String == calls[1]["agent"] as? String, "the answer continues clarify's own thread")
        let answer = try #require(run.messages.last { $0.role == .user })
        #expect(answer.replyTo == question.id && answer.spaceID == first)

        // General feedback with no question: into every planning conversation; nothing changed, nothing rebuilt.
        let before = try prompts(fixture).count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "Keep it short.")
        try await fixture.wait(id, phase: .map)
        #expect(Array(try prompts(fixture).dropFirst(before)) == ["Keep it short.", "Keep it short."])
        // Feedback that changes one spec rebuilds only that repository's plan and tasks.
        let reply = try #require(try controller.record(id).run?.messages.last { $0.role == .assistant && $0.spaceID == second })
        let changed = try prompts(fixture).count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "CHANGE-SPEC add logging", replyTo: reply.id)
        try await fixture.wait(id, phase: .map)
        #expect(Array(try prompts(fixture).dropFirst(changed)) == ["CHANGE-SPEC add logging", "/speckit.plan", "/speckit.tasks", "/speckit.analyze"])

        // A step that writes nothing stops planning; it is not repeated or skipped.
        try Data().write(to: fixture.root.appendingPathComponent("skip-plan-output"))
        let failing = try prompts(fixture).count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "CHANGE-SPEC again", replyTo: reply.id)
        try await fixture.wait(id, phase: .map)
        #expect(Array(try prompts(fixture).dropFirst(failing)) == ["CHANGE-SPEC again", "/speckit.plan"])
        #expect(try controller.record(id).run?.pendingQuestion?.contains("without writing plan.md") == true)
        #expect(try controller.record(id).approvedPlanRevision == nil)
        // Continue planning runs that step again (it makes progress, rather than stopping on the same receipt).
        let retried = try prompts(fixture).count
        try await controller.plan(id: id)
        try await fixture.wait(id, phase: .map)
        #expect(Array(try prompts(fixture).dropFirst(retried)) == ["/speckit.plan", "/speckit.tasks", "/speckit.analyze"])
        #expect(try controller.record(id).run?.pendingQuestion == nil)
    }

    static func bounds() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try Data().write(to: fixture.root.appendingPathComponent("ask"))
        try Data().write(to: fixture.root.appendingPathComponent("never-resolve"))
        MissionController.clarifyRounds = 2
        MissionController.planningTurnsPerMission = 3 // per repository: 6 for these two
        let (id, reports) = try await prepared(fixture)
        let controller = try #require(fixture.controller)
        for (index, space) in fixture.spaces.enumerated() {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: reports[space.id]!.consentFingerprint, continuePlanning: index == 1)
        }
        try await fixture.wait(id, phase: .map)
        // Round 1 asks; the unresolved answer is round 2; the third is refused by the per-repository bound.
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "plain")
        try await fixture.wait(id, phase: .map)
        #expect(try controller.record(id).run?.pendingQuestion?.contains("still needs clarification after 2 rounds") == true)
        try await controller.plan(id: id)
        try await fixture.wait(id, phase: .map)
        #expect(try prompts(fixture).filter { $0 == "/speckit.clarify" }.count == 1, "asking again never resets the clarify bound")
        // The per-call bound (per repository, so two here), then planning pauses with the reason.
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("never-resolve"))
        MissionController.planningTurnsPerCall = 1
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "plain")
        try await fixture.wait(id, phase: .paused)
        #expect(try controller.record(id).run?.notice?.contains("steps for this request") == true)
        // The mission-wide bound holds across calls.
        MissionController.planningTurnsPerCall = 12
        try await controller.plan(id: id)
        try await fixture.wait(id, phase: .paused)
        let notice = try controller.record(id).run?.notice ?? ""
        #expect(notice.contains("6-step limit"), "\(notice)")
        let steps = try fixture.loggedCalls().count
        #expect(steps <= 6)
    }

    static func journey() async throws {
        let fixture = try MissionSpecKitFixture(); defer { fixture.stop() }
        try await fixture.start()
        let controller = try #require(fixture.controller)
        let branches = Dictionary(uniqueKeysWithValues: fixture.spaces.map { ($0.id, "refs/heads/main") })
        let id = try await controller.create(goal: "Change result.txt to after.", spaces: fixture.spaces.map(\.id),
                                             model: MissionSpecKitFixture.model, branches: branches)
        try await fixture.wait(id, phase: .map)
        let reports = try #require(controller.specKitReports[id])
        #expect(reports.count == 2 && reports.values.allSatisfy { $0.status == .ready && $0.matchesTestedRelease })
        #expect(try fixture.loggedCalls().isEmpty, "preparing reads files and sends nothing")

        // No consent: refused before any thread starts.
        await #expect(throws: MissionError.self) {
            try await controller.runSpecKit(id: id, revision: try fixture.revision(id), command: .specify)
        }
        #expect(try fixture.loggedCalls().isEmpty)
        for space in fixture.spaces {
            try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: space.id,
                                                     fingerprint: try #require(reports[space.id]).consentFingerprint)
        }

        // Specify: one persistent planning thread per repository, loading only that worktree's stock prompts.
        try await controller.runSpecKit(id: id, revision: try fixture.revision(id), command: .specify)
        try await fixture.wait(id, phase: .map)
        var mission = try controller.record(id)
        let run = try #require(mission.run)
        let calls = try fixture.loggedCalls()
        #expect(calls.map { $0["prompt"] as? String } == ["/speckit.specify Change result.txt to after.", "/speckit.specify Change result.txt to after."])
        for (call, checkout) in zip(calls, run.checkouts) {
            #expect(call["cwd"] as? String == URL(fileURLWithPath: checkout.path).resolvingSymlinksInPath().path || call["cwd"] as? String == checkout.path)
            #expect(call["templates"] as? [String] == [checkout.path + "/.pi/prompts"])
            #expect(call["denied"] as? String == "1", "nested pi -p is refused for Spec Kit mission agents")
            #expect((call["argv"] as? [String])?.contains { $0.contains("shepherd-children") } == false)
        }
        let planners = try run.specKit!.lanes.map { try #require($0.plannerAgentID) }
        #expect(run.specKit!.lanes.allSatisfy { $0.featureDirectory == "specs/001-result" })
        #expect(mission.draft.requirements.contains { $0.contains("FR-001") })

        // A reply goes only to the thread that asked, in the same session, with its persisted association.
        let asked = try #require(run.messages.last { $0.role == .assistant && $0.spaceID == fixture.spaces[0].id })
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "Keep the trailing newline.", replyTo: asked.id)
        try await fixture.wait(id, phase: .map)
        var replies = try fixture.loggedCalls().dropFirst(2)
        // The reply goes to that repository only; then the planner continues each repository's stock steps.
        #expect(replies.map { $0["prompt"] as? String } == ["Keep the trailing newline.", "/speckit.plan", "/speckit.tasks", "/speckit.analyze", "/speckit.plan", "/speckit.tasks", "/speckit.analyze"])
        #expect(replies.first?["agent"] as? String == planners[0].rawValue, "follow-up continues the same planning session")
        mission = try controller.record(id)
        let answer = try #require(mission.run?.messages.last { $0.role == .user })
        #expect(answer.replyTo == asked.id && answer.spaceID == fixture.spaces[0].id)
        let followUp = try #require(mission.run?.attempts.first { $0.agentID == planners[0] && $0.command == .specify && $0.operationIDs != nil }
            ?? mission.run?.attempts.first { $0.agentID == planners[0] && $0.operationIDs?.count == 1 })
        #expect(followUp.status == .succeeded && followUp.operationIDs?.count == 1)

        // Changed stock files void consent before anything is sent to that repository.
        let second = try #require(mission.run?.checkouts.first { $0.spaceID == fixture.spaces[1].id })
        let plan = URL(fileURLWithPath: second.path).appendingPathComponent(SpecKitCommand.plan.promptPath)
        let stock = try Data(contentsOf: plan)
        try Data("tampered\n".utf8).write(to: plan)
        let sent = try fixture.loggedCalls().count
        try await controller.answer(id: id, revision: try fixture.revision(id), text: "Any concerns?")
        try await fixture.wait(id, phase: .paused)
        #expect(try controller.record(id).run?.specKit?[fixture.spaces[1].id]?.consentFingerprint == nil)
        replies = try fixture.loggedCalls().dropFirst(sent)
        #expect(replies.map { $0["agent"] as? String } == [planners[0].rawValue], "only the unchanged repository got the message")
        try stock.write(to: plan)
        let refreshed = try await controller.specKitPreflight(id: id)
        try await controller.grantSpecKitConsent(id: id, revision: try fixture.revision(id), space: fixture.spaces[1].id,
                                                 fingerprint: try #require(refreshed[fixture.spaces[1].id]).consentFingerprint, continuePlanning: true)
        try await fixture.wait(id, phase: .map)
        #expect(try controller.record(id).run?.notice?.contains("map is ready") == true)
        #expect(controller.specKitPhases[id]?.values.allSatisfy { $0.first?.tasks.first?.done == false } == true)

        // Launch: implement in a fresh thread, steered while it works.
        try Data().write(to: fixture.root.appendingPathComponent("hold-implement"))
        try Data().write(to: fixture.root.appendingPathComponent("append-once"))
        try await controller.launch(id: id, revision: try fixture.revision(id))
        let implementStation = SpecKit.stationID(id, fixture.spaces[0].id, "phase-0")
        var implement: MissionAttempt?
        try await eventuallyOnMain("implement is working", timeout: .seconds(30)) {
            implement = try? controller.record(id).run?.latest(implementStation)
            return implement?.status == .running && (try? fixture.loggedCalls().contains { ($0["prompt"] as? String) == "/speckit.implement" }) == true
        }
        let working = try #require(implement)
        #expect(!planners.contains(try #require(working.agentID)), "implement runs in a fresh thread")
        let source = try #require(controller.thread(for: working.id))
        #expect(source.send != nil && source.agentID == working.agentID)
        // Wrong owners are refused without touching the record: a settled attempt, an agent with no running
        // attempt, and a follow-up into a turn that is still working.
        let runID = try #require(try controller.record(id).run?.id)
        await #expect(throws: MissionError.self) {
            try await controller.steer(id: id, revision: try fixture.revision(id), attemptID: followUp.id, text: "not yours")
        }
        await #expect(throws: MissionError.self) {
            try await fixture.app.server.sendMissionSteer(id: id, runID: runID, agentID: planners[1], operationID: UUID(), text: "not yours")
        }
        await #expect(throws: MissionError.self) {
            try await fixture.app.server.sendMissionFollowUp(id: id, runID: runID, agentID: working.agentID!, operationID: UUID(), text: "not yet")
        }
        await #expect(throws: MissionError.self) {
            try await fixture.app.server.sendMissionSteer(id: id, runID: UUID(), agentID: working.agentID!, operationID: UUID(), text: "stale run")
        }
        #expect(try controller.record(id).run?.attempts.first { $0.id == working.id }?.operationIDs == nil)
        // A steer returns once pi has read it, so it waits on the held turn; release the turn, then await it.
        let steering = Task { try await controller.steer(id: id, revision: try fixture.revision(id), attemptID: working.id, text: "Prefer a minimal edit.") }
        try await eventuallyOnMain("steer queued with pi") { (try? controller.record(id).run?.attempts.first { $0.id == working.id }?.operationIDs?.count) == 1 }
        try Data().write(to: fixture.root.appendingPathComponent("release-implement"))
        try await steering.value
        try await fixture.wait(id, phase: .map)
        mission = try controller.record(id)
        let steered = try #require(mission.run?.attempts.first { $0.id == working.id })
        #expect(steered.deliveredOperationIDs == steered.operationIDs, "a durable receipt says pi read the steer")
        #expect(steered.status == .succeeded && steered.operationIDs?.count == 1 && steered.output.contains("steered: Prefer a minimal edit."))
        #expect(try fixture.loggedCalls().contains { $0["steer"] as? String == "Prefer a minimal edit." })

        // Converge appended a task: approval is gone, acceptance is refused, the owner approves again.
        var lane = try #require(mission.run?.specKit?[fixture.spaces[0].id])
        #expect(lane.convergence?.outcome == .tasksAppended && mission.approvedPlanRevision == nil)
        await #expect(throws: MissionError.self) {
            try await controller.acceptConvergence(id: id, revision: try fixture.revision(id), attemptID: lane.convergence!.attemptID)
        }
        try await controller.launch(id: id, revision: try fixture.revision(id))
        try await fixture.wait(id, phase: .map)
        mission = try controller.record(id)
        lane = try #require(mission.run?.specKit?[fixture.spaces[0].id])
        #expect(mission.run?.attempts.filter { $0.stationID == implementStation && $0.command == .implement }.count == 2, "retries are cumulative")
        #expect(lane.convergence?.outcome == .unchanged && lane.convergence?.accepted == false, "unchanged tasks.md never passes on its own")

        // Implement's own edits to feature artifacts (checked tasks, a filled-in contract) are its outputs, not a
        // reason to re-approve. An edit made outside the mission's turns is: accepting resumes nothing until
        // the files are back as the host last observed them.
        let first = try #require(mission.run?.checkouts.first { $0.spaceID == fixture.spaces[0].id })
        let contract = URL(fileURLWithPath: first.path).appendingPathComponent("specs/001-result/contracts/cli.md")
        #expect(try String(contentsOf: contract, encoding: .utf8).contains("result.txt holds after"), "implement wrote into a design artifact")
        let planFile = URL(fileURLWithPath: first.path).appendingPathComponent("specs/001-result/plan.md")
        let planned = try Data(contentsOf: planFile)
        try Data("# Plan\nEdited outside the mission.\n".utf8).write(to: planFile)
        let attemptsBefore = try #require(try controller.record(id).run?.attempts.count)
        await #expect(throws: MissionError.self) {
            try await controller.acceptConvergence(id: id, revision: try fixture.revision(id), attemptID: lane.convergence!.attemptID)
        }
        #expect(try controller.record(id).run?.attempts.count == attemptsBefore, "a stale artifact starts no turn")
        #expect(try controller.record(id).run?.phase.active == false)
        try planned.write(to: planFile)

        // Only the owner's explicit acceptance resolves it; the second repository then runs, then review.
        // Its implement turn ends without pi reading a steer: the steer is refused as undelivered (the person keeps
        // it), recorded on the attempt, and never sent again as a turn of its own.
        try Data().write(to: fixture.root.appendingPathComponent("hold-implement"))
        try Data().write(to: fixture.root.appendingPathComponent("ignore-steer"))
        try? FileManager.default.removeItem(at: fixture.root.appendingPathComponent("release-implement"))
        try await controller.launch(id: id, revision: try fixture.revision(id))
        let secondStation = SpecKit.stationID(id, fixture.spaces[1].id, "phase-0")
        var secondImplement: MissionAttempt?
        try await eventuallyOnMain("second repository implements", timeout: .seconds(30)) {
            secondImplement = try? controller.record(id).run?.latest(secondStation)
            // pi's run has started (the stub logs the turn after agent_start): only then can it take a steer.
            return secondImplement?.status == .running
                && (try? fixture.loggedCalls().filter { ($0["prompt"] as? String) == "/speckit.implement" }.count) == 3
        }
        let lost = "Unread steer."
        // Not read within the bound: the call says so (words kept) and a second steer is refused while it waits.
        let bound = MissionController.steerOutcomeSeconds
        MissionController.steerOutcomeSeconds = 1
        defer { MissionController.steerOutcomeSeconds = bound }
        do {
            try await controller.steer(id: id, revision: try fixture.revision(id), attemptID: secondImplement!.id, text: lost)
            Issue.record("an unread steer must not return as delivered")
        } catch let error as MissionError { #expect(error.code == "mission_steer_pending", "\(error)") }
        do {
            try await controller.steer(id: id, revision: try fixture.revision(id), attemptID: secondImplement!.id, text: lost)
            Issue.record("a second steer while one waits must be refused")
        } catch let error as MissionError { #expect(error.code == "mission_steer_waiting", "\(error)") }
        #expect(try controller.record(id).run?.attempts.first { $0.id == secondImplement!.id }?.operationIDs?.count == 1, "the refused steer sent nothing")
        try Data().write(to: fixture.root.appendingPathComponent("release-implement"))
        try await fixture.wait(id, phase: .map)
        let unreadAttempt = try #require(try controller.record(id).run?.attempts.first { $0.id == secondImplement!.id })
        #expect(unreadAttempt.status == .succeeded && unreadAttempt.undeliveredOperationIDs?.count == 1)
        #expect(unreadAttempt.output.contains("not delivered"))
        #expect(!(try fixture.loggedCalls()).contains { ($0["prompt"] as? String) == lost || ($0["steer"] as? String) == lost },
                "an unread steer never becomes a turn of its own")
        #expect(try controller.record(id).run?.specKit?[fixture.spaces[0].id]?.convergence?.accepted == true)
        let other = try #require(try controller.record(id).run?.specKit?[fixture.spaces[1].id]?.convergence)
        #expect(other.outcome == .unchanged && !other.accepted)
        try await controller.acceptConvergence(id: id, revision: try fixture.revision(id), attemptID: other.attemptID)
        try await fixture.wait(id, phase: .review)
        mission = try controller.record(id)
        let implementCounts = fixture.spaces.map { space in
            mission.run?.attempts.filter { $0.stationID == SpecKit.stationID(id, space.id, "phase-0") && $0.command == .implement }.count
        }
        #expect(implementCounts == [2, 1], "accepting a report resumes review without implementing again")
        #expect(mission.run?.publicationApproval == nil && mission.run?.reviewFingerprint != nil)
        #expect(controller.reviews[id]?.allSatisfy { $0.files.contains { file in file.displayPath == "result.txt" } } == true)
        for repo in fixture.repos {
            #expect(try String(contentsOf: repo.appendingPathComponent("result.txt"), encoding: .utf8) == "before\n", "primary checkouts untouched")
        }
    }
}
