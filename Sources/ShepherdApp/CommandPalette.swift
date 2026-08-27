import Foundation
import ShepherdCore
import ShepherdProtocol

/// One row in the command palette: a destination or an action.
struct PaletteItem: Identifiable {
    enum Kind {
        case agent(AgentID)
        case space(SpaceID)
        case shell(TabID)
        case child(agentID: AgentID, child: ChildRun)
        case remoteAgent(hostID: UUID, agentID: AgentID)
        case remoteSpace(hostID: UUID)
        case action(String)
    }

    /// Grouping header in the results list, in display order.
    enum Section: Int, CaseIterable {
        case commands, threads, shells, spaces, subagents, fuzzyMatches

        var title: String {
            switch self {
            case .commands: return "commands"
            case .threads: return "threads"
            case .shells: return "shells"
            case .spaces: return "spaces"
            case .subagents: return "subagents"
            case .fuzzyMatches: return "fuzzy matches"
            }
        }
    }

    let id: String
    let kind: Kind
    let section: Section
    /// Row text ("new agent in dotfiles/", "rate-limit").
    let title: String
    /// Dim trailing context ("agent · MONO", "⌘T").
    var subtitle: String?
    /// Keycap hint shown trailing, when the item has a chord.
    var shortcut: String?
    /// Set on thread rows whose *session content* matched the query (title
    /// may not contain it); shows a dim `…matched text…` snippet.
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

    /// Title-filtered items, grouped into sections; ranking orders rows
    /// within a section but sections keep their fixed order.
    static func filter(_ items: [PaletteItem], query: String) -> [PaletteItem] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return items }
        var ranked: [(item: PaletteItem, rank: Int)] = []
        for item in items {
            if let r = rank(query: query, in: item.title) {
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
