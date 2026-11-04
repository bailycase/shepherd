import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The Mac's Settings › Hooks driving another host over `hooks.v1`: the same `HooksModel` reads the
/// host's hooks and a remote thread's glyph, switches one off, adds one to a space, says a stale
/// edit changed in its file and reopens it on Reload, and runs a test there with its output. Every
/// file lives in the scratch host's folder, never the person's home.
@Suite("Remote hooks on the Mac", .integrationTimeLimit)
@MainActor
struct RemoteHooksModelTests {
    @Test func theMacsHooksPageDrivesARemoteHost() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        try await app.start()
        // Real paths, as a host names its spaces (the scratch folder sits behind /var's link).
        let dir = PiHome.canonical(app.dir.path)
        let home = dir + "/host-home", space = dir + "/payments"
        let file = home + "/.shepherd/hooks.json"
        try FileManager.default.createDirectory(atPath: home + "/.shepherd", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: space + "/.git", withIntermediateDirectories: true)
        try #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exit 2"}]}]}}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        app.server.hooks = HookCatalog(home: home, support: app.dir.appendingPathComponent("host-support"))
        try await app.server.addSpace(Space(name: "payments", path: space))

        let tokenURL = app.dir.appendingPathComponent("remote-token")
        let port = try app.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "mac")
        defer { client.disconnect() }
        let id = UUID()
        let host = SettingsHost(id: id, name: "Studio", client: client, capabilities: client.capabilities)
        let model = HooksModel(host: id) { host }
        let root = space

        // The host's hooks, and a remote thread's glyph in its space.
        #expect(model.unavailable == nil)
        model.reload()
        try await eventuallyOnMain("the host's hooks") { model.snapshot != nil && !model.loading }
        #expect(model.home == home && model.hostName == "Studio")
        #expect(model.groups.flatMap(\.rows).map(\.command) == ["exit 2"])
        #expect(model.sections.flatMap(\.files).allSatisfy { $0.action == nil }, "a host's files don't open here")
        model.ensure(cwd: space + "/src")
        #expect(model.indicator(forCwd: space + "/src") == HookIndicator(HookSummary(running: 1), spaceRoot: root))

        // The switch goes to the host; with nothing on, the glyph goes.
        let row = try #require(model.groups.first?.rows.first)
        model.setOn(row, false)
        try await eventuallyOnMain("the hook off on the host") { model.snapshot?.entries.first?.on == false }
        #expect(model.indicator(forCwd: space + "/src") == nil)

        // Add hook in the space writes the host's space file.
        model.add(spaceRoot: space)
        let adding = try #require(model.editor)
        #expect(adding.targetRoot == root)
        adding.event = .stop
        adding.handlers[0].command = "npm test"
        #expect(await adding.save(with: model))
        #expect(model.snapshot?.entries.contains { $0.file == root + "/.shepherd/hooks.json" && $0.handler.command == "npm test" } == true)

        // A hook changed on the host since it was read: said, with Reload, which opens it as it is now.
        let entry = try #require(model.snapshot?.entries.first { $0.file == file })
        model.edit(entry)
        let stale = try #require(model.editor)
        try #"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"exit 3"}]}]}}"#
            .write(toFile: file, atomically: true, encoding: .utf8)
        stale.handlers[0].command = "exit 0"
        #expect(await stale.save(with: model) == false)
        #expect(stale.conflict && stale.problem?.contains("Reload") == true)
        model.reloadEditing(entry)
        try await eventuallyOnMain("Reload to open the hook as the host has it") { model.editor?.entry?.handler.command == "exit 3" }

        // Test runs on the host, in the space, and keeps what the hook printed.
        model.add(spaceRoot: space)
        let testing = try #require(model.editor)
        testing.handlers[0].command = "pwd; echo nope >&2; exit 2"
        testing.test(with: model)
        try await eventuallyOnMain("the host's test result") { testing.testResult != nil }
        let result = try #require(testing.testResult)
        #expect(result.outcome == .blocked(reason: "nope"))
        #expect(HookEditorModel.testMeta(result, event: testing.event, matcher: testing.matcher, host: model.hostName).hasSuffix(" · on Studio"))
        #expect(HookTestOutput(result)?.streams == [.init(label: "stdout", text: root, note: nil), .init(label: "stderr", text: "nope", note: nil)])
    }

    @Test func anOfflineOrOlderHostSaysWhyAndReadsNothing() {
        let id = UUID()
        let offline = HooksModel(host: id) { SettingsHost(id: id, name: "Studio", client: nil, capabilities: []) }
        #expect(offline.unavailable == "Studio is offline. Its hooks show here once it's back.")
        let older = HooksModel(host: id) { SettingsHost(id: id, name: "Studio", client: RemoteHostClient(), capabilities: [RemoteProtocol.skillsCapability]) }
        #expect(older.unavailable == "Studio's Shepherd is too old to share its hooks: update it to change them here.")
        older.reload()
        #expect(!older.loading && older.snapshot == nil)
    }
}
