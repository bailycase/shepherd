import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
@testable import ShepherdSessions

/// Explicit opt-in. The caller supplies an isolated, access-token-only auth file, never a live
/// home or refresh token. The server, launcher, Pi processes, MCP transport and model are real.
@Suite("Spec Kit real-model acceptance", .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_SPECKIT_LIVE_AUTH"] != nil))
struct SpecKitLiveTests {
    @Test(.timeLimit(.minutes(30)))
    func upstreamWorkflowUsesOwnedChildrenThroughTheNativeServer() async throws {
        let env = ProcessInfo.processInfo.environment
        let engine = try #require(EngineSmoke.engine)
        let source = URL(fileURLWithPath: try #require(env["SHEPHERD_SPECKIT_LIVE_AUTH"]))
        let python = try #require(env["SHEPHERD_TEST_SPECKIT_PYTHON"])
        let model = env["SHEPHERD_SPECKIT_LIVE_MODEL"] ?? "openai-codex/gpt-6.1-sol"
        let root = source.deletingLastPathComponent()
        try #require(root.path.hasPrefix("/tmp/shepherd-speckit-live-"))
        let files = FileManager.default
        let auth = try Data(contentsOf: source)
        let credentials = try #require(JSONSerialization.jsonObject(with: auth) as? [String: [String: Any]])
        try #require(credentials.count == 1 && credentials["openai-codex"]?["type"] as? String == "oauth")
        try #require(credentials["openai-codex"]?["refresh"] as? String == "disabled-for-live-acceptance")
        let expires = try #require(credentials["openai-codex"]?["expires"] as? Double)
        try #require(expires > Date().timeIntervalSince1970 * 1000 + 60_000, "Access token expired; the test never refreshes a live login")
        let home = PiHome(directory: root.appendingPathComponent("pi"), engine: .bundled(engine), userHome: root.appendingPathComponent("user").path)
        let project = root.appendingPathComponent("project")
        for folder in [project, URL(fileURLWithPath: home.userHome)] { try files.createDirectory(at: folder, withIntermediateDirectories: true) }
        try home.install()
        let authFile = home.directory.appendingPathComponent("auth.json")
        try PiHome.write(auth, to: authFile, mode: 0o600)
        try files.removeItem(at: source)
        defer { try? files.removeItem(at: authFile) }
        var environment = ["HOME": home.userHome, "PATH": home.directory.appendingPathComponent("bin").path + ":/usr/bin:/bin:/usr/sbin:/sbin"]
        let fixture = EngineSmoke.repository.appendingPathComponent("Tests/Extensions/fixtures/speckit-contract.py")
        let setup = try EngineSmoke.runTool(python, [fixture.path, "setup", project.path], environment: environment)
        try #require(setup.status == 0, "Upstream Spec Kit setup failed: \(setup.output)")
        try JSONSerialization.data(withJSONObject: [PiHome.canonical(project.path): true]).write(to: home.directory.appendingPathComponent("trust.json"))
        let hook = project.appendingPathComponent(".pi/prompts/speckit.fixture.record.md")
        try """
            ---
            description: Registered acceptance hook
            ---
            Record hook completion by appending one line to upstream-hooks.txt using Bash.
            Call the available MCP fixture echo tool with text SPECKIT_LIVE_MCP_OK and verify its reply.
            Never read credentials, auth files, or the Pi home. Reply briefly when done.

            """.write(to: hook, atomically: true, encoding: .utf8)
        let mcp: [String: Any] = ["mcpServers": ["fixture": ["command": engine.node.path,
            "args": [EngineSmoke.repository.appendingPathComponent("Tests/Extensions/fixtures/fake-mcp-stdio.mjs").path],
            "env": ["PRIVATE_TOKEN": "${SHEPHERD_MCP_SECRET_FIXTURE}", "FAKE_MCP_LOG": project.appendingPathComponent("live-mcp.jsonl").path]]]]
        try JSONSerialization.data(withJSONObject: mcp).write(to: home.directory.appendingPathComponent("mcp.json"))
        var settings = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: home.settings)) as? [String: Any])
        settings["retry"] = ["enabled": false]
        try JSONSerialization.data(withJSONObject: settings).write(to: home.settings)
        let guardFile = root.appendingPathComponent("live-guard.ts")
        try """
            import fs from "node:fs";
            export default pi => {
              for (const event of ["input", "before_agent_start", "agent_start", "agent_end"])
                pi.on(event, () => { fs.appendFileSync(\(String(reflecting: project.appendingPathComponent("live-events.txt").path)), event + "\\n"); });
              pi.on("tool_call", event => {
                if (/auth\\.json|codex-auth|refresh.token/i.test(JSON.stringify(event.input)))
                  return { block: true, reason: "Acceptance tests never read credentials through tools" };
              });
            }
            """.write(to: guardFile, atomically: true, encoding: .utf8)

        let host = try ScratchServer(dir: root, pi: PiSetup(engine: .bundled(engine), home: home.directory, userHome: home.userHome))
        host.useRealPeerCheck()
        defer { host.stop(keepFiles: true) }
        let bridge = EngineSmoke.repository.appendingPathComponent("Extensions/shepherd-children.ts")
        let status = EngineSmoke.repository.appendingPathComponent("Extensions/shepherd-status.ts")
        let publisher = EngineSmoke.repository.appendingPathComponent("Extensions/shepherd-subagents.ts")
        let agentID = AgentID()
        environment.merge(["SHEPHERD_AGENT_ID": agentID.rawValue, "SHEPHERD_SOCKET": root.appendingPathComponent("s.sock").path,
                           "SHEPHERD_EXT_CHILDREN": bridge.path, "SHEPHERD_NATIVE_CHILDREN": "0",
                           "SHEPHERD_MCP_SECRET_FIXTURE": "acceptance-local-fixture", "SHEPHERD_MCP_SECRETS": "SHEPHERD_MCP_SECRET_FIXTURE"]) { _, new in new }
        let sessionID = UUID().uuidString.lowercased()
        let folder = home.sessionDirectory(forCwd: project.path)
        try files.createDirectory(at: folder, withIntermediateDirectories: true)
        let sessionFile = folder.appendingPathComponent("2026-10-24T00-00-00-000Z_\(sessionID).jsonl")
        let header: [String: Any] = ["type": "session", "version": 3, "id": sessionID, "timestamp": "2026-10-24T00:00:00.000Z", "cwd": PiHome.canonical(project.path)]
        try (JSONSerialization.data(withJSONObject: header) + Data("\n".utf8)).write(to: sessionFile)
        let command = try PiLaunch.agent(home: home, cwd: project.path, sessionID: sessionID, model: model, thinking: "minimal",
                                        extensions: [status.path, bridge.path, publisher.path, "builtin:mcp", guardFile.path])
        let session = try await host.server.createSession(params: CreateSessionParams(cwd: project.path, command: command.argv, env: environment, runtime: .rpc), resuming: sessionID)
        let space = Space(name: "Spec Kit acceptance", path: project.path)
        try await host.server.addSpace(space)
        let pane = LeafPane(sessionID: session.id, cwd: project.path)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: agentID, name: "Spec Kit acceptance", spaceID: space.id, tabID: tab.id, paneID: pane.id)
        try await host.server.addAgent(agent, withTab: tab)
        let pi = PiAgent(host: host, agent: agent, sessionID: session.id, log: root.appendingPathComponent("unused.log"))
        let ready = try await pi.snapshot("live provider bootstrap", timeout: .seconds(30)) { $0.model != nil && $0.stats != nil }
        let driver = EngineSmoke.repository.appendingPathComponent("Tests/Extensions/fixtures/speckit-live.py")
        let shell = [python, driver.path, project.path, model].map(PiLaunch.quoted).joined(separator: " ")
        let dispatched = try await pi.send("""
            Run this exact command once with the Bash tool, timeout 1800 seconds: \(shell)
            It runs an upstream Spec Kit acceptance workflow in this disposable repository.
            Do not implement the feature yourself, start other helpers, change the command, or read credentials.
            The registered hook must use the MCP fixture. Report the command's result briefly.
            """, from: ready)
        if case .failure(let code, let message) = dispatched { throw CommandFailure(code, message) }
        FileHandle.standardOutput.write(Data("Spec Kit live: native server accepted the workflow prompt\n".utf8))
        let reportURL = project.appendingPathComponent("live-report.json")
        var completedSteps = 0
        var totalCost = 0.0
        try await eventually("the complete real-model Spec Kit workflow", timeout: .seconds(28 * 60), poll: .milliseconds(500)) {
            totalCost = try Self.reportedCost(in: root)
            try #require(totalCost < 10, "Acceptance test reached its $10 reported model-cost cap")
            let snapshot = try #require(try await pi.request(.snapshot()).snapshotValue)
            let state: [String: Any] = ["running": snapshot.running, "messages": snapshot.messages.count,
                                        "dialogs": snapshot.dialogs.map(\.title), "reported_cost": totalCost]
            try JSONSerialization.data(withJSONObject: state).write(to: root.appendingPathComponent("live-state.json"))
            if let data = try? Data(contentsOf: reportURL), let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                let steps = report["steps"] as? [[String: Any]] ?? []
                if steps.count != completedSteps {
                    completedSteps = steps.count
                    FileHandle.standardOutput.write(Data("Spec Kit live: \(steps.last?["step"] ?? "unknown") \(steps.last?["status"] ?? "unknown"), reported cost $\(String(format: "%.3f", totalCost))\n".utf8))
                }
                try #require(report["error"] == nil, "Workflow failed. Inspect \(project.path)/live-*.txt and live-report.json")
                if report["complete"] as? Bool == true && !snapshot.running { return true }
            }
            if !snapshot.running && snapshot.messages.contains(where: { $0.role == "assistant" }) {
                throw CommandFailure("Spec Kit live workflow", "Agent settled before acceptance completed. Inspect \(sessionFile.path)")
            }
            return false
        }
        let report = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reportURL)) as? [String: Any])
        #expect(report["acceptance"] as? String == "passed")
        let calls = try String(contentsOf: project.appendingPathComponent("live-mcp.jsonl"), encoding: .utf8)
        #expect(calls.contains("tools/call") && calls.contains("SPECKIT_LIVE_MCP_OK"))
        let childDirectory = root.appendingPathComponent("children")
        let children = try files.contentsOfDirectory(at: childDirectory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("native-") }
        #expect(children.count >= 8)
        let summary: [String: Any] = ["model": model, "reported_cost": totalCost, "owned_children": children.count,
                                     "native_server_peer_check": "real", "helper_tools_enabled": false, "acceptance": "passed"]
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("acceptance-summary.json"))
        print("Spec Kit live acceptance passed: \(children.count) owned children; reported cost $\(String(format: "%.3f", totalCost)); artifacts \(root.path)")
    }

    private static func reportedCost(in root: URL) throws -> Double {
        guard let entries = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return 0 }
        var total = 0.0
        for case let file as URL in entries where file.pathExtension == "jsonl" && file.lastPathComponent != "live-mcp.jsonl" {
            guard let data = try? Data(contentsOf: file) else { continue }
            for line in data.split(separator: 10) {
                guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                      let message = entry["message"] as? [String: Any], message["role"] as? String == "assistant",
                      let usage = message["usage"] as? [String: Any], let cost = usage["cost"] as? [String: Any] else { continue }
                total += cost["total"] as? Double ?? 0
            }
        }
        return total
    }
}
