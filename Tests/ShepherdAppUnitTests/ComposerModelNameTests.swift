import Testing
@testable import ShepherdApp

@Suite("Composer model names")
struct ComposerModelNameTests {
    @Test(arguments: [
        ("anthropic/claude-sonnet-4-20250514", "claude-sonnet-4"),
        ("claude-opus-4-5-20251101", "claude-opus-4-5"),
        ("openai/gpt-6-astra", "gpt-6-astra"),
        ("cpa/deepseek-v4-flash", "deepseek-v4-flash"),
        ("gemini-3.1-pro-2025", "gemini-3.1-pro-2025"),
        ("model-12345678x", "model-12345678x"),
        ("-20250514", "-20250514"),
    ])
    func theNarrowComposerDropsOnlyATrailingReleaseDate(model: String, name: String) {
        #expect(nativeModelCompactName(model) == name)
    }
}
