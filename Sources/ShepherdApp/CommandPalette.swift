import Foundation
import ShepherdCore
import ShepherdProtocol

/// One row in the command palette: a destination or an action.
struct PaletteItem: Identifiable {
    enum Kind {
        case agent(AgentID)
        case space(SpaceID)
        case child(agentID: AgentID, child: ChildRun)
        case remoteAgent(hostID: UUID, agentID: AgentID)
        case remoteSpace(hostID: UUID)
        case remoteChild(hostID: UUID, agentID: AgentID, child: ChildRun)
        case remoteOperation(hostID: UUID, agentID: AgentID)
        case action(String)
    }

    /// Grouping header in the results list, in display order (spec §12: Commands, This thread,
    /// Subagents, and Agents when searching).
    enum Section: Int, CaseIterable {
        case commands, thisThread, subagents, agents, spaces, conversations

        var title: String {
            switch self {
            case .commands: "Commands"
            case .thisThread: "This thread"
            case .subagents: "Subagents"
            case .agents: "Agents"
            case .spaces: "Spaces"
            case .conversations: "Found in conversations"
            }
        }

        /// Destinations stay out of the idle list (it would be the whole sidebar again); they
        /// appear once there is a query or the Agents scope is chosen.
        var isDestination: Bool {
            switch self {
            case .agents, .spaces, .conversations: true
            case .commands, .thisThread, .subagents: false
            }
        }
    }

    /// The scope pills beside the search field.
    enum Scope: CaseIterable {
        case all, commands, agents

        var title: String {
            switch self {
            case .all: "All"
            case .commands: "Commands"
            case .agents: "Agents"
            }
        }

        func includes(_ section: Section) -> Bool {
            switch self {
            case .all: true
            case .commands: section == .commands || section == .thisThread
            case .agents: section != .commands && section != .thisThread
            }
        }
    }

    let id: String
    let kind: Kind
    let section: Section
    /// Row label ("New agent", "Rename", an agent's name).
    let title: String
    /// Dim trailing context ("in Shepherd/", "working tree", "proj · running").
    var subtitle: String?
    /// The real chord, as the keybinding store displays it ("⇧⌘N").
    var shortcut: String?
    /// SF Symbol for the 15pt row icon.
    var icon: String = "circle"
    /// Set on agent rows whose *session content* matched the query (the title may not
    /// contain it); shows a dim `…matched text…` snippet.
    var contentSnippet: String?
}

/// Pure matching/ordering so palette behavior is testable without views.
enum PaletteSearch {
    /// Case-insensitive subsequence match ("nal" hits "new agent in ../").
    /// Returns a rank (lower is better) or nil for no match: word-prefix
    /// beats substring beats scattered subsequence.
    static func rank(query: String, in title: String) -> Int? {
        let q = query.lowercased()
        let t = title.lowercased()
        if q.isEmpty { return 0 }
        if t.hasPrefix(q) { return 0 }
        if t.split(separator: " ").contains(where: { $0.hasPrefix(q) }) { return 1 }
        if t.contains(q) { return 2 }
        // Scattered subsequence.
        var index = t.startIndex
        for ch in q {
            guard let found = t[index...].firstIndex(of: ch) else { return nil }
            index = t.index(after: found)
        }
        return 3
    }

    /// The rows for `scope` and `query`, grouped into sections; ranking orders rows within a
    /// section but sections keep their fixed order. An empty query in the All scope lists
    /// only commands, this thread, and subagents.
    static func filter(_ items: [PaletteItem], query: String, scope: PaletteItem.Scope = .all) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let scoped = items.filter { scope.includes($0.section) }
        guard !trimmed.isEmpty else {
            return scope == .all ? scoped.filter { !$0.section.isDestination } : scoped
        }
        var ranked: [(item: PaletteItem, rank: Int)] = []
        for item in scoped {
            let text = [item.title, item.subtitle].compactMap { $0 }.joined(separator: " ")
            if let r = rank(query: trimmed, in: item.title) ?? rank(query: trimmed, in: text).map({ $0 + 4 }) {
                ranked.append((item, r))
            }
        }
        ranked.sort { a, b in
            if a.item.section.rawValue != b.item.section.rawValue {
                return a.item.section.rawValue < b.item.section.rawValue
            }
            return a.rank < b.rank
        }
        return ranked.map(\.item)
    }
}
