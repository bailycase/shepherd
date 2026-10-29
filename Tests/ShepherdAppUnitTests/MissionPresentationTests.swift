import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdUI
@testable import ShepherdApp

@Suite("Mission presentation")
@MainActor
struct MissionPresentationTests {
    @Test func missionsFollowNewThreadRegardlessOfDesignExperiment() {
        for designs in [false, true] {
            let rows = SidebarDerivation.destinations(shown: .missions, newThreadChord: "test", designs: designs, missions: true)
            #expect(rows[1].target == .page(.missions))
            #expect(rows[1].icon == .symbol(SHGlyph.mission.symbolName))
            #expect(rows.filter(\.selected).map(\.title) == ["Missions"])
        }
    }

    @Test func mapKeepsDataConsumersBelowProducersAndPreventsLaneOverlap() throws {
        var lane = MissionLane(spaceID: SpaceID(), name: "service")
        lane.baseBranch = "refs/remotes/origin/main"
        let first = MissionStation(kind: .worker, laneID: lane.id, title: "First", goal: "Implement")
        let second = MissionStation(kind: .worker, laneID: lane.id, title: "Second", goal: "Implement")
        let validator = MissionStation(kind: .validator, title: "Validate", goal: "Check outputs independently")
        let plan = MissionPlan(lanes: [lane], stations: [validator, first, second], dependencies: [
            MissionDependency(source: first.id, target: validator.id, kind: .data, artifact: "change"),
            MissionDependency(source: second.id, target: validator.id, kind: .data, artifact: "change"),
        ])
        let layout = MissionMapLayout(plan: plan)
        let a = try #require(layout.node(first.id))
        let b = try #require(layout.node(second.id))
        let v = try #require(layout.node(validator.id))
        #expect(a.column == b.column)
        #expect(a.rank != b.rank)
        #expect(v.rank > a.rank && v.rank > b.rank)
        #expect(v.column == 0)
        #expect(layout.dependencies == plan.dependencies)
        #expect(layout.lanes.first { $0.id == lane.id.rawValue }?.subtitle == "origin/main")
        // The route's host-owned ends: the goal first, then your review, the lane's PR and publication.
        #expect(layout.node(id: "goal")?.rank == 0)
        let review = try #require(layout.node(id: "review"))
        #expect(review.rank > v.rank)
        #expect(layout.node(id: "pr-\(lane.id.rawValue)")?.rank == review.rank + 1)
        #expect(layout.wires.contains { $0.source == "goal" && $0.target == first.id.rawValue })
        #expect(layout.wires.contains { $0.source == validator.id.rawValue && $0.target == "review" })
        // Two wires into the validator join above it.
        #expect(layout.incoming(validator.id.rawValue).count == 2)
    }

