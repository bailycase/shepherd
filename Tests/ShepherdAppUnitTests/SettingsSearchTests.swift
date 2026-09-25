import Testing
@testable import ShepherdApp

/// The Settings search field lists matching rows under their section and jumps to the first
/// section with a match.
@Suite("Settings search")
struct SettingsSearchTests {
    @Test func theNavListsEveryPageInDesignOrder() {
        #expect(SettingsSection.allCases.map(\.title) == [
            "Appearance", "Terminal", "Agents", "Worktrees", "Pi", "Remote", "Keyboard", "Advanced",
        ])
    }

    @Test func everyPageListsItsRows() {
        for section in SettingsSection.allCases {
            #expect(!section.items.isEmpty, "\(section.title) has no searchable rows")
        }
    }

    @Test(arguments: [
        // Row titles, case-insensitively.
        ("font", SettingsSection.terminal, ["Font family", "Font size"]),
        ("SHELL", .terminal, ["Shell"]),
        ("default model", .agents, ["Default model"]),
        // Keywords people search for that aren't row titles.
        ("dark", .appearance, ["Mode"]),
        ("zoom", .appearance, ["Text size"]),
        ("tailscale", .remote, ["Hosts"]),
        ("port", .remote, ["Listener"]),
        ("hotkey", .keyboard, ["Shortcuts"]),
        ("nightly", .advanced, ["Update channel"]),
        ("reasoning", .agents, ["Default thinking level"]),
        ("github", .worktrees, ["Merge PR automatically"]),
        ("steer", .agents, ["Return while the agent is working"]),
        ("queue", .agents, ["Return while the agent is working", "When a turn ends, send the queue"]),
        ("all at once", .agents, ["When a turn ends, send the queue"]),
    ])
    func rowsMatchByTitleOrKeyword(query: String, section: SettingsSection, rows: [String]) {
        #expect(section.matches(for: query) == rows)
    }

    /// Naming the page lists everything on it.
    @Test(arguments: SettingsSection.allCases)
    func matchingASectionTitleListsAllItsRows(section: SettingsSection) {
        #expect(section.matches(for: "  \(section.title.lowercased()) ") == section.items)
    }

    @Test func aKeywordFindsOnlyTheSectionsThatOwnIt() {
        let hits = SettingsSection.allCases.filter { !$0.matches(for: "dark").isEmpty }
        #expect(hits == [.appearance])
    }

    @Test func piThemeSyncIsNotASetting() {
        #expect(SettingsSection.pi.matches(for: "theme").isEmpty)
        #expect(!SettingsSection.pi.items.contains("Sync pi theme"))
    }

    @Test(arguments: ["", "   ", "zzzz-no-such-setting"])
    func emptyOrUnmatchedQueriesListNothing(query: String) {
        for section in SettingsSection.allCases {
            #expect(section.matches(for: query).isEmpty)
        }
    }
}
