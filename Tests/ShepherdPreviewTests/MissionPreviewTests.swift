import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Missions in the real shell (sidebar, header, destination) from core mission records, at the
/// boards' width and at a narrow window, in both appearances.
extension PreviewTests {
    @Test func missionsShell() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let fixture = try MissionPreviewFixture(dir: workspace.dir)
        try await fixture.seed(workspace)
        let vm = workspace.vm
        // Missions is an experiment, off by default; these previews draw it turned on.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        let controller = vm.missions
        func show(_ id: MissionID?, _ name: String, widths: [CGFloat] = [1440], panes: MissionInitialPanes = MissionInitialPanes()) async throws {
            controller.selectedID = id
            controller.reviews = fixture.reviews
            for width in widths {
                // Review and Done refresh their diffs on open; the fixture's worktrees are records, not
                // checkouts, so let that refresh fail and clear its banner before capturing.
                let refreshes = id.flatMap { id in controller.records.first { $0.id == id } }.map { [.review, .done].contains($0.phase) } ?? false
                try await Preview.render(width == 1440 ? name : "\(name)-\(Int(width))", size: CGSize(width: width, height: 900),
                                         ready: { !controller.availableModels.isEmpty && (!refreshes || controller.error != nil) },
                                         afterReady: { controller.error = nil; controller.reviews = fixture.reviews }) {
                    RootView(vm: vm).environment(\.missionInitialPanes, panes)
                }
            }
        }
        let side = MissionInitialPanes(side: true)
        try await show(nil, "missions-list", widths: [1440, 720])
        // The same Missions section in the Spaces sidebar style, above the Spaces tree.
        vm.settings.sidebarStyle = .projects
        try await show(nil, "missions-sidebar-spaces")
        vm.settings.sidebarStyle = .activity
        try await show(fixture.goal.id, "mission-goal-question", widths: [1440, 720])
        try await show(fixture.planning.id, "mission-goal-planning")
        try await show(fixture.pausedPlanning.id, "mission-paused-planning")
        try await show(fixture.draft.id, "mission-map", widths: [1440, 720])
        try await show(fixture.running.id, "mission-run", widths: [1440, 720])
        try await show(fixture.review.id, "mission-review", widths: [1440, 720])
        try await show(fixture.done.id, "mission-done", widths: [1440, 720])
        // The narrow windows' other pane: the brief, the station, Done's summary.
        try await show(fixture.goal.id, "mission-goal-brief", widths: [720], panes: side)
        try await show(fixture.draft.id, "mission-map-station", widths: [720], panes: side)
        try await show(fixture.running.id, "mission-run-station", widths: [720], panes: side)
        try await show(fixture.done.id, "mission-done-summary", widths: [720], panes: side)
        try await show(fixture.draft.id, "mission-map-data", panes: MissionInitialPanes(wires: .data))
        try await show(fixture.draft.id, "mission-map-both", panes: MissionInitialPanes(wires: .both))
        // Review with a queued change, a draft on another line and the third requirement's evidence open.
        let repo = fixture.reviews[fixture.review.id]?.first
        let path = repo?.files.first?.displayPath ?? ""
        let comments = [
            MissionReviewComment(repository: repo?.name ?? "", path: path, line: 44,
                                 text: "Can the topic name come from the events package instead of a string literal?", queued: true),
            MissionReviewComment(repository: repo?.name ?? "", path: path, line: 47, text: ""),
        ]
        try await show(fixture.review.id, "mission-review-details", widths: [1440, 720],
                       panes: MissionInitialPanes(comments: comments, openContractItem: 2))
        try await show(fixture.review.id, "mission-review-contract", widths: [720], panes: MissionInitialPanes(side: true, openContractItem: 2))
    }

    @Test func missionsEmptyAndStart() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let fixture = try MissionPreviewFixture(dir: workspace.dir)
        try await workspace.seed(fixture.state)
        let vm = workspace.vm
        // Missions is an experiment, off by default; these previews draw it turned on.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        let controller = vm.missions
        try await Preview.render("missions-empty", size: CGSize(width: 1440, height: 900)) { RootView(vm: vm) }
        // New mission in the real shell, as its button opens it: empty, then with words and two repositories.
        try await Preview.render("mission-start", size: CGSize(width: 1440, height: 900),
                                 ready: { controller.availableSpaces.count == fixture.spaces.count && !controller.availableModels.isEmpty }) {
            RootView(vm: vm).environment(\.missionInitialPanes, MissionInitialPanes(creating: true))
        }
        let chosen = fixture.spaces.prefix(2).map(\.id)
        for width: CGFloat in [1440, 720] {
            try await Preview.render(width == 1440 ? "mission-start-ready" : "mission-start-ready-720", size: CGSize(width: width, height: 900),
                                     ready: { chosen.allSatisfy { controller.branchChoices[$0]?.isEmpty == false } && !controller.availableModels.isEmpty }) {
                RootView(vm: vm).environment(\.missionInitialPanes, MissionInitialPanes(creating: true, startGoal: fixture.draft.draft.goal, startSpaces: chosen))
            }
        }
    }
}