    @Test func publishApprovalPinsRevisionAndRejectsStaleOrMissingRepositoryReceipts() {
        let space = SpaceID()
        var mission = Mission(revision: 4, draft: MissionDraft(title: "Change", goal: "Ship change"),
                              run: MissionRun(model: "test", phase: .review,
                                  checkouts: [MissionCheckout(spaceID: space, repo: "service", path: "/scratch/service", branch: "mission/change", base: "base", head: "reviewed", fingerprint: "content")],
                                  reviewFingerprint: "approval"))
        let review = MissionRepositoryReview(spaceID: space, name: "service", path: "/scratch/service", branch: "mission/change", head: "reviewed", fingerprint: "content", files: [])
        let state = MissionReviewApprovalState(mission: mission, repositories: [review])
        #expect(!state.stale)
        #expect(state.approval == MissionPublishApproval(id: mission.id, revision: 4, fingerprint: "approval"))
        mission.revision = 5
        mission.run?.checkouts[0].fingerprint = "changed-after-validation"
        #expect(state.approval?.revision == 4)
        #expect(MissionReviewApprovalState(mission: mission, repositories: [review]).approval == nil)
        #expect(MissionReviewApprovalState(mission: mission, repositories: []).stale)
        mission.run?.checkouts[0].fingerprint = "content"
        mission.run?.phase = .publishing
        #expect(MissionReviewApprovalState(mission: mission, repositories: [review]).approval == nil)
        mission.run?.publicationApproval = "approval"
        mission.run?.phase = .paused
        let retry = MissionReviewApprovalState(mission: mission, repositories: [review])
        #expect(retry.publicationAuthorized)
        #expect(retry.publishLabel == "Retry publication")
        #expect(retry.approval == MissionPublishApproval(id: mission.id, revision: 5, fingerprint: "approval"))
        #expect(MissionWorkspacePage.resolve(mission: mission) == .review)
        #expect(MissionWorkspacePage.review.available(for: mission))
        mission.run?.checkouts[0].publishedHead = "newcommit"
        var published = review; published.head = "newcommit-full-sha"
        #expect(MissionReviewApprovalState(mission: mission, repositories: [published]).approval != nil)
        mission.run?.phase = .stopped
        #expect(MissionReviewApprovalState(mission: mission, repositories: [published]).approval != nil)
        #expect(MissionWorkspacePage.resolve(mission: mission) == .review)
        published.head = "unrecognized-commit"
        #expect(MissionReviewApprovalState(mission: mission, repositories: [published]).approval == nil)
        mission.run?.checkouts[0].fingerprint = "changed-after-approval"
        #expect(MissionReviewApprovalState(mission: mission, repositories: [review]).approval == nil)
        mission.run?.reviewFingerprint = nil
        #expect(!MissionWorkspacePage.review.available(for: mission))
        // Stopped before any station ran (and with no map): back to the conversation, not Run.
        #expect(MissionWorkspacePage.resolve(mission: mission) == .goal)
        #expect(MissionWorkspacePage.reached(mission) == 0)
        mission.run?.attempts = [MissionAttempt(stationID: MissionStationID(), status: .interrupted)]
        #expect(MissionWorkspacePage.resolve(mission: mission) == .run)
        #expect(MissionWorkspacePage.reached(mission) == 2)
    }

    @Test func pausedPlanningShowsTheMapNotRun() {
        let station = MissionStation(kind: .research, title: "Research", goal: "Explore")
        let mission = Mission(draft: MissionDraft(title: "Plan", goal: "Plan", plan: MissionPlan(stations: [station])),
                              run: MissionRun(model: "test", phase: .paused))
        #expect(MissionWorkspacePage.resolve(mission: mission) == .map)
        #expect(MissionWorkspacePage.reached(mission) == 1)
        #expect(!MissionWorkspacePage.run.available(for: mission))
    }

    @Test func spendAndDurationsReadAsTheBoardWritesThem() {
        #expect(MissionFormat.duration(72 * 60) == "1h12")
        #expect(MissionFormat.duration(4 * 3600) == "4h")
        #expect(MissionFormat.duration(38 * 60) == "38m")
        #expect(MissionFormat.duration(0, dash: true) == "—")
        #expect(MissionFormat.tokens(6_000_000) == "6M")
        #expect(MissionFormat.tokens(2_300_000) == "2.3M")
        #expect(MissionFormat.tokens(0, dash: true) == "—")
        #expect(MissionFormat.pullNumber("https://github.com/o/r/pull/318") == "#318")
        #expect(MissionFormat.pullNumber(nil) == nil)
    }

    @Test func branchChoicesRequireEveryLaneAndLateDefaultsPreserveUserSelections() {
        let first = SpaceID(), second = SpaceID()
        let local = "refs/heads/main", remote = "refs/remotes/origin/main"
        let choices = [first: [local, remote], second: [local]]
        let defaults = [first: local, second: local]
        #expect(MissionBranchSelection.label(local) == "main")
        #expect(MissionBranchSelection.label(remote) == "origin/main")
        #expect(MissionBranchSelection.label("refs/heads/feature/checkout") == "feature/checkout")
        #expect(MissionBranchSelection.applyingDefaults(defaults, choices: [:], to: [:]).isEmpty)
        let selected = MissionBranchSelection.applyingDefaults(defaults, choices: choices, to: [first: remote])
        #expect(selected == [first: remote, second: local])
        #expect(MissionBranchSelection.ready(selected: [first, second], choices: choices, selections: selected))
        #expect(!MissionBranchSelection.ready(selected: [first, second], choices: choices, selections: [first: remote]))
        #expect(!MissionBranchSelection.ready(selected: [], choices: choices, selections: selected))
        let refreshed = [first: [local], second: [local]]
        #expect(MissionBranchSelection.applyingDefaults(defaults, choices: refreshed, to: selected) == selected)
        #expect(!MissionBranchSelection.ready(selected: [first, second], choices: refreshed, selections: selected))
        #expect(MissionBranchSelection.applyingDefaults(defaults, choices: choices, to: [first: ""])[first] == "")
    }

