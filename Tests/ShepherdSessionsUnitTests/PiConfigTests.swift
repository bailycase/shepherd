import Foundation
import Testing
@testable import ShepherdSessions

/// pi's agent directory (config and sessions) resolves like pi's own `PI_CODING_AGENT_DIR`,
/// against an explicit environment.
@Suite("pi agent directory")
struct PiConfigTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    @Test(arguments: [
        (nil, "\(home)/.pi/agent"),
        ("", "\(home)/.pi/agent"),
        ("  ", "\(home)/.pi/agent"),
        ("/tmp/pi-agent/../pi-agent2", "/tmp/pi-agent2"),
        ("~/elsewhere", "\(home)/elsewhere"),
    ] as [(String?, String)])
    func theAgentDirectoryFollowsPisOverride(_ override: String?, expected: String) {
        let env = override.map { [PiConfig.agentDirectoryEnvKey: $0] } ?? [:]
        #expect(PiConfig.agentDirectory(environment: env).path == expected)
        #expect(PiConfig.sessionsDirectory(environment: env).path == expected + "/sessions")
    }

    /// The model a new session starts with when none is passed: pi's default provider and model,
    /// never the bare id another provider could also serve.
    @Test(arguments: [
        (#"{"defaultProvider":"cpa","defaultModel":"gpt-6"}"#, "cpa/gpt-6"),
        (#"{"defaultModel":"gpt-6"}"#, nil),
        ("not json", nil),
    ] as [(String, String?)])
    func aNewSessionsModelIsPisDefaultProviderAndModel(_ settings: String, expected: String?) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(settings.utf8).write(to: dir.appendingPathComponent("settings.json"))
        #expect(PiConfig.defaultModel(in: dir) == expected)
    }

    /// What pi loads besides Shepherd's own: its packages, in either form, then its extension
    /// paths; anything unreadable is skipped.
    @Test(arguments: [
        (#"{"packages":["npm:@example/pi-tools@1.0.0",{"source":"git:github.com/example/checks@v1","skills":[]},{"skills":[]},7],"extensions":["~/pi/local.ts",""]}"#,
         ["npm:@example/pi-tools@1.0.0", "git:github.com/example/checks@v1", "~/pi/local.ts"]),
        (#"{"defaultModel":"gpt-6"}"#, []),
        ("not json", []),
    ] as [(String, [String])])
    func piLoadsTheExtensionsItsSettingsDeclare(_ settings: String, expected: [String]) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(settings.utf8).write(to: dir.appendingPathComponent("settings.json"))
        #expect(PiConfig.installedExtensions(in: dir) == expected)
    }

    /// models.json in pi's own shape lists each model as "provider/id", the form `--model` takes,
    /// and says whether it reasons (pi's default is no).
    @Test(arguments: [
        (#"{"providers":{"qa":{"baseUrl":"http://x","models":[{"id":"gemini-3.1-flash-lite"},{"id":"deep","reasoning":true}]},"# +
         #""b":{"models":[{"id":"gemini-3.1-flash-lite","reasoning":false}]}}}"#,
         [PiModelCatalog.Entry(id: "b/gemini-3.1-flash-lite", reasoning: false),
          PiModelCatalog.Entry(id: "qa/gemini-3.1-flash-lite", reasoning: false),
          PiModelCatalog.Entry(id: "qa/deep", reasoning: true)]),
        (#"{"models":["anthropic/claude-4",{"id":"openai/gpt-5"}]}"#,
         [PiModelCatalog.Entry(id: "anthropic/claude-4"), PiModelCatalog.Entry(id: "openai/gpt-5")]),
        ("not json", []),
    ] as [(String, [PiModelCatalog.Entry])])
    func configuredModelsAreProviderAndID(_ models: String, expected: [PiModelCatalog.Entry]) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data(models.utf8).write(to: dir.appendingPathComponent("models.json"))
        #expect(PiConfig.modelEntries(in: dir) == expected)
        #expect(PiConfig.modelIDs(in: dir) == expected.map(\.id))
    }

    /// A model's `thinkingLevelMap`, with a provider's `modelOverrides` laid over it; null kept as
    /// a level pi drops.
    @Test func configuredThinkingLevelMapsAreReadPerModel() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let json = #"{"providers":{"qa":{"models":[{"id":"deep","reasoning":true,"thinkingLevelMap":{"xhigh":"xhigh","minimal":null}},{"id":"plain"}],"# +
            #""modelOverrides":{"deep":{"thinkingLevelMap":{"max":"max"}},"other":{"thinkingLevelMap":{"xhigh":"high"}}}}}}"#
        try Data(json.utf8).write(to: dir.appendingPathComponent("models.json"))
        let maps = PiConfig.thinkingLevelMaps(in: dir)
        let deep: [String: String?] = ["xhigh": "xhigh", "minimal": String?.none, "max": "max"]
        #expect(maps["qa/deep"] == deep)
        #expect(maps["qa/other"] == ["xhigh": "high"])
        #expect(maps["qa/plain"] == nil)
    }
}
