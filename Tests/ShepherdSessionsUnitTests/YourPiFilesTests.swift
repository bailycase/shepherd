import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// The user's own pi's files as Shepherd reads them to copy them: plain JSON, one parser each.
/// Every credential here is a fake.
@Suite("Your pi's files")
struct YourPiFilesTests {
    // MARK: auth.json

    @Test(arguments: [
        ("sk-FAKE-literal-0001", PiKeySource.literal),
        ("$OPENAI_API_KEY", .environment(["OPENAI_API_KEY"])),
        ("${GEMINI_API_KEY}", .environment(["GEMINI_API_KEY"])),
        ("prefix-${A_1}-$B_2", .environment(["A_1", "B_2"])),
        ("!op read op://vault/fake", .command),
        ("!", .command),
        ("costs $$5 and $!", .literal),
        ("$1abc", .literal),
        ("${1BAD}", .literal),
        ("${UNCLOSED", .literal),
        ("", .literal),
    ])
    func anAPIKeysSourceFollowsPisRules(key: String, source: PiKeySource) {
        #expect(YourPiFiles.keySource(key) == source)
    }

    @Test func authJSONListsEachProvidersKindAndNeverItsValue() throws {
        let data = Data(#"""
        {
          "openai": {"type": "api_key", "key": "sk-FAKE-literal-0001"},
          "google": {"type": "api_key", "key": "$GEMINI_API_KEY"},
          "groq": {"type": "api_key", "key": "!op read op://fake/groq"},
          "anthropic": {"type": "oauth", "refresh": "FAKE-REFRESH", "access": "FAKE-ACCESS", "expires": 1790000000000},
          "future": {"type": "passkey"},
          "broken": "not an object"
        }
        """#.utf8)
        let logins = try YourPiFiles.logins(data)
        #expect(logins == [
            PiLogin(provider: "anthropic", kind: .subscription),
            PiLogin(provider: "future", kind: .other("passkey")),
            PiLogin(provider: "google", kind: .apiKey(.environment(["GEMINI_API_KEY"]))),
            PiLogin(provider: "groq", kind: .apiKey(.command)),
            PiLogin(provider: "openai", kind: .apiKey(.literal)),
        ])
        #expect(!String(describing: logins).contains("FAKE"))
    }

    @Test(arguments: ["", "  \n", "\u{FEFF}{}", "// comment\n{}"])
    func anEmptyAuthJSONHasNoLogins(text: String) throws {
        #expect(try YourPiFiles.logins(Data(text.utf8)).isEmpty)
    }

    @Test(arguments: ["[1, 2]", "{", "\"text\"", "{\"a\": }"])
    func anAuthJSONThatIsNotAnObjectIsRefusedWithoutQuotingIt(text: String) {
        #expect {
            _ = try YourPiFiles.logins(Data(text.utf8))
        } throws: { error in
            String(describing: error) == "auth.json isn't a valid JSON object"
        }
    }

    // MARK: Comments

    @Test(arguments: [
        ("{\"a\": 1} // trailing", "{\"a\": 1} "),
        ("{/* x */\"a\": \"// not a comment\"}", "{\"a\": \"// not a comment\"}"),
        ("{\"a\": \"\\\"/*\"}", "{\"a\": \"\\\"/*\"}"),
        ("/* one\n two */{}", "{}"),
    ])
    func commentsGoOutsideStringsOnly(text: String, stripped: String) {
        #expect(YourPiFiles.strippingComments(text) == stripped)
    }

    // MARK: models.json

    @Test(arguments: [
        (#"{"providers": {"zeta": {}, "local-llm": {"apiKey": "FAKE"}}}"#, ["local-llm", "zeta"]),
        (#"// custom providers\n{"providers": {}}"#, []),
        (#"{}"#, []),
    ])
    func modelsJSONNamesItsCustomProviders(text: String, providers: [String]) throws {
        #expect(try YourPiFiles.customProviders(Data(text.utf8)) == providers)
    }

    @Test(arguments: [#"{"providers": []}"#, "not json", "[]"])
    func anInvalidModelsJSONIsRefused(text: String) {
        #expect(throws: YourPiFileError.self) { _ = try YourPiFiles.customProviders(Data(text.utf8)) }
    }

    // MARK: settings.json

    @Test(arguments: [
        (["defaultProvider": "anthropic", "defaultModel": "claude-opus-4-5"], "anthropic/claude-opus-4-5"),
        (["defaultProvider": "anthropic"], nil),
        (["defaultModel": "claude-opus-4-5"], nil),
        (["defaultProvider": " ", "defaultModel": "x"], nil),
        ([:], nil),
    ] as [([String: String], String?)])
    func theDefaultModelIsProviderSlashModelWhenBothAreSet(settings: [String: String], model: String?) {
        #expect(YourPiFiles.defaultModel(settings) == model)
    }

    /// Skills and prompts are read in place: their own folder when it exists, then their settings'
    /// entries made absolute, filters kept.
    @Test(arguments: [
        (["AGENTS.md", "CLAUDE.md"], "AGENTS.md"),
        (["AGENTS.override.md", "AGENTS.md"], "AGENTS.override.md"),
        (["CLAUDE.md"], "CLAUDE.md"),
        ([], nil),
    ] as [([String], String?)])
    func theWinningContextFileIsPisFirst(files: [String], winner: String?) throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in files { try Data("# \(name)\n".utf8).write(to: dir.appendingPathComponent(name)) }
        #expect(YourPiFiles.contextFile(in: dir)?.lastPathComponent == winner)
    }

    @Test func aFolderNamedLikeAContextFileDoesNotWin() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("AGENTS.override.md"), withIntermediateDirectories: false)
        try Data("# rules\n".utf8).write(to: dir.appendingPathComponent("CLAUDE.md"))
        #expect(YourPiFiles.contextFile(in: dir)?.lastPathComponent == "CLAUDE.md")
    }

    // MARK: trust.json

    /// The home folder is never trusted as a project: a `true` for it, or for a folder above it,
    /// isn't copied; every other decision is, and null means none.
    @Test func trustNeverCopiesTheHomeFolderAsAProject() throws {
        let data = Data(#"{"/u": true, "/": true, "/u/work/a": true, "/u/work/b": false, "/u/work/c": null, "/other": false}"#.utf8)
        let (decisions, dropped) = try YourPiFiles.trust(data, home: "/u")
        #expect(decisions == ["/u/work/a": true, "/u/work/b": false, "/other": false])
        #expect(dropped == ["/", "/u"])
    }

    @Test(arguments: [#"{"/a": "yes"}"#, "[true]", "{"])
    func anInvalidTrustJSONIsRefused(text: String) {
        #expect(throws: YourPiFileError.self) { _ = try YourPiFiles.trust(Data(text.utf8), home: "/u") }
    }

    // MARK: Extensions

    @Test func environmentKeysNameTheirProvidersByNameOnly() {
        #expect(PiProviders.providers(withKeys: ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "UNRELATED"])
            == ["openai": ["OPENAI_API_KEY"], "anthropic": ["ANTHROPIC_API_KEY"]])
        #expect(PiProviders.name("openai-codex") == "OpenAI Codex")
        #expect(PiProviders.name("my-proxy") == "my-proxy")
        #expect(PiProviders.allEnvironmentKeys.allSatisfy { $0.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } })
    }

    /// What the welcome step still asks to sign in to: a provider a model names that nothing in
    /// Shepherd's pi covers. A login, a key in the environment or a custom provider covers it;
    /// cloud-credential and unknown providers are never asked for.
    @Test(arguments: [
        (["anthropic/claude-x"], [String]()),
        (["openai/gpt-x"], []),
        (["xai/grok-x"], []),
        (["local-llm/qwen"], []),
        (["google/gemini-x", "groq/llama", "google/other"], ["google", "groq"]),
        (["amazon-bedrock/claude", "google-vertex/gemini"], []),
        (["my-extension-provider/model", "no-slash", "/leading"], []),
    ])
    func missingSignInsAreTheModelsProvidersNothingCovers(models: [String], missing: [String]) {
        var survey = YourPiSurvey(folder: "/u/.pi/agent")
        survey.logins = [
            .init(provider: "anthropic", shepherd: .subscription, yours: .subscription),
            .init(provider: "openai", shepherd: .apiKey(.command)),
            .init(provider: "xai", environment: ["XAI_API_KEY"]),
            .init(provider: "google", yours: .apiKey(.literal)),
        ]
        survey.shepherdCustomProviders = ["local-llm"]
        #expect(survey.missingSignIns(for: models) == missing)
    }
}
