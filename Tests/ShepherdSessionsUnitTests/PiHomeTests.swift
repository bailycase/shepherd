import Foundation
import ShepherdTestKit
import Testing
@testable import ShepherdSessions

/// Shepherd's pi home: the launcher's content, what gives an agent's shell commands their
/// environment back, the startup guards, and Shepherd's keys in pi's `settings.json`.
@Suite("Shepherd's pi home")
struct PiHomeTests {
    static let engine = PiEngine(command: ["/Apps/Shepherd.app/Contents/Helpers/node", "/Apps/Shepherd.app/Contents/Resources/pi-engine/dist/bundle/cli.js"],
                                 packageDirectory: "/Apps/Shepherd.app/Contents/Resources/pi-engine", version: "0.87.1",
                                 node: .executable("/Apps/Shepherd.app/Contents/Helpers/node"))
    static let home = PiHome(directory: URL(fileURLWithPath: "/Users/me/Library/Application Support/Shepherd/pi"), engine: engine)

    // MARK: ~/.agents/skills

    /// pi enables `$HOME/.agents/skills` unless a `!` pattern in the global `skills` matches its
    /// absolute path, so Shepherd's settings carry one for the home pi sees, escaped for minimatch.
    @Test(arguments: [
        ("/Users/me", "!/Users/me/.agents/skills/**"),
        ("/Users/me/", "!/Users/me/.agents/skills/**"),
        ("/Users/a[b]*c", #"!/Users/a\[b\]\*c/.agents/skills/**"#),
        ("/Users/x (y)+z@q!", #"!/Users/x \(y\)\+z\@q\!/.agents/skills/**"#),
    ])
    func theUsersAgentsSkillsFolderIsFilteredOut(_ home: String, _ exclusion: String) {
        #expect(PiHome.userSkillsExclusions(home: home).first == exclusion)
    }

    /// Other entries stay, in order; an exclusion written for another home is replaced.
    @Test func theExclusionReplacesAnOldOneAndKeepsOtherSkillsEntries() {
        let entries: [Any] = ["/x/skills", "!/Users/old/.agents/skills/**", "!**/draft-*", 3]
        let kept = PiHome.excludingUserSkills(entries, home: "/Users/me")
        #expect(kept.count == 4)
        #expect(kept.compactMap { $0 as? String } == ["/x/skills", "!**/draft-*", "!/Users/me/.agents/skills/**"])
        #expect(PiHome.excludingUserSkills(nil, home: "/Users/me").compactMap { $0 as? String } == ["!/Users/me/.agents/skills/**"])
    }

    /// The stash's prefix survives the children extension's filter, which drops `SHEPHERD_*`.
    @Test func theStashSurvivesTheChildrensEnvironmentFilter() {
        #expect(!PiHome.stashPrefix.hasPrefix("SHEPHERD_") && !PiHome.stashNamesKey.hasPrefix("SHEPHERD_"))
        #expect(!PiHome.stashPrefix.hasPrefix("PI_") && !PiHome.stashPrefix.hasPrefix("NODE_"))
    }

    // MARK: The startup guards

    @Test(arguments: [
        ("/s/support/pi", "/s/pi-agent", nil, false),
        ("/s/support/pi", "/s/support", nil, true),                  // the home inside your pi
        ("/s/pi-agent/shepherd", "/s/pi-agent", nil, true),          // the same
        ("/s/support/pi", "/s/support/pi/agent", nil, true),         // your pi inside the home
        ("/s/support/pi", "/s/support/pi", nil, true),
        ("/s/support/pi", "/s/pi-agent", "/s/support/pi/sessions", true), // their sessions in ours
        ("/s/support/pi", "/s/pi-agent", "/s/support", true),
        ("/s/support/pi", "/s/pi-agent", "/s/pi-sessions", false),
    ] as [(String, String, String?, Bool)])
    func aHomeThatOverlapsYourPiStartsNoPi(_ home: String, _ yours: String, _ sessions: String?, _ refused: Bool) {
        let files = PiHome(directory: URL(fileURLWithPath: home), engine: Self.engine)
        let yourPi = YourPi(agentDirectory: URL(fileURLWithPath: yours), sessionDirectory: sessions.map { URL(fileURLWithPath: $0) })
        #expect((PiSetup.check(files, yourPi: yourPi) != nil) == refused)
    }

    @Test func withNoYourPiThereIsNothingToOverlap() {
        #expect(PiSetup.check(Self.home, yourPi: nil) == nil)
    }

    /// A folder the startup files name, refused as "your pi" for being inside a support folder,
    /// still may not overlap the home: the terminal pi would share it. One inside another
    /// edition's support folder, apart from this home, is only not read.
    @Test(arguments: [
        ("/s/support/pi", true),
        ("/s/support/pi/agent", true),
        ("/s/support", true),
        ("/s/support/pi/sessions", true),
        ("/s/other-edition/pi", false),
    ] as [(String, Bool)])
    func aFolderRefusedAsYourPiStillMayNotOverlapTheHome(_ refused: String, _ overlaps: Bool) {
        let files = PiHome(directory: URL(fileURLWithPath: "/s/support/pi"), engine: Self.engine)
        #expect((PiSetup.check(files, yourPi: nil, refused: URL(fileURLWithPath: refused)) != nil) == overlaps)
    }

    // MARK: Your pi

    static let supportFolders = [URL(fileURLWithPath: "/u/Library/Application Support/Shepherd"),
                                 URL(fileURLWithPath: "/u/Library/Application Support/Shepherd Nightly")]

    @Test(arguments: [
        (nil, nil, "/u/.pi/agent", nil, nil),
        ("", "", "/u/.pi/agent", nil, nil),
        ("~/pi-home", nil, "/u/pi-home", nil, "/u/.pi/agent"),
        ("/opt/pi", "~/pi-sessions", "/opt/pi", "/u/pi-sessions", "/u/.pi/agent"),
        ("relative/pi", nil, "/u/relative/pi", nil, "/u/.pi/agent"),
    ] as [(String?, String?, String, String?, String?)])
    func yourPiIsWhatTheirStartupFilesSay(_ dir: String?, _ sessions: String?, _ agent: String, _ sessionFolder: String?, _ fallback: String?) throws {
        let yours = try #require(YourPiLocator.interpret(dir: dir, sessions: sessions, home: "/u", supportFolders: Self.supportFolders))
        #expect(yours.agentDirectory.path == agent)
        #expect(yours.sessionDirectory?.path == sessionFolder)
        #expect(yours.fallbackAgentDirectory?.path == fallback)
    }

    /// A "your pi" inside any edition's support folder would have Shepherd read its own home.
    @Test(arguments: ["/u/Library/Application Support/Shepherd/pi", "/u/Library/Application Support/Shepherd Nightly",
                      "~/Library/Application Support/Shepherd/pi/agent"])
    func yourPiInsideASupportFolderIsRefused(_ dir: String) {
        #expect(YourPiLocator.interpret(dir: dir, sessions: nil, home: "/u", supportFolders: Self.supportFolders) == nil)
        let refused = YourPiLocator.answer(dir: dir, sessions: nil, home: "/u", supportFolders: Self.supportFolders).refused
        #expect(refused?.path == (dir.hasPrefix("~/") ? "/u" + dir.dropFirst() : dir), "kept for the guards")
    }

    @Test func sessionSettingsUseTheBoundedReaderForUserAndProjectFiles() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let agent = dir.appendingPathComponent("agent")
        let project = dir.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: agent, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: project.appendingPathComponent(".pi"), withIntermediateDirectories: true)
        let userSettings = agent.appendingPathComponent("settings.json")
        let projectSettings = project.appendingPathComponent(".pi/settings.json")
        let commented = Data("// pi permits comments\n{\"sessionDir\":\"saved\"}".utf8)
        for url in [userSettings, projectSettings] { try commented.write(to: url) }
        let yours = try #require(YourPiLocator.interpret(dir: agent.path, sessions: nil, home: dir.path, supportFolders: []))
        #expect(yours.sessionDirectory == agent.appendingPathComponent("saved", isDirectory: true))
        #expect(yours.sessionFolders(forCwd: project.path).contains(project.appendingPathComponent("saved", isDirectory: true)))
        let oversized = Data(repeating: 0x20, count: YourPiFiles.maxBytes + 1)
        for url in [userSettings, projectSettings] { try oversized.write(to: url) }
        let bounded = try #require(YourPiLocator.interpret(dir: agent.path, sessions: nil, home: dir.path, supportFolders: []))
        #expect(bounded.sessionDirectory == nil)
        #expect(!bounded.sessionFolders(forCwd: project.path).contains(project.appendingPathComponent("saved", isDirectory: true)))
        for url in [userSettings, projectSettings] { #expect(try Data(contentsOf: url) == oversized) }
    }

    /// Where an agent's old conversation may be: the folder their pi is set to, then theirs and
    /// `~/.pi/agent`'s project folders, with pi's name for the project.
    @Test func yourPisSessionFoldersForAProject() {
        let yours = YourPi(agentDirectory: URL(fileURLWithPath: "/u/pi-home"), sessionDirectory: URL(fileURLWithPath: "/u/flat"),
                           fallbackAgentDirectory: URL(fileURLWithPath: "/u/.pi/agent"))
        #expect(yours.sessionFolders(forCwd: "/nonexistent/proj:x").map(\.path) == [
            "/u/flat", "/u/pi-home/sessions/--nonexistent-proj-x--", "/u/.pi/agent/sessions/--nonexistent-proj-x--",
        ])
    }
}

