import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Missions track's screens: every host's missions (iPhone list, iPad beside the chosen one, Home's
// section), a mission waiting on a planner question, one asking for a repository's Spec Kit OK,
// one running, its review with a file's diff, and New mission. The host answers reads from here;
// the fixture host refuses every action and New mission.
extension FixtureCatalog {
    static var missions: [FixtureScreen] {
        let hosts = MissionsFixtureData.hosts()
        let studio = FixtureData.studio
        let load: @MainActor (MobileApp) async -> Void = { app in
            for host in app.hosts.hosts where host.servesMissions { await host.missions.refresh() }
        }
        let choose: (MissionID) -> @MainActor (MobileApp) async -> Void = { id in
            { app in
                await load(app)
                MissionsChoice.shared.chosen = MissionKey(host: studio, mission: id)
            }
        }
        let D = MissionsFixtureData.self
        return [
            FixtureScreen(name: "missions-home", hosts: hosts, prepare: load),
            FixtureScreen(name: "missions-list", hosts: hosts, routes: [.missions(.list)], prepare: choose(D.review)),
            FixtureScreen(name: "mission-question", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.question))],
                          prepare: choose(D.question)),
            FixtureScreen(name: "mission-consent", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.consent))],
                          prepare: choose(D.consent)),
            FixtureScreen(name: "mission-running", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.running))],
                          prepare: choose(D.running)),
            FixtureScreen(name: "mission-review", hosts: hosts,
                          routes: [.missions(.list), .missions(.mission(host: studio, mission: D.review)), .missions(.review(host: studio, mission: D.review))],
                          prepare: choose(D.review)),
            FixtureScreen(name: "mission-file", hosts: hosts,
                          routes: [.missions(.list), .missions(.review(host: studio, mission: D.review)),
                                   .missions(.file(host: studio, mission: D.review, space: FixtureData.shepherdSpace.id, path: "Sources/Checkout/Events.swift"))],
                          prepare: load),
            FixtureScreen(name: "mission-patch", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.patched))],
                          prepare: choose(D.patched)),
            FixtureScreen(name: "mission-train", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.training))],
                          prepare: choose(D.training)),
            FixtureScreen(name: "mission-train-blocked", hosts: hosts, routes: [.missions(.list), .missions(.mission(host: studio, mission: D.blocked))],
                          prepare: choose(D.blocked)),
            FixtureScreen(name: "mission-new", hosts: hosts, routes: [.missions(.list)], presented: .missions(.new(host: studio)), prepare: load),
        ]
    }
}

/// A host's missions as the fixture host serves them.
struct FixtureMissions: Sendable {
    var records: [Mission]
    var options: RemoteMissionStartOptions
    var reviews: [MissionID: [RemoteMissionReview]] = [:]
    var files: [String: DiffFile] = [:]
    var specKit: [MissionID: RemoteMissionSpecKit] = [:]
    /// What running missions' agents say now, read with the record.
    var live: [MissionID: RemoteMissionLive] = [:]

    func answer(_ request: RemoteMissionRequest) -> Result<RemoteMissionResult, MissionError> {
        switch request {
        case .list: return .success(.list(records.map(RemoteMissionSummary.init)))
        case .get(let id):
            guard let mission = records.first(where: { $0.id == id }) else { return .failure(MissionError("mission_missing", "Mission no longer exists.")) }
            return .success(.mission(mission, live: live[id]))
        case .startOptions: return .success(.startOptions(options))
        case .review(let id): return .success(.review(reviews[id] ?? []))
        case .reviewFile(_, _, let path):
            guard let file = files[path] else { return .failure(MissionError("mission_review_file", "That file is not in the current review.")) }
            return .success(.reviewFile(file))
        case .specKit(let id): return .success(.specKit(specKit[id] ?? RemoteMissionSpecKit()))
        case .templates: return .success(.templates([]))
        case .create, .action: return .failure(MissionError("fixture", "The fixture host changes nothing."))
        }
    }
}

