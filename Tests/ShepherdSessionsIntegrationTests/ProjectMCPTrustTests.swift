import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite("Project MCP approval through real Pi RPC", .integrationTimeLimit,
       .enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a staged engine"))
struct ProjectMCPTrustTests {
    @Test func approvalRejectsAFolderRetargetedAfterValidation() async throws {
        let engine = try #require(EngineSmoke.engine)
        let root = try makeScratchDirectory("trust-swap")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = FileManager.default
        let project = root.appendingPathComponent("project")
        let other = root.appendingPathComponent("other")
        let userHome = root.appendingPathComponent("home")
        for directory in [project, other, userHome] { try files.createDirectory(at: directory, withIntermediateDirectories: true) }
        let canonical = PiHome.canonical(project.path)
        try files.moveItem(at: project, to: root.appendingPathComponent("original"))
        try files.createSymbolicLink(at: project, withDestinationURL: other)
        let setup = PiSetup(engine: .bundled(engine), home: root.appendingPathComponent("support/pi"), userHome: userHome.path)
        let service = ProjectMCPService(pi: setup)
        await #expect(throws: ProjectFileError.self) {
            _ = try await service.request(directory: project.path, file: ".shepherd/mcp.json", text: "{}", action: .approveProject,
                                          owner: nil, canonicalDirectory: canonical)
        }
        #expect(!files.fileExists(atPath: setup.home.appendingPathComponent("trust.json").path))
    }

    @Test func approvalUnblocksNewThreadsWithoutApprovingHomeOrSiblingProjects() async throws {
        let engine = try #require(EngineSmoke.engine)
        let fixture = try await RealPi.launch(engine: engine)
        defer { fixture.stop() }
        _ = try await fixture.ready()
        let root = fixture.host.dir
        let project = root.appendingPathComponent("project").standardizedFileURL.resolvingSymlinksInPath()
        let userHome = root.appendingPathComponent("home")
        let home = PiHome(directory: root.appendingPathComponent("support/pi"), engine: .bundled(engine), userHome: userHome.path)
        let files = FileManager.default
        let config = project.appendingPathComponent(".shepherd")
        try files.createDirectory(at: config, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("mcp-calls.jsonl")
        let marker = root.appendingPathComponent("project-extension-ran")
        let server = EngineSmoke.repository.appendingPathComponent("Tests/Extensions/fixtures/fake-mcp-stdio.mjs")
        let mcp: [String: Any] = ["mcpServers": ["probe": ["command": engine.node.path, "args": [server.path],
                                                               "env": ["FAKE_MCP_LOG": log.path], "exposure": "deferred"]]]
        try files.createDirectory(at: config.appendingPathComponent("extensions"), withIntermediateDirectories: true)
        try "import fs from 'node:fs'; fs.writeFileSync(\(String(reflecting: marker.path)), 'ran'); export default function() {}"
            .write(to: config.appendingPathComponent("extensions/mark.ts"), atomically: true, encoding: .utf8)
        let probe = root.appendingPathComponent("probe.ts")
        try "export default function(pi) { pi.on('session_start', () => pi.setActiveTools([...new Set([...pi.getActiveTools(), 'codemode', 'tool_search'])])); }"
            .write(to: probe, atomically: true, encoding: .utf8)
        let state = fixture.host.server.state
        #expect(ProjectSettingsStore.directories(in: state).contains { PiHome.canonical($0.0) == PiHome.canonical(project.path) })
        let store = fixture.host.server.projects
        _ = try await store.request(.files(directory: project.path), state: state)
        func approval(_ action: ProjectMCPAction, directory: URL = project) async throws -> ProjectMCPResult {
            guard case .mcp(let result) = try await store.request(.mcp(directory: directory.path, file: ".shepherd/mcp.json", action: action), state: state) else {
                throw ProjectFileError("protocol", "Expected MCP reply")
            }
            return result
        }
        func thread(in directory: URL = project) async throws -> PiAgent {
            let id = UUID().uuidString.lowercased()
            let folder = home.sessionDirectory(forCwd: directory.path)
            try files.createDirectory(at: folder, withIntermediateDirectories: true)
            let sessionFile = folder.appendingPathComponent("2026-10-01T00-00-00-000Z_\(id).jsonl")
            let header: [String: Any] = ["type": "session", "version": 3, "id": id, "timestamp": "2026-10-01T00:00:00.000Z", "cwd": PiHome.canonical(directory.path)]
            try (JSONSerialization.data(withJSONObject: header, options: [.sortedKeys]) + Data("\n".utf8)).write(to: sessionFile)
            let line = try PiLaunch.agent(home: home, cwd: directory.path, sessionID: id, model: "fixture/fixture", thinking: nil,
                                          extensions: ["builtin:mcp", "builtin:tool-search", "builtin:codemode", probe.path],
                                          untrustedProject: PiLaunch.isHomeFolder(directory.path, userHome: userHome.path))
            let session = try await fixture.host.server.createSession(params: .init(cwd: directory.path, command: line.argv,
                env: ["HOME": userHome.path, "TMPDIR": root.appendingPathComponent("tmp").path + "/", "PATH": "/usr/bin:/bin:/usr/sbin:/sbin"], runtime: .rpc), resuming: id)
            let space = try #require(state.spaces.first)
            let pane = LeafPane(sessionID: session.id, cwd: directory.path)
            let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
            let agent = Agent(name: "MCP probe", spaceID: space.id, tabID: tab.id, paneID: pane.id)
            try await fixture.host.server.addAgent(agent, withTab: tab)
            return PiAgent(host: fixture.host, agent: agent, sessionID: session.id, log: log)
        }
        func probeTools(_ agent: PiAgent) async throws -> NativeThreadSnapshot {
            let ready: NativeThreadSnapshot
            do { ready = try await agent.snapshot("real Pi ready") { !$0.piSessionID.isEmpty && $0.commands != nil && $0.model != nil } }
            catch {
                let snapshot = try? await agent.request(.snapshot()).snapshotValue
                throw CommandFailure("MCP RPC startup", "\(error); problem \(String(describing: snapshot?.startProblem)); messages \(snapshot?.messages.flatMap(\.blocks).map(\.text).joined() ?? "none")")
            }
            _ = try await agent.send("mcp probe", from: ready)
            return try await agent.snapshot("MCP discovery and call finish", timeout: .seconds(30)) {
                !$0.running && $0.messages.last?.blocks.first?.text == "tool done"
            }
        }
        func output(_ snapshot: NativeThreadSnapshot, tool: String) -> String {
            snapshot.messages.filter { $0.toolName == tool }.flatMap(\.blocks).map(\.text).joined()
        }

        #expect(try await approval(.credentials).projectTrusted == false, "A missing native MCP file still reports approval")
        try "{}".write(to: config.appendingPathComponent("mcp.json"), atomically: true, encoding: .utf8)
        #expect(try await approval(.credentials).projectTrusted == false, "An empty object is valid for approval checks")
        try JSONSerialization.data(withJSONObject: mcp).write(to: config.appendingPathComponent("mcp.json"))
        #expect(try await approval(.credentials).projectTrusted == false)
        #expect(!files.fileExists(atPath: marker.path), "Checking approval executes no project resource")
        let blocked = try await probeTools(thread())
        #expect(output(blocked, tool: "tool_search").contains("mcp__probe__echo") == false)
        #expect(output(blocked, tool: "codemode").contains("\"mcpNames\":[]"))
        #expect(!files.fileExists(atPath: marker.path) && !files.fileExists(atPath: log.path))

        try JSONEncoder().encode([PiHome.canonical(project.path): false]).write(to: home.directory.appendingPathComponent("trust.json"))
        #expect(try await approval(.credentials).projectTrusted == false, "Pi's saved denial remains blocked until explicit approval")
        let tokenURL = root.appendingPathComponent("remote-token")
        let port = try fixture.host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let client = RemoteHostClient()
        defer { client.disconnect() }
        _ = try await client.connect(host: "127.0.0.1", port: port,
            token: String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), clientName: "mcp-approval-test")
        #expect(client.capabilities.contains(RemoteProtocol.projectTrustCapability))
        guard case .mcp(let approvalResult) = try await client.projects(.mcp(directory: project.path, file: ".shepherd/mcp.json", action: .approveProject)) else {
            Issue.record("Expected project approval reply"); return
        }
        #expect(approvalResult.projectTrusted == true)
        #expect(!files.fileExists(atPath: marker.path), "Saving approval loads no project extensions")
        let trustData = try Data(contentsOf: home.directory.appendingPathComponent("trust.json"))
        let trust = try #require(try JSONSerialization.jsonObject(with: trustData) as? [String: Bool])
        #expect(trust == [PiHome.canonical(project.path): true], "No parent, sibling or global approval")
        let approved = try await probeTools(thread())
        #expect(output(approved, tool: "tool_search").contains("mcp__probe__echo"))
        #expect(output(approved, tool: "codemode").contains("echo: approved scratch project"))
        #expect(files.fileExists(atPath: marker.path))
        let calls = try String(contentsOf: log, encoding: .utf8)
        #expect(calls.contains("tools/list") && calls.contains("tools/call"))

        // A fresh project is still undecided, even after another project's approval.
        let sibling = root.appendingPathComponent("sibling")
        try files.createDirectory(at: sibling.appendingPathComponent(".shepherd"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: mcp).write(to: sibling.appendingPathComponent(".shepherd/mcp.json"))
        let other = try await probeTools(thread(in: sibling))
        #expect(output(other, tool: "codemode").contains("\"mcpNames\":[]"))

        // Even a saved home approval plus Pi's global "always" default cannot override
        // Shepherd's --no-approve protection. All files here are isolated scratch data.
        try files.createDirectory(at: userHome.appendingPathComponent(".shepherd"), withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: mcp).write(to: userHome.appendingPathComponent(".shepherd/mcp.json"))
        try JSONSerialization.data(withJSONObject: [project.path: true, PiHome.canonical(userHome.path): true])
            .write(to: home.directory.appendingPathComponent("trust.json"))
        var settings = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        settings["defaultProjectTrust"] = "always"
        try JSONSerialization.data(withJSONObject: settings).write(to: home.settings)
        let inHome = try await probeTools(thread(in: userHome))
        #expect(output(inHome, tool: "codemode").contains("\"mcpNames\":[]"))
        await #expect(throws: ProjectFileError.self) { try await approval(.approveProject, directory: userHome) }
    }
}