/// pi's settings.json, as Shepherd writes its keys into its own home's copy.
@Suite("Shepherd's pi settings")
struct PiSettingsFileTests {
    @Test func shepherdsKeysAreWrittenAndPiPackagesRemovedWhileEverythingElseStays() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data(#"{"defaultProvider":"anthropic","lastChangelogVersion":"0.87.1","packages":["npm:@x/y"],"shellCommandPrefix":"old"}"#.utf8).write(to: url)

        let notes = try PiSettingsFile(url: url).update { settings in
            settings["shellCommandPrefix"] = "new"
            return settings.removeValue(forKey: "packages") == nil ? [] : ["removed"]
        }

        #expect(notes == ["removed"])
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["defaultProvider"] as? String == "anthropic" && written["lastChangelogVersion"] as? String == "0.87.1")
        #expect(written["shellCommandPrefix"] as? String == "new" && written["packages"] == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: dir.path) == ["settings.json"], "the lock is gone")
    }

    @Test func aFileThatIsNotAnObjectIsLeftAlone() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        try Data("[1, 2".utf8).write(to: url)
        let notes = try PiSettingsFile(url: url).update { settings in
            settings["shellCommandPrefix"] = "new"
            return []
        }
        #expect(notes.count == 1)
        #expect(try String(contentsOf: url, encoding: .utf8) == "[1, 2")
    }

    /// Unchanged keys write nothing: pi's own writes aren't raced for nothing.
    @Test func unchangedSettingsAreNotRewritten() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let text = #"{"shellCommandPrefix":"same"}"#
        try Data(text.utf8).write(to: url)
        _ = try PiSettingsFile(url: url).update { settings in
            settings["shellCommandPrefix"] = "same"
            return []
        }
        #expect(try String(contentsOf: url, encoding: .utf8) == text)
    }

    /// A lock pi left behind long ago is taken over; a fresh one is waited for, up to a limit.
    @Test func aStaleLockIsTakenOverAndAFreshOneWaitedFor() throws {
        let dir = try makeScratchDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("settings.json")
        let lock = PiHome.canonical(dir.path) + "/settings.json.lock"
        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -60)], ofItemAtPath: lock)
        _ = try PiSettingsFile(url: url).update { settings in settings["a"] = 1; return [] }
        #expect(!FileManager.default.fileExists(atPath: lock))

        try FileManager.default.createDirectory(atPath: lock, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) {
            _ = try PiSettingsFile(url: url, patience: 0).update { settings in settings["a"] = 2; return [] }
        }
        #expect(FileManager.default.fileExists(atPath: lock), "someone else's lock stays")
    }
}
