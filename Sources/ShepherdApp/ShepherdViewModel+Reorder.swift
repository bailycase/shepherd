import Foundation
import ShepherdCore

/// Sidebar drag-and-drop reordering. Array order in `ShepherdState` is the
/// sidebar order (spaces in declaration order, agents in declaration order
/// within their space), so reordering is an array move persisted wholesale
/// via putState.
extension ShepherdViewModel {
    /// Sidebar drag payloads: `"agent:<id>"` or `"space:<id>"`.
    static func dragPayload(agent id: AgentID) -> String { "agent:\(id.rawValue)" }
    static func dragPayload(space id: SpaceID) -> String { "space:\(id.rawValue)" }

    /// Move the dragged agent to sit at `target`'s position. Same space only:
    /// an agent runs in its space's checkout, so a cross-space drop is
    /// meaningless and rejected. Returns whether the drop was accepted.
    @discardableResult
    func dropAgent(payload: String, on target: AgentID) -> Bool {
        guard payload.hasPrefix("agent:") else { return false }
        let id = AgentID(rawValue: String(payload.dropFirst("agent:".count)))
        guard id != target else { return false }
        var agents = state.agents
        guard let from = agents.firstIndex(where: { $0.id == id }),
              let to = agents.firstIndex(where: { $0.id == target }),
              agents[from].spaceID == agents[to].spaceID else { return false }
        agents.insert(agents.remove(at: from), at: to)
        state.agents = agents
        persistReorder()
        return true
    }

    /// Move the dragged space to sit at `target`'s position in declaration
    /// order. Nested projects (path containment is derived at render) follow
    /// their parent automatically.
    @discardableResult
    func dropSpace(payload: String, on target: SpaceID) -> Bool {
        guard payload.hasPrefix("space:") else { return false }
        let id = SpaceID(rawValue: String(payload.dropFirst("space:".count)))
        guard id != target else { return false }
        var spaces = state.spaces
        guard let from = spaces.firstIndex(where: { $0.id == id }),
              let to = spaces.firstIndex(where: { $0.id == target }) else { return false }
        spaces.insert(spaces.remove(at: from), at: to)
        state.spaces = spaces
        persistReorder()
        return true
    }

    private func persistReorder() {
        sessions.stateDidChange(state)
        let snapshot = state
        enqueuePersistence("sidebar reorder") { try await $0.putState(snapshot) }
    }
}