/// Stock Spec Kit missions over the same repositories: each preflight state the owner can meet, the
/// explicit grant, the next stock command, and a converge report waiting for acceptance. The reports
/// are the controller's in-memory preflight results, set as `reviews` are.
extension PreviewTests {
    @Test func missionSpecKit() async throws {
        let workspace = try PreviewWorkspace()
        defer { workspace.stop() }
        let fixture = try MissionPreviewFixture(dir: workspace.dir)
        try await workspace.server.putState(fixture.state)
        let repos = fixture.spaces
        let lanes = repos.map { MissionLane(spaceID: $0.id, name: $0.name, baseBranch: "refs/heads/main") }
        let goal = fixture.draft.draft.goal
        let checkouts = repos.map { MissionCheckout(spaceID: $0.id, repo: $0.path, path: $0.path + "-mission", branch: "mission/anl-214", base: "1234567", head: "abcdef0") }
        let user = MissionChatMessage(role: .user, text: "Add checkout funnel analytics. It's ANL-214.")

        func report(_ status: String, fingerprint: String = "files-now", customized: [String] = [], hooks: [[String: Any]] = [],
                    conflicts: [String] = [], warnings: [String] = [], missing: [String] = []) throws -> SpecKitPreflight {
            let json: [String: Any] = [
                "status": status, "recordedVersion": "1.2.3", "testedVersion": "1.2.3", "matchesTestedRelease": customized.isEmpty,
                "scriptType": "sh", "integrations": ["pi"], "defaultIntegration": "pi", "missingCommands": missing,
                "customizedFiles": customized, "hooks": hooks, "ownershipConflicts": conflicts, "warnings": warnings,
                "consentFingerprint": fingerprint,
            ]
            return try JSONDecoder().decode(SpecKitPreflight.self, from: JSONSerialization.data(withJSONObject: json))
        }
        let ready = try report("ready", customized: [".pi/prompts/speckit.plan.md"],
                               hooks: [["event": "after_tasks", "command": "speckit.analyze", "optional": true, "enabled": true]])

        func mission(_ title: String, consent: String?, commands: [SpecKitCommand] = [], plan: MissionPlan? = nil,
                     converge: Bool = false) -> Mission {
            let id = MissionID()
            var run = MissionRun(model: "claude-sonnet-4", messages: [user], checkouts: checkouts,
                                 notice: "Review each repository's Spec Kit files and consent before the first command. Nothing has been sent.")
            run.specKit = MissionSpecKitRun(lanes: repos.map { MissionSpecKitLane(spaceID: $0.id, featureDirectory: commands.isEmpty ? nil : "specs/001-checkout-funnel", consentFingerprint: consent) })
            run.attempts = repos.flatMap { repo in commands.map { command in
                var attempt = MissionAttempt(stationID: SpecKit.stationID(id, repo.id, command.rawValue), agentID: AgentID(), status: .succeeded,
                                             output: "Wrote specs/001-checkout-funnel/\(command == .specify ? "spec" : command.rawValue).md", tokens: 120_000)
                attempt.command = command
                return attempt
            } }
            if converge, let first = repos.first {
                var report = MissionAttempt(stationID: SpecKit.stationID(id, first.id, SpecKitCommand.converge.rawValue), agentID: AgentID(), status: .succeeded,
                                            output: "All tasks in tasks.md are complete and match the spec. No tasks appended.", tokens: 90_000)
                report.command = .converge
                run.attempts.append(report)
                run.specKit?.lanes[0].convergence = MissionSpecKitConvergence(attemptID: report.id, outcome: .unchanged)
                run.notice = "Read the /speckit.converge report for \(first.name). Accept it, reply or request changes. It is an assessment, not test evidence."
            }
            return Mission(id: id, draft: MissionDraft(title: title, goal: goal, plan: plan ?? MissionPlan(lanes: lanes)),
                           approvedPlanRevision: converge ? 1 : nil, run: run)
        }
        func convergePlan(_ id: MissionID) -> MissionPlan {
            // As the projection draws it: spec → plan → tasks, then each implement phase feeds its own converge.
            MissionPlan(lanes: lanes, stations: repos.flatMap { repo in [
                MissionStation(id: SpecKit.stationID(id, repo.id, "specify"), kind: .research, laneID: repo.id, title: "Specify", goal: "/speckit.specify writes spec.md"),
                MissionStation(id: SpecKit.stationID(id, repo.id, "plan"), kind: .research, laneID: repo.id, title: "Plan", goal: "/speckit.plan writes plan.md"),
                MissionStation(id: SpecKit.stationID(id, repo.id, "tasks"), kind: .research, laneID: repo.id, title: "Tasks", goal: "/speckit.tasks writes tasks.md"),
                MissionStation(id: SpecKit.stationID(id, repo.id, "phase-0"), kind: .worker, laneID: repo.id, title: "Phase 1: Setup", goal: "/speckit.implement"),
                MissionStation(id: SpecKit.stationID(id, repo.id, SpecKitCommand.converge.rawValue), kind: .validator, laneID: repo.id, title: "Converge", goal: "/speckit.converge"),
            ] }, dependencies: repos.flatMap { repo in
                let station = { (key: String) in SpecKit.stationID(id, repo.id, key) }
                return [
                    MissionDependency(source: station("specify"), target: station("plan"), kind: .data, artifact: "spec.md"),
                    MissionDependency(source: station("plan"), target: station("tasks"), kind: .data, artifact: "plan.md"),
                    MissionDependency(source: station("tasks"), target: station("phase-0"), kind: .data, artifact: "tasks.md"),
                    MissionDependency(source: station("phase-0"), target: station(SpecKitCommand.converge.rawValue), kind: .data, artifact: "tasks.md"),
                ]
            })
        }

        let unconsented = mission("Spec Kit: needs your consent", consent: nil)
        let allowed = mission("Spec Kit: next command", consent: "files-now", commands: [.specify])
        let changed = mission("Spec Kit: files changed", consent: "files-before")
        let blocked = mission("Spec Kit: blocked", consent: nil)
        var converging = mission("Spec Kit: converge report", consent: "files-now", commands: [.specify, .plan, .tasks], converge: true)
        converging.draft.plan = convergePlan(converging.id)
        // The planner's clarifying question, asked from one repository's thread.
        var asking = mission("Spec Kit: planner question", consent: "files-now", commands: [.specify])
        let question = "Should replayed events keep their original timestamps?"
        asking.run?.messages.append(MissionChatMessage(role: .assistant, text: "The spec for contracts leaves replay ordering open. \(question)",
                                                       question: question, choices: ["Keep the original timestamps", "Stamp them on replay"],
                                                       spaceID: repos[0].id))
        asking.run?.pendingQuestion = question
        asking.run?.pendingChoices = ["Keep the original timestamps", "Stamp them on replay"]
        // Spec, plan and tasks everywhere: the map is ready for Launch to approve.
        var mapReady = mission("Spec Kit: map ready", consent: "files-now", commands: [.specify, .plan, .tasks])
        mapReady.draft.plan = convergePlan(mapReady.id)
        mapReady.draft.requirements = repos.flatMap { repo in fixture.draft.draft.requirements.prefix(2).map { "\(repo.name): \($0)" } }
        // The spec's requirements, as the projection copies them into the brief per repository.
        converging.draft.requirements = repos.flatMap { repo in fixture.draft.draft.requirements.prefix(2).map { "\(repo.name): \($0)" } }

        for value in [unconsented, allowed, changed, blocked, converging, asking, mapReady] {
            var saved = try await workspace.server.createMission(id: value.id, draft: value.draft)
            if value.approvedPlanRevision != nil { saved = try await workspace.server.approveMissionPlan(id: value.id, expectedRevision: saved.revision) }
            _ = try await workspace.server.setMissionRun(id: value.id, expectedRevision: saved.revision, run: value.run!)
        }
        let vm = workspace.vm
        try await eventuallyOnMain("missions to load") { vm.state.missions.count == 7 }
        // Missions is an experiment, off by default; these previews draw it turned on.
        vm.settings.missionsEnabled = true
        vm.openDestination(.missions)
        let controller = vm.missions
        let reports: [MissionID: [SpaceID: SpecKitPreflight]] = [
            unconsented.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
            allowed.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
            changed.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
            blocked.id: [
                repos[0].id: try report("blocked", conflicts: ["A mandatory before_implement hook runs `git commit`; missions own their commits."]),
                repos[1].id: try report("notInitialized"),
                repos[2].id: try report("piIntegrationMissing", missing: ["specify", "plan", "tasks", "implement"]),
            ],
            converging.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
            asking.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
            mapReady.id: Dictionary(uniqueKeysWithValues: repos.map { ($0.id, ready) }),
        ]
        /// `side`: at 720, open the side pane (the brief, or the station on Map) instead of the conversation,
        /// where the trust cards, the planner's activity and its question live.
        func show(_ id: MissionID, _ name: String, side: Bool = false) async throws {
            controller.selectedID = id
            for width: CGFloat in [1440, 720] {
                try await Preview.render(width == 1440 ? name : "\(name)-720", size: CGSize(width: width, height: 1100),
                                         ready: { !controller.availableModels.isEmpty },
                                         afterReady: { controller.error = nil; controller.specKitReports = reports }) {
                    // Narrow windows show the brief, where the Spec Kit section lives.
                    RootView(vm: vm).environment(\.missionInitialPanes, MissionInitialPanes(side: side && width < 1440))
                }
            }
        }
        controller.specKitReports = reports
        try await show(unconsented.id, "mission-speckit-consent")
        try await show(allowed.id, "mission-speckit-next", side: true)
        try await show(changed.id, "mission-speckit-changed")
        try await show(blocked.id, "mission-speckit-blocked")
        try await show(asking.id, "mission-speckit-question")
        try await show(mapReady.id, "mission-speckit-ready")
        try await show(converging.id, "mission-speckit-converge", side: true)
    }
}

