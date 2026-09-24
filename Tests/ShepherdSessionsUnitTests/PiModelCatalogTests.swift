import Testing
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
