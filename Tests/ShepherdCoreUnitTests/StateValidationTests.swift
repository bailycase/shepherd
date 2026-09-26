import Testing
import ShepherdCore

@Suite("ShepherdState validation")
struct StateValidationTests {
    /// Which error a broken state must raise — the case name, so a regression that throws the
    /// wrong error for the right input still fails.
    enum Breakage: String, CaseIterable, Sendable {
        case duplicateSpace, duplicateTab, duplicateAgent, duplicatePane, duplicateAutomation, duplicateDesign
        case tabInUnknownSpace, agentInUnknownSpace, agentInUnknownTab, agentAndTabInDifferentSpaces
        case agentPointsAtUnknownPane, paneOwnedByAnotherAgent, leafNamesUnknownAgent
        case leafNamesAgentOfAnotherTab, automationNamesUnknownAgent

        var expectedError: String {
            switch self {
            case .duplicateSpace, .duplicateTab, .duplicateAgent, .duplicatePane, .duplicateAutomation, .duplicateDesign:
                return "duplicateID"
            case .tabInUnknownSpace: return "missingSpaceForTab"
            case .agentInUnknownSpace: return "missingSpaceForAgent"
            case .agentInUnknownTab: return "missingTabForAgent"
            case .agentAndTabInDifferentSpaces: return "agentTabSpaceMismatch"
            case .agentPointsAtUnknownPane: return "missingPaneForAgent"
            case .paneOwnedByAnotherAgent: return "inconsistentPaneOwnership"
            case .leafNamesUnknownAgent: return "leafAgentMissing"
            case .leafNamesAgentOfAnotherTab: return "leafAgentInWrongTab"
            case .automationNamesUnknownAgent: return "missingAgentForAutomation"
            }
        }

        func apply(to state: inout ShepherdState) {
            let space = state.spaces[0], tab = state.tabs[0], agent = state.agents[0]
            let pane = tab.layout.firstLeaf
            switch self {
            case .duplicateSpace: state.spaces.append(space)
            case .duplicateTab: state.tabs.append(tab)
            case .duplicateAgent: state.agents.append(agent)
            case .duplicatePane:
                state.tabs[0].layout = .split(axis: .vertical, ratio: 0.5, first: .leaf(pane), second: .leaf(pane))
            case .duplicateAutomation:
                let automation = Automation(name: "a", prompt: "p", cwd: "/tmp")
                state.automations = [automation, automation]
            case .duplicateDesign:
                let design = Design(name: "d", spaceID: space.id, createdAt: 1)
                state.designs = [design, design]
            case .tabInUnknownSpace: state.tabs[0].spaceID = SpaceID()
            case .agentInUnknownSpace: state.agents[0].spaceID = SpaceID()
            case .agentInUnknownTab: state.agents[0].tabID = TabID()
            case .agentAndTabInDifferentSpaces:
                let other = Space(name: "beta", path: "/tmp/beta")
                state.spaces.append(other)
                state.tabs[0].spaceID = other.id
            case .agentPointsAtUnknownPane: state.agents[0].paneID = PaneID()
            case .paneOwnedByAnotherAgent:
                let intruder = AgentID()
                state.tabs[0].layout = .leaf(LeafPane(id: pane.id, cwd: pane.cwd, agentID: intruder))
                state.agents.append(Agent(id: intruder, name: "intruder", spaceID: space.id, tabID: tab.id))
            case .leafNamesUnknownAgent:
                state.tabs[0].layout = .leaf(LeafPane(id: pane.id, cwd: pane.cwd, agentID: AgentID()))
                state.agents[0].paneID = nil
            case .leafNamesAgentOfAnotherTab:
                state.tabs.append(Tab(spaceID: space.id, order: 1, layout: .leaf(LeafPane(cwd: "/tmp", agentID: agent.id))))
            case .automationNamesUnknownAgent:
                state.automations = [Automation(name: "a", prompt: "p", cwd: "/tmp", agentID: AgentID())]
            }
        }
    }

    private static func caseName(_ error: ShepherdStateValidationError) -> String {
        Mirror(reflecting: error).children.first?.label ?? ""
    }

    @Test func aFullyLinkedStateIsValid() throws {
        try Fixture.state().validate()
    }

    @Test func ownershipFieldsAreOptionalForOldFiles() throws {
        var state = Fixture.state()
        state.agents[0].paneID = nil
        state.tabs[0].layout = .leaf(LeafPane(cwd: "/tmp/alpha"))
        try state.validate()
    }

    @Test func aTabWithoutASpaceIsTolerated() throws {
        var state = Fixture.state()
        state.tabs.append(Tab(spaceID: nil, order: 1, layout: .leaf(Fixture.leaf())))
        try state.validate()
    }

    @Test func automationsMayBeUnlinkedOrLinkedToALiveAgent() throws {
        var state = Fixture.state()
        state.automations = [
            Automation(name: "linked", prompt: "p", cwd: "/tmp", agentID: state.agents[0].id),
            Automation(name: "stopped", prompt: "p", cwd: "/tmp"),
        ]
        try state.validate()
    }

    /// A design's agent and an agent's design are soft references: startup clears what dangles,
    /// so a state that still has one is valid.
    @Test func designsAndTheirAgentsMayPointAtWhatIsGone() throws {
        var state = Fixture.state()
        state.designs = [Design(name: "d", spaceID: SpaceID(), agentID: AgentID(), createdAt: 1)]
        state.agents[0].designID = DesignID()
        try state.validate()
    }

    @Test(arguments: Breakage.allCases)
    func brokenStateIsRejectedWithTheMatchingError(_ breakage: Breakage) throws {
        var state = Fixture.state()
        breakage.apply(to: &state)
        let error = try #require(#expect(throws: ShepherdStateValidationError.self) { try state.validate() })
        #expect(Self.caseName(error) == breakage.expectedError)
    }

    @Test(arguments: [0.0, 1.0, -0.1, 1.1, .infinity, -.infinity, .nan])
    func splitRatiosOutsideTheOpenUnitIntervalAreRejected(_ ratio: Double) throws {
        var state = Fixture.state()
        state.tabs[0].layout = .split(
            axis: .vertical, ratio: ratio, first: state.tabs[0].layout, second: .leaf(Fixture.leaf())
        )
        let error = try #require(#expect(throws: ShepherdStateValidationError.self) { try state.validate() })
        #expect(Self.caseName(error) == "invalidSplitRatio")
    }

    @Test func errorsDescribeTheOffendingIDs() {
        let error = ShepherdStateValidationError.missingTabForAgent(agentID: AgentID(rawValue: "a1"), tabID: TabID(rawValue: "t9"))
        #expect(error.description == "agent a1 references unknown tab t9")
    }
}