/// Core mission records in every phase, over real Git repositories (the start page lists their
/// branches) and real diffs; not a screenshot-only presentation model.
private struct MissionPreviewFixture {
    let spaces: [Space]
    let state: ShepherdState
    let goal, planning, pausedPlanning, draft, running, review, done: Mission
    let reviews: [MissionID: [MissionRepositoryReview]]

    init(dir: URL) throws {
        let names = ["contracts", "analytics-ingest", "orders-svc"]
        let repos = try names.map { name in
            let path = dir.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            _ = try git(["init", "-q", "-b", "main"], in: path)
            _ = try git(["-c", "user.name=Preview", "-c", "user.email=preview@example.com", "commit", "-q", "--allow-empty", "-m", "init"], in: path)
            return Space(name: name, path: path.path)
        }
        spaces = repos
        let lanes = repos.map { MissionLane(spaceID: $0.id, name: $0.name, baseBranch: "refs/heads/main") }
        let (contracts, analytics, orders) = (repos[0].id, repos[1].id, repos[2].id)

        let audit = MissionStation(kind: .research, title: "event-audit", goal: "Find every producer and consumer of order events and the existing outbox.", doneWhen: ["List producers, consumers and the registry they share."])
        let schema = MissionStation(kind: .worker, laneID: contracts, title: "schema", goal: "Add CheckoutStarted and checkout_id to OrderPlaced in events/v1 without breaking consumers.", doneWhen: ["buf breaking is clean against main.", "OrderPlaced carries checkout_id."])
        let buf = MissionStation(kind: .check, laneID: contracts, title: "buf lint + breaking", goal: "Lint and check compatibility.", command: "buf lint && buf breaking --against .git#branch=main", doneWhen: ["Exit 0."])
        let ingest = MissionStation(kind: .worker, laneID: analytics, title: "analytics", goal: "Store funnel events in analytics.checkout_funnel, partitioned monthly.", model: "claude-sonnet-4", doneWhen: ["Replaying the topic doesn't double-count."])
        let ingestTest = MissionStation(kind: .check, laneID: analytics, title: "go test ./...", goal: "Run the ingest tests.", command: "go test ./...", doneWhen: ["Exit 0."])
        let place = MissionStation(kind: .worker, laneID: orders, title: "orders", goal: "Publish OrderPlaced through the existing outbox when an order commits. Carry order_id, totals and currency.", doneWhen: ["go test ./... green.", "OrderPlaced is written in the same transaction as the order.", "No Kafka producer calls outside the relay."])
        let ordersTest = MissionStation(kind: .check, laneID: orders, title: "go test ./...", goal: "Run the order service tests.", command: "go test ./...", doneWhen: ["Exit 0."])
        let validator = MissionStation(kind: .validator, title: "validator", goal: "Run the e2e stack and verify every requirement against the actual diffs.", doneWhen: ["Every requirement verified with evidence."])
        let stations = [audit, schema, buf, ingest, ingestTest, place, ordersTest, validator]
        let plan = MissionPlan(lanes: lanes, stations: stations, dependencies: [
            MissionDependency(source: audit.id, target: schema.id, kind: .data, artifact: "findings"),
            MissionDependency(source: schema.id, target: buf.id, kind: .data, artifact: "protos"),
            MissionDependency(source: buf.id, target: ingest.id, kind: .data, artifact: "events v1.8.0-rc.1"),
            MissionDependency(source: buf.id, target: place.id, kind: .data, artifact: "events v1.8.0-rc.1"),
            MissionDependency(source: ingest.id, target: ingestTest.id, kind: .data, artifact: "ingest"),
            MissionDependency(source: place.id, target: ordersTest.id, kind: .data, artifact: "outbox"),
            MissionDependency(source: ingestTest.id, target: validator.id, kind: .data, artifact: "ingest branch"),
            MissionDependency(source: ordersTest.id, target: validator.id, kind: .data, artifact: "orders branch"),
        ], limits: MissionLimits(tokens: 6_000_000, seconds: 4 * 3600))
        let draftValue = MissionDraft(title: "Checkout funnel events", goal: "Checkout and orders emit `CheckoutStarted` and `OrderPlaced`; analytics-ingest stores them in `analytics.checkout_funnel` so product can see drop-off per step.",
            requirements: ["Order in the e2e stack emits CheckoutStarted → OrderPlaced", "Every OrderPlaced joins a CheckoutStarted in checkout_funnel", "Replaying the topic doesn't double-count", "Outbox only, never inline"],
            context: ["ANL-214", "funnel-spec.md", "events/v1/order.proto", "internal/outbox"], plan: plan)
        let now = Date().timeIntervalSince1970
        let user = MissionChatMessage(role: .user, text: "Add checkout funnel analytics. Product wants to see drop-off at every checkout step, so CheckoutStarted and OrderPlaced need to land somewhere we can query. It's ANL-214.")
        let summary = MissionChatMessage(role: .assistant, text: "This touches three repos. `contracts` owns the event protos, `orders-svc` produces OrderPlaced through its transactional outbox, and `analytics-ingest` consumes `orders.events.v1` into Postgres.")
        let planner = MissionAttempt(agentID: AgentID(), status: .succeeded, output: summary.text, tokens: 210_000, cost: 1.2)

        func attempt(_ station: MissionStation, _ status: MissionAttempt.Status, start: Double, end: Double? = nil, tokens: Int = 0, output: String = "", exit: Int32? = nil) -> MissionAttempt {
            var value = MissionAttempt(stationID: station.id, agentID: station.kind == .check ? nil : AgentID(), status: status, output: output, tokens: tokens, cost: Double(tokens) / 200_000, exitCode: exit)
            value.startedAt = now - start; value.endedAt = end.map { now - $0 }
            return value
        }
        let checkouts = repos.map { space in
            MissionCheckout(spaceID: space.id, repo: space.path, path: space.path + "-mission", branch: "mission/anl-214", base: "1234567", head: "abcdef0", fingerprint: "content-\(space.name)")
        }
        func mission(_ title: String, _ phase: MissionRun.Phase, draft: MissionDraft? = nil, attempts: [MissionAttempt] = [], elapsed: Double = 0,
                     messages: [MissionChatMessage]? = nil, question: String? = nil, choices: [String]? = nil, notice: String? = nil,
                     published: Bool = false) -> Mission {
            var value = draft ?? draftValue
            value.title = title
            var run = MissionRun(model: "claude-sonnet-4", phase: phase, messages: messages ?? [user, summary],
                                 checkouts: checkouts.map { checkout in
                                     var copy = checkout
                                     if published { copy.prURL = "https://github.com/acme/\(repos.first { $0.id == checkout.spaceID }!.name)/pull/\(300 + (repos.firstIndex { $0.id == checkout.spaceID } ?? 0))"; copy.publishedHead = "abcdef0" }
                                     return copy
                                 },
                                 attempts: [planner] + attempts, elapsedSeconds: elapsed, notice: notice,
                                 reviewFingerprint: [.review, .done].contains(phase) ? "reviewed-set" : nil)
            run.pendingQuestion = question; run.pendingChoices = choices
            if published { run.publicationApproval = "reviewed-set" }
            return Mission(draft: value, approvedPlanRevision: phase == .map || phase == .planning ? nil : 1, run: run)
        }
        let passed = stations.enumerated().map { index, station in
            attempt(station, .succeeded, start: Double(9000 - index * 900), end: Double(8400 - index * 900), tokens: 400_000,
                    output: station.kind == .validator ? "Ran the e2e stack after 2,000 checkouts: every OrderPlaced joined its CheckoutStarted (0 unmatched). Replayed the topic twice; row counts unchanged." : station.kind == .check ? "Command: \(station.command ?? "")\nExit: 0\nok" : "Done.",
                    exit: station.kind == .check ? 0 : nil)
        }

        goal = mission("Checkout funnel events", .map, draft: MissionDraft(title: "", goal: draftValue.goal, requirements: Array(draftValue.requirements.prefix(2)), context: draftValue.context, plan: MissionPlan(lanes: lanes)),
                       messages: [user, MissionChatMessage(role: .assistant, text: summary.text + "\n\n`payments-svc` also emits order events, but the ticket only mentions checkout steps. One question decides whether it's in.")],
                       question: "Should the funnel include payment steps?", choices: ["No, checkout and orders only", "Yes, add payments-svc"])
        // An answered question, through its receipts: the asking message and the reply that picked a suggestion.
        let refundsQuestion = "Should partial refunds post as their own ledger entries?"
        let asked = MissionChatMessage(role: .assistant, text: "Refunds already flow through `payments-svc` webhooks. \(refundsQuestion)",
                                       question: refundsQuestion, choices: ["Yes, one entry per refund", "No, net them daily"])
        let refundsConversation = [
            MissionChatMessage(role: .user, text: "Record refunds in the ledger so finance can reconcile them daily."), asked,
            MissionChatMessage(role: .user, text: "Yes, one entry per refund", replyTo: asked.id, choice: "Yes, one entry per refund"),
        ]
        planning = mission("Refunds in the ledger", .planning, draft: MissionDraft(title: "", goal: "Record refunds in the ledger so finance can reconcile them daily.", plan: MissionPlan(lanes: Array(lanes.prefix(2)))),
                           messages: refundsConversation)
        pausedPlanning = mission("Search reindex on Postgres 17", .paused, notice: "Paused. Worktrees and evidence are retained; nothing will resume on its own.")
        draft = mission("Checkout funnel events", .map)
        running = mission("Checkout funnel events", .running, attempts: [
            attempt(audit, .succeeded, start: 4300, end: 3900, tokens: 320_000, output: "Producers: orders-svc via internal/outbox. Consumers: analytics-ingest. Registry: buf."),
            attempt(schema, .succeeded, start: 3800, end: 3000, tokens: 610_000, output: "Added CheckoutStarted and checkout_id to OrderPlaced."),
            attempt(buf, .failed, start: 2950, end: 2900, output: "Command: buf breaking\nExit: 1\nfield 4 renamed", exit: 1),
            attempt(schema, .succeeded, start: 2880, end: 2500, tokens: 220_000, output: "Kept field 4's name; added checkout_id as field 7."),
            attempt(buf, .succeeded, start: 2480, end: 2400, output: "Command: buf lint && buf breaking\nExit: 0", exit: 0),
            attempt(ingest, .running, start: 540, tokens: 380_000),
            attempt(place, .running, start: 840, tokens: 612_000),
        ], elapsed: 4320)
        review = mission("Checkout funnel events", .review, attempts: passed, elapsed: 9600)
        done = mission("Checkout funnel events", .done, attempts: passed, elapsed: 10_680, published: true)

        let files = DiffFile.parse("""
        diff --git a/internal/orders/place.go b/internal/orders/place.go
        --- a/internal/orders/place.go
        +++ b/internal/orders/place.go
        @@ -38,9 +38,12 @@ func (s *Service) PlaceOrder(ctx context.Context, req *ordersv1.PlaceOrderRequest) {
         	tx, err := s.db.BeginTx(ctx, nil)
         	if err != nil {
         		return nil, err
         	}
         	defer tx.Rollback()
        -	if err := tx.Commit(); err != nil {
        -		return nil, err
        -	}
        -	s.publisher.Publish(ctx, "orders.placed", order.ID)
        +	evt := &eventsv1.OrderPlaced{OrderId: order.ID, CheckoutId: req.GetCheckoutId()}
        +	if err := s.outbox.Write(ctx, tx, "orders.events.v1", evt); err != nil {
        +		return nil, fmt.Errorf("outbox: %w", err)
        +	}
        +	if err := tx.Commit(); err != nil {
        +		return nil, err
        +	}
         	return toProto(order), nil
        diff --git a/internal/outbox/events.go b/internal/outbox/events.go
        --- a/internal/outbox/events.go
        +++ b/internal/outbox/events.go
        @@ -1,3 +1,4 @@
         package outbox
        +const OrdersTopic = "orders.events.v1"
        """)
        let byRepo = checkouts.map { checkout in
            MissionRepositoryReview(spaceID: checkout.spaceID, name: repos.first { $0.id == checkout.spaceID }!.name, path: checkout.path,
                                    branch: checkout.branch, head: checkout.head, fingerprint: checkout.fingerprint!, files: files)
        }
        var reviews: [MissionID: [MissionRepositoryReview]] = [:]
        for value in [running, review, done] { reviews[value.id] = byRepo }
        self.reviews = reviews
        var state = ShepherdState()
        state.spaces = repos
        self.state = state
    }

    /// Through the revision-checked mission service, as the app writes them.
    @MainActor func seed(_ workspace: PreviewWorkspace) async throws {
        try await workspace.server.putState(state)
        for mission in [goal, planning, pausedPlanning, draft, running, review, done] {
            var saved = try await workspace.server.createMission(id: mission.id, draft: mission.draft)
            if mission.approvedPlanRevision != nil { saved = try await workspace.server.approveMissionPlan(id: mission.id, expectedRevision: saved.revision) }
            if let run = mission.run { _ = try await workspace.server.setMissionRun(id: mission.id, expectedRevision: saved.revision, run: run) }
        }
        let vm = workspace.vm
        try await eventuallyOnMain("missions to load") { vm.state.missions.count == 7 }
    }
}
