import Foundation
import ShepherdCore

/// Space lifecycle from the sidebar's context menu.
@MainActor
extension ShepherdViewModel {
    /// Rename a space's sidebar label. Display-only: the checkout path (and
    /// everything derived from it — nesting, cwds, sessions) is untouched.
    func renameSpace(_ id: SpaceID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty,
              let index = state.spaces.firstIndex(where: { $0.id == id }),
              state.spaces[index].name != trimmed else { return }
        state.spaces[index].name = trimmed
        sessions.stateDidChange(state)
        let space = state.spaces[index]
        enqueuePersistence("rename space") { try await $0.updateSpace(space) }
    }

    /// Delete a space and everything in it (agents, layouts, sessions). Spaces nested under it by path are independent
    /// entities and survive — they re-root in the sidebar's derived forest.
    func deleteSpace(_ id: SpaceID) {
        guard let index = state.spaces.firstIndex(where: { $0.id == id }) else { return }
        let doomedAgents = Set(state.agents.filter { $0.spaceID == id }.map(\.id))
        let doomedTabs = state.tabs.filter { $0.spaceID == id }

        // Detach views before the server kills processes (same ordering as
        // deleteAgent: no exit callback may race a half-removed UI tree).
        for tab in doomedTabs {
            for leaf in tab.layout.leaves {
                sessions.detachPane(leaf.id)
            }
        }

        let doomedTabIDs = Set(doomedTabs.map(\.id))
        state.spaces.remove(at: index)
        state.agents.removeAll { doomedAgents.contains($0.id) }
        state.tabs.removeAll { doomedTabIDs.contains($0.id) }
        for agentID in doomedAgents {
            cancelReviews(for: agentID)
            childRuns.clear(agent: agentID)
            selectionHistory.removeAll { $0 == agentID }
            collapsedChildren.remove(agentID)
            subagentInspector.runByAgent.removeValue(forKey: agentID)
        }
        collapsedSpaces.remove(id)
        if selectedAgentID.map(doomedAgents.contains) == true {
            selectedAgentID = nil
        }
        if selectedSpaceID == id {
            selectedSpaceID = state.spaces.first?.id
            if selectedAgentID == nil {
                selectedAgentID = state.agents.first { $0.spaceID == selectedSpaceID }?.id
            }
        }
        sessions.stateDidChange(state)
        syncFocus()
        enqueuePersistence("space deletion") { try await $0.deleteSpace(id) }
    }
}
