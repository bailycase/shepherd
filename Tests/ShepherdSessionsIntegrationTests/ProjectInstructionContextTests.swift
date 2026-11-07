import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

@Suite("Project instruction context", .integrationTimeLimit)
struct ProjectInstructionContextTests {
    @Test func detailsCapabilityIsOptionalForProjectOnlyHosts() async throws {
        let host = try RemoteHost(); defer { host.stop() }
        host.server.advertisedCapabilities = [RemoteProtocol.projectsV2Capability]
        let client = try await host.typed()
        defer { client.disconnect() }
        guard case .listing = try await client.projects(.list()) else { Issue.record("Project-only host could not list projects"); return }
        do { _ = try await client.projects(.context(directory: "/repo")); Issue.record("Missing details capability was ignored") }
        catch let error as RemoteHostClientError {
            guard case .rejected(let code, _) = error else { Issue.record("Expected unsupported, got \(error)"); return }
            #expect(code == "update_required")
        }
    }

    @Test func contextReadsHostFilesAndTheEditorOpensOnlyAnAllowlistedFile() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let home = scratch.dir.appendingPathComponent("home")
        let root = home.appendingPathComponent("dev/repo")
        let agents = root.appendingPathComponent("AGENTS.md")
        let global = home.appendingPathComponent(".pi/agent/AGENTS.md")
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".shepherd/skills/test"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("global".utf8).write(to: global)
        try Data("project".utf8).write(to: agents)
        try Data("skill".utf8).write(to: root.appendingPathComponent(".shepherd/skills/test/SKILL.md"))
        try Data("{\"mcpServers\":{\"docs\":{}}}".utf8).write(to: root.appendingPathComponent(".shepherd/mcp.json"))
        let opened = await MainActor.run { OpenedProjectFile() }
        let store = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("history.json"), home: home,
                                        sessions: scratch.dir.appendingPathComponent("sessions"), openEditor: { opened.path = try String(contentsOf: $0, encoding: .utf8) })
        let state = ShepherdState(spaces: [Space(name: "repo", path: root.path)])
        let result = try await store.request(.context(directory: root.path), state: state)
        guard case .context(let context) = result else { Issue.record("Missing project context"); return }
        #expect(context.files.contains { $0.displayPath == "~/.pi/agent/AGENTS.md" && $0.isGlobal == true })
        #expect(context.files.last?.displayPath == "~/dev/repo/AGENTS.md")
        #expect(context.resources == 1 && context.mcpServers == 1)
        let text = try await store.request(.read(directory: root.path, file: "AGENTS.md"), state: state)
        guard case .text(let file) = text else { Issue.record("Missing project text"); return }
        #expect(file.modifiedAt != nil)
        _ = try await store.request(.open(directory: root.path, file: "AGENTS.md"), state: state)
        await MainActor.run { #expect(opened.path == "project") }
        do {
            _ = try await store.request(.open(directory: root.path, file: "../AGENTS.md"), state: state)
            Issue.record("Escaping file opened")
        } catch let error as ProjectFileError { #expect(error.code == "invalid_file") }
    }

    /// The Settings form's global values come from Shepherd's pi home, and only the form's keys cross.
    @Test func contextCarriesOnlyTheFormsGlobalSettings() async throws {
        let scratch = try ScratchServer()
        defer { scratch.stop() }
        let home = scratch.dir.appendingPathComponent("home")
        let root = home.appendingPathComponent("dev/repo")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let pi = PiSetup(engine: PiSetup.app.engine, home: scratch.dir.appendingPathComponent("pi"), userHome: home.path)
        try FileManager.default.createDirectory(at: pi.home, withIntermediateDirectories: true)
        try Data(#"{"defaultModel":"demo-model","defaultThinkingLevel":"low","retry":{"maxRetries":5},"apiKeys":{"demo":"secret"}}"#.utf8)
            .write(to: pi.home.appendingPathComponent("settings.json"))
        let store = ProjectSettingsStore(historyURL: scratch.dir.appendingPathComponent("history.json"), home: home,
                                        sessions: scratch.dir.appendingPathComponent("sessions"), pi: pi)
        let state = ShepherdState(spaces: [Space(name: "repo", path: root.path)])
        guard case .context(let context) = try await store.request(.context(directory: root.path), state: state) else { Issue.record("Missing project context"); return }
        let global = try #require(context.globalSettings.flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        #expect(Set(global.keys) == ["defaultModel", "defaultThinkingLevel", "retry"])
    }
}

@MainActor private final class OpenedProjectFile: Sendable { var path: String? }
