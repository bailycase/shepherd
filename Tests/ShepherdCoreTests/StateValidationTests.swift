import Testing
import ShepherdCore

@Suite("Shepherd state validation")
struct StateValidationTests {
    private func validState(withLeafAgent: Bool = true) -> ShepherdState {
        let space = Space(name: "alpha", path: "/tmp/alpha")
        let agentID = AgentID()
        let pane = LeafPane(cwd: "/tmp/alpha", agentID: withLeafAgent ? agentID : nil)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(
            id: agentID,
            name: "worker",
            spaceID: space.id,
            tabID: tab.id,
            paneID: pane.id
        )
        return ShepherdState(spaces: [space], tabs: [tab], agents: [agent])
    }

    @Test func acceptsValidStateAndLegacyOptionalOwnership() throws {
        try validState().validate()

        var legacy = validState(withLeafAgent: false)
        legacy.agents[0].paneID = nil
        try legacy.validate()
    }

    @Test(arguments: [
        "duplicateSpace",
        "duplicateTab",
        "duplicateAgent",
        "duplicatePane",
        "missingTabSpace",
        "missingAgentSpace",
        "missingAgentTab",
        "agentTabSpaceMismatch",
        "missingAgentPane",
        "inconsistentPaneOwnership",
        "missingLeafAgent",
        "leafAgentWrongTab",
        "invalidRatio",
    ])
    func rejectsBrokenState(_ kind: String) {
        var state = validState()
        let originalSpace = state.spaces[0]
        let originalTab = state.tabs[0]
        let originalAgent = state.agents[0]
        let originalPane = originalTab.layout.firstLeaf

        switch kind {
        case "duplicateSpace":
            state.spaces.append(originalSpace)
        case "duplicateTab":
            state.tabs.append(originalTab)
        case "duplicateAgent":
            state.agents.append(originalAgent)
        case "duplicatePane":
            state.tabs[0].layout = .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(originalPane),
                second: .leaf(originalPane)
            )
        case "missingTabSpace":
            state.tabs[0].spaceID = SpaceID()
        case "missingAgentSpace":
            state.agents[0].spaceID = SpaceID()
        case "missingAgentTab":
            state.agents[0].tabID = TabID()
        case "agentTabSpaceMismatch":
            let otherSpace = Space(name: "beta", path: "/tmp/beta")
            state.spaces.append(otherSpace)
            state.tabs[0].spaceID = otherSpace.id
        case "missingAgentPane":
            state.agents[0].paneID = PaneID()
        case "inconsistentPaneOwnership":
            let otherAgentID = AgentID()
            state.tabs[0].layout = .leaf(LeafPane(cwd: "/tmp/alpha", agentID: otherAgentID))
            state.agents.append(Agent(
                id: otherAgentID,
                name: "other",
                spaceID: originalSpace.id,
                tabID: originalTab.id,
                paneID: originalPane.id
            ))
        case "missingLeafAgent":
            state.tabs[0].layout = .leaf(LeafPane(cwd: "/tmp/alpha", agentID: AgentID()))
        case "leafAgentWrongTab":
            let otherTab = Tab(spaceID: originalSpace.id, order: 1, layout: .leaf(LeafPane(cwd: "/tmp/other")))
            state.tabs.append(otherTab)
            state.tabs[1].layout = .leaf(LeafPane(cwd: "/tmp/other", agentID: originalAgent.id))
        case "invalidRatio":
            state.tabs[0].layout = .split(
                axis: .vertical,
                ratio: .nan,
                first: .leaf(originalPane),
                second: .leaf(LeafPane(cwd: "/tmp/other"))
            )
        default:
            Issue.record("unknown validation case: \(kind)")
            return
        }

        #expect(throws: ShepherdStateValidationError.self) {
            try state.validate()
        }
    }

    @Test func validatesAutomations() throws {
        var state = validState()
        let agentID = state.agents[0].id

        // Valid: linked to a live agent, or not linked at all.
        state.automations = [
            Automation(name: "a", prompt: "p", cwd: "/tmp", agentID: agentID),
            Automation(name: "b", prompt: "p", cwd: "/tmp"),
        ]
        try state.validate()

        // Duplicate automation ids rejected.
        state.automations[1].id = state.automations[0].id
        #expect(throws: ShepherdStateValidationError.self) { try state.validate() }

        // Dangling agent reference rejected.
        state = validState()
        state.automations = [Automation(name: "a", prompt: "p", cwd: "/tmp", agentID: AgentID())]
        #expect(throws: ShepherdStateValidationError.self) { try state.validate() }
    }

    @Test func rejectsEveryOutOfBoundsSplitRatio() {
        for ratio in [0.0, 1.0, -0.1, 1.1, Double.infinity, -Double.infinity, Double.nan] {
            var state = validState()
            let first = state.tabs[0].layout.firstLeaf
            state.tabs[0].layout = .split(
                axis: .vertical,
                ratio: ratio,
                first: .leaf(first),
                second: .leaf(LeafPane(cwd: "/tmp/other"))
            )
            #expect(throws: ShepherdStateValidationError.self) {
                try state.validate()
            }
        }
    }
}
