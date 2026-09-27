import Foundation

/// A scratch "your pi" (the user's own pi folder) holding one of everything Shepherd copies or
/// reads: fake logins of each kind, a custom provider, a default model, skills and prompts,
/// trusted folders (one of them the home folder), global instructions and extensions. Every
/// credential in it is a fake, listed in `secrets` so a test can prove none leaks.
public enum YourPiFixture {
    /// Every credential value in the fixture: none may reach a log, a report, the UI or pi's context.
    public static let secrets = ["sk-FAKE-literal-0001", "FAKE-REFRESH-anthropic", "FAKE-ACCESS-anthropic", "FAKE-REFRESH-codex",
                                 "FAKE-ACCESS-codex", "FAKE-models-json-key"]

    /// The fixture's auth.json: a subscription sign-in each for Anthropic and OpenAI Codex, and API
    /// keys stored literally, from the environment, and from a command.
    public static let auth = #"""
        {
          "anthropic": {"type": "oauth", "refresh": "FAKE-REFRESH-anthropic", "access": "FAKE-ACCESS-anthropic", "expires": 1790000000000},
          "openai-codex": {"type": "oauth", "refresh": "FAKE-REFRESH-codex", "access": "FAKE-ACCESS-codex", "expires": 1790000000000, "accountId": "fake-account"},
          "openai": {"type": "api_key", "key": "sk-FAKE-literal-0001"},
          "google": {"type": "api_key", "key": "$GEMINI_API_KEY"},
          "groq": {"type": "api_key", "key": "!printf fake-command-output"}
        }

        """#

    public static let models = #"""
        // A custom provider, with a comment as pi allows.
        {"providers": {"local-llm": {"baseUrl": "http://127.0.0.1:9/v1", "api": "openai-completions", "apiKey": "FAKE-models-json-key",
          "models": [{"id": "fixture-model", "name": "Fixture"}]}}}

        """#

    /// Writes the fixture into `dir` (created) and returns it. `home` is the user's home folder:
    /// the fixture trusts it as a project, which Shepherd never copies.
    @discardableResult
    public static func make(at dir: URL, home: String, trusted: [String] = []) throws -> URL {
        let files = FileManager.default
        try files.createDirectory(at: dir, withIntermediateDirectories: true)
        func write(_ text: String, _ path: String, mode: Int = 0o644) throws {
            let url = dir.appendingPathComponent(path)
            try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
            try files.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
        }
        try write(auth, "auth.json", mode: 0o600)
        try write(models, "models.json")
        try write(#"""
            {
              "defaultProvider": "anthropic",
              "defaultModel": "claude-fixture-4",
              "skills": ["~/fixture-extra-skills", "!**/draft-*"],
              "prompts": ["more-prompts"],
              "extensions": ["~/fixture-ext/tool.ts"],
              "packages": ["npm:@fixture/pi-tools@1.0.0"],
              "lastChangelogVersion": "0.80.0"
            }

            """#, "settings.json")
        var trust: [String: Bool] = [home: true]
        for path in trusted { trust[path] = true }
        trust["/fixture/untrusted"] = false
        try write(String(decoding: try JSONSerialization.data(withJSONObject: trust, options: [.sortedKeys]), as: UTF8.self), "trust.json")
        try write("# Your rules\n\n- Say FIXTURE-GLOBAL-INSTRUCTIONS when asked.\n", "AGENTS.md")
        try write("---\nname: fixture-skill\ndescription: A fixture skill.\n---\n", "skills/fixture-skill/SKILL.md")
        try write("Fixture prompt\n", "prompts/fixture.md")
        try write("Another prompt\n", "more-prompts/another.md")
        try write("throw new Error('your extension must never load')\n", "extensions/yours.ts")
        try files.createDirectory(at: dir.appendingPathComponent("npm/node_modules/@fixture/pi-tools"), withIntermediateDirectories: true)
        return dir
    }

    /// Every path under `root`, links as links and folders as folders, with each file's bytes and
    /// permissions: equal before and after means nothing was written, created or locked.
    public static func tree(_ root: URL) throws -> [String: String] {
        var tree: [String: String] = [:]
        let files = FileManager.default
        for path in try files.subpathsOfDirectory(atPath: root.path) {
            let url = root.appendingPathComponent(path)
            let attributes = try files.attributesOfItem(atPath: url.path)
            let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0
            switch attributes[.type] as? FileAttributeType {
            case .typeSymbolicLink?: tree[path] = "link:" + (try files.destinationOfSymbolicLink(atPath: url.path))
            case .typeDirectory?: tree[path] = "dir:\(mode)"
            default: tree[path] = "file:\(mode):" + (files.contents(atPath: url.path) ?? Data()).base64EncodedString()
            }
        }
        return tree
    }
}
