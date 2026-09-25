import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// `pi --list-models` prints an aligned table; its format is not a contract, so parsing is lenient.
@Suite("pi model catalog parsing")
struct PiModelCatalogTests {
    private let table = """
    provider      model                            context  max-out  thinking  images
    anthropic     claude-opus-4-6                  1M       128K     yes       yes
    anthropic     claude-sonnet-4-5                1M       64K      yes       yes
    cpa           ~anthropic/claude-opus-latest    128K     16.4K    no        no
    """

    @Test func rowsBecomeProviderSlashModelInCatalogOrder() {
        #expect(PiModelCatalog.parse(table) == [
            "anthropic/claude-opus-4-6",
            "anthropic/claude-sonnet-4-5",
            "cpa/~anthropic/claude-opus-latest",
        ])
    }

    @Test func entriesReadContextAndThinkingByHeaderPosition() {
        let entries = PiModelCatalog.parseEntries(table)
        #expect(entries.first == .init(id: "anthropic/claude-opus-4-6", context: "1M", reasoning: true))
        #expect(entries.last == .init(id: "cpa/~anthropic/claude-opus-latest", context: "128K", reasoning: false))
        #expect(entries.last?.provider == "cpa")
    }

    @Test func withoutAHeaderColumnsAreUnknownAndReasoningIsAssumed() {
        #expect(PiModelCatalog.parseEntries("openai gpt-5 400K") == [.init(id: "openai/gpt-5")])
    }

    @Test func blankShortAndDuplicateRowsAreSkipped() {
        let output = """
        provider model context
        openai gpt-5 400K

        justoneword
        openai gpt-5 400K
        """
        #expect(PiModelCatalog.parse(output) == ["openai/gpt-5"])
    }

    @Test(arguments: ["", "provider model\n"])
    func noRowsMeansNoModels(output: String) {
        #expect(PiModelCatalog.parse(output).isEmpty)
    }
}

/// A catalog travels to a remote client as a `ModelListing` and comes back as picker rows with
/// the same thinking: a model a host (or an older one) says nothing about reasons.
@Suite("Model listings")
struct ModelListingTests {
    @Test func aCatalogKeepsWhichModelsReasonThroughAListing() {
        let entries = [PiModelCatalog.Entry(id: "qa/plain", reasoning: false), PiModelCatalog.Entry(id: "qa/deep")]
        let listing = ModelListing(entries: entries, defaultModel: "qa/plain")
        #expect(listing == ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"]))
        #expect(listing.entries == entries)
    }

    /// models.json's `thinkingLevelMap`s name a reasoning model's levels in the listing (xhigh and
    /// max where mapped, a level mapped to null left out); a model without reasoning gets none.
    @Test func configuredLevelMapsNameAModelsLevels() {
        let entries = [PiModelCatalog.Entry(id: "qa/plain", reasoning: false), PiModelCatalog.Entry(id: "qa/deep"),
                       PiModelCatalog.Entry(id: "qa/max")]
        let maps: [String: [String: String?]] = ["qa/max": ["xhigh": "xhigh", "max": "max", "minimal": nil], "qa/plain": ["max": "max"]]
        let listing = ModelListing(entries: entries, defaultModel: nil, levelMaps: maps)
        #expect(listing.thinkingLevels == ["qa/max": ["off", "low", "medium", "high", "xhigh", "max"]])
    }

    @Test func anOlderHostsListingReadsAsModelsThatReason() {
        #expect(ModelListing(models: ["a/b"], defaultModel: "a/b").entries == [PiModelCatalog.Entry(id: "a/b", reasoning: true)])
    }
}
