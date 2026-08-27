import Foundation
import ShepherdCore

/// The slice of herdr's ~/.config/herdr/session.json we import. Herdr's file
/// is not a contract we control — every field beyond what's listed decodes
/// away, and missing optionals just skip that pane.
struct HerdrSession: Decodable {
    struct Workspace: Decodable {
        var custom_name: String?
        var identity_cwd: String
        var tabs: [Tab]
    }
    struct Tab: Decodable {
        var panes: [String: Pane]
    }
    struct Pane: Decodable {
        var cwd: String
        var agent_session: AgentSession?
    }
    struct AgentSession: Decodable {
        var agent: String
        var kind: String
        var value: String
    }
    var workspaces: [Workspace]
}

enum HerdrImport {
    struct Summary {
        var spacesAdded = 0
        var agentsAdded = 0
        var agentsSkipped = 0
    }

    /// Pi names session files `<timestamp>_<session id>.jsonl`.
    static func sessionID(fromPath path: String) -> String? {
        let name = (path as NSString).lastPathComponent
        guard name.hasSuffix(".jsonl"), let underscore = name.lastIndex(of: "_") else { return nil }
        let id = String(name[name.index(after: underscore)...].dropLast(".jsonl".count))
        return id.isEmpty ? nil : id
    }

    /// Merge herdr workspaces into `state`. Spaces dedup by path; agents dedup
    /// by pi session id. `agentName` resolves a display name for a session
    /// file path (injected so tests stay filesystem-free).
    static func merge(
        _ herdr: HerdrSession,
        into state: inout ShepherdState,
        agentName: (String) -> String?
    ) -> Summary {
        var summary = Summary()
        var nextOrder = (state.tabs.map(\.order).max() ?? -1) + 1
        let knownSessions = Set(state.agents.map(\.effectivePiSessionID))

        for workspace in herdr.workspaces {
            let path = (workspace.identity_cwd as NSString).expandingTildeInPath
            let space: Space
            if let existing = state.spaces.first(where: { $0.path == path }) {
                space = existing
            } else {
                let name = workspace.custom_name ?? (path as NSString).lastPathComponent
                space = Space(name: name.isEmpty ? path : name, path: path)
                state.spaces.append(space)
                // Every visible space carries a main shell workspace.
                state.tabs.append(
                    Tab(spaceID: space.id, order: nextOrder, layout: .leaf(LeafPane(cwd: path)))
                )
                nextOrder += 1
                summary.spacesAdded += 1
            }

            for tab in workspace.tabs {
                for pane in tab.panes.values {
                    guard let session = pane.agent_session,
                          session.agent == "pi", session.kind == "path",
                          let sessionID = sessionID(fromPath: session.value)
                    else { continue }
                    guard !knownSessions.contains(sessionID),
                          !state.agents.contains(where: { $0.effectivePiSessionID == sessionID })
                    else {
                        summary.agentsSkipped += 1
                        continue
                    }

                    let agentID = AgentID()
                    let leaf = LeafPane(cwd: pane.cwd, agentID: agentID)
                    let agentTab = Tab(spaceID: space.id, order: nextOrder, layout: .leaf(leaf))
                    nextOrder += 1
                    state.tabs.append(agentTab)
                    state.agents.append(
                        Agent(
                            id: agentID,
                            name: agentName(session.value) ?? "Imported from herdr",
                            spaceID: space.id,
                            tabID: agentTab.id,
                            paneID: leaf.id,
                            nameIsFinal: true,
                            piSessionID: sessionID
                        )
                    )
                    summary.agentsAdded += 1
                }
            }
        }
        return summary
    }

    /// First user message of a pi session jsonl, truncated for a sidebar row.
    static func firstUserMessage(inSessionFile url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  object["type"] as? String == "message",
                  let message = object["message"] as? [String: Any],
                  message["role"] as? String == "user"
            else { continue }
            let text: String?
            if let content = message["content"] as? [[String: Any]] {
                text = content.compactMap { $0["text"] as? String }.first
            } else {
                text = message["content"] as? String
            }
            guard var name = text?
                .replacingOccurrences(of: "\n", with: " ")
                .trimmingCharacters(in: .whitespaces), !name.isEmpty
            else { return nil }
            if name.count > 60 { name = String(name.prefix(60)) + "…" }
            return name
        }
        return nil
    }
}
