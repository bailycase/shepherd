import Darwin
import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The local socket (`host.sock`): the app as a background host's client. This test process runs
/// the same code as the server it talks to, so it gets past the peer check; a system binary
/// (signed by Apple, not as this code) is refused before its `hello` is read. Sockets live under
/// the scratch server's short folder.
@Suite("Local listener", .integrationTimeLimit)
struct LocalListenerTests {
    struct Local {
        let host: ScratchServer
        let path: String
        let token: String

        init() throws {
            host = try ScratchServer.fresh()
            path = host.dir.appendingPathComponent("h.sock").path
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            try host.server.startLocalListener(path: path, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func client() async throws -> (RemoteHostClient, ShepherdState) {
            let client = RemoteHostClient(localSocket: path)
            let state = try await client.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            return (client, state)
        }
    }

    @Test func theAppConnectsReadsStateSendsToAThreadAndAttachesATerminal() async throws {
        let local = try Local()
        defer { local.host.stop() }
        var mode = stat()
        #expect(stat(local.path, &mode) == 0 && mode.st_mode & 0o777 == 0o600)
        let pi = try await PiAgent.launch(on: local.host)
        let shell = try await local.host.shell("echo LOCAL_MARKER; cat")
        try await local.host.waitForScreen(shell.id, toContain: "LOCAL_MARKER")

        let (client, state) = try await local.client()
        defer { client.disconnect() }
        #expect(client.capabilities.contains(RemoteProtocol.localCapability))
        #expect(state.agents.contains { $0.id == pi.agent.id })

        // A thread send, as the app's composer sends it.
        let ready = try await pi.ready()
        let operation = UUID()
        let sent = try await client.nativeThread(agentID: pi.agent.id, request: .send(
            expectedSessionID: ready.piSessionID, generation: ready.generation, operationID: operation,
            text: "hello from the app", delivery: .followUp, images: nil))
        #expect(sent == .accepted(operationID: operation))
        _ = try await pi.snapshot("the sent turn") { snapshot in
            snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == "hello from the app" } }
        }

        // A terminal: its replay, then live input.
        let received = Locked(Data())
        client.onOutput = { id, data in if id == shell.id { received.withValue { $0.append(data) } } }
        _ = try await client.attach(sessionID: shell.id, cols: 100, rows: 30)
        try await eventually("the replay") { String(decoding: received.current, as: UTF8.self).contains("LOCAL_MARKER") }
        client.write(sessionID: shell.id, data: Data("typed-locally\n".utf8))
        try await eventually("the echoed input") { String(decoding: received.current, as: UTF8.self).contains("typed-locally") }
    }

    @Test func onlyTheLocalSocketOffersLocalAndClosingTheTCPListenerKeepsIt() async throws {
        let local = try Local()
        defer { local.host.stop() }
        let port = try local.host.server.startRemoteListener(port: 0, tokenURL: local.host.dir.appendingPathComponent("remote-token"))
        let remote = RemoteHostClient()
        _ = try await remote.connect(host: "127.0.0.1", port: port, token: local.token, clientName: "iPhone")
        defer { remote.disconnect() }
        #expect(!remote.capabilities.contains(RemoteProtocol.localCapability))

        let (client, _) = try await local.client()
        defer { client.disconnect() }
        local.host.server.stopRemoteListener()
        // Still served after the TCP listener closed: the host answers, here that there is no such agent.
        do {
            _ = try await client.nativeThread(agentID: AgentID(), request: .snapshot())
            Issue.record("expected the host to refuse an unknown agent")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "native_unavailable")
        }

        // A wrong token is refused like on TCP.
        let stranger = RemoteHostClient(localSocket: local.path)
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await stranger.connect(host: "", port: 0, token: "not-the-token", clientName: "Shepherd")
        }
    }

    @Test func aProcessSignedAsSomethingElseIsRefusedBeforeHello() async throws {
        let local = try Local()
        defer { local.host.stop() }
        let nc = Process()
        nc.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
        nc.arguments = ["-U", local.path]
        let input = Pipe(), output = Pipe()
        nc.standardInput = input
        nc.standardOutput = output
        nc.standardError = FileHandle.nullDevice
        try nc.run()
        defer { if nc.isRunning { nc.terminate() } }
        // The right token: only the code check can refuse it.
        let hello = try NDJSON.encode(RemoteRequest.hello(id: 1, token: local.token, clientName: "agent",
                                                          protocolVersion: RemoteProtocol.version))
        try input.fileHandleForWriting.write(contentsOf: hello)
        // Accepted, it would answer and wait on stdin, which stays open: refused, it is closed.
        try await eventually("the host to close the connection") { !nc.isRunning }
        #expect(nc.terminationStatus == 0, "it connected (nc exits 1 when it can't), and the host closed it")
        #expect(output.fileHandleForReading.readDataToEndOfFile().isEmpty, "nothing was answered")
        try? input.fileHandleForWriting.close()
    }

    @Test func stoppingTheServerRemovesTheSocket() throws {
        let local = try Local()
        #expect(FileManager.default.fileExists(atPath: local.path))
        local.host.stop()
        #expect(!FileManager.default.fileExists(atPath: local.path))
    }
}
