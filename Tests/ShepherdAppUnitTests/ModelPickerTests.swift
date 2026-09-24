import ShepherdSessions
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The model picker's catalog and list: derived once per catalog and query, never while drawing.
@Suite("Model picker")
struct ModelPickerTests {
    static let catalog = ModelCatalog([
        PiModelCatalog.Entry(id: "anthropic/claude-opus-4-5", context: "200K"),
        PiModelCatalog.Entry(id: "openai/gpt-5", context: "400K"),
        PiModelCatalog.Entry(id: "anthropic/claude-haiku-4-5", context: "200K", reasoning: false),
        PiModelCatalog.Entry(id: "openrouter/openai/gpt-5-mini", context: "128K"),
    ])

    private func sections(_ list: NWModelList) -> [String] {
        list.rows.compactMap { if case .header(let title) = $0.kind { title } else { nil } }
    }

    @Test func modelsGroupByProviderInCatalogOrder() {
        let list = Self.catalog.list(query: "", recent: [], current: nil)
        #expect(sections(list) == ["anthropic", "openai", "openrouter"])
        #expect(list.options.map(\.id) == ["anthropic/claude-opus-4-5", "anthropic/claude-haiku-4-5", "openai/gpt-5", "openrouter/openai/gpt-5-mini"])
        #expect(list.options.map(\.title) == ["claude-opus-4-5", "claude-haiku-4-5", "gpt-5", "openai/gpt-5-mini"])
        #expect(list.options.first?.note == "200K")
    }

    @Test func recentComesFirstAndLeavesItsProvidersSection() {
        let list = Self.catalog.list(query: "", recent: ["openai/gpt-5", "anthropic/claude-haiku-4-5"], current: "openai/gpt-5")
        #expect(sections(list) == ["Recent", "anthropic", "openrouter"])
        #expect(list.options.prefix(2).map(\.id) == ["openai/gpt-5", "anthropic/claude-haiku-4-5"])
        #expect(list.options.filter { $0.id == "openai/gpt-5" }.count == 1)
        #expect(list.options.filter(\.isCurrent).map(\.id) == ["openai/gpt-5"])
    }

    @Test(arguments: [("GPT", ["openai/gpt-5", "openrouter/openai/gpt-5-mini"]), ("  opus ", ["anthropic/claude-opus-4-5"]),
                      ("openai/", ["openai/gpt-5", "openrouter/openai/gpt-5-mini"]), ("nothing", [])])
    func aQueryMatchesAnywhereInTheIdIgnoringCase(query: String, ids: [String]) {
        #expect(Self.catalog.list(query: query, recent: [], current: nil).options.map(\.id) == ids)
    }

    /// A recent model the catalog lacks (another host's, or one pi dropped) shows only without a
    /// query; a query filters Recent like everything else.
    @Test func recentModelsFollowTheQuery() {
        let recent = ["gone/model-x", "openai/gpt-5"]
        #expect(Self.catalog.list(query: "", recent: recent, current: nil).options.prefix(2).map(\.id) == recent)
        #expect(Self.catalog.list(query: "gpt", recent: recent, current: nil).options.map(\.id) == ["openai/gpt-5", "openrouter/openai/gpt-5-mini"])
        #expect(ModelCatalog.empty.list(query: "", recent: recent, current: nil).options.map(\.title) == ["model-x", "gpt-5"])
    }

    @Test func theCatalogKnowsWhichModelsTakeAThinkingLevel() {
        #expect(Self.catalog.model("anthropic/claude-opus-4-5")?.reasoning == true)
        #expect(Self.catalog.model("anthropic/claude-haiku-4-5")?.reasoning == false)
        #expect(Self.catalog.model("unknown/model") == nil)
    }

    @MainActor @Test func aPickerOpenedBeforeTheCatalogShowsRecentWhileItLoads() {
        let state = ModelPickerState(catalog: nil, recent: ["openai/gpt-5"], current: nil)
        #expect(state.loading)
        #expect(state.list.options.map(\.id) == ["openai/gpt-5"])

        state.update(Self.catalog)

        #expect(!state.loading)
        #expect(state.list.options.count == 4)
    }

    @MainActor @Test func typingRederivesTheListFromTheCatalog() {
        let state = ModelPickerState(catalog: Self.catalog, recent: [], current: nil)
        state.query = "claude"
        #expect(state.list.options.map(\.id) == ["anthropic/claude-opus-4-5", "anthropic/claude-haiku-4-5"])
        state.query = ""
        #expect(state.list.options.count == 4)
    }
}
