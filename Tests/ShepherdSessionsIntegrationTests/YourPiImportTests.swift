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
        // Instructions, skills, prompts and extensions are copied into the home as files, and
        // Shepherd's settings name none of theirs.
        #expect(report.copied(.instructions).map(\.name) == ["AGENTS.md"])
        #expect(try Data(contentsOf: setup.home.directory.appendingPathComponent("AGENTS.md"))
            == Data(contentsOf: setup.yours.appendingPathComponent("AGENTS.md")))
        #expect(report.copied(.skills).map(\.destination) == ["skills/fixture-skill"])
        #expect(FileManager.default.fileExists(atPath: setup.home.directory.appendingPathComponent("skills/fixture-skill/SKILL.md").path))
        #expect(report.copied(.prompts).map(\.destination) == ["prompts/fixture.md", "prompts/another.md"])
        #expect(report.copied(.extensions).map(\.destination) == ["your-extensions/files/yours.ts"])
        #expect(settings["skills"] == nil && settings["prompts"] == nil)
        // Nothing else of theirs came over, and their extension is switched off.
        #expect(settings["extensions"] == nil && settings["packages"] == nil && settings["lastChangelogVersion"] == nil)
        #expect(setup.importer().state()?.copies == report.copied)
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

    /// Re-import copies a kind of file again: their edits replace Shepherd's copies, a new one
    /// comes over, a skill of Shepherd's own of one name stays Shepherd's, and their pi stays
    /// byte-identical. Instructions follow the file pi would pick now.
    @Test func reimportingFilesReplacesShepherdsCopiesAndKeepsItsOwn() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let files = FileManager.default
        let own = setup.home.directory.appendingPathComponent("skills/own")
        try files.createDirectory(at: own, withIntermediateDirectories: true)
        try Self.write("---\nname: own\ndescription: Shepherd's own.\n---\n", to: own.appendingPathComponent("SKILL.md"))
        try Self.write("---\nname: own\ndescription: Theirs.\n---\n", to: setup.yours.appendingPathComponent("skills/own/SKILL.md"))
        let first = setup.importer().copyOnce()
        #expect(first.copied(.skills).map(\.name) == ["fixture-skill"], "Shepherd's own skill of that name is kept")
        #expect(first.skipped.contains { $0.contains("skills/own") })

        try Self.write("---\nname: fixture-skill\ndescription: Edited.\n---\n", to: setup.yours.appendingPathComponent("skills/fixture-skill/SKILL.md"))
        try Self.write("---\nname: added\ndescription: New.\n---\n", to: setup.yours.appendingPathComponent("skills/added/SKILL.md"))
        let before = try YourPiFixture.tree(setup.yours)

        let skills = try setup.importer().reimport(.files(.skills))

        #expect(skills.copied(.skills).map(\.name) == ["added", "fixture-skill"])
        #expect(try String(contentsOf: setup.home.directory.appendingPathComponent("skills/fixture-skill/SKILL.md"), encoding: .utf8).contains("Edited."))
        #expect(try String(contentsOf: own.appendingPathComponent("SKILL.md"), encoding: .utf8).contains("Shepherd's own."))
        #expect(setup.importer().state()?.copies(.skills).map(\.name) == ["fixture-skill", "added"])

        // They moved to CLAUDE.md: pi would now pick it, so the old copy goes.
        try files.removeItem(at: setup.yours.appendingPathComponent("AGENTS.md"))
        try Self.write("# Claude rules\n", to: setup.yours.appendingPathComponent("CLAUDE.md"))
        let instructions = try setup.importer().reimport(.files(.instructions))
        #expect(instructions.copied(.instructions).map(\.name) == ["CLAUDE.md"])
        #expect(!files.fileExists(atPath: setup.home.directory.appendingPathComponent("AGENTS.md").path))
        #expect(files.fileExists(atPath: setup.home.directory.appendingPathComponent("CLAUDE.md").path))
        #expect(try YourPiFixture.tree(setup.yours).filter { !$0.key.hasPrefix("AGENTS") && !$0.key.hasPrefix("CLAUDE") }
            == before.filter { !$0.key.hasPrefix("AGENTS") }, "their pi is only read")

        #expect(throws: YourPiFileError.self) { try setup.importer().reimport(.files(.themes)) }
    }

    /// A home whose first copy read skills and prompts in place (version 1) gets them copied once,
    /// quietly, and Shepherd's settings stop naming the user's folders; an entry of Shepherd's own stays.
    @Test func anEarlierCopyThatReadFilesInPlaceHasThemCopiedOnce() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let legacy = [setup.yours.path + "/skills", "!**/draft-*"]
        try Self.write(#"{"version": 1, "copied": true, "copiedAt": "2026-09-26T09:41:00Z", "from": "\#(setup.yours.path)", "#
            + #""instructions": true, "skillsOn": true, "skills": ["\#(legacy[0])", "\#(legacy[1])"], "prompts": ["\#(setup.yours.path)/prompts"]}"#,
            to: setup.importer().stateURL)
        try Self.write(#"{"skills": ["\#(legacy[0])", "!**/draft-*", "/own/skill"], "prompts": ["\#(setup.yours.path)/prompts"]}"#,
            to: setup.home.settings)

        let report = setup.importer().copyOnce()

        #expect(!report.first && report.logins.isEmpty, "no welcome, and no login copied again")
        #expect(report.copied(.skills).map(\.name) == ["fixture-skill"] && report.copied(.instructions).map(\.name) == ["AGENTS.md"])
        let settings = try setup.json("settings.json")
        #expect(settings["skills"] as? [String] == ["/own/skill"] && settings["prompts"] == nil)
        let state = try #require(setup.importer().state())
        #expect(state.version == YourPiImportState.currentVersion && state.legacySkills.isEmpty && state.from == setup.yours.path)
        #expect(setup.importer().copyOnce().copied.isEmpty, "and only once")
    }

    /// Switching one of their extensions on names its copy in Shepherd's settings; a failure to
    /// load leaves it out with pi's reason until its files change or it is switched on again; a
    /// path that isn't one of theirs changes nothing.
    @Test func anExtensionIsOptInAndFailsClosed() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let copy = try #require(setup.importer().copyOnce().copied(.extensions).first)
        let entry = setup.home.directory.appendingPathComponent(copy.destination).standardizedFileURL.path
        _ = try PiSettingsFile(url: setup.home.settings).update { settings in settings["extensions"] = ["/own/extension.ts"]; return [] }
        #expect(setup.importer().survey().extensions.map(\.on) == [false])

        try setup.importer().setExtension(copy.destination, on: true)
        #expect(try setup.json("settings.json")["extensions"] as? [String] == ["/own/extension.ts", entry])

        #expect(try setup.importer().extensionFailed(path: "/own/extension.ts", reason: "boom") == nil)
        #expect(try setup.importer().extensionFailed(path: entry, reason: "Cannot find module 'turndown'\n    at require") == "yours")
        #expect(try setup.json("settings.json")["extensions"] as? [String] == ["/own/extension.ts"])
        let row = try #require(setup.importer().survey().extensions.first)
        #expect(row.on && row.failure == "Cannot find module 'turndown'")

        // Unchanged, it stays out at every launch; a change to its file tries it again.
        try setup.importer().applyExtensions()
        #expect(try setup.json("settings.json")["extensions"] as? [String] == ["/own/extension.ts"])
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: 60)], ofItemAtPath: entry)
        try setup.importer().applyExtensions()
        #expect(try setup.json("settings.json")["extensions"] as? [String] == ["/own/extension.ts", entry])
        #expect(setup.importer().state()?.extensionFailures.isEmpty == true)

        // Its files gone: left out, and said why.
        try FileManager.default.removeItem(atPath: entry)
        try setup.importer().applyExtensions()
        #expect(try setup.json("settings.json")["extensions"] as? [String] == ["/own/extension.ts"])
        #expect(setup.importer().state()?.extensionFailures[copy.destination]?.reason.contains("missing") == true)

        try setup.importer().setExtension(copy.destination, on: false)
        #expect(setup.importer().state()?.extensionsOn.isEmpty == true)
    }

    /// pi's words for extensions that failed to load, from its stderr.
    @Test func piFailureLinesNameThePathAndTheReason() {
        let failures = YourPiImport.extensionFailures(in: [
            #"Error: Failed to load extension "/h/your-extensions/files/a.ts": Failed to load extension: Cannot find module 'x'"#,
            "Run with --no-extensions to start without extensions.",
            #"Error: Failed to load extension "/h/b/index.ts": Extension does not export a valid factory function: /h/b/index.ts"#,
        ])
        #expect(failures.map(\.path) == ["/h/your-extensions/files/a.ts", "/h/b/index.ts"])
        #expect(failures.map(\.reason) == ["Cannot find module 'x'", "Extension does not export a valid factory function: /h/b/index.ts"])
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
        #expect(fresh.copies.isEmpty && fresh.extensions.isEmpty, "nothing copied yet")

        _ = setup.importer().copyOnce()
        let copied = setup.importer().survey()
        #expect(copied.copied && copied.canStartAgents)
        #expect(copied.logins.first { $0.provider == "groq" } == .init(provider: "groq", shepherd: .apiKey(.command), yours: .apiKey(.command)))
        #expect(copied.shepherdCustomProviders == ["local-llm"] && copied.shepherdDefaultModel == "anthropic/claude-fixture-4")
        #expect(copied.shepherdTrustedFolders == 1)
        #expect(copied.extensions.map(\.copy.name) == ["yours"] && copied.extensions.allSatisfy { !$0.on })
        #expect(copied.instructionLines == 3)
        Self.expectNoSecret(in: [String(describing: fresh), String(describing: copied)])
    }

    static func write(_ text: String, to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
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
