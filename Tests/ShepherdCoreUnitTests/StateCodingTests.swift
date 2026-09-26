import Foundation
import Testing
import ShepherdCore

/// state.json compatibility: files written by any earlier Shepherd must decode, and what we
/// write back must be the current shape.
@Suite("State JSON coding and migration")
struct StateCodingTests {
    /// A pre-automation, pre-worktree, pre-autoname file from the terminal-agent era, carrying
    /// keys that have since been removed from every model.
    static let terminalEraFile = """
    {
      "spaces": [{"id": "s1", "name": "legacy", "path": "/tmp/legacy",
                  "gitBranch": "main", "colorHex": "#7D8FB3", "lastActiveTabID": "t1"}],
      "tabs": [{"id": "t1", "spaceID": "s1", "name": "old title", "nameIsFinal": true,
                "restoreCommand": "htop", "order": 0,
                "layout": {"type": "leaf", "pane": {"id": "p1", "cwd": "/tmp/legacy", "agentID": "a1"}}}],
      "agents": [{"id": "a1", "name": "worker", "spaceID": "s1", "tabID": "t1", "paneID": "p1",
                  "status": "working", "sessionMode": "tui", "runtime": "terminal"}],
      "subagents": [{"id": "child"}]
    }
    """

    @Test func aTerminalEraFileDecodesIntoAValidState() throws {
        let state = try Fixture.decode(ShepherdState.self, Self.terminalEraFile)
        try state.validate()
        #expect(state.spaces == [Space(id: SpaceID(rawValue: "s1"), name: "legacy", path: "/tmp/legacy")])
        #expect(state.tabs == [Tab(
            id: TabID(rawValue: "t1"), spaceID: SpaceID(rawValue: "s1"), order: 0,
            layout: .leaf(LeafPane(id: PaneID(rawValue: "p1"), cwd: "/tmp/legacy", agentID: AgentID(rawValue: "a1")))
        )])
        #expect(state.automations.isEmpty)
    }

    /// A terminal tab's name (Rename tab) rides on its first pane; older files have none.
    @Test func aPaneKeepsItsTabNameAndOlderPanesHaveNone() throws {
        let old = try Fixture.decode(LeafPane.self, #"{"id":"p1","cwd":"/tmp/x"}"#)
        #expect(old.title == nil)
        let named = LeafPane(cwd: "/tmp/x", title: "logs")
        #expect(try Fixture.roundTrip(named) == named)
        #expect(try Fixture.encodeObject(LeafPane(cwd: "/tmp/x"))["title"] == nil, "an unnamed pane writes no key")
    }

    @Test func removedKeysAreNotWrittenBack() throws {
        let state = try Fixture.decode(ShepherdState.self, Self.terminalEraFile)
        let object = try Fixture.encodeObject(state)
        let space = try #require((object["spaces"] as? [[String: Any]])?.first)
        let tab = try #require((object["tabs"] as? [[String: Any]])?.first)
        let agent = try #require((object["agents"] as? [[String: Any]])?.first)
        #expect(object["subagents"] == nil)
        for key in ["gitBranch", "colorHex", "lastActiveTabID"] { #expect(space[key] == nil, "space.\(key)") }
        for key in ["name", "nameIsFinal", "restoreCommand"] { #expect(tab[key] == nil, "tab.\(key)") }
        #expect(agent["sessionMode"] == nil)
    }

    @Test func aTerminalEraAgentKeepsItsSessionAndEncodesAsRPC() throws {
        let agent = try Fixture.decode(Agent.self, """
        {"id":"a","name":"old","spaceID":"s","tabID":"t","status":"idle","piSessionID":"conv","runtime":"terminal"}
        """)
        #expect(agent.effectivePiSessionID == "conv")
        #expect(try Fixture.encodeObject(agent)["runtime"] as? String == "rpc")
        #expect(try Fixture.roundTrip(agent) == agent)
    }

    @Test func aNewAgentAlsoEncodesItsRuntimeAsRPC() throws {
        let agent = Agent(name: "n", spaceID: SpaceID(), tabID: TabID())
        #expect(try Fixture.encodeObject(agent)["runtime"] as? String == "rpc")
    }

    @Test func agentOptionalFieldsDefaultWhenAbsent() throws {
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"done"}"#)
        #expect(agent.nameIsFinal, "pre-autoname names were chosen by a person and must stay")
        #expect(agent.piSessionID == nil)
        #expect(agent.effectivePiSessionID == "a1", "an untracked session is the one named after the agent")
        #expect(agent.paneID == nil && agent.model == nil && agent.thinkingLevel == nil)
        #expect(agent.worktreeBranch == nil && agent.worktreeBase == nil && agent.worktreePath == nil)
        #expect(agent.lastActiveAt == nil && agent.waitingOn == nil && agent.waitingReason == nil,
                "older hosts and state files carry none")
        #expect(agent.checkout == nil, "older hosts and state files carry no checkout")
    }

    /// An agent keeps any level pi has; one this build does not know reads as pi's default.
    @Test(arguments: [("xhigh", ThinkingLevel.xhigh as ThinkingLevel?), ("minimal", .minimal), ("max", .max), ("ultra", nil)])
    func anAgentsThinkingLevelDecodes(_ raw: String, _ expected: ThinkingLevel?) throws {
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"done","thinkingLevel":"\#(raw)"}"#)
        #expect(agent.thinkingLevel == expected)
    }

    /// What a client from before minimal, xhigh and max is sent: each level as pi would clamp it
    /// to Off, Low, Medium and High, and an unchanged state when it already knows them all.
    @Test func aStateForAnOlderClientCarriesOnlyTheLevelsItKnows() {
        let space = SpaceID(), tab = TabID()
        let levels: [ThinkingLevel?] = [.off, .minimal, .low, .medium, .high, .xhigh, .max, nil]
        let state = ShepherdState(agents: levels.map { Agent(name: "a", spaceID: space, tabID: tab, thinkingLevel: $0) })
        #expect(!state.usesOnlyLegacyThinkingLevels)
        let legacy = state.legacyThinkingLevels()
        #expect(legacy.agents.map(\.thinkingLevel) == [.off, .low, .low, .medium, .high, .high, .high, nil])
        #expect(legacy.usesOnlyLegacyThinkingLevels)
        #expect(legacy.legacyThinkingLevels() == legacy)
    }

    @Test func aFreshlyCreatedAgentIsNotFinalNamed() {
        #expect(!Agent(name: "fix the bug", spaceID: SpaceID(), tabID: TabID()).nameIsFinal)
    }

    @Test func agentFieldsRoundTrip() throws {
        let agent = Agent(
            name: "calm-stone-3831", spaceID: SpaceID(), tabID: TabID(), paneID: PaneID(),
            status: .blocked, model: "anthropic/claude", thinkingLevel: .high, nameIsFinal: true,
            piSessionID: "s-2", worktreeBranch: "worktree/calm-stone-3831", worktreeBase: "origin/main",
            worktreePath: "/tmp/calm-stone-3831", lastActiveAt: 1_790_000_000_000, waitingOn: "Which base?", waitingReason: "base?",
            checkout: AgentCheckout(branch: "worktree/calm-stone-3831", changedFiles: 3)
        )
        #expect(try Fixture.roundTrip(agent) == agent)
    }

    /// What an agent waits on is a running host's to say: state.json never keeps it, and
    /// everything else stays as it was.
    @Test func theStateFileKeepsNoQuestion() throws {
        let space = SpaceID(), tab = TabID()
        let asking = Agent(name: "a", spaceID: space, tabID: tab, status: .blocked, lastActiveAt: 5, waitingOn: "Ship it?",
                           waitingReason: "ship?")
        let quiet = Agent(name: "b", spaceID: space, tabID: tab, lastActiveAt: 7)
        let state = ShepherdState(agents: [asking, quiet])
        let persisted = state.persisted
        #expect(persisted.agents.map(\.waitingOn) == [nil, nil])
        #expect(persisted.agents.map(\.waitingReason) == [nil, nil])
        #expect(persisted.agents.map(\.lastActiveAt) == [5, 7])
        #expect(try Fixture.encodeObject(persisted.agents[0])["waitingOn"] == nil)
        #expect(try Fixture.encodeObject(persisted.agents[0])["waitingReason"] == nil)
        let unchanged = ShepherdState(agents: [quiet])
        #expect(unchanged.persisted == unchanged)
    }

    @Test func spaceHiddenDefaultsFalseAndRoundTrips() throws {
        #expect(try Fixture.decode(Space.self, #"{"id":"s","name":"n","path":"/p"}"#).hidden == false)
        let hidden = Space(name: "automations", path: "/tmp", hidden: true)
        #expect(try Fixture.roundTrip(hidden) == hidden)
    }

    @Test func tabIgnoresShellOnlyKeysAndDefaultsInspectorForToNil() throws {
        let tab = try Fixture.decode(Tab.self, """
        {"id":"t","name":"zsh","nameIsFinal":false,"restoreCommand":"btop","order":3,
         "layout":{"type":"leaf","pane":{"id":"p","cwd":"/"}}}
        """)
        #expect(tab.spaceID == nil, "global shells had no space; startup drops them")
        #expect(tab.inspectorFor == nil)
        #expect(tab.order == 3)
    }

    @Test func utilityTerminalTabsRoundTripTheirInspectedAgent() throws {
        let tab = Tab(spaceID: SpaceID(), order: 0, layout: .leaf(Fixture.leaf()), inspectorFor: AgentID())
        #expect(try Fixture.roundTrip(tab) == tab)
    }

    @Test func wholeStateRoundTrips() throws {
        var state = Fixture.state()
        state.automations = [Automation(name: "watch", prompt: "p", cwd: "/tmp", agentID: state.agents[0].id)]
        #expect(try Fixture.roundTrip(state) == state)
    }

    @Test func missingRequiredCollectionsFailToDecode() {
        #expect(throws: DecodingError.self) { try Fixture.decode(ShepherdState.self, #"{"spaces":[],"tabs":[]}"#) }
    }

    @Test func createSessionParamsDefaultToAPTYRuntime() throws {
        let decoded = try Fixture.decode(CreateSessionParams.self, #"{"cwd":"/tmp","command":[],"cols":80,"rows":24}"#)
        #expect(decoded.runtime == .pty)
        #expect(decoded.env == nil)
        let rpc = CreateSessionParams(cwd: "/tmp", command: ["pi", "--mode", "rpc"], env: ["K": "V"], runtime: .rpc)
        #expect(try Fixture.roundTrip(rpc) == rpc)
    }

    @Test func sessionRuntimeWireSpellingIsStable() {
        #expect(SessionRuntime.pty.rawValue == "terminal")
        #expect(SessionRuntime.rpc.rawValue == "rpc")
    }
}

