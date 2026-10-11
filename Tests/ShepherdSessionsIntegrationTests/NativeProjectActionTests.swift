import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

@Suite("Native typed Project action producer", .integrationTimeLimit)
struct NativeProjectActionTests {
    @Test func realToolResultRetainsOnlyTypedIdentityLiveSettledReconnectedAndReplayed() async throws {
        let rig = try ProjectRuntimeTests.Rig(); defer { rig.stop() }
        let created = try await rig.create()
        let operation = UUID()
        let project = try await rig.perform(created.id, .assign(operationID: operation, spaceID: try #require(created.linkedSpaces.first?.spaceID), title: "Not an identity", prompt: "hang"))
        let task = try #require(project.tasks.first { $0.operationID == operation })
        let expected = NativeProjectAction(projectID: project.id, revision: project.revision, operationID: operation, taskID: task.id)
        let ownerText = String(decoding: try JSONEncoder().encode(project), as: UTF8.self)
        let result: [String: Any] = ["toolName": "project_assign", "content": [["type": "text", "text": ownerText]],
                                    "details": ["projectID": project.id.rawValue, "revision": project.revision,
                                                "operationID": operation.uuidString, "taskID": task.id.rawValue, "private": "must not be retained"], "isError": false]
        try JSONSerialization.data(withJSONObject: result).write(to: rig.host.dir.appendingPathComponent("project-tool-result.json"))
        let history = rig.host.dir.appendingPathComponent("replay.json")
        let pi = try await PiAgent.launch(on: rig.host, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let idle = try await pi.ready()
        _ = try await pi.send("project-action", from: idle)
        let live = try await pi.snapshot("typed live tool receipt") { $0.provisional.contains { $0.projectAction != nil } }
        let row = try #require(live.provisional.first { $0.projectAction != nil })
        #expect(row.projectAction == expected && row.toolName == "project_assign")
        #expect(row.blocks.first?.text == ownerText, "Ordinary tool text is preserved, not rewritten into card prose")
        let encoded = String(decoding: try JSONEncoder().encode(row), as: UTF8.self)
        #expect(!encoded.contains("must not be retained"))
        pi.release(1)
        let settled = try await pi.snapshot("settled get_messages receipt") { !$0.running && $0.messages.contains { $0.projectAction != nil } }
        #expect(settled.messages.first { $0.projectAction != nil }?.projectAction == expected)
        _ = try await pi.waitForStdin("get_messages", count: 2)
        let tokenURL = rig.host.dir.appendingPathComponent("token")
        let port = try rig.host.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let client = RemoteHostClient(); defer { client.disconnect() }
        for _ in 0..<2 {
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: "viewer")
            let reply = try await client.nativeThread(agentID: pi.agent.id, request: .snapshot())
            #expect(reply.snapshotValue?.messages.first { $0.projectAction != nil }?.projectAction == expected)
            client.disconnect()
        }
        let replay = try await PiAgent.launch(on: rig.host, env: ["STUB_PI_MESSAGES_FILE": history.path])
        let restored = try await replay.ready()
        #expect(restored.messages.first { $0.projectAction != nil }?.projectAction == expected)
    }
}