    @Test func emptyPlannerMapStaysInGoalEvenWithAnOldMapSelection() {
        var mission = Mission(draft: MissionDraft(title: "Plan", goal: "Plan", plan: MissionPlan()), run: MissionRun(model: "test", phase: .map))
        #expect(MissionWorkspacePage.resolve(mission: mission, preferred: .map) == .goal)
        #expect(!MissionWorkspacePage.map.available(for: mission))
        mission.draft.plan = nil
        #expect(MissionWorkspacePage.resolve(mission: mission) == .goal)
        mission.draft.plan = MissionPlan(stations: [MissionStation(kind: .research, title: "Research", goal: "Explore")])
        #expect(MissionWorkspacePage.resolve(mission: mission) == .map)
    }

    @Test func navigationAndFilteringFollowRecordedPhaseNotAttemptProse() {
        let paused = Mission(draft: MissionDraft(title: "Work", goal: "Work"), run: MissionRun(model: "test", phase: .paused))
        #expect(MissionListFilter.needsYou.includes(paused))
        #expect(!MissionListFilter.running.includes(paused))
        #expect(MissionWorkspacePage(phase: .review) == .review)
        #expect(MissionWorkspacePage(phase: .done) == .done)
        #expect(!MissionWorkspacePage.done.available(for: paused))
        #expect(MissionRun.Phase.done.missionLabel == "PRs published")
    }

    @Test func askedQuestionLeavesTheProseOnlyWhenItEndsTheMessage() {
        let asked = MissionChatMessage(role: .assistant, text: "Refunds flow through webhooks.\n\nNet them daily?", question: "Net them daily?")
        #expect(asked.prose == "Refunds flow through webhooks.")
        let quoted = MissionChatMessage(role: .assistant, text: "Net them daily? I'd say no.", question: "Net them daily?")
        #expect(quoted.prose == quoted.text)
        #expect(MissionChatMessage(role: .assistant, text: "Plain.").prose == "Plain.")
    }

    @Test func aRemovedLineCommentSaysSoInItsRequest() {
        let removed = MissionReviewComment(repository: "orders-svc", path: "place.go", line: 44, old: true, text: "Keep this")
        let added = MissionReviewComment(repository: "orders-svc", path: "place.go", line: 44, text: "Rename")
        #expect(removed.request == "orders-svc/place.go:44 (removed line): Keep this")
        #expect(added.request == "orders-svc/place.go:44: Rename")
    }

