import Darwin
import Foundation
import Testing
@testable import ShepherdSessions
import ShepherdTestSupport

/// The copy from "your pi" against the files a real one may hold: links, a FIFO or folder where a
/// file should be, a huge or invalid auth.json, sign-ins with fields Shepherd doesn't know, keys
/// that run a command, a damaged state file, and a "your pi" that overlaps Shepherd's home. Each
/// fails closed and fast, their folder stays byte-identical with no lock taken, and no credential
/// value reaches a log, a report or the survey. Every credential is a fake.
@Suite("Copying from your pi: hostile files", .integrationTimeLimit)
struct YourPiImportEdgeTests {
    typealias Setup = YourPiImportTests.Setup

    static func write(_ text: String, to url: URL) throws {
        try Data(text.utf8).write(to: url)
    }

    static func texts(_ setup: Setup, _ reports: [YourPiImportReport], _ extra: [String] = []) -> [String] {
        setup.logged.current + reports.flatMap { [$0.summary, String(describing: $0)] } + extra
    }

    /// A linked auth.json is read through the link (as pi reads it) and copied as a new, private
    /// file; the link and its target stay as they were.
    @Test func aLinkedAuthFileIsCopiedThroughTheLinkAndLeftAsALink() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let elsewhere = setup.dir.appendingPathComponent("dotfiles", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let target = elsewhere.appendingPathComponent("auth.json")
        try FileManager.default.moveItem(at: setup.yours.appendingPathComponent("auth.json"), to: target)
        try FileManager.default.createSymbolicLink(at: setup.yours.appendingPathComponent("auth.json"), withDestinationURL: target)
        let before = try YourPiFixture.tree(setup.yours)
        let targetBefore = try Data(contentsOf: target)

        let report = setup.importer().copyOnce()

        #expect(report.problems.isEmpty && report.logins.count == 5)
        let copied = setup.home.directory.appendingPathComponent("auth.json")
        var info = stat()
        #expect(lstat(copied.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1, "a regular file of Shepherd's own")
        #expect(info.st_mode & 0o777 == 0o600)
        #expect(try YourPiFixture.tree(setup.yours) == before)
        #expect(try Data(contentsOf: target) == targetBefore)
        YourPiImportTests.expectNoSecret(in: Self.texts(setup, [report]))
    }

    /// A FIFO, a folder or a device where auth.json should be fails at once, without hanging the
    /// first launch; the rest still copies, and the marker is written.
    @Test(arguments: ["fifo", "folder", "device", "dangling", "loop"])
    func anAuthFileThatIsNotAFileFailsAtOnce(_ kind: String) throws {
        let setup = try Setup()
        defer { setup.remove() }
        let auth = setup.yours.appendingPathComponent("auth.json")
        try FileManager.default.removeItem(at: auth)
        switch kind {
        case "fifo": #expect(mkfifo(auth.path, 0o600) == 0)
        case "folder": try FileManager.default.createDirectory(at: auth, withIntermediateDirectories: false)
        case "device": try FileManager.default.createSymbolicLink(atPath: auth.path, withDestinationPath: "/dev/zero")
        case "dangling": try FileManager.default.createSymbolicLink(atPath: auth.path, withDestinationPath: setup.dir.appendingPathComponent("gone").path)
        default: try FileManager.default.createSymbolicLink(atPath: auth.path, withDestinationPath: auth.path)
        }
        let before = try YourPiFixture.tree(setup.yours)
        let started = Date()

        let report = setup.importer().copyOnce()

        #expect(Date().timeIntervalSince(started) < 5, "no read blocks")
        #expect(report.logins.isEmpty && report.customProviders == ["local-llm"])
        #expect(report.problems.count == (kind == "dangling" ? 0 : 1), "a missing file is no problem; anything else says so")
        #expect(setup.importer().state()?.copied == true)
        #expect(try YourPiFixture.tree(setup.yours) == before)
    }

