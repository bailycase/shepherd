import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// Copying the user's own pi into Shepherd's home: once, at the first launch, with every login
/// (subscription sign-ins included), custom providers, the default model and trust; then only
/// on request, one item at a time. Their folder stays byte-identical throughout, with no lock
/// taken, and no credential value reaches a log or a report. Every credential is a fake.
@Suite("Copying from your pi", .integrationTimeLimit)
struct YourPiImportTests {
    /// A scratch home, a fixture "your pi", and a log that records every line.
    struct Setup {
        let dir: URL
        let home: PiHome
        let yours: URL
        let userHome: String
        let logged = Locked<[String]>([])

        init(yourPi: Bool = true) throws {
            dir = try makeScratchDirectory("imp")
            userHome = dir.appendingPathComponent("user", isDirectory: true).path
            try FileManager.default.createDirectory(atPath: userHome, withIntermediateDirectories: true)
            home = PiHome(directory: dir.appendingPathComponent("support/pi", isDirectory: true),
                          engine: PiEngine(command: ["/nonexistent/pi"], packageDirectory: nil, version: nil, node: .onPath("node")))
            try FileManager.default.createDirectory(at: home.directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            yours = dir.appendingPathComponent("user/.pi/agent", isDirectory: true)
            if yourPi { try YourPiFixture.make(at: yours, home: userHome, trusted: [dir.appendingPathComponent("work").path]) }
        }

        func importer(yourPi: Bool = true) -> YourPiImport {
            let logged = logged
            return YourPiImport(home: home, yourPi: yourPi ? YourPi(agentDirectory: yours) : nil, userHome: userHome,
                                log: { line in logged.withValue { $0.append(line) } })
        }

        func json(_ name: String) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.directory.appendingPathComponent(name))) as? [String: Any])
        }

        func theirs(_ name: String) throws -> [String: Any] {
            try YourPiFiles.object(Data(contentsOf: yours.appendingPathComponent(name)), file: name)
        }

        func remove() { try? FileManager.default.removeItem(at: dir) }
    }

    @Test func theFirstCopyBringsOverEveryLoginProvidersTheDefaultModelTrustAndResources() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let before = try YourPiFixture.tree(setup.yours)

        let report = setup.importer().copyOnce()

        #expect(report.first && report.from == setup.yours.path)
        // Every login, subscription sign-ins included, exactly as their pi stores it.
        #expect(report.logins.map(\.provider) == ["anthropic", "google", "groq", "openai", "openai-codex"])
        let auth = try setup.json("auth.json")
        let theirs = try setup.theirs("auth.json")
        #expect(NSDictionary(dictionary: auth).isEqual(to: theirs))
        #expect(report.logins.contains(PiLogin(provider: "groq", kind: .apiKey(.command))))
        #expect(report.logins.contains(PiLogin(provider: "anthropic", kind: .subscription)))
        // auth.json is private, in a private folder.
        #expect(try Self.mode(setup.home.directory.appendingPathComponent("auth.json")) == 0o600)
        #expect(try Self.mode(setup.home.directory) == 0o700)
        // Custom providers as bytes, the default model, trust without the home folder.
        #expect(try Data(contentsOf: setup.home.directory.appendingPathComponent("models.json")) == Data(YourPiFixture.models.utf8))
        #expect(report.customProviders == ["local-llm"])
        let settings = try setup.json("settings.json")
        #expect(settings["defaultProvider"] as? String == "anthropic" && settings["defaultModel"] as? String == "claude-fixture-4")
        #expect(report.defaultModel == "anthropic/claude-fixture-4")
        let trust = try setup.json("trust.json")
        #expect(trust[setup.userHome] == nil, "the home folder is never trusted as a project")
        #expect(trust[setup.dir.appendingPathComponent("work").path] as? Bool == true && trust["/fixture/untrusted"] as? Bool == false)
        #expect(report.trustedFolders == 2 && report.droppedTrust == [setup.userHome])
        // Skills and prompts are read in place, by absolute path.
        #expect(settings["skills"] as? [String] == [setup.yours.path + "/skills", setup.userHome + "/fixture-extra-skills", "!**/draft-*"])
        #expect(settings["prompts"] as? [String] == [setup.yours.path + "/prompts", setup.yours.path + "/more-prompts"])
        #expect(report.instructions == "AGENTS.md")
        // Nothing else of theirs came over.
        #expect(settings["extensions"] == nil && settings["packages"] == nil && settings["lastChangelogVersion"] == nil)
        #expect(report.problems.isEmpty)

        #expect(try YourPiFixture.tree(setup.yours) == before, "your pi is byte-identical")
        #expect(!(try YourPiFixture.tree(setup.yours).keys.contains { $0.hasSuffix(".lock") }), "no lock was taken in your pi")
        #expect(!(try FileManager.default.contentsOfDirectory(atPath: setup.home.directory.path).contains { $0.hasSuffix(".lock") }))
        Self.expectNoSecret(in: setup.logged.current + [report.summary, String(describing: report)])
    }

    @Test func theMarkerStopsTheCopyFromRepeatingOnItsOwn() throws {
        let setup = try Setup()
        defer { setup.remove() }
        #expect(setup.importer().copyOnce().first)
        let state = try #require(setup.importer().state())
        #expect(state.from == setup.yours.path)

        // Their pi changes, and Shepherd signs out of one provider: a second launch copies nothing.
        try Data(#"{"xai": {"type": "api_key", "key": "$XAI_API_KEY"}}"#.utf8).write(to: setup.yours.appendingPathComponent("auth.json"))
        _ = try PiSettingsFile(url: setup.home.directory.appendingPathComponent("auth.json")).update { auth in
            auth.removeValue(forKey: "openai")
            return []
        }
        let again = setup.importer().copyOnce()
        #expect(!again.first && again.logins.isEmpty)
        let auth = try setup.json("auth.json")
        #expect(auth["xai"] == nil && auth["openai"] == nil && auth["anthropic"] != nil)
        #expect(setup.importer().state() == state)
    }

    /// A sign-in Shepherd's pi already has (made before this build), its own custom providers and
    /// its default model are kept by the first copy.
    @Test func theFirstCopyKeepsWhatShepherdsPiAlreadyHas() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let ownAuth = #"{"anthropic": {"type": "oauth", "refresh": "SHEPHERDS-OWN", "access": "SHEPHERDS-OWN", "expires": 1}}"#
        try Data(ownAuth.utf8).write(to: setup.home.directory.appendingPathComponent("auth.json"))
        let ownModels = #"{"providers": {"shepherds-own": {}}}"#
        try Data(ownModels.utf8).write(to: setup.home.directory.appendingPathComponent("models.json"))
        try Data(#"{"defaultProvider": "openai", "defaultModel": "gpt-own", "shellCommandPrefix": "kept"}"#.utf8)
            .write(to: setup.home.settings)

        let report = setup.importer().copyOnce()

        #expect(report.keptLogins == ["anthropic"] && !report.logins.contains { $0.provider == "anthropic" })
        let auth = try setup.json("auth.json")
        #expect((auth["anthropic"] as? [String: Any])?["refresh"] as? String == "SHEPHERDS-OWN")
        #expect(auth["openai"] != nil, "the rest still came over")
        #expect(report.keptCustomProviders && report.customProviders.isEmpty)
        #expect(try String(contentsOf: setup.home.directory.appendingPathComponent("models.json"), encoding: .utf8) == ownModels)
        #expect(report.keptDefaultModel == "openai/gpt-own" && report.defaultModel == nil)
        let settings = try setup.json("settings.json")
        #expect(settings["defaultModel"] as? String == "gpt-own" && settings["shellCommandPrefix"] as? String == "kept")
    }

    /// Re-import copies one provider's login again, overwriting only Shepherd's copy of it; the
    /// others, and their pi, stay as they are.
    @Test func reimportingOneProviderOverwritesOnlyThatLogin() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let own = #"{"anthropic": {"type": "oauth", "refresh": "SHEPHERDS-OWN"}, "openai": {"type": "api_key", "key": "SHEPHERDS-OWN"}}"#
        try Data(own.utf8).write(to: setup.home.directory.appendingPathComponent("auth.json"))
        _ = setup.importer().copyOnce()
        let before = try YourPiFixture.tree(setup.yours)

        let report = try setup.importer().reimport(.login("anthropic"))

        #expect(report.logins == [PiLogin(provider: "anthropic", kind: .subscription)])
        let auth = try setup.json("auth.json")
        let theirs = try setup.theirs("auth.json")
        #expect(NSDictionary(dictionary: auth["anthropic"] as? [String: Any] ?? [:]).isEqual(to: theirs["anthropic"] as? [String: Any] ?? [:]))
        #expect((auth["openai"] as? [String: Any])?["key"] as? String == "SHEPHERDS-OWN", "another provider's login stays Shepherd's")

        #expect(throws: YourPiFileError.self) { try setup.importer().reimport(.login("mistral")) }
        #expect(try YourPiFixture.tree(setup.yours) == before)
        Self.expectNoSecret(in: setup.logged.current)
    }

    /// Custom providers, the default model and trust copy again on request; an invalid models.json
    /// in their pi keeps Shepherd's copy and says why, without quoting it.
    @Test func reimportingEachItemOverwritesShepherdsCopyAndInvalidJSONKeepsIt() throws {
        let setup = try Setup()
        defer { setup.remove() }
        _ = setup.importer().copyOnce()
        let before = try YourPiFixture.tree(setup.yours)
        _ = try PiSettingsFile(url: setup.home.settings).update { settings in
            settings["defaultProvider"] = "openai"
            settings["defaultModel"] = "changed"
            return []
        }
        try setup.importer().reimport(.defaultModel)
        #expect(try setup.json("settings.json")["defaultModel"] as? String == "claude-fixture-4")
        try setup.importer().reimport(.trust)
        #expect(try setup.json("trust.json")[setup.userHome] == nil)
        #expect(try YourPiFixture.tree(setup.yours) == before)

        let copied = try Data(contentsOf: setup.home.directory.appendingPathComponent("models.json"))
        try Data(#"{"providers": {"broken": "FAKE-models-json-key" "#.utf8).write(to: setup.yours.appendingPathComponent("models.json"))
        #expect {
            try setup.importer().reimport(.customProviders)
        } throws: { error in
            !String(describing: error).contains("FAKE") && String(describing: error).contains("models.json")
        }
        #expect(try Data(contentsOf: setup.home.directory.appendingPathComponent("models.json")) == copied, "Shepherd's copy stays")
    }

    /// Switching skills (or prompts) off removes exactly the entries Shepherd added; one the user
    /// added in Shepherd's own pi stays. On again reads their settings afresh.
    @Test func switchingSkillsOffRemovesOnlyShepherdsEntries() throws {
        let setup = try Setup()
        defer { setup.remove() }
        _ = setup.importer().copyOnce()
        _ = try PiSettingsFile(url: setup.home.settings).update { settings in
            settings["skills"] = (settings["skills"] as? [String] ?? []) + ["/own/skill"]
            return []
        }
        try setup.importer().setResources("skills", on: false)
        #expect(try setup.json("settings.json")["skills"] as? [String] == ["/own/skill"])
        #expect(setup.importer().state()?.skillsOn == false)
        #expect(try setup.json("settings.json")["prompts"] != nil, "prompts are separate")

        try setup.importer().setResources("skills", on: true)
        #expect(try setup.json("settings.json")["skills"] as? [String]
            == [setup.yours.path + "/skills", setup.userHome + "/fixture-extra-skills", "!**/draft-*", "/own/skill"])

        try setup.importer().setInstructions(false)
        #expect(setup.importer().instructionsDirectory() == nil)
        try setup.importer().setInstructions(true)
        #expect(setup.importer().instructionsDirectory() == setup.yours.standardizedFileURL)
    }

    @Test func withNoPiOfTheirsTheFirstCopyOnlyRecordsItself() throws {
        let setup = try Setup(yourPi: false)
        defer { setup.remove() }
        let report = setup.importer(yourPi: false).copyOnce()
        #expect(report.first && report.from == nil && !report.broughtOver)
        #expect(try FileManager.default.contentsOfDirectory(atPath: setup.home.directory.path) == [YourPiImport.stateName])
        #expect(setup.importer(yourPi: false).state()?.from == nil)
        #expect(throws: YourPiFileError.self) { try setup.importer(yourPi: false).reimport(.trust) }
    }

    /// Settings ▸ Pi's view of both sides: each provider's login in Shepherd's pi and theirs, and
    /// the keys their shell sets, by name.
    @Test func theSurveyShowsBothSidesByKindAndName() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let fresh = setup.importer().survey(environmentKeys: ["XAI_API_KEY"])
        #expect(!fresh.copied && fresh.canStartAgents, "a key in the environment can start an agent")
        #expect(!setup.importer().survey().canStartAgents, "nothing in Shepherd's pi and no key in the environment")
        #expect(fresh.logins.first { $0.provider == "anthropic" } == .init(provider: "anthropic", yours: .subscription))
        #expect(fresh.logins.first { $0.provider == "xai" } == .init(provider: "xai", environment: ["XAI_API_KEY"]))
        #expect(fresh.customProviders == ["local-llm"] && fresh.defaultModel == "anthropic/claude-fixture-4" && fresh.trustedFolders == 2)
        #expect(fresh.instructionsFile == setup.yours.appendingPathComponent("AGENTS.md").path)
        #expect(fresh.extensions.map(\.name) == ["yours", "@fixture/pi-tools", "tool.ts"])

        _ = setup.importer().copyOnce()
        let copied = setup.importer().survey()
        #expect(copied.copied && copied.canStartAgents)
        #expect(copied.logins.first { $0.provider == "groq" } == .init(provider: "groq", shepherd: .apiKey(.command), yours: .apiKey(.command)))
        #expect(copied.shepherdCustomProviders == ["local-llm"] && copied.shepherdDefaultModel == "anthropic/claude-fixture-4")
        #expect(copied.shepherdTrustedFolders == 1)
        Self.expectNoSecret(in: [String(describing: fresh), String(describing: copied)])
    }

    static func mode(_ url: URL) throws -> Int {
        ((try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o777
    }

    static func expectNoSecret(in texts: [String], sourceLocation: SourceLocation = #_sourceLocation) {
        for text in texts {
            for secret in YourPiFixture.secrets {
                #expect(!text.contains(secret), "a credential leaked: \(secret)", sourceLocation: sourceLocation)
            }
        }
    }
}