    @Test func specKitStepsFollowEachRepositorysOwnReceipts() {
        let a = SpaceID(), b = SpaceID()
        var run = MissionRun(model: "m")
        run.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: a), MissionSpecKitLane(spaceID: b)])
        var mission = Mission(draft: MissionDraft(title: "t", goal: "g"), run: run)
        #expect(!mission.specKitConsented)
        #expect(mission.specKitNext == .specify)
        run.specKit?.lanes[0].consentFingerprint = "f"; run.specKit?.lanes[1].consentFingerprint = "f"
        func done(_ space: SpaceID, _ command: SpecKitCommand) -> MissionAttempt {
            var attempt = MissionAttempt(stationID: SpecKit.stationID(mission.id, space, command.rawValue), status: .succeeded)
            attempt.command = command
            return attempt
        }
        // One repository's specify is not every repository's.
        run.attempts = [done(a, .specify)]
        mission.run = run
        #expect(mission.specKitConsented)
        #expect(mission.specKitNext == .specify)
        run.attempts += [done(b, .specify), done(a, .plan), done(b, .plan), done(a, .tasks), done(b, .tasks)]
        mission.run = run
        #expect(mission.specKitNext == nil)
        #expect(mission.specKitAwaitingAcceptance == nil)
        let converge = MissionAttempt(stationID: SpecKit.stationID(mission.id, a, "converge"), status: .succeeded)
        run.attempts.append(converge)
        run.specKit?.lanes[0].convergence = MissionSpecKitConvergence(attemptID: converge.id, outcome: .unchanged)
        mission.run = run
        #expect(mission.specKitAwaitingAcceptance?.attempt == converge.id)
        run.specKit?.lanes[0].convergence?.accepted = true
        mission.run = run
        #expect(mission.specKitAwaitingAcceptance == nil)
    }

    @Test func trustFollowsTheFingerprintThePersonAllowed() throws {
        func report(_ status: String, _ fingerprint: String) throws -> SpecKitPreflight {
            let json: [String: Any] = ["status": status, "testedVersion": "1.2.3", "matchesTestedRelease": true, "integrations": ["pi"],
                                       "missingCommands": [], "customizedFiles": [], "hooks": [], "ownershipConflicts": [], "warnings": [],
                                       "consentFingerprint": fingerprint]
            return try JSONDecoder().decode(SpecKitPreflight.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let space = SpaceID()
        let now = try report("ready", "now")
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space), report: now) == .needs(now))
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space, consentFingerprint: "now"), report: now) == .allowed)
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space, consentFingerprint: "before"), report: now) == .changed(now))
        let blocked = try report("blocked", "now")
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space, consentFingerprint: "now"), report: blocked) == .unready(blocked))
        // Not read since launch: an existing grant shows as allowed; planning re-reads before it runs.
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space, consentFingerprint: "now"), report: nil) == .allowed)
        #expect(MissionTrust(lane: MissionSpecKitLane(spaceID: space), report: nil) == .unread)
    }

    @Test func aSpecKitMapEditsOnlyTheOwnersChecksWhileTheLegacyMapEditsEveryStation() {
        let worker = MissionStation(kind: .worker, title: "Phase 1", goal: "/speckit.implement")
        let check = MissionStation(kind: .check, title: "go test", goal: "Run tests", command: "go test ./...")
        let legacy = Mission(draft: MissionDraft(title: "t", goal: "g"), run: MissionRun(model: "m"))
        #expect(legacy.mapStationsEditable(worker) && legacy.mapStationsEditable(check))
        var run = MissionRun(model: "m")
        run.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: SpaceID())])
        let specKit = Mission(draft: MissionDraft(title: "t", goal: "g"), run: run)
        #expect(!specKit.mapStationsEditable(worker))
        #expect(specKit.mapStationsEditable(check))
    }

    /// One /speckit.implement turn covers every tasks.md phase, so no phase reads "waiting" after it; and a
    /// completion report waiting for acceptance needs you rather than reading as a draft.
    @Test func specKitPhasesShareImplementAndAPendingReportNeedsYou() {
        let id = MissionID(), space = SpaceID()
        let projected = SpecKit.projection(mission: id, lane: space, artifacts: [.specify: true, .plan: true, .tasks: true], spec: nil,
                                           phases: SpecKit.parseTasks("## Phase 1: Setup\n- [ ] T001 a\n## Phase 2: Core\n- [ ] T002 b\n"))
        let plan = MissionPlan(lanes: [MissionLane(spaceID: space, name: "repo")], stations: projected.stations, dependencies: projected.dependencies)
        let implement = MissionAttempt(stationID: SpecKit.stationID(id, space, "phase-0"), status: .succeeded)
        var run = MissionRun(model: "m", phase: .map, attempts: [implement])
        run.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: space)])
        var mission = Mission(id: id, draft: MissionDraft(title: "t", goal: "g", plan: plan), run: run)
        #expect(mission.latest(SpecKit.stationID(id, space, "phase-1"))?.status == .succeeded)
        #expect(mission.latest(SpecKit.stationID(id, space, "converge")) == nil)
        #expect(mission.pill.label != "Needs you")
        mission.run?.specKit?.lanes[0].convergence = MissionSpecKitConvergence(attemptID: UUID(), outcome: .unchanged)
        #expect(mission.pill == (.attention, "Needs you"))
    }
}