    /// An auth.json larger than the cap, invalid JSON, JSON nested past the parser's depth, or an
    /// array: nothing is copied from it, the reason never quotes it, and Shepherd's copy stays.
    @Test(arguments: ["huge", "invalid", "deep", "array"])
    func anUnreadableAuthFileCopiesNoLoginAndNeverQuotesIt(_ kind: String) throws {
        let setup = try Setup()
        defer { setup.remove() }
        let own = #"{"mistral": {"type": "api_key", "key": "SHEPHERDS-OWN"}}"#
        try Self.write(own, to: setup.home.directory.appendingPathComponent("auth.json"))
        let secret = "sk-FAKE-literal-0001"
        let text: String = switch kind {
        case "huge": #"{"openai": {"type": "api_key", "key": "\#(secret)"}, "pad": ""# + String(repeating: "x", count: YourPiFiles.maxBytes) + "\"}"
        case "invalid": #"{"openai": {"type": "api_key", "key": "\#(secret)""#
        case "deep": String(repeating: "[", count: 100_000) + "\"\(secret)\"" + String(repeating: "]", count: 100_000)
        default: #"[{"openai": {"type": "api_key", "key": "\#(secret)"}}]"#
        }
        try Self.write(text, to: setup.yours.appendingPathComponent("auth.json"))
        let before = try YourPiFixture.tree(setup.yours)

        let report = setup.importer().copyOnce()

        #expect(report.logins.isEmpty && report.problems.count == 1)
        #expect(report.problems.first?.contains("auth.json") == true)
        #expect(try String(contentsOf: setup.home.directory.appendingPathComponent("auth.json"), encoding: .utf8) == own)
        #expect(throws: YourPiFileError.self) { try setup.importer().reimport(.login("openai")) }
        let survey = setup.importer().survey()
        #expect(survey.problems.count == 1)
        #expect(try YourPiFixture.tree(setup.yours) == before)
        YourPiImportTests.expectNoSecret(in: Self.texts(setup, [report], survey.problems + [String(describing: survey)]))
    }

