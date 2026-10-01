import Testing
import ShepherdProtocol
@testable import ShepherdApp

/// Settings ▸ Pi ▸ Slash commands' rows: the commands pi listed grouped by where each comes from,
/// the switches on them, and the page's search.
@Suite("Slash commands page")
struct SlashCommandsPresentationTests {
    static let catalog = [
        NativeCommand(name: "session-name", description: "Set or clear session name", source: "extension"),
        NativeCommand(name: "release-notes", description: "Draft release notes", source: "prompt", arguments: "[tag]"),
        NativeCommand(name: "fix-tests", description: "Fix failing tests", source: "prompt"),
        NativeCommand(name: "skill:brave-search", description: "Search the web", source: "skill"),
        NativeCommand(name: "mystery", description: nil, source: nil),
    ]

    @Test func commandsGroupByWhereTheyComeFromEachByName() {
        let page = SlashCommandsPresentation(catalog: Self.catalog, hidden: [], query: "")
        #expect(page.groups.map(\.title) == ["Extensions", "Prompt templates", "Skills", "Other"])
        #expect(page.groups.map { $0.rows.map(\.name) } == [["session-name"], ["fix-tests", "release-notes"], ["skill:brave-search"], ["mystery"]])
        #expect(page.groups[1].rows.last?.arguments == "[tag]")
        #expect(page.groups.flatMap(\.rows).allSatisfy { $0.isOn && !$0.unlisted }, "every command starts on")
        #expect(page.summary == "5 commands")
    }

    @Test func aSwitchedOffCommandStaysListedAndCounts() {
        let page = SlashCommandsPresentation(catalog: Self.catalog, hidden: ["fix-tests"], query: "")
        let row = page.groups[1].rows[0]
        #expect(row.name == "fix-tests" && !row.isOn && !row.unlisted, "so it can be switched back on")
        #expect(page.groups.flatMap(\.rows).filter(\.isOn).count == 4)
        #expect(page.hidden == 1 && page.summary == "5 commands · 1 hidden")
    }

    /// Hidden before this launch, or its pi has stopped: no pi lists it, but it stays on the page.
    @Test func aHiddenCommandNoPiListsStillHasARowToSwitchBackOn() {
        let page = SlashCommandsPresentation(catalog: Self.catalog, hidden: ["gone"], query: "")
        let row = page.groups.last?.rows.first { $0.name == "gone" }
        #expect(row == SlashCommandRow(name: "gone", description: nil, arguments: nil, isOn: false, unlisted: true))
        #expect(page.total == 6 && page.hidden == 1)
    }

    @Test(arguments: [
        ("release", ["release-notes"]), ("/FIX", ["fix-tests"]), ("search the web", ["skill:brave-search"]),
        ("  session  ", ["session-name"]), ("tests", ["fix-tests"]), ("zzz", []),
    ])
    func theSearchMatchesNamesAndDescriptionsAndIgnoresASlash(query: String, names: [String]) {
        let page = SlashCommandsPresentation(catalog: Self.catalog, hidden: [], query: query)
        #expect(page.groups.flatMap(\.rows).map(\.name) == names)
        #expect(page.total == 5, "the summary counts every command, not the ones the search leaves")
        #expect(page.shown == names.count)
    }

    @Test func noCommandsYetSaysSo() {
        let page = SlashCommandsPresentation(catalog: [], hidden: [], query: "")
        #expect(page.groups.isEmpty && page.summary == "No commands yet")
    }

    @MainActor
    @Test func theModelDerivesOnceAndOnlyWritesWhatChanged() {
        let model = SlashCommandsModel(catalog: Self.catalog)
        #expect(model.presentation.total == 5)
        model.setHidden(["fix-tests"])
        #expect(model.presentation.hidden == 1)
        model.query = "tests"
        #expect(model.presentation.shown == 1)
        model.catalog = Self.catalog + [NativeCommand(name: "more-tests", description: nil, source: "prompt")]
        #expect(model.presentation.shown == 2, "a new command lists as soon as the server says so")
    }
}
