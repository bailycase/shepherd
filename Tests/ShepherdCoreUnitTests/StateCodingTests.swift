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
    }

    /// An agent keeps any level pi has; one this build does not know reads as pi's default.
    @Test(arguments: [("xhigh", ThinkingLevel.xhigh as ThinkingLevel?), ("minimal", .minimal), ("max", .max), ("ultra", nil)])
    func anAgentsThinkingLevelDecodes(_ raw: String, _ expected: ThinkingLevel?) throws {
        let agent = try Fixture.decode(Agent.self, #"{"id":"a1","name":"n","spaceID":"s","tabID":"t","status":"done","thinkingLevel":"\#(raw)"}"#)
        #expect(agent.thinkingLevel == expected)
    }

    @Test func aFreshlyCreatedAgentIsNotFinalNamed() {
        #expect(!Agent(name: "fix the bug", spaceID: SpaceID(), tabID: TabID()).nameIsFinal)
    }

    @Test func agentFieldsRoundTrip() throws {
        let agent = Agent(
            name: "calm-stone-3831", spaceID: SpaceID(), tabID: TabID(), paneID: PaneID(),
            status: .blocked, model: "anthropic/claude", thinkingLevel: .high, nameIsFinal: true,
            piSessionID: "s-2", worktreeBranch: "worktree/calm-stone-3831", worktreeBase: "origin/main",
            worktreePath: "/tmp/calm-stone-3831"
        )
        #expect(try Fixture.roundTrip(agent) == agent)
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
