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

    /// Move the dragged agent to sit just above `target` (where the drop line is). Same space only:
    /// an agent runs in its space's checkout, so a cross-space drop is
    /// meaningless and rejected. Returns whether the drop was accepted.
    @discardableResult
    func dropAgent(payload: String, on target: AgentID) -> Bool {
        guard payload.hasPrefix("agent:") else { return false }
        let id = AgentID(rawValue: String(payload.dropFirst("agent:".count)))
        guard id != target else { return false }
        guard let dragged = state.agents.first(where: { $0.id == id }),
              state.agents.first(where: { $0.id == target })?.spaceID == dragged.spaceID,
              let agents = state.agents.moving(id, before: target) else { return false }
        state.agents = agents
        persistReorder()
        return true
    }

    /// Move the dragged space to sit just above `target` in declaration
    /// order. Nested projects (path containment is derived at render) follow
    /// their parent automatically.
    @discardableResult
    func dropSpace(payload: String, on target: SpaceID) -> Bool {
        guard payload.hasPrefix("space:") else { return false }
        let id = SpaceID(rawValue: String(payload.dropFirst("space:".count)))
        guard id != target else { return false }
        guard let spaces = state.spaces.moving(id, before: target) else { return false }
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
