import Testing
@testable import ShepherdApp

@Suite("Palette search")
struct PaletteSearchTests {
    private func item(_ title: String, section: PaletteItem.Section = .commands) -> PaletteItem {
        PaletteItem(id: title, kind: .action(title), section: section, title: title)
    }

    @Test func idleListShowsCommandsThreadAndSubagentsButNotDestinations() {
        let items = [item("New agent"), item("Rename", section: .thisThread), item("worker", section: .subagents),
                     item("fix nightly", section: .agents), item("proj", section: .spaces)]
        #expect(PaletteSearch.filter(items, query: "").map(\.title) == ["New agent", "Rename", "worker"])
        // A query reaches every section; the Agents scope lists destinations even idle.
        #expect(PaletteSearch.filter(items, query: "n").map(\.title).contains("fix nightly"))
        #expect(PaletteSearch.filter(items, query: "", scope: .agents).map(\.title) == ["worker", "fix nightly", "proj"])
        #expect(PaletteSearch.filter(items, query: "", scope: .commands).map(\.title) == ["New agent", "Rename"])
    }

    @Test func contextMatchesRankBelowTitleMatches() {
        let items = [
            PaletteItem(id: "a", kind: .action("a"), section: .agents, title: "Fix login", subtitle: "shepherd · idle"),
            PaletteItem(id: "b", kind: .action("b"), section: .agents, title: "shepherd docs", subtitle: "notes"),
        ]
        #expect(PaletteSearch.filter(items, query: "shepherd").map(\.id) == ["b", "a"])
    }

    @Test func emptyQueryKeepsOrder() {
        let items = [item("b"), item("a")]
        #expect(PaletteSearch.filter(items, query: "  ").map(\.title) == ["b", "a"])
    }

    @Test func ranksPrefixOverWordOverSubstringOverScattered() {
        let items = [
            item("rename nvim-lsp"),        // "ne": word-prefix (nvim)? no — substring
            item("new agent in dotfiles/"), // "ne": prefix
            item("next blocked agent"),     // "ne": prefix
            item("broadcast prompt"),       // "ne": no match
        ]
        let filtered = PaletteSearch.filter(items, query: "ne").map(\.title)
        #expect(filtered.first == "new agent in dotfiles/")
        #expect(filtered.contains("rename nvim-lsp"))
        #expect(!filtered.contains("broadcast prompt"))
    }

    @Test func scatteredSubsequenceMatches() {
        #expect(PaletteSearch.rank(query: "nal", in: "new agent latch") != nil)
        #expect(PaletteSearch.rank(query: "xyz", in: "new agent") == nil)
    }

    @Test func matchingIsCaseInsensitive() {
        #expect(PaletteSearch.rank(query: "MONO", in: "mono") == 0)
    }

    @Test func sectionsStayGroupedAcrossRanks() {
        // A weak thread match must not interleave into commands even when a
        // command matches worse.
        let items = [
            item("clear done markers"),                      // commands, substring for "ar"
            item("rate-limit", section: .agents),           // threads, no "ar"
            item("dashboard workspace", section: .agents) // threads, scattered
        ]
        let filtered = PaletteSearch.filter(items, query: "ar")
        let sections = filtered.map(\.section)
        #expect(sections == sections.sorted { $0.rawValue < $1.rawValue })
    }
}
