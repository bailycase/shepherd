import Foundation
import AppKit
import UniformTypeIdentifiers
import ShepherdCore

/// Where a reorder drop lands relative to the row under the pointer.
enum SidebarDropEdge: Equatable {
    case above, below

    /// The half of a row `height` tall the pointer at `y` is over. `below` only where the row
    /// has nothing drawn beneath it, so the line always sits where the row will land.
    static func at(y: CGFloat, height: CGFloat, allowsBelow: Bool) -> SidebarDropEdge {
        allowsBelow && height > 0 && y > height / 2 ? .below : .above
    }
}

extension UTType {
    /// Sidebar reorder drags: a private, undeclared type registered with `.ownProcess`
    /// visibility, so a dragged row never lands as text in another app (or the composer).
    static let shepherdSidebarItem = UTType(tag: "shepherd-sidebar-item", tagClass: .filenameExtension, conformingTo: .data)
        ?? UTType(exportedAs: "app.shepherd.sidebar-item")
}

/// Sidebar drag-and-drop reordering. Array order in `ShepherdState` is the
/// sidebar order (spaces in declaration order, agents in declaration order
/// within their space), so reordering is an array move persisted wholesale
/// via putState.
extension ShepherdViewModel {
    /// Sidebar drag payloads: `"agent:<id>"` or `"space:<id>"`.
    static func dragPayload(agent id: AgentID) -> String { "agent:\(id.rawValue)" }
    static func dragPayload(space id: SpaceID) -> String { "space:\(id.rawValue)" }

    /// A row drag starts: remember what is dragged (drop targets validate against it while the
    /// drag hovers) and hand AppKit a provider only this process can read.
    func beginSidebarDrag(_ payload: String) -> NSItemProvider {
        sidebarDragPayload = payload
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.shepherdSidebarItem.identifier, visibility: .ownProcess) { completion in
            completion(Data(payload.utf8), nil)
            return nil
        }
        return provider
    }

    /// `agents` with `id` moved directly above or below `target`, or nil when the move is not
    /// allowed or changes nothing. Both must share a space (an agent runs in its space's
    /// checkout) and a group: worktree agents always list before standard ones, so a move
    /// across the groups could never land where the drop line was drawn. Pure.
    static func reorderedAgents(_ agents: [Agent], moving id: AgentID, beside target: AgentID,
                                edge: SidebarDropEdge) -> [Agent]? {
        guard id != target,
              let dragged = agents.first(where: { $0.id == id }),
              let anchor = agents.first(where: { $0.id == target }),
              dragged.spaceID == anchor.spaceID,
              (dragged.worktreeBranch != nil) == (anchor.worktreeBranch != nil),
              let result = moved(agents, id: id, beside: target, edge: edge) else { return nil }
        func group(_ agents: [Agent]) -> [AgentID] {
            agents.filter { $0.spaceID == anchor.spaceID && ($0.worktreeBranch != nil) == (anchor.worktreeBranch != nil) }.map(\.id)
        }
        return group(result) == group(agents) ? nil : result
    }

    /// `spaces` with `id` moved directly above or below `target`, or nil when not allowed or a
    /// no-op. Spaces nest by path containment (`forest`, the sidebar's), so only siblings
    /// reorder; anything else would land somewhere other than the drop line. Pure.
    static func reorderedSpaces(_ spaces: [Space], forest: [(space: Space, depth: Int)]? = nil, moving id: SpaceID,
                                beside target: SpaceID, edge: SidebarDropEdge) -> [Space]? {
        guard id != target else { return nil }
        let parents = forestParents(forest: forest ?? spaceForest(spaces))
        guard let draggedParent = parents[id], let targetParent = parents[target], draggedParent == targetParent,
              let result = moved(spaces, id: id, beside: target, edge: edge) else { return nil }
        func siblings(_ spaces: [Space]) -> [SpaceID] { spaces.filter { parents[$0.id] == .some(targetParent) }.map(\.id) }
        return siblings(result) == siblings(spaces) ? nil : result
    }

    /// Each space's parent in the containment forest (nil for a root).
    static func forestParents(_ spaces: [Space]) -> [SpaceID: SpaceID?] {
        forestParents(forest: spaceForest(spaces))
    }

    static func forestParents(forest: [(space: Space, depth: Int)]) -> [SpaceID: SpaceID?] {
        var parents: [SpaceID: SpaceID?] = [:]
        var stack: [(id: SpaceID, depth: Int)] = []
        for entry in forest {
            while let last = stack.last, last.depth >= entry.depth { stack.removeLast() }
            // updateValue: a nil (root) parent must be stored, not remove the key.
            parents.updateValue(stack.last?.id, forKey: entry.space.id)
            stack.append((entry.space.id, entry.depth))
        }
        return parents
    }

    private static func moved<Element: Identifiable>(_ items: [Element], id: Element.ID, beside target: Element.ID,
                                                     edge: SidebarDropEdge) -> [Element]? {
        var result = items
        guard let from = result.firstIndex(where: { $0.id == id }) else { return nil }
        let item = result.remove(at: from)
        guard let anchor = result.firstIndex(where: { $0.id == target }) else { return nil }
        result.insert(item, at: edge == .below ? anchor + 1 : anchor)
        return result
    }

    /// Move the dragged agent above (the default) or below `target`. Returns whether the drop
    /// is accepted; `validateOnly` answers without moving anything.
    @discardableResult
    func dropAgent(payload: String, on target: AgentID, edge: SidebarDropEdge = .above, validateOnly: Bool = false) -> Bool {
        guard payload.hasPrefix("agent:") else { return false }
        let id = AgentID(rawValue: String(payload.dropFirst("agent:".count)))
        guard let agents = Self.reorderedAgents(state.agents, moving: id, beside: target, edge: edge) else { return false }
        if !validateOnly {
            state.agents = agents
            persistReorder()
        }
        return true
    }

    /// Move the dragged space above (the default) or below `target` among its siblings; nested
    /// projects follow their parent automatically.
    @discardableResult
    func dropSpace(payload: String, on target: SpaceID, edge: SidebarDropEdge = .above, validateOnly: Bool = false) -> Bool {
        guard payload.hasPrefix("space:") else { return false }
        let id = SpaceID(rawValue: String(payload.dropFirst("space:".count)))
        // The sidebar's memoized forest: this runs on every pointer move while a drag hovers.
        guard let spaces = Self.reorderedSpaces(state.spaces, forest: sidebarForest, moving: id, beside: target, edge: edge) else { return false }
        if !validateOnly {
            state.spaces = spaces
            persistReorder()
        }
        return true
    }

    private func persistReorder() {
        sessions.stateDidChange(state)
        let snapshot = state
        enqueuePersistence("sidebar reorder") { try await $0.putState(snapshot) }
    }
}
