import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Settings › Hooks over the listener (`hooks.v1`): a client reads a host's hooks and its spaces',
/// switches one off, turns a reader off, adds, edits and deletes with the file guard, tests one on
/// the host, and is refused a file or space the catalog doesn't hold. The host's GUI hears each
/// change. Every file lives in the scratch host's folder, never the person's home.
@Suite("Remote hooks", .integrationTimeLimit)
struct RemoteHooksTests {
    /// A host whose catalog reads a scratch home, with one This Mac hook and a space (a git folder).
    static func host() async throws -> (RemoteHost, home: String, space: String) {
        let host = try RemoteHost()
        let home = host.host.dir.appendingPathComponent("home").path
        let space = host.host.dir.appendingPathComponent("payments").path
        try FileManager.default.createDirectory(atPath: home + "/.shepherd", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: space + "/.git", withIntermediateDirectories: true)
        try #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exit 2","keep":1}]}]}}"#
            .write(toFile: home + "/.shepherd/hooks.json", atomically: true, encoding: .utf8)
        host.server.hooks = HookCatalog(home: home, support: host.host.dir.appendingPathComponent("support"))
        try await host.server.addSpace(Space(name: "payments", path: space))
        return (host, home, space)
    }

    /// The code a host refused with, or nil when it answered.
    static func refusal(_ body: () async throws -> RemoteHooksResult) async -> String? {
        do { _ = try await body(); return nil } catch RemoteHostClientError.rejected(let code, _) { return code } catch { return "\(error)" }
    }

    static func snapshot(_ result: RemoteHooksResult) throws -> HookCatalogSnapshot {
        guard case .hooks(let snapshot) = result else { throw WireError("expected the host's hooks, got \(result)") }
        return snapshot
    }

    @Test func aClientReadsSwitchesAddsEditsAndDeletesTheHostsHooks() async throws {
        let (host, home, space) = try await Self.host()
        defer { host.stop() }
        let heard = Locked<Int>(0)
        host.server.onHooksChanged = { heard.withValue { $0 += 1 } }
        let client = try await host.typed()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.hooksCapability))

        let first = try Self.snapshot(try await client.hooks())
        #expect(first.home == home)
        #expect(first.entries.map(\.handler.command) == ["exit 2"])
        let root = PiHome.canonical(space)
        #expect(HooksPresentation.saveTargets(first, home: home).map(\.root) == [nil, root])

        // The off switch and a reader.
        let entry = try #require(first.entries.first)
        let off = try Self.snapshot(try await client.hooks(.setOn(hash: entry.hash, on: false)))
        #expect(off.entries.first?.on == false)
        let noCodex = try Self.snapshot(try await client.hooks(.setReader(format: .codex, on: false)))
        #expect(noCodex.settings.readers.codex == false)

        // Add to the space's file, which doesn't exist yet.
        let spaceFile = root + "/.shepherd/hooks.json"
        let added = try Self.snapshot(try await client.hooks(.save(drafts: [HookDraft(event: "Stop", handler: .command("npm test"))],
                                                                    file: spaceFile, replacing: nil, kept: nil)))
        #expect(added.entries.first { $0.file == spaceFile }?.handler.command == "npm test")

        // Edit in place keeps the unknown key and the off switch.
        let edited = try Self.snapshot(try await client.hooks(.save(
            drafts: [HookDraft(event: "PreToolUse", matcher: "Bash", handler: HookHandler(raw: entry.handler.raw.with("command", "exit 0")))],
            file: entry.file, replacing: HookRef(entry), kept: 0)))
        let now = try #require(edited.entries.first { $0.file == entry.file })
        #expect(now.handler.command == "exit 0" && now.handler.raw["keep"] == .number(1) && now.on == false)

        // The old hash is gone: a client still holding it is told to reload, and nothing is written.
        #expect(await Self.refusal { try await client.hooks(.delete(HookRef(entry))) } == "hook_changed")
        let deleted = try Self.snapshot(try await client.hooks(.delete(HookRef(now))))
        #expect(!deleted.entries.contains { $0.file == entry.file })
        #expect(deleted.settings.off.isEmpty)

        try await eventually("the GUI to hear all five changes") { heard.current == 5 }
    }

    @Test func aTestRunsOnTheHostAndReadingOrTestingTellsTheGUINothing() async throws {
        let (host, _, space) = try await Self.host()
        defer { host.stop() }
        let heard = Locked<Int>(0)
        host.server.onHooksChanged = { heard.withValue { $0 += 1 } }
        let client = try await host.typed()
        defer { client.disconnect() }
        let root = PiHome.canonical(space)
        let result = try await client.hooks(.test(command: "pwd >&2; exit 2", event: .preToolUse, matcher: "Bash", timeout: 5, root: root))
        guard case .tested(let tested) = result else { Issue.record("expected a test result"); return }
        #expect(tested.exit == 2)
        #expect(tested.outcome == .blocked(reason: root))
        guard case .tested(let slow) = try await client.hooks(.test(command: "sleep 5", event: .stop, matcher: "", timeout: 0.2, root: nil)) else {
            Issue.record("expected a test result"); return
        }
        #expect(slow.outcome == .timedOut)
        _ = try await client.hooks()
        #expect(heard.current == 0)
    }

    /// A client names only the catalog's own JSON files and spaces: never another path on the host.
    @Test func aFileOrSpaceOutsideTheCatalogIsRefused() async throws {
        let (host, home, _) = try await Self.host()
        defer { host.stop() }
        let client = try await host.typed()
        defer { client.disconnect() }
        let elsewhere = host.host.dir.appendingPathComponent("elsewhere.json").path
        let draft = HookDraft(event: "Stop", handler: .command("true"))
        #expect(await Self.refusal { try await client.hooks(.save(drafts: [draft], file: elsewhere, replacing: nil, kept: nil)) } == "not_a_hooks_file")
        #expect(!FileManager.default.fileExists(atPath: elsewhere))
        #expect(await Self.refusal { try await client.hooks(.save(drafts: [draft], file: home + "/.codex/config.toml", replacing: nil, kept: nil)) } == "not_a_hooks_file")
        #expect(await Self.refusal { try await client.hooks(.save(drafts: [HookDraft(event: "Stop", matcher: "(", handler: .command("true"))], file: home + "/.shepherd/hooks.json",
                                         replacing: nil, kept: nil)) } == "invalid_hook")
        #expect(await Self.refusal { try await client.hooks(.test(command: "true", event: .stop, matcher: "", timeout: 1, root: "/tmp")) } == "no_such_space")
    }
}

private extension HookJSON {
    func with(_ key: String, _ value: String) -> HookJSON {
        var copy = self
        copy[key] = .string(value)
        return copy
    }
}