enum MissionsFixtureData {
    static let review = MissionID(rawValue: "00000000-0000-4000-8000-000000000001")
    static let question = MissionID(rawValue: "00000000-0000-4000-8000-000000000002")
    static let running = MissionID(rawValue: "00000000-0000-4000-8000-000000000003")
    static let consent = MissionID(rawValue: "00000000-0000-4000-8000-000000000004")
    static let patched = MissionID(rawValue: "00000000-0000-4000-8000-000000000005")
    static let training = MissionID(rawValue: "00000000-0000-4000-8000-000000000006")
    static let blocked = MissionID(rawValue: "00000000-0000-4000-8000-000000000007")
    static let shepherd = FixtureData.shepherdSpace, horizon = FixtureData.horizonSpace
    static let now = FixtureData.start / 1000

    static func station(_ n: Int, _ kind: MissionStation.Kind, _ lane: Space?, _ title: String, command: String? = nil) -> MissionStation {
        MissionStation(id: MissionStationID(rawValue: String(format: "00000000-0000-4000-8000-0000000001%02d", n)), kind: kind, laneID: lane?.id,
                       title: title, goal: title, command: command)
    }

    static func plan() -> MissionPlan {
        MissionPlan(lanes: [MissionLane(spaceID: shepherd.id, name: shepherd.name, baseBranch: "refs/heads/main"),
                            MissionLane(spaceID: horizon.id, name: horizon.name, baseBranch: "refs/heads/main")],
                    stations: [station(1, .worker, shepherd, "Emit checkout events"), station(2, .worker, horizon, "Join events to orders"),
                               station(3, .check, horizon, "swift test", command: "swift test"), station(4, .validator, nil, "Replay orders end to end")])
    }

    static func mission(_ id: MissionID, _ title: String, phase: MissionRun.Phase, settled: Int, running: Int? = nil) -> Mission {
        var run = MissionRun(model: "anthropic/claude-opus", phase: phase, messages: [
            .init(role: .user, text: title + " across Shepherd and horizon."),
            .init(role: .assistant, text: "I read both repositories. The map has a worker per repository, the test suite, and an independent replay."),
        ], elapsedSeconds: 38 * 60)
        let stations = plan().stations
        run.attempts = stations.prefix(settled).map { MissionAttempt(stationID: $0.id, agentID: AgentID(rawValue: "mission-\($0.id.rawValue.suffix(2))"),
                                                                    status: .succeeded, tokens: 120_000) }
        if let running { run.attempts.append(MissionAttempt(stationID: stations[running].id, agentID: AgentID(rawValue: "mission-run"), status: .running)) }
        return Mission(id: id, revision: 7, draft: MissionDraft(title: title, goal: title, requirements: ["Every order joins a checkout"], plan: plan()),
                       approvedPlanRevision: phase == .map ? nil : 5, run: run)
    }

