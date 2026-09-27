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
        ("skills", ["/u/.pi/agent/skills"], ["~/extra", "vendor/skills", "/abs/x", "+more/y", "-/abs/skip", "!**/draft*", " ", "~"],
         ["/u/.pi/agent/skills", "/u/extra", "/u/.pi/agent/vendor/skills", "/abs/x", "+/u/.pi/agent/more/y", "-/abs/skip", "!**/draft*", "/u"]),
        ("prompts", [], ["../shared/prompts", "/abs/x", "/abs/x"], ["/u/.pi/shared/prompts", "/abs/x"]),
        ("skills", [], [], []),
    ])
    func resourcesAreListedAsAbsolutePaths(key: String, existing: [String], entries: [String], expected: [String]) {
        let listed = YourPiFiles.resourceEntries(key, settings: [key: entries], agentDirectory: URL(fileURLWithPath: "/u/.pi/agent"),
                                                 home: "/u", exists: { existing.contains($0) })
        #expect(listed == expected)
    }

    // MARK: Instructions

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

    @Test func theirExtensionsAreListedFromTheFolderAndSettingsNeverLoaded() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let files = FileManager.default
        for folder in ["extensions/tooling", "extensions/empty", "npm/node_modules/@acme/pi-tools", "npm/node_modules/solo",
                       "git/github.com/me/pi-ext"] {
            try files.createDirectory(at: dir.appendingPathComponent(folder), withIntermediateDirectories: true)
        }
        for file in ["extensions/single.ts", "extensions/tooling/index.ts", "extensions/notes.md", "extensions/.hidden.ts"] {
            try Data("throw new Error('never loaded')\n".utf8).write(to: dir.appendingPathComponent(file))
        }
        let settings: [String: Any] = ["extensions": ["~/own/ext.ts", "!skip"], "packages": ["npm:@acme/pi-tools@1.0.0", ["source": "git:github.com/x/y"]]]
        let listed = YourPiFiles.extensions(in: dir, settings: settings, home: "/u")
        #expect(listed.map(\.name) == ["single", "tooling", "@acme/pi-tools", "solo", "me/pi-ext", "ext.ts", "git:github.com/x/y"])
        #expect(listed.map(\.source) == [.file, .file, .npm, .npm, .git, .settings, .settings])
        #expect(listed[5].path == "/u/own/ext.ts")
    }

    // MARK: Providers

    @Test func environmentKeysNameTheirProvidersByNameOnly() {
        #expect(PiProviders.providers(withKeys: ["OPENAI_API_KEY", "ANTHROPIC_API_KEY", "UNRELATED"])
            == ["openai": ["OPENAI_API_KEY"], "anthropic": ["ANTHROPIC_API_KEY"]])
        #expect(PiProviders.name("openai-codex") == "OpenAI Codex")
        #expect(PiProviders.name("my-proxy") == "my-proxy")
        #expect(PiProviders.allEnvironmentKeys.allSatisfy { $0.allSatisfy { $0.isUppercase || $0.isNumber || $0 == "_" } })
    }
}
