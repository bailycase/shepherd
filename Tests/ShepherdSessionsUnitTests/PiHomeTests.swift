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

    // MARK: The launcher

    @Test func theLauncherRunsWithNoStartupFiles() {
        #expect(Self.home.launcherScript.hasPrefix("#!/bin/zsh -f\n"))
    }

    /// Every pi, jiti and Node variable, and OpenSSL's config, is set aside and unset before the
    /// pins, keeping only corporate CAs.
    @Test func theLauncherSetsAsideTheEnvironmentsPiJitiAndNodeVariables() {
        let script = Self.home.launcherScript
        #expect(script.contains("(PI_*|JITI_*|NODE_*|OPENSSL_CONF)"))
        #expect(script.contains(#"export "_SHEPHERD_STASH_$_shepherd_name=${(P)_shepherd_name}""#))
        #expect(script.contains("unset $_shepherd_name"))
        #expect(script.contains(#"export _SHEPHERD_STASH_NAMES="${_shepherd_names[*]}""#))
        #expect(script.contains(#"export NODE_EXTRA_CA_CERTS="$_SHEPHERD_STASH_NODE_EXTRA_CA_CERTS""#))
        // Set aside first, then pinned: a pin is never stashed as the user's.
        let stash = try! #require(script.range(of: "unset $_shepherd_name"))
        let pin = try! #require(script.range(of: "export PI_CODING_AGENT_DIR="))
        #expect(stash.lowerBound < pin.lowerBound)
    }

    @Test(arguments: [
        ("PI_CODING_AGENT_DIR", "'/Users/me/Library/Application Support/Shepherd/pi'"),
        ("PI_PACKAGE_DIR", "'/Apps/Shepherd.app/Contents/Resources/pi-engine'"),
        ("PI_OFFLINE", "'1'"), ("PI_SKIP_VERSION_CHECK", "'1'"), ("PI_TELEMETRY", "'0'"),
        ("PI_SUBAGENTS_TEMP_ROOT", "'/Users/me/Library/Application Support/Shepherd/pi/tmp/pi-subagents'"),
    ])
    func theLauncherPins(_ key: String, _ value: String) {
        #expect(Self.home.launcherScript.contains("\nexport \(key)=\(value)\n"))
    }

    /// An override brings its own package: no `PI_PACKAGE_DIR` is pinned for it.
    @Test func anOverrideEngineGetsNoPackagePin() {
        let home = PiHome(directory: Self.home.directory, engine: PiEngine(command: ["/s/pi-engine"], packageDirectory: nil, version: nil, node: .onPath("node")))
        #expect(!home.launcherScript.contains("PI_PACKAGE_DIR="))
        #expect(home.launcherScript.contains("exec '/s/pi-engine' \"$@\"\n"))
    }

    @Test func theLauncherRefusesPisOwnPackageAndConfigCommands() {
        #expect(Self.home.launcherScript.contains("  (install|remove|uninstall|update|config)\n"))
        #expect(Self.home.launcherScript.contains("exit 2 ;;"))
    }

    /// It execs the engine, or, when a file is missing, says so and exits as a missing command.
    @Test func theLauncherExecsTheEngineOrSaysItIsMissing() {
        let script = Self.home.launcherScript
        #expect(script.contains("if [[ ! -x '/Apps/Shepherd.app/Contents/Helpers/node' || ! -f '/Apps/Shepherd.app/Contents/Resources/pi-engine/dist/bundle/cli.js' ]]; then\n"))
        #expect(script.contains("  exit 127\n"))
        #expect(script.hasSuffix("exec '/Apps/Shepherd.app/Contents/Helpers/node' '/Apps/Shepherd.app/Contents/Resources/pi-engine/dist/bundle/cli.js' \"$@\"\n"))
    }

    /// The bash tool's shell unsets every pin and exports what the launcher set aside, by name.
    @Test func restoringUnsetsThePinsAndExportsTheStash() {
        let script = Self.home.restoreEnvScript
        #expect(script.contains("\nunset PI_CODING_AGENT_DIR PI_PACKAGE_DIR PI_OFFLINE PI_SKIP_VERSION_CHECK PI_TELEMETRY PI_SUBAGENTS_TEMP_ROOT\n"))
        #expect(script.contains(#"for _shepherd_name in $(printf '%s\n' "${_SHEPHERD_STASH_NAMES-}"); do"#))
        #expect(script.contains(#"eval "export $_shepherd_name=\"\${_SHEPHERD_STASH_$_shepherd_name}\"""#))
        #expect(Self.home.shellCommandPrefix == ". '/Users/me/Library/Application Support/Shepherd/pi/restore-env.sh'")
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