    /// A sign-in with fields Shepherd doesn't know (nested objects, arrays, null, floats, big
    /// numbers, booleans) comes over whole, value for value.
    @Test func aSignInWithUnknownFieldsComesOverWhole() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let auth = #"""
            {"anthropic": {"type": "oauth", "refresh": "FAKE-REFRESH-anthropic", "access": "FAKE-ACCESS-anthropic",
              "expires": 1790000000123, "scopes": ["user:inference", "user:profile"], "account": {"id": "fake", "org": null},
              "ratio": 0.25, "enterprise": false, "extra": {"nested": [1, {"deep": true}]}}}
            """#
        try Self.write(auth, to: setup.yours.appendingPathComponent("auth.json"))

        let report = setup.importer().copyOnce()

        #expect(report.logins == [PiLogin(provider: "anthropic", kind: .subscription)])
        let ours = try setup.json("auth.json")
        let theirs = try setup.theirs("auth.json")
        #expect(NSDictionary(dictionary: ours).isEqual(to: theirs))
        let entry = try #require(ours["anthropic"] as? [String: Any])
        #expect((entry["expires"] as? NSNumber)?.int64Value == 1_790_000_000_123)
        #expect((entry["account"] as? [String: Any])?["org"] is NSNull)
        YourPiImportTests.expectNoSecret(in: Self.texts(setup, [report]))
    }

    /// A key that runs a command is copied as its reference (the command runs in Shepherd's pi,
    /// never at the copy) and shown as "runs a command": the command, which may name a secret,
    /// never appears.
    @Test func aKeyThatRunsACommandIsCopiedAsItIsAndNeverShown() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let marker = setup.dir.appendingPathComponent("command-ran")
        let command = "!touch \(marker.path); echo FAKE-COMMAND-SECRET"
        let auth = try JSONSerialization.data(withJSONObject: ["groq": ["type": "api_key", "key": command]])
        try auth.write(to: setup.yours.appendingPathComponent("auth.json"))

        let report = setup.importer().copyOnce()
        let survey = setup.importer().survey()

        #expect(report.logins == [PiLogin(provider: "groq", kind: .apiKey(.command))])
        #expect((try setup.json("auth.json")["groq"] as? [String: Any])?["key"] as? String == command)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the copy never runs it")
        #expect(survey.logins.first?.shepherd == .apiKey(.command))
        for text in Self.texts(setup, [report], [String(describing: survey)]) {
            #expect(!text.contains("FAKE-COMMAND-SECRET") && !text.contains("touch"))
        }
    }

    /// A state file that can't be read counts as a copy that ran: a second launch never copies
    /// again, and never overwrites a login Shepherd's pi changed since.
    @Test func aDamagedStateFileNeverCopiesAgain() throws {
        let setup = try Setup()
        defer { setup.remove() }
        #expect(setup.importer().copyOnce().first)
        _ = try PiSettingsFile(url: setup.home.directory.appendingPathComponent("auth.json")).update { auth in
            auth.removeValue(forKey: "openai")
            return []
        }
        try Self.write("{ not json", to: setup.importer().stateURL)

        let again = setup.importer().copyOnce()

        #expect(!again.first && again.logins.isEmpty)
        #expect(try setup.json("auth.json")["openai"] == nil)
    }

    /// A switch saved in Settings ▸ Pi before the first copy (a copy that overran its deadline)
    /// neither stops the next launch's copy nor is lost by it.
    @Test func aSwitchSavedBeforeTheFirstCopyKeepsTheCopyComing() throws {
        let setup = try Setup()
        defer { setup.remove() }
        try setup.importer().setResources("skills", on: false)
        #expect(setup.importer().state()?.copied == false)
        #expect(!setup.importer().survey().copied)

        let report = setup.importer().copyOnce()

        #expect(report.first && report.logins.count == 5)
        let state = try #require(setup.importer().state())
        #expect(state.copied && !state.skillsOn && state.skills.isEmpty)
        #expect(try setup.json("settings.json")["skills"] == nil)
        #expect(!setup.importer().copyOnce().first)
    }

    /// Shepherd's own auth.json that isn't a JSON object is left as it is, and the copy says so
    /// rather than claiming the logins came over.
    @Test func aDamagedAuthFileOfShepherdsIsLeftAndReported() throws {
        let setup = try Setup()
        defer { setup.remove() }
        try Self.write("[]", to: setup.home.directory.appendingPathComponent("auth.json"))

        let report = setup.importer().copyOnce()

        #expect(report.logins.isEmpty && report.problems.count == 1)
        #expect(report.problems.first?.contains("auth.json") == true)
        #expect(try String(contentsOf: setup.home.directory.appendingPathComponent("auth.json"), encoding: .utf8) == "[]")
        YourPiImportTests.expectNoSecret(in: Self.texts(setup, [report]))
    }

    /// A "your pi" that overlaps Shepherd's home (inside it, or holding it) is never copied from:
    /// the first launch's copy is refused before anything is read or written.
    @Test(arguments: ["inside", "around"])
    func aYourPiThatOverlapsShepherdsHomeIsNeverCopied(_ where_: String) throws {
        let dir = try makeScratchDirectory("ovl")
        defer { try? FileManager.default.removeItem(at: dir) }
        let support = dir.appendingPathComponent("support", isDirectory: true)
        let home = support.appendingPathComponent("pi", isDirectory: true)
        let yours = where_ == "inside" ? home.appendingPathComponent("agent", isDirectory: true) : support
        try YourPiFixture.make(at: yours, home: dir.path)
        let before = try YourPiFixture.tree(yours)
        let pi = PiSetup(engine: PiSetup.app.engine, home: home, yourPi: YourPiLocator(.fixed(yours)), userHome: dir.path)

        #expect(pi.copyYourPiOnce() == nil)
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent(YourPiImport.stateName).path))
        #expect(!FileManager.default.fileExists(atPath: home.appendingPathComponent("auth.json").path))
        #expect(try YourPiFixture.tree(yours) == before)
    }

    /// A private package's source may carry a token in its URL: the extension listing drops it.
    @Test func aPackageSourcesTokenNeverReachesTheListing() throws {
        let setup = try Setup()
        defer { setup.remove() }
        let settings = #"""
            {"packages": ["git:https://fake-user:FAKE-PACKAGE-TOKEN@github.com/fixture/private-tools", {"source": "https://FAKE-PACKAGE-TOKEN@example.com/x.git"}],
             "extensions": ["https://FAKE-PACKAGE-TOKEN@example.com/ext.ts"]}
            """#
        try Self.write(settings, to: setup.yours.appendingPathComponent("settings.json"))

        let survey = setup.importer().survey()

        #expect(survey.extensions.contains { $0.path == "git:https://github.com/fixture/private-tools" })
        #expect(!String(describing: survey).contains("FAKE-PACKAGE-TOKEN"))
    }
}