    static func hosts() -> [FixtureHostData] {
        var reviewed = mission(review, "Checkout funnel events", phase: .review, settled: 4)
        reviewed.run?.reviewFingerprint = String(repeating: "a1", count: 32)
        reviewed.run?.checkouts = [shepherd, horizon].map { space in
            MissionCheckout(spaceID: space.id, repo: space.path, path: "/Users/dev/.shepherd/worktrees/mission-\(space.name)", branch: "mission/checkout-events",
                            base: "refs/heads/main", head: "4b825dc", fingerprint: "fp-\(space.name)")
        }
        var asking = mission(question, "Refund webhooks", phase: .map, settled: 0)
        let asked = MissionChatMessage(role: .assistant, text: "Which queue should refunds use?", question: "Which queue should refunds use?",
                                       choices: ["The existing payments queue", "A new refunds queue"])
        asking.run?.messages.append(asked)
        asking.run?.pendingQuestion = asked.question
        asking.run?.pendingChoices = asked.choices
        let working = mission(running, "Ledger cleanup", phase: .running, settled: 1, running: 1)
        var trusting = mission(consent, "Search indexing", phase: .map, settled: 0)
        trusting.draft.plan?.stations = []
        trusting.run?.specKit = MissionSpecKitRun(lanes: [MissionSpecKitLane(spaceID: shepherd.id)])
        trusting.run?.checkouts = [MissionCheckout(spaceID: shepherd.id, repo: shepherd.path, path: "/wt/search", branch: "mission/search",
                                                   base: "refs/heads/main", head: "4b825dc")]
        trusting.draft.plan?.lanes = [MissionLane(spaceID: shepherd.id, name: shepherd.name, baseBranch: "refs/heads/main")]
        let events = DiffFile(oldPath: "Sources/Checkout/Events.swift", newPath: "Sources/Checkout/Events.swift", displayPath: "Sources/Checkout/Events.swift",
                              isNew: false, isDeleted: false, isRenamed: false, isBinary: false, hunks: [DiffHunk(header: "@@ -12,6 +12,9 @@ struct CheckoutEvents", lines: [
                                  DiffLine(kind: .context, text: "    func record(_ step: Step) {", oldLine: 12, newLine: 12, id: 0),
                                  DiffLine(kind: .removed, text: "        log(step)", oldLine: 13, newLine: nil, id: 1),
                                  DiffLine(kind: .added, text: "        let event = CheckoutEvent(step: step, order: order.id)", oldLine: nil, newLine: 13, id: 2),
                                  DiffLine(kind: .added, text: "        outbox.append(event)", oldLine: nil, newLine: 14, id: 3),
                                  DiffLine(kind: .added, text: "        log(event)", oldLine: nil, newLine: 15, id: 4),
                                  DiffLine(kind: .context, text: "    }", oldLine: 14, newLine: 16, id: 5),
                              ])])
        let join = DiffFile(oldPath: nil, newPath: "analytics/join.sql", displayPath: "analytics/join.sql", isNew: true, isDeleted: false, isRenamed: false,
                            isBinary: false, hunks: [DiffHunk(header: "@@ -0,0 +1,3 @@", lines: [
                                DiffLine(kind: .added, text: "select o.id, e.step", oldLine: nil, newLine: 1, id: 0),
                                DiffLine(kind: .added, text: "from orders o join checkout_events e on e.order_id = o.id", oldLine: nil, newLine: 2, id: 1),
                                DiffLine(kind: .added, text: "order by e.at;", oldLine: nil, newLine: 3, id: 2)])])
        let reviews = [RemoteMissionReview(spaceID: shepherd.id, name: shepherd.name, path: reviewed.run!.checkouts[0].path, branch: "mission/checkout-events",
                                           head: "4b825dc", fingerprint: "fp-Shepherd", files: [RemoteMissionReviewFile(events)]),
                       RemoteMissionReview(spaceID: horizon.id, name: horizon.name, path: reviewed.run!.checkouts[1].path, branch: "mission/checkout-events",
                                           head: "4b825dc", fingerprint: "fp-horizon", files: [RemoteMissionReviewFile(join)])]
        let ready = try! JSONDecoder().decode(SpecKitPreflight.self, from: Data("""
        {"status":"ready","testedVersion":"1.2.3","matchesTestedRelease":true,"integrations":["pi"],"missingCommands":[],"customizedFiles":[],
         "hooks":[],"ownershipConflicts":[],"warnings":[],"consentFingerprint":"5c1f0a9be27d4e8a"}
        """.utf8))
        // MobilePatch: the planner's patch for horizon after a failed join, waiting on Apply.
        var stuck = mission(patched, "Checkout funnel events", phase: .paused, settled: 1)
        stuck.run?.notice = "Join events to orders failed its check twice. Paused for you."
        var after = stuck.draft
        let outbox = MissionStation(id: MissionStationID(rawValue: "00000000-0000-4000-8000-000000000150"), kind: .worker, laneID: horizon.id,
                                    title: "outbox-tx", goal: "make outbox.Write take the caller's tx")
        let outboxTest = MissionStation(id: MissionStationID(rawValue: "00000000-0000-4000-8000-000000000151"), kind: .check, laneID: horizon.id,
                                        title: "go test ./internal/outbox/...", goal: "Run the outbox tests", command: "go test ./internal/outbox/...")
        after.plan?.stations.insert(contentsOf: [outbox, outboxTest], at: 1)
        after.plan?.stations[3].goal = "Join events to orders on top of the outbox fix"
        after.plan?.estimate = MissionEstimate(tokens: 3_500_000, seconds: 2 * 3600 + 5 * 60)
        stuck.draft.plan?.estimate = MissionEstimate(tokens: 3_100_000, seconds: 3600 + 38 * 60)
        stuck.run?.patch = MissionPatch(proposedAt: now - 120, base: stuck.draft, draft: after,
                                        summary: "Only horizon changes. The validator still waits for it, so nothing else re-runs.")
        let missions = FixtureMissions(records: [reviewed, asking, working, trusting, stuck, train(training, blocked: false), train(blocked, blocked: true)],
                                       options: RemoteMissionStartOptions(models: ["anthropic/claude-opus", "openai/gpt-5"], defaultModel: "anthropic/claude-opus",
                                                                          spaces: [shepherd, horizon],
                                                                          branchChoices: [shepherd.id: ["refs/heads/main", "refs/remotes/origin/main"],
                                                                                          horizon.id: ["refs/heads/main"]],
                                                                          defaultBranches: [shepherd.id: "refs/heads/main", horizon.id: "refs/heads/main"]),
                                       reviews: [review: reviews], files: [events.displayPath: events, join.displayPath: join],
                                       specKit: [consent: RemoteMissionSpecKit(reports: [shepherd.id: ready])],
                                       live: [running: RemoteMissionLive(output: "Joining checkout_events to orders on order_id; 2 of 3 partitions backfilled.",
                                                                         attempts: [working.run!.attempts.last!.id: "Joining checkout_events to orders on order_id; 2 of 3 partitions backfilled."])])
        var hosts = FixtureData.hosts()
        hosts[0].missions = missions
        return hosts
    }

