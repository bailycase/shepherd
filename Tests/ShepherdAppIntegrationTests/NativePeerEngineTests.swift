import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Opt in: SHEPHERD_ENGINE_SMOKE=$PWD/.build/pi-engine swift test --build-system native --filter NativePeerEngineTests
/// Synthetic model traffic only: the existing fake-provider library listens on IPv4 loopback.
@Suite("Native peer spawn and send through shipped pi", .mainActorExclusive,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"] != nil,
                "set SHEPHERD_ENGINE_SMOKE to a staged engine or disposable app"))
@MainActor
struct NativePeerEngineTests {
    /// `read` is the SHEPHERD-MACOS-2 shape: agent_spawn, then agent_read of the new thread,
    /// then agent_send. The relayed read used to corrupt `state.spaces` in the Release build.
    @Test(arguments: ["baseline", "busy-task", "busy-report", "read"])
    func actualSpawnThenSendPreservesWorkspaceAndMenuSnapshots(scenario: String) async throws {
        let reads = scenario == "read"
        let busy = scenario.hasPrefix("busy-")
        let delivery = scenario == "busy-report" ? "report" : "task"
        let expectedTurns = delivery == "task" ? 2 : 1
        let started = ContinuousClock.now
        let deadline = started + .seconds(90)
        let root = try makeScratchDirectory("peer-engine")
        defer { try? FileManager.default.removeItem(at: root) }
        let location = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["SHEPHERD_ENGINE_SMOKE"]))
        let engine = try #require(BundledPiEngine(contents: location) ?? BundledPiEngine(app: location))
        let project = root.appendingPathComponent("project")
        let userHome = root.appendingPathComponent("home")
        for folder in [project, userHome] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let setup = PiSetup(engine: .bundled(engine), home: root.appendingPathComponent("support/pi"), userHome: userHome.path)
        try setup.files.install()
        let library = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/fake-provider.mjs")
        let driver = root.appendingPathComponent("provider.mjs")
        // State comes from the actual tool results in pi's next request, not a synthetic socket client.
        try """
        import { startProvider } from \(String(data: try JSONEncoder().encode(library.absoluteString), encoding: .utf8)!);
        import * as fs from 'node:fs';
        const log = new URL('./requests.jsonl', import.meta.url);
        const cwd = \(String(data: try JSONEncoder().encode(project.path), encoding: .utf8)!);
        const busy = \(busy);
        const reads = \(reads);
        const delivery = '\(delivery)';
        const events = new URL('./events.jsonl', import.meta.url);
        const mark = event => fs.appendFileSync(events, JSON.stringify(event) + '\\n');
        let peerReady, releasePeer;
        let recipientRequests = 0;
        const peerStarted = new Promise(resolve => { peerReady = resolve; });
        const dispatchCompleted = new Promise(resolve => { releasePeer = resolve; });
        const provider = await startProvider({ uniqueIds: true, usage: () => ({input: 20, output: 5}), async onRequest(entry) {
          fs.appendFileSync(log, JSON.stringify(entry) + '\\n');
          if (entry.index >= 15) {
            setImmediate(() => provider.stop());
            return {status: 400, text: 'fixture request bound reached'};
          }
          const input = entry.body?.input ?? [];
          const users = input.filter(x => x.role === 'user');
          if ((entry.body?.tools ?? []).some(x => x.name === 'propose_title')) return {};
          const first = users[0]?.content;
          const opening = users.map(user => typeof user.content === 'string' ? user.content : (user.content ?? []).map(x => x.text ?? '').join('')).find(x => x.startsWith('fixture-parent-start:') || x === 'fixture-peer-opening') ?? ''; 
          if (!opening.startsWith('fixture-parent-start:')) {
            if (opening === 'fixture-peer-opening') {
              peerReady();
              recipientRequests++;
              mark('recipient-request-' + recipientRequests);
              // Keep the actual first model turn active while agent_send queues its follow-up.
              if (busy && recipientRequests === 1) {
                mark('peer-held');
                await dispatchCompleted;
                mark('peer-released');
              }
            }
            return {};
          }
          const results = input.filter(x => x.type === 'function_call_output');
          if (results.some(x => String(x.output).startsWith('Error:'))) return {};
          const spawned = results.map(x => String(x.output)).join('\\n').match(/spawned agent ([^ ]+) /);
          const sent = results.some(x => String(x.output).includes(delivery + ' dispatch requested for agent'));
          if (sent) {
            mark('dispatch-confirmed');
            releasePeer();
            return {};
          }
          if (input.some(x => x.type === 'function_call' && x.name === 'agent_send')) return {};
          if (spawned) await peerStarted;
          const readDone = results.some(x => String(x.output).includes('"messages"'));
          const name = !spawned ? 'agent_spawn' : reads && !readDone ? 'agent_read' : 'agent_send';
          const tools = entry.body.tools ?? [];
          if (!tools.some(x => x.name === name || x.function?.name === name)) {
            if (!tools.some(x => x.name === 'tool_search' || x.function?.name === 'tool_search'))
              return {status: 400, text: 'fixture missing peer tool and tool_search'};
            return {tool: {name: 'tool_search', arguments: {query: name, limit: 1}}};
          }
          return {tool: {name, arguments: !spawned
            ? {cwd, prompt: 'fixture-peer-opening'} : name === 'agent_read'
            ? {agentID: spawned[1], limit:30} : {agentID: spawned[1], text: 'fixture-peer-followup', delivery}}};
        }});
        fs.writeFileSync(new URL('./ready.json', import.meta.url), JSON.stringify({port: provider.port}));
        const stop = async () => { await provider.stop(); process.exit(0); };
        process.stdin.on('end', stop); process.stdin.resume();
        process.on('SIGTERM', stop);
        setTimeout(stop, 90000).unref();
        """.write(to: driver, atomically: true, encoding: .utf8)
        let provider = Process()
        let input = Pipe()
        provider.executableURL = engine.node
        provider.arguments = [driver.path]
        provider.currentDirectoryURL = root
        provider.environment = ["PATH": "/usr/bin:/bin", "HOME": userHome.path]
        provider.standardInput = input
        try provider.run()
        defer {
            try? input.fileHandleForWriting.close()
            if provider.isRunning { provider.terminate() }
            provider.waitUntilExit()
        }
        let ready = root.appendingPathComponent("ready.json")
        try await eventuallyOnMain("the loopback fixture to listen", timeout: .seconds(10)) {
            FileManager.default.fileExists(atPath: ready.path)
        }
        let record = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: ready)) as? [String: Int])
        let port = try #require(record["port"])
        try """
        {"providers":{"fixture":{"baseUrl":"http://127.0.0.1:\(port)/v1","api":"openai-responses","apiKey":"fixture-key","models":[{"id":"fixture","name":"fixture","reasoning":false,"input":["text"],"contextWindow":64000,"maxTokens":1024,"cost":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0}}]}}}
        """.write(to: setup.home.appendingPathComponent("models.json"), atomically: true, encoding: .utf8)
        try #"{"defaultProvider":"fixture","defaultModel":"fixture","retry":{"enabled":false},"compaction":{"enabled":false}}"#
            .write(to: setup.files.settings, atomically: true, encoding: .utf8)
        try "{}".write(to: setup.home.appendingPathComponent("auth.json"), atomically: true, encoding: .utf8)
        let app = try AppHarness(directory: root, pi: setup,
                                 modelCatalog: { ModelListing(models: ["fixture/fixture"], defaultModel: "fixture/fixture") })
        defer { app.stop() }
        app.scratch.useRealPeerCheck()
        // App launches name the process-isolated default socket; ScratchServer binds its own.
        // Alias only inside test isolation, without changing the process environment.
        let socketAlias = ShepherdPaths.socketURL()
        try #require(socketAlias.path.hasPrefix(TestProcess.supportDirectory.path + "/"))
        try #require(!FileManager.default.fileExists(atPath: socketAlias.path))
        try FileManager.default.createSymbolicLink(atPath: socketAlias.path, withDestinationPath: app.scratch.socketPath)
        defer { try? FileManager.default.removeItem(at: socketAlias) }
        let space = Fixture.space("fixture project", path: project.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        defer { vm.threadStores.prune(live: []) }
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                     WorkspaceView(vm: vm).background(MenuStateSync(vm: vm)))
        defer { window.close() }
        let parent = try await vm.startAgent(NewAgentConfig(
            spaceID: space.id, workingDirectory: project.path, model: "fixture/fixture", thinking: .off,
            initialPrompt: "fixture-parent-start: Open a new sidebar peer with fixture-peer-opening, then send it fixture-peer-followup with delivery \(delivery)."),
            focusWindow: false)
        #expect(vm.selectedAgentID == parent)
        var parentSnapshot: NativeThreadSnapshot?
        var peerSnapshot: NativeThreadSnapshot?
        defer {
            print("Fixture parent rows: \(parentSnapshot?.messages.map { "\($0.role):\($0.toolName ?? ""):\($0.blocks.map(\.text).joined().prefix(240))" } ?? [])")
            if let log = try? String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8) {
                for line in log.split(separator: "\n") {
                    if let entry = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                       let body = entry["body"] as? [String: Any] {
                        let items = body["input"] as? [[String: Any]] ?? []
                        let lastResult = items.last { $0["type"] as? String == "function_call_output" }
                        print("Fixture request \(entry["index"] ?? "?"): last tool result \(String(describing: lastResult?["output"] ?? "none").prefix(240))")
                    }
                }
            }
        }
        try await eventuallyAsync("real spawn and send results and recipient completion", timeout: ContinuousClock.now.duration(to: deadline)) {
            ListPerf.settle(window)
            let agents = app.server.state.agents
            if let data = try? Data(contentsOf: root.appendingPathComponent("requests.jsonl")) {
                try #require(data.split(separator: UInt8(ascii: "\n")).count <= 16)
            }
            try #require(agents.count <= 2, "the fixture may create only one peer")
            #expect(vm.selectedAgentID == parent)
            #expect(vm.state.spaces == [space])
            #expect(MenuState.Snapshot(vm).spaces.map(\.id) == [space.id.rawValue])
            if case .snapshot(let snapshot)? = try? await app.server.nativeThread(agentID: parent, request: .snapshot()) {
                parentSnapshot = snapshot
            }
            guard let peer = agents.first(where: { $0.id != parent }) else { return false }
            if case .snapshot(let snapshot)? = try? await app.server.nativeThread(agentID: peer.id, request: .snapshot()) {
                peerSnapshot = snapshot
            }
            let messages = parentSnapshot?.messages ?? []
            try #require(!messages.contains { $0.isError == true }, "real pi tool error: \(messages.filter { $0.isError == true })")
            return parentSnapshot?.running == false && peerSnapshot?.running == false
                && messages.contains { $0.toolName == "agent_spawn" && $0.isError != true && $0.blocks.map(\.text).joined().contains("spawned agent \(peer.id)") }
                && messages.contains { $0.toolName == "agent_send" && $0.isError != true && $0.blocks.map(\.text).joined().contains("\(delivery) dispatch requested") }
                && (peerSnapshot?.messages.filter { $0.role == "assistant" }.count ?? 0) == expectedTurns
                && (delivery == "report" || peerSnapshot?.messages.contains { $0.role == "user" && $0.blocks.map(\.text).joined().contains("fixture-peer-followup") } == true)
                && peerSnapshot?.messages.last?.role == "assistant"
                && peerSnapshot?.messages.last?.blocks.first?.text == "ok"
                && vm.menuState.agents.count == 2
        }
        let peer = try #require(vm.state.agents.first { $0.id != parent })
        let received = try #require(peerSnapshot)
        #expect(received.messages.filter { $0.role == "user" && $0.blocks.map(\.text).joined() == "fixture-peer-opening" }.count == 1)
        #expect(received.messages.filter { $0.role == "user" && $0.blocks.map(\.text).joined().contains("fixture-peer-followup") }.count == (delivery == "task" ? 1 : 0))
        #expect(received.messages.filter { $0.role == "assistant" }.count == expectedTurns)
        #expect(received.messages.filter { $0.role == "assistant" }.allSatisfy { $0.blocks.map(\.text).joined() == "ok" && $0.isError != true })
        #expect(received.provisional.isEmpty)
        #expect(received.queue?.items.isEmpty != false)
        #expect(parentSnapshot?.messages.filter { $0.toolName == "agent_spawn" }.count == 1)
        #expect(parentSnapshot?.messages.filter { $0.toolName == "agent_send" }.count == 1)
        if reads {
            let read = try #require(parentSnapshot?.messages.first { $0.toolName == "agent_read" })
            #expect(read.isError != true)
            #expect(read.blocks.map(\.text).joined().contains("fixture-peer-opening"))
        }
        let events = try String(contentsOf: root.appendingPathComponent("events.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONDecoder().decode(String.self, from: Data($0.utf8)) }
        #expect(events.filter { $0.hasPrefix("recipient-request-") }.count == expectedTurns)
        #expect(events.filter { $0 == "dispatch-confirmed" }.count == 1)
        if busy {
            #expect(events.filter { !$0.hasPrefix("recipient-request-") } == ["peer-held", "dispatch-confirmed", "peer-released"])
        }
        if delivery == "report" {
            let file = try #require(PiSessionFile.file(sessionID: peer.effectivePiSessionID, cwd: project.path, sessionsRoot: setup.sessionsRoot))
            let entries = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
                .map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
            let reports = entries.filter { $0["type"] as? String == "custom_message" && $0["customType"] as? String == "shepherd-peer-report" }
            #expect(reports.count == 1)
            #expect(reports.first?["display"] as? Bool == false)
            let content = String(describing: reports.first?["content"] ?? "")
            #expect(content.contains("fixture-peer-followup"))
        }
        #expect(vm.state.agents.count == 2)
        #expect(vm.selectedAgentID == parent)
        #expect(vm.visibleSpaces.map(\.id) == [space.id])
        #expect(vm.state.spaces == [space])
        #expect(Set(vm.menuState.agents.map(\.id)) == Set([parent, peer.id].map { "\(SidebarRowID.local($0))" }))
        #expect(app.scratch.broadcasts.withValue { $0.allSatisfy { $0.agents.count <= 2 } })
        let requests = try String(contentsOf: root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            .split(separator: "\n").map { try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any] }
        #expect(requests.count <= 16)
        #expect(requests.allSatisfy { ($0["body"] as? [String: Any])?["model"] as? String == "fixture" })
        #expect(started.duration(to: .now) <= .seconds(90))
        #expect(parentSnapshot?.stats?.cost == 0)
        #expect(peerSnapshot?.stats?.cost == 0)
        // A task has settled in the native queue; a report's append receipt has arrived.
        // Neither may leave a permanent move fence after real engine delivery.
        let destinationPath = root.appendingPathComponent("moved")
        try FileManager.default.createDirectory(at: destinationPath, withIntermediateDirectories: true)
        let destination = Space(name: "Moved", path: destinationPath.path)
        try await app.server.addSpace(destination)
        try await eventuallyAsync("the delivered peer message and final turn capture to settle") {
            do { try await vm.moveThread(peer.id, to: destination.id); return true }
            catch let error as ProjectFileError where error.code == "thread_active" { return false }
        }
        #expect(app.server.state.agents.first { $0.id == peer.id }?.spaceID == destination.id)
        print("NativePeerEngineTests \(scenario): \(requests.count) loopback requests; real agent_spawn + agent_send finalized; \(expectedTurns) recipient turns; events \(events); two native peers; parent selection and menu spaces intact")
    }
}
