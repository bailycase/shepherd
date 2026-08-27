import Testing
@testable import ShepherdSessions

@Suite("pi model catalog parsing")
struct PiModelCatalogTests {
    @Test func parsesAlignedTableIntoProviderSlashModel() {
        let output = """
        provider      model                            context  max-out  thinking  images
        anthropic     claude-opus-4-6                  1M       128K     yes       yes
        anthropic     claude-sonnet-4-5                1M       64K      yes       yes
        cpa           ~anthropic/claude-opus-latest    128K     16.4K    no        no
        """
        #expect(PiModelCatalog.parse(output) == [
            "anthropic/claude-opus-4-6",
            "anthropic/claude-sonnet-4-5",
            "cpa/~anthropic/claude-opus-latest",
        ])
    }

    @Test func toleratesBlankLinesShortRowsAndDuplicates() {
        let output = """
        provider model context
        openai gpt-5 400K

        justoneword
        openai gpt-5 400K
        """
        #expect(PiModelCatalog.parse(output) == ["openai/gpt-5"])
    }

    @Test func emptyOutputYieldsNoModels() {
        #expect(PiModelCatalog.parse("").isEmpty)
        #expect(PiModelCatalog.parse("provider model\n").isEmpty)
    }
}