    /// MXTrain on the phone: a published mission's four pull requests, the second soaking on staging,
    /// or (blocked) the third stopped on a code conflict with the train paused.
    static func train(_ id: MissionID, blocked: Bool) -> Mission {
        let names = ["contracts", "analytics-ingest", "checkout-svc", "orders-svc"]
        let lanes = names.map { MissionLane(spaceID: SpaceID(rawValue: "space-\($0)"), name: $0, baseBranch: "refs/heads/main") }
        var run = MissionRun(model: "anthropic/claude-opus", phase: .done, elapsedSeconds: 2 * 3600 + 52 * 60)
        run.publicationApproval = String(repeating: "b2", count: 32)
        run.checkouts = lanes.enumerated().map { index, lane in
            MissionCheckout(spaceID: lane.spaceID, repo: "/Users/dev/\(lane.name)", path: "/wt/\(lane.name)", branch: "mission/checkout-events",
                            base: "refs/heads/main", head: "4b825dc", prURL: "https://github.com/acme/\(lane.name)/pull/\([412, 97, 231, 318][index])")
        }
        var train = MissionTrain(order: lanes.map(\.spaceID), rules: MissionTrain.Rules(between: .stagingSoak, soakMinutes: 10), startedAt: now - 30 * 60)
        let finished = blocked ? 2 : 1
        for car in 0..<finished { for step in train.cars[car].steps.indices { train.cars[car].steps[step].status = .done; train.cars[car].steps[step].at = now - Double(20 - car * 5) * 60 } }
        if blocked {
            train.cars[2].steps[0].status = .failed
            train.cars[2].steps[0].note = "code conflict with main in internal/events/emit.go"
            train.pause("checkout-svc has a code conflict with main in internal/events/emit.go. Code conflicts pause and ask.")
        } else {
            for step in 0..<4 { train.cars[1].steps[step].status = .done; train.cars[1].steps[step].at = now - 8 * 60 }
            train.cars[1].steps[4].status = .running
            train.cars[1].steps[4].at = now - 4 * 60
        }
        run.train = train
        return Mission(id: id, revision: 12, draft: MissionDraft(title: blocked ? "Order events" : "Checkout funnel events", goal: "Emit checkout funnel events",
                                                                plan: MissionPlan(lanes: lanes)), approvedPlanRevision: 5, run: run)
    }
}
