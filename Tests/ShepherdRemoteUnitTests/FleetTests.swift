import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Fleet: Home across hosts")
struct FleetTests {
    static let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let build = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let space = Space(id: SpaceID(rawValue: "s1"), name: "Shepherd", path: "/src/Shepherd")
    static let hidden = Space(id: SpaceID(rawValue: "auto"), name: "Automations", path: "/", hidden: true)

    static func agent(_ id: String, _ status: AgentStatus, space: Space = space, worktree: String? = nil) -> Agent {
        Agent(id: AgentID(rawValue: id), name: id.capitalized, spaceID: space.id, tabID: TabID(rawValue: "t-" + id),
              status: status, nameIsFinal: true, worktreeBranch: worktree)
    }

    static func host(_ id: UUID, _ name: String, _ phase: RemoteHostPhase = .connected, agents: [Agent],
                     automations: [Automation] = []) -> FleetHost {
        FleetHost(id: id, name: name, address: name.lowercased() + ".local", port: 7433, phase: phase,
                  state: ShepherdState(spaces: [space, hidden], agents: agents, automations: automations))
    }

    static func ref(_ agent: String, on host: UUID = studio) -> FleetRef { FleetRef(host: host, agent: AgentID(rawValue: agent)) }

    static func snapshot(_ messages: [NativeThreadMessage] = [], running: Bool = false, dialogs: [NativeThreadDialog] = [],
                         subagents: [ChildRun]? = nil, revision: UInt64 = 1, actions: [String] = ["answer"]) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "session", generation: "gen", revision: revision, running: running,
                             supportedActions: actions, dialogsSupported: true, dialogs: dialogs, messages: messages,
                             provisional: [], clipped: false, runtime: "rpc", subagents: subagents)
    }

    static func digest(_ snapshot: NativeThreadSnapshot) -> FleetDigest { FleetDigest(snapshot) }

    // MARK: Digest

    @Test(arguments: [
        (#"{"command":"swift build\nswift test"}"#, "bash", "swift build"),
        (#"{"path":"App/iOS/ThreadView.swift","oldText":"a","newText":"b"}"#, "edit", "edit ThreadView.swift"),
        (#"{"path":"Sources/Fleet.swift"}"#, "read", "read Fleet.swift"),
    ] as [(String, String, String)])
    func aRunningCallIsTheThreadsActivity(args: String, tool: String, activity: String) {
        let digest = Self.digest(Self.snapshot([
            Fixture.message("user", "go"),
            Fixture.tool(tool, args: args, status: "running", startedAt: 1_000, timestamp: 1_500),
        ], running: true))
        #expect(digest.activity == activity)
        #expect(digest.activitySince == 1_000)
    }

    @Test func aSettledThreadHasNoActivityButKnowsWhenItLastMoved() {
        let digest = Self.digest(Self.snapshot([
            Fixture.tool("bash", args: #"{"command":"ls"}"#, status: "running", timestamp: 2_000),
            NativeThreadMessage(entryID: "a", role: "assistant", blocks: [], timestamp: 9_000),
        ]))
        #expect(digest.activity == nil)
        #expect(digest.activitySince == nil)
        #expect(digest.lastActivity == 9_000)
    }

    @Test func theFirstDialogIsTheQuestionAndAnAskingSubagentIsKept() {
        var child = Fixture.run("run-1", needsAttention: true)
        child.role = "reviewer"
        child.question = ChildQuestion(text: "Rename or replace?")
        let digest = Self.digest(Self.snapshot(dialogs: [
            NativeThreadDialog(id: "d1", kind: .select, title: "Where?", options: ["Left", "Right"], message: "Pick one"),
            NativeThreadDialog(id: "d2", kind: .confirm, title: "Second"),
        ], subagents: [Fixture.run("quiet"), child]))
        #expect(digest.question == FleetDigest.Question(dialogID: "d1", kind: .select, title: "Where?", message: "Pick one",
                                                       options: ["Left", "Right"]))
        #expect(digest.subagentQuestion == FleetDigest.SubagentQuestion(runID: "run-1", label: "reviewer", text: "Rename or replace?"))
    }

    @Test(arguments: [
        (AgentStatus.working, nil, true),
        (.blocked, nil, true),
        (.done, nil, false),
        (.idle, [], false),
        (.done, [Fixture.run("finished", state: "complete")], false),
        (.done, [Fixture.run("background")], true),
        (.idle, [Fixture.run("finished", state: "failed"), Fixture.run("unknown-state", state: "queued")], true),
    ] as [(AgentStatus, [ChildRun]?, Bool)])
    func aSettledThreadStaysWatchedWhileASubagentMayStillAsk(status: AgentStatus, runs: [ChildRun]?, watched: Bool) {
        let digest = runs.map { Self.digest(Self.snapshot(subagents: $0)) }
        #expect(FleetDigest.watches(status: status, digest: digest) == watched)
    }

    @Test func aSettledThreadWithAQuestionOrARunningTurnIsWatched() {
        #expect(FleetDigest.watches(status: .done, digest: Self.digest(Self.snapshot(running: true))))
        #expect(FleetDigest.watches(status: .idle, digest: Self.digest(Self.snapshot(dialogs: [
            NativeThreadDialog(id: "d1", kind: .confirm, title: "Sure?"),
        ]))))
        #expect(FleetDigest.watches(status: .done, digest: Self.digest(Self.snapshot(subagents: [
            Fixture.run("asking", state: "paused", needsAttention: true),
        ]))))
    }

    @Test func anUnchangedAnswerMatchesOnlyTheSameSessionAndRevision() {
        let digest = Self.digest(Self.snapshot(revision: 7))
        #expect(digest.matches(piSessionID: "session", generation: "gen", revision: 7))
        #expect(!digest.matches(piSessionID: "session", generation: "gen", revision: 8))
        #expect(!digest.matches(piSessionID: "other", generation: "gen", revision: 7))
    }

    // MARK: Needs you

    @Test(arguments: [
        (NativeThreadDialog(id: "d", kind: .select, title: "Q", options: ["A", "B"]), FleetAttention.Reply.choose(["A", "B"])),
        (NativeThreadDialog(id: "d", kind: .select, title: "Q", options: ["A", "B", "C", "D"]), .open),
        (NativeThreadDialog(id: "d", kind: .select, title: "Q", options: [String(repeating: "x", count: 40)]), .open),
        (NativeThreadDialog(id: "d", kind: .confirm, title: "Q"), .confirm),
        (NativeThreadDialog(id: "d", kind: .input, title: "Q"), .open),
        (NativeThreadDialog(id: "d", kind: .editor, title: "Q"), .open),
        (NativeThreadDialog(id: "d", kind: .confirm, title: "Q", unavailable: "payload-limit"), .open),
    ] as [(NativeThreadDialog, FleetAttention.Reply)])
    func aQuestionAnswersInPlaceOnlyWhenItsOptionsFit(dialog: NativeThreadDialog, reply: FleetAttention.Reply) throws {
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("dock", .blocked)])],
                               digests: [Self.ref("dock"): Self.digest(Self.snapshot(running: true, dialogs: [dialog]))])
        let item = try #require(model.needsYou.first)
        #expect(model.needsYou.count == 1)
        #expect(item.reply == reply)
        #expect(item.dialogID == "d")
        #expect(item.question == "Q")
        #expect(item.reason == "asked you")
        #expect(item.session == NativeThreadSession(piSessionID: "session", generation: "gen"))
    }

    /// The sidebar's chip says why in the agent's own words when it gave them ("retention?"),
    /// cut as the Mac's when they run long, and "asked you" when it gave none or only blanks.
    @Test(arguments: [("retention?" as String?, "retention?"), ("  approve\n plan ", "approve plan"),
                      ("which base branch to use", "which base…"), (nil, "asked you"), (" ", "asked you")])
    func aQuestionsReasonIsTheAgentsOwnWhenItGaveOne(short: String?, reason: String) throws {
        var agent = Self.agent("dock", .blocked)
        agent.waitingOn = "Retention: 30 days or 13 months?"
        agent.waitingReason = short
        let dialog = NativeThreadDialog(id: "d", kind: .confirm, title: "Retention: 30 days or 13 months?")
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [agent])],
                               digests: [Self.ref("dock"): Self.digest(Self.snapshot(running: true, dialogs: [dialog]))])
        #expect(try #require(model.needsYou.first).reason == reason)
    }

    /// An asking subagent's chip is its own reason when it gave one, else its name.
    @Test(arguments: [("token names?" as String?, "token names?"), ("rename or replace tokens", "rename or…"),
                      (nil, "reviewer"), ("", "reviewer")])
    func anAskingSubagentsReasonIsItsOwnWhenItGaveOne(short: String?, reason: String) throws {
        var child = Fixture.run("run-1", needsAttention: true)
        child.label = "reviewer"
        child.question = ChildQuestion(text: "Rename or replace?", short: short)
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("restyle", .working)])],
                               digests: [Self.ref("restyle"): Self.digest(Self.snapshot(running: true, subagents: [child]))])
        let item = try #require(model.needsYou.first)
        #expect(item.reason == reason)
        #expect(item.origin == .subagent("reviewer"), "the subagent is still named by its label")
    }

    @Test func aThreadWhoseHostTakesNoAnswersIsAnsweredInTheThread() throws {
        let dialog = NativeThreadDialog(id: "d", kind: .confirm, title: "Q")
        let snapshot = Self.snapshot(running: true, dialogs: [dialog], actions: [])
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("dock", .blocked)])],
                               digests: [Self.ref("dock"): Self.digest(snapshot)])
        let item = try #require(model.needsYou.first)
        #expect(item.reply == .open)
        #expect(item.question == "Q")
    }

    @Test func aBlockedAgentWithoutItsSnapshotYetStillNeedsYou() throws {
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("dock", .blocked)])], digests: [:])
        let item = try #require(model.needsYou.first)
        #expect(item.reply == .open)
        #expect(item.question == "Waiting on you")
        #expect(item.title == "Dock")
        #expect(item.originLabel == "Thread")
    }

    @Test func anAskingSubagentIsItsOwnItemAndItsThreadStaysInRecentsOnlyIfNothingElseAsks() throws {
        var child = Fixture.run("run-1", needsAttention: true)
        child.label = "reviewer"
        child.attentionText = "Rename or replace?"
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("restyle", .working)])],
                               digests: [Self.ref("restyle"): Self.digest(Self.snapshot(running: true, subagents: [child]))])
        let item = try #require(model.needsYou.first)
        #expect(item.origin == .subagent("reviewer"))
        #expect(item.title == "reviewer asks")
        #expect(item.originLabel == "Subagent · Restyle")
        #expect(item.question == "Rename or replace?")
        #expect(item.runID == "run-1")
        #expect(item.reply == .open)
        #expect(model.recents.isEmpty)
        #expect(model.running.map(\.ref) == [Self.ref("restyle")])
    }

    @Test func onlyConnectedHostsAskAndOfflineRowsAreTheirLastKnownState() {
        let model = FleetModel(hosts: [
            Self.host(Self.studio, "Studio", .failed(RemoteHostFailure(kind: .unreachable, detail: "refused")), agents: [Self.agent("dock", .blocked), Self.agent("run", .working)]),
        ], digests: [:])
        #expect(model.needsYou.isEmpty)
        #expect(model.running.isEmpty)
        #expect(model.recents.map(\.ref) == [Self.ref("dock"), Self.ref("run")])
        #expect(model.recents.allSatisfy { $0.offline })
        #expect(model.recents.first?.detail == "needs you · Shepherd")
    }

    // MARK: Recents

    @Test func runningThreadsLeadThenTheMostRecentlyActiveAcrossHosts() {
        let digests: [FleetRef: FleetDigest] = [
            Self.ref("old"): Self.digest(Self.snapshot([NativeThreadMessage(entryID: "a", role: "assistant", blocks: [], timestamp: 1_000)])),
            Self.ref("new", on: Self.build): Self.digest(Self.snapshot([NativeThreadMessage(entryID: "b", role: "assistant", blocks: [], timestamp: 5_000)])),
        ]
        let model = FleetModel(hosts: [
            Self.host(Self.studio, "Studio", agents: [Self.agent("old", .idle), Self.agent("unknown", .done), Self.agent("live", .working)]),
            Self.host(Self.build, "build-01", agents: [Self.agent("new", .done)]),
        ], digests: digests)
        #expect(model.recents.map(\.ref) == [Self.ref("live"), Self.ref("new", on: Self.build), Self.ref("old"), Self.ref("unknown")])
        #expect(model.tagsHosts)
        #expect(model.recents.map(\.hostTag) == ["Studio", "build-01", "Studio", "Studio"])
        #expect(model.finished.map(\.ref) == [Self.ref("new", on: Self.build), Self.ref("unknown")])
        #expect(model.recents[2].clock == .ago(1_000))
    }

    @Test func aRunningRowSaysWhatItRunsAndSinceWhen() throws {
        let digest = Self.digest(Self.snapshot([
            Fixture.tool("bash", args: #"{"command":"swift build"}"#, status: "running", startedAt: 4_000, timestamp: 4_000),
        ], running: true))
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [Self.agent("plan", .working, worktree: "wt/a")])],
                               digests: [Self.ref("plan"): digest])
        let row = try #require(model.recents.first)
        #expect(row.detail == "running · swift build")
        #expect(row.activity == "swift build")
        #expect(row.clock == .elapsed(since: 4_000))
        #expect(row.worktree)
        #expect(row.hostTag == nil)
        #expect(!model.tagsHosts)
    }

    @Test func automationRunsAndHiddenSpacesStayOutOfTheThreads() {
        let run = Self.agent("run", .blocked, space: Self.hidden)
        let automation = Automation(id: AutomationID(rawValue: "a1"), name: "Nightly", prompt: "p", cwd: "/src/Shepherd",
                                    agentID: run.id)
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: [run, Self.agent("stray", .idle, space: Self.hidden)],
                                                 automations: [automation])], digests: [:])
        #expect(model.recents.isEmpty)
        #expect(model.needsYou.map(\.origin) == [.automation("Nightly")])
        #expect(model.needsYou.first?.originLabel == "Automation · Nightly")
        #expect(model.hosts.first?.summary == "No threads yet")
    }

    // MARK: Automations

    @Test(arguments: [
        (true, nil, "stopped"),
        (false, nil, "off"),
        (true, AgentStatus.working, "running"),
        (true, .blocked, "needs you"),
        (true, .idle, "done"),
        (true, .done, "done"),
    ] as [(Bool, AgentStatus?, String)])
    func anAutomationSaysHowItsRunIsDoing(enabled: Bool, status: AgentStatus?, word: String) throws {
        let run = status.map { Self.agent("run", $0, space: Self.hidden) }
        let automation = Automation(id: AutomationID(rawValue: "a1"), name: "Nightly", prompt: "watch CI", cwd: "/src/Shepherd",
                                    enabled: enabled, agentID: run?.id)
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", agents: run.map { [$0] } ?? [], automations: [automation])],
                               digests: [:])
        let row = try #require(model.automations.first)
        #expect(row.stateWord == word)
        #expect(row.place == "Shepherd")
        #expect(row.run == run.map { FleetRef(host: Self.studio, agent: $0.id) })
        let live = status == .working || status == .blocked
        #expect(model.automationsRunning.map(\.id) == (live ? [row.id] : []))
        #expect(model.automationsQuiet.map(\.id) == (live ? [] : [row.id]))
    }

    // MARK: Hosts

    @Test(arguments: [
        (RemoteHostPhase.connected, [agent("a", .working), agent("b", .working), agent("c", .idle)], "2 threads running · Shepherd", false),
        (.connected, [agent("a", .idle)], "1 thread · none running", false),
        (.connected, [], "No threads yet", false),
        (.connecting, [agent("a", .idle)], "Connecting…", false),
        (.failed(RemoteHostFailure(kind: .unreachable, detail: "connect failed: Connection refused (errno 61)")), [],
         "Shepherd isn't running on Studio, or it can't be reached.", true),
        (.failed(RemoteHostFailure(kind: .tokenRefused, detail: "unauthorized: bad token")), [],
         "Studio refused the token. Edit the host to paste its current token.", true),
        (.disconnected, [], "Not connected", true),
    ] as [(RemoteHostPhase, [Agent], String, Bool)])
    func aHostCardSummarizesItsThreadsOrWhyItIsOffline(phase: RemoteHostPhase, agents: [Agent], summary: String, retry: Bool) throws {
        let model = FleetModel(hosts: [Self.host(Self.studio, "Studio", phase, agents: agents)], digests: [:])
        let card = try #require(model.hosts.first)
        #expect(card.summary == summary)
        #expect(card.canRetry == retry)
        #expect(card.address == "studio.local:7433")
    }

    @Test func theSummariesCountAcrossHosts() {
        let model = FleetModel(hosts: [
            Self.host(Self.studio, "Studio", agents: [Self.agent("a", .working), Self.agent("b", .blocked),
                                                     Self.agent("run", .working, space: Self.hidden)],
                      automations: [Automation(id: AutomationID(rawValue: "nightly"), name: "Nightly", prompt: "go",
                                               cwd: "/", agentID: AgentID(rawValue: "run"))]),
            Self.host(Self.build, "build-01", .failed(RemoteHostFailure(kind: .lost, detail: "down")), agents: []),
        ], digests: [:])
        // Running counts what the overview's Running now lists: threads and automation runs.
        #expect(model.runningCount == 2)
        #expect(model.summary == "1 needs you · 2 running · 2 hosts")
        #expect(model.offlineSummary == "1 host offline")
        #expect(model.hosts.first?.needsYou == 1)
        #expect(FleetModel(hosts: [], digests: [:]).offlineSummary == nil)
    }
}
