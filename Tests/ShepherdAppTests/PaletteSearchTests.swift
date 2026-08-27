import Testing
@testable import ShepherdApp

@Suite("Palette search")
struct PaletteSearchTests {
    private func item(_ title: String, section: PaletteItem.Section = .commands) -> PaletteItem {
        PaletteItem(id: title, kind: .action(title), section: section, title: title)
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
            item("rate-limit", section: .threads),           // threads, no "ar"
            item("dashboard workspace", section: .threads) // threads, scattered
        ]
        let filtered = PaletteSearch.filter(items, query: "ar")
        let sections = filtered.map(\.section)
        #expect(sections == sections.sorted { $0.rawValue < $1.rawValue })
    }
}
