import SwiftUI
import ShepherdUI

// Settings search (MobileSettings): over page and row titles, like the Mac's. A hit opens its
// page; row hits can't deep-link to the row, so they open the page too.

enum SettingsSearch {
    /// The row titles each page draws, as it draws them.
    static let rows: [SettingsPage: [String]] = [
        .general: ["Questions and approvals", "Failures", "Finished work",
                   "Only when I’m away from my Mac", "Live Activities",
                   "Muted threads", "Send from"],
        .appearance: ["System", "Light", "Dark"],
        .models: ["Sign in", "Subscriptions", "Switch accounts at a limit", "Use",
                  "API keys", "Add an API key", "Custom providers",
                  "Model", "Thinking", "Speed",
                  "Text generation model", "Image reading model"],
        .agents: ["When a turn ends, send the queue", "Threads can start threads", "Where they work",
                  "Compact at", "Concurrency", "Subagent context", "Subagent thinking",
                  "Profiles", "New profile", "Restore defaults"],
        .instructions: ["Shepherd’s AGENTS.md", "System prompt", "History", "Restore", "Save", "Files"],
        .skills: ["Installed", "Update", "Updating", "Add from repo", "Search skills.sh",
                  "View on skills.sh", "Use it", "Show in the / menu", "Update automatically",
                  "Repository", "SKILL.md", "Select all new", "Install"],
        .tools: ["MCP servers", "Add server", "Also use a repo’s .mcp.json",
                 "Commands in the / menu", "Built in", "Use them",
                 "Extensions", "Add from Git"],
        .hooks: ["Add hook", "Sources", "Files a Mac reads hooks from", "When", "Command",
                 "Time limit", "Matches", "Runs", "Output", "Shown in the thread",
                 "While it runs", "Show", "Status while it runs", "Delete hook",
                 "Read Claude Code hooks", "Read Codex hooks"],
        .spaces: ["Spaces", "Resources", "Skills, extensions and MCP servers",
                  "Instructions", "Extensions", "MCP servers", "Organize spaces"],
        .git: ["Base branch", "Fetch before creating", "Draft commit messages",
               "Deleting a worktree agent", "Close threads when their pull request merges", "Worktree"],
        .apps: ["Run", "Stop", "Restart", "Output", "Command", "Folder", "Quick action", "Agents can start it"],
        .fleet: ["Macs", "Add a Mac", "Phones and tablets", "Add a device",
                 "Threads can send work to other Macs", "Recent work", "Room"],
        .advanced: ["Share diagnostics"],
        .experiments: ["Suggested instructions", "Goals", "Projects", "Design tool",
                       "Computer use", "Automations", "Waiting for you", "Learn from",
                       "Open Instructions"],
    ]

    /// The pages with a hit, each with its matching rows (empty when only the page's title did).
    static func hits(for query: String, showsHooks: Bool) -> [(page: SettingsPage, rows: [String])] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return SettingsPage.allCases.compactMap { page in
            guard page != .hooks || showsHooks else { return nil }
            let rows = rows[page, default: []].filter { $0.localizedCaseInsensitiveContains(query) }
            guard page.title.localizedCaseInsensitiveContains(query) || !rows.isEmpty else { return nil }
            return (page, rows)
        }
    }
}

/// The matching pages with their matching rows, each opening its page (beside the iPad's list, filling the
/// open one); or that nothing matched.
struct SettingsSearchResults: View {
    let hits: [(page: SettingsPage, rows: [String])]
    let pad: Bool
    let selection: SettingsSelection
    let open: (SettingsPage, String?) -> Void

    var body: some View {
        if hits.isEmpty {
            SettingsFootnote("No settings match.")
        } else {
            ForEach(hits, id: \.page) { page, rows in
                SettingsSection(page.title) {
                    SettingsCard {
                        if rows.isEmpty {
                            Button { open(page, nil) } label: {
                                SettingsRow(page.title, chevron: !pad, selected: pad && selection.isSelected(page))
                            }
                            .buttonStyle(.shRow(radius: 0))
                        } else {
                            ForEach(rows, id: \.self) { row in
                                Button { open(page, row) } label: {
                                    SettingsRow(row, subtitle: rows.count > 1 ? page.title : nil, chevron: !pad,
                                                selected: pad && selection.isSelected(page, row: row))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                        }
                    }
                }
            }
        }
    }
}
