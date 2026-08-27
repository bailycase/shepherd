import Foundation

/// Structural errors that make a persisted workspace unsafe to use.
public enum ShepherdStateValidationError: Error, CustomStringConvertible, Sendable {
    case duplicateID(kind: String, id: String)
    case missingSpaceForTab(tabID: TabID, spaceID: SpaceID)
    case missingSpaceForAgent(agentID: AgentID, spaceID: SpaceID)
    case missingTabForAgent(agentID: AgentID, tabID: TabID)
    case agentTabSpaceMismatch(agentID: AgentID, agentSpaceID: SpaceID, tabSpaceID: SpaceID)
    case missingPaneForAgent(agentID: AgentID, paneID: PaneID)
    case inconsistentPaneOwnership(agentID: AgentID, paneID: PaneID)
    case leafAgentMissing(agentID: AgentID, paneID: PaneID)
    case leafAgentInWrongTab(agentID: AgentID, paneID: PaneID, tabID: TabID)
    case invalidSplitRatio(Double)
    case missingAgentForAutomation(automationID: AutomationID, agentID: AgentID)

    public var description: String {
        switch self {
        case .duplicateID(let kind, let id):
            return "duplicate \(kind) id: \(id)"
        case .missingSpaceForTab(let tabID, let spaceID):
            return "tab \(tabID) references unknown space \(spaceID)"
        case .missingSpaceForAgent(let agentID, let spaceID):
            return "agent \(agentID) references unknown space \(spaceID)"
        case .missingTabForAgent(let agentID, let tabID):
            return "agent \(agentID) references unknown tab \(tabID)"
        case .agentTabSpaceMismatch(let agentID, let agentSpaceID, let tabSpaceID):
            return "agent \(agentID) belongs to space \(agentSpaceID), but its tab belongs to \(tabSpaceID)"
        case .missingPaneForAgent(let agentID, let paneID):
            return "agent \(agentID) references unknown pane \(paneID)"
        case .inconsistentPaneOwnership(let agentID, let paneID):
            return "agent \(agentID) and pane \(paneID) disagree about ownership"
        case .leafAgentMissing(let agentID, let paneID):
            return "pane \(paneID) references unknown agent \(agentID)"
        case .leafAgentInWrongTab(let agentID, let paneID, let tabID):
            return "pane \(paneID) references agent \(agentID) outside tab \(tabID)"
        case .invalidSplitRatio(let ratio):
            return "split ratio must be finite and between 0 and 1: \(ratio)"
        case .missingAgentForAutomation(let automationID, let agentID):
            return "automation \(automationID) references unknown agent \(agentID)"
        }
    }
}

public extension ShepherdState {
    /// Verify the references and layout invariants required by the server and UI.
    /// Optional agent/pane ownership fields remain optional for old state files.
    func validate() throws {
        var spaceIDs = Set<SpaceID>()
        for space in spaces {
            guard spaceIDs.insert(space.id).inserted else {
                throw ShepherdStateValidationError.duplicateID(kind: "space", id: space.id.rawValue)
            }
        }

        var tabIDs = Set<TabID>()
        var paneIDs = Set<PaneID>()
        var tabByID: [TabID: Tab] = [:]
        for tab in tabs {
            guard tabIDs.insert(tab.id).inserted else {
                throw ShepherdStateValidationError.duplicateID(kind: "tab", id: tab.id.rawValue)
            }
            // Global shells (spaceID == nil) belong to no space by design.
            if let spaceID = tab.spaceID {
                guard spaceIDs.contains(spaceID) else {
                    throw ShepherdStateValidationError.missingSpaceForTab(tabID: tab.id, spaceID: spaceID)
                }
            }
            tabByID[tab.id] = tab
            try validate(tab.layout, paneIDs: &paneIDs)
        }

        var agentIDs = Set<AgentID>()
        for agent in agents {
            guard agentIDs.insert(agent.id).inserted else {
                throw ShepherdStateValidationError.duplicateID(kind: "agent", id: agent.id.rawValue)
            }
            guard spaceIDs.contains(agent.spaceID) else {
                throw ShepherdStateValidationError.missingSpaceForAgent(agentID: agent.id, spaceID: agent.spaceID)
            }
            guard let tab = tabByID[agent.tabID] else {
                throw ShepherdStateValidationError.missingTabForAgent(agentID: agent.id, tabID: agent.tabID)
            }
            guard tab.spaceID == agent.spaceID else {
                throw ShepherdStateValidationError.agentTabSpaceMismatch(
                    agentID: agent.id,
                    agentSpaceID: agent.spaceID,
                    tabSpaceID: tab.spaceID ?? agent.spaceID
                )
            }
            if let paneID = agent.paneID {
                guard let pane = tab.layout.leaf(withID: paneID) else {
                    throw ShepherdStateValidationError.missingPaneForAgent(agentID: agent.id, paneID: paneID)
                }
                if let leafAgentID = pane.agentID, leafAgentID != agent.id {
                    throw ShepherdStateValidationError.inconsistentPaneOwnership(agentID: agent.id, paneID: paneID)
                }
            }
        }

        var automationIDs = Set<AutomationID>()
        for automation in automations {
            guard automationIDs.insert(automation.id).inserted else {
                throw ShepherdStateValidationError.duplicateID(kind: "automation", id: automation.id.rawValue)
            }
            // A dangling agent reference is stale, not fatal — the server
            // clears agentID at startup — but a *live* state must not point
            // at an agent that does not exist.
            if let agentID = automation.agentID, !agentIDs.contains(agentID) {
                throw ShepherdStateValidationError.missingAgentForAutomation(
                    automationID: automation.id, agentID: agentID
                )
            }
        }

        for tab in tabs {
            for pane in tab.layout.leaves {
                guard let agentID = pane.agentID else { continue }
                guard let agent = agents.first(where: { $0.id == agentID }) else {
                    throw ShepherdStateValidationError.leafAgentMissing(agentID: agentID, paneID: pane.id)
                }
                guard agent.tabID == tab.id else {
                    throw ShepherdStateValidationError.leafAgentInWrongTab(
                        agentID: agentID,
                        paneID: pane.id,
                        tabID: tab.id
                    )
                }
                if let agentPaneID = agent.paneID, agentPaneID != pane.id {
                    throw ShepherdStateValidationError.inconsistentPaneOwnership(agentID: agentID, paneID: pane.id)
                }
            }
        }
    }

    private func validate(_ node: PaneNode, paneIDs: inout Set<PaneID>) throws {
        switch node {
        case .leaf(let pane):
            guard paneIDs.insert(pane.id).inserted else {
                throw ShepherdStateValidationError.duplicateID(kind: "pane", id: pane.id.rawValue)
            }
        case .split(_, let ratio, let first, let second):
            guard ratio.isFinite, ratio > 0, ratio < 1 else {
                throw ShepherdStateValidationError.invalidSplitRatio(ratio)
            }
            try validate(first, paneIDs: &paneIDs)
            try validate(second, paneIDs: &paneIDs)
        }
    }
}