@Suite("Design model")
struct DesignModelTests {
    @Test func stateAndAgentsFromBeforeDesignsDecodeWithout() throws {
        let state = try Fixture.decode(ShepherdState.self, #"{"spaces":[],"tabs":[],"agents":[],"automations":[]}"#)
        #expect(state.designs.isEmpty)
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"idle"}"#)
        #expect(agent.designID == nil)
        #expect(try Fixture.encodeObject(agent)["designID"] == nil, "an agent that draws nothing writes no designID")
    }

    @Test func aDesignAndItsAgentRoundTrip() throws {
        let design = Design(name: "Checkout", spaceID: SpaceID(), agentID: AgentID(), systemNamespace: "acme-web",
                            createdAt: 1_000, lastActiveAt: 2_000, boardCount: 4)
        #expect(try Fixture.roundTrip(design) == design)
        let bare = Design(name: "Bare", spaceID: SpaceID(), createdAt: 5)
        #expect(bare.lastActiveAt == 5, "a new design was last active when it was made")
        #expect(try Fixture.roundTrip(bare) == bare)
        let agent = Agent(name: "designer", spaceID: SpaceID(), tabID: TabID(), designID: design.id)
        #expect(try Fixture.roundTrip(agent).designID == design.id)
    }

    /// The board count is what the host reads from the design's files: never written to state.json.
    @Test func thePersistedStateDropsBoardCounts() {
        let design = Design(name: "Checkout", spaceID: SpaceID(), createdAt: 1, boardCount: 4)
        let state = ShepherdState(designs: [design])
        #expect(state.persisted.designs.first?.boardCount == nil)
        #expect(state.persisted.designs.first?.name == "Checkout")
        let uncounted = ShepherdState(designs: [Design(name: "New", spaceID: SpaceID(), createdAt: 1)])
        #expect(uncounted.persisted == uncounted)
    }
}

@Suite("Automation model")
struct AutomationModelTests {
    @Test func newAutomationsAreEnabledAndStopped() {
        let automation = Automation(name: "pr-watch", prompt: "watch PR 1", cwd: "/tmp")
        #expect(automation.enabled)
        #expect(automation.agentID == nil)
    }

    @Test func automationRoundTripsWithAndWithoutARunningAgent() throws {
        let stopped = Automation(name: "a", prompt: "p", cwd: "/tmp", enabled: false)
        let running = Automation(name: "b", prompt: "q", cwd: "/repo", agentID: AgentID())
        #expect(try Fixture.roundTrip(stopped) == stopped)
        #expect(try Fixture.roundTrip(running) == running)
    }

    @Test func automationsDefaultToEmptyInPreAutomationFiles() throws {
        let state = try Fixture.decode(ShepherdState.self, #"{"spaces":[],"tabs":[],"agents":[]}"#)
        #expect(state.automations.isEmpty)
    }
}
