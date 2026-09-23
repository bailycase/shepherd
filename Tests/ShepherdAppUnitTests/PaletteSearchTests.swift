import Testing
@testable import ShepherdApp

@Suite("Palette search")
struct PaletteSearchTests {
    private func item(_ title: String, _ section: PaletteItem.Section = .commands, subtitle: String? = nil) -> PaletteItem {
        PaletteItem(id: "\(section).\(title)", kind: .action(title), section: section, title: title, subtitle: subtitle)
    }

    /// One row per section, so scope and idle filtering are visible by title.
    private var everySection: [PaletteItem] {
        PaletteItem.Section.allCases.map { item("\($0)", $0) }
    }

    // MARK: Idle list and scopes

    /// The idle list is actions, not destinations — otherwise it is the whole sidebar again.
    @Test func theIdleListShowsCommandsThisThreadAndSubagentsOnly() {
        #expect(PaletteSearch.filter(everySection, query: "").map(\.section) == [.commands, .thisThread, .subagents])
    }

    @Test func whitespaceOnlyQueriesAreIdle() {
        #expect(PaletteSearch.filter(everySection, query: "  \t").map(\.section) == [.commands, .thisThread, .subagents])
    }

    @Test(arguments: [
        (PaletteItem.Scope.all, [PaletteItem.Section.commands, .thisThread, .subagents]),
        (.commands, [.commands, .thisThread]),
        (.agents, [.subagents, .agents, .spaces, .conversations]),
    ])
    func eachScopeListsItsSectionsWhenIdle(scope: PaletteItem.Scope, sections: [PaletteItem.Section]) {
        #expect(PaletteSearch.filter(everySection, query: "", scope: scope).map(\.section) == sections)
    }

    @Test func aQueryReachesDestinationsInTheAllScope() {
        let items = [item("New agent"), item("fix nightly", .agents), item("shepherd", .spaces)]
        #expect(PaletteSearch.filter(items, query: "ni").map(\.title) == ["fix nightly"])
        #expect(PaletteSearch.filter(items, query: "shep").map(\.title) == ["shepherd"])
    }

    @Test func theCommandsScopeNeverShowsDestinations() {
        let items = [item("new agent"), item("new-feature", .agents)]
        #expect(PaletteSearch.filter(items, query: "new", scope: .commands).map(\.title) == ["new agent"])
    }

    @Test func destinationSectionsAreExactlyAgentsSpacesAndConversations() {
        let destinations = PaletteItem.Section.allCases.filter(\.isDestination)
        #expect(destinations == [.agents, .spaces, .conversations])
    }

    // MARK: Ranking

    @Test(arguments: [
        ("new", "new agent", 0),        // prefix
        ("", "anything", 0),            // empty query matches everything
        ("ag", "new agent", 1),         // word prefix
        ("gen", "new agent", 2),        // substring
        ("nwa", "new agent", 3),        // scattered subsequence
        ("MONO", "mono", 0),            // case-insensitive
        ("xyz", "new agent", nil),
        ("agentx", "new agent", nil),
    ] as [(String, String, Int?)])
    func rankPrefersPrefixThenWordThenSubstringThenScattered(query: String, title: String, rank: Int?) {
        #expect(PaletteSearch.rank(query: query, in: title) == rank)
    }

    @Test func betterMatchesSortFirstWithinASection() {
        let items = [item("nice echo"), item("honest"), item("open new"), item("new agent")]
        let titles = PaletteSearch.filter(items, query: "ne").map(\.title)
        #expect(titles == ["new agent", "open new", "honest", "nice echo"])
    }

    @Test func nonMatchingRowsAreDropped() {
        #expect(PaletteSearch.filter([item("broadcast prompt")], query: "zz").isEmpty)
    }

    /// Subtitle context ("Shepherd · idle") can find a row, but a title hit always ranks above it.
    @Test func subtitleMatchesRankBelowTitleMatches() {
        let items = [
            item("Fix login", .agents, subtitle: "shepherd · idle"),
            item("shepherd docs", .agents, subtitle: "notes"),
        ]
        #expect(PaletteSearch.filter(items, query: "shepherd").map(\.title) == ["shepherd docs", "Fix login"])
    }

    /// Sections keep their fixed order even when a later section has a better match.
    @Test func sectionsStayGroupedRegardlessOfRank() {
        let items = [
            item("clear markers", .commands),     // substring "ar"
            item("archive", .agents),             // prefix "ar"
            item("dashboard", .thisThread),       // substring "ar"
        ]
        #expect(PaletteSearch.filter(items, query: "ar").map(\.section) == [.commands, .thisThread, .agents])
    }
}

/// The results list is one flat run of single views: a header before each section's first
/// row, and every row keeping its place in the results (keyboard selection is by index).
@Suite("Palette entries")
struct PaletteEntryTests {
    private func item(_ id: String, _ section: PaletteItem.Section) -> PaletteItem {
        PaletteItem(id: id, kind: .action(id), section: section, title: id)
    }

    @Test func eachSectionGetsOneHeaderBeforeItsFirstRow() {
        let entries = PaletteEntry.entries([item("a", .commands), item("b", .commands), item("c", .agents)])
        #expect(entries.map(\.id) == ["section.\(PaletteItem.Section.commands.rawValue)", "a", "b",
                                      "section.\(PaletteItem.Section.agents.rawValue)", "c"])
    }

    @Test func rowsKeepTheirIndexInTheResults() {
        let entries = PaletteEntry.entries([item("a", .commands), item("b", .agents)])
        let indices = entries.compactMap { entry -> Int? in
            if case .row(let index, _, _) = entry { return index }
            return nil
        }
        #expect(indices == [0, 1])
    }

    /// Transcript matches follow the filtered rows except in the Commands scope, and the list
    /// is built from both at once.
    @Test(arguments: [(PaletteItem.Scope.all, ["new agent", "found"]), (.commands, ["new agent"])])
    func resultsAppendTranscriptMatchesOutsideTheCommandsScope(scope: PaletteItem.Scope, titles: [String]) {
        var found = item("found", .conversations)
        found.contentSnippet = "…the login redirect…"
        let results = PaletteResults(items: [item("new agent", .commands), item("fix", .agents)], query: "new", scope: scope,
                                     contentRows: [found])
        #expect(results.rows.map(\.title) == titles)
        #expect(results.entries.count == titles.count + Set(results.rows.map(\.section)).count)
    }

    /// The highlight is found once, when the list is built: a row carries its snippet split
    /// around the query's first match, case-insensitively.
    @Test(arguments: [
        ("REDIRECT", "…fix the ", "redirect", " loop…"),
        (" redirect ", "…fix the ", "redirect", " loop…"),
        ("absent", "…fix the redirect loop…", "", ""),
        ("", "…fix the redirect loop…", "", ""),
    ])
    func aSnippetIsSplitAroundTheQuery(query: String, before: String, match: String, after: String) throws {
        var found = item("found", .conversations)
        found.contentSnippet = "…fix the redirect loop…"
        let entry = try #require(PaletteEntry.entries([found], highlighting: query).last)
        guard case .row(_, _, let snippet) = entry else { Issue.record("expected a row"); return }
        #expect(snippet == PaletteSnippet("…fix the redirect loop…", term: query))
        #expect(snippet?.before == before && snippet?.match == match && snippet?.after == after)
    }

    @Test func aRowWithoutATranscriptMatchHasNoSnippet() {
        guard case .row(_, _, let snippet)? = PaletteEntry.entries([item("a", .commands)], highlighting: "a").last else {
            Issue.record("expected a row")
            return
        }
        #expect(snippet == nil)
    }
}
