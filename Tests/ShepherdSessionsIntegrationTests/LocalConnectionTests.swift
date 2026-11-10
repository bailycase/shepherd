import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// The app's link to the host on its own Mac (`host.sock`) ends only when the host does: a busy
/// host, a large workspace or an app that reads slowly fails or waits, and the link stays. A
/// paired host over TCP keeps its stricter rules, checked beside each.
@Suite("Local connection", .integrationTimeLimit)
struct LocalConnectionTests {
    struct Host {
        let scratch: ScratchServer
        let path: String
        let token: String
        let port: UInt16

        init() throws {
            scratch = try ScratchServer.fresh()
            path = scratch.dir.appendingPathComponent("h.sock").path
            let tokenURL = scratch.dir.appendingPathComponent("remote-token")
            try scratch.server.startLocalListener(path: path, tokenURL: tokenURL)
            port = try scratch.server.startRemoteListener(port: 0, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        /// A connected client and the reasons it was told it lost the connection.
        func client(local: Bool) async throws -> (RemoteHostClient, Locked<[String]>) {
            let client = local ? RemoteHostClient(localSocket: path) : RemoteHostClient()
            let drops = Locked<[String]>([])
            client.onDisconnected = { reason in drops.withValue { $0.append(reason) } }
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: local ? "Shepherd" : "iPhone")
            return (client, drops)
        }

        /// Holds the host's queue, as a loaded Mac does, until the returned gate opens.
        func stall() -> DispatchSemaphore {
            let gate = DispatchSemaphore(value: 0)
            scratch.server.queue.async { gate.wait() }
            return gate
        }
    }

    private static func fetchState(_ client: RemoteHostClient) async throws -> ShepherdState? {
        guard case .state(_, let state) = try await client.request(timeout: 30, { .stateFetch(id: $0) }) else { return nil }
        return state
    }

    // MARK: Request timeouts

    @Test func aSlowHostFailsOneRequestAndKeepsTheLocalConnection() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        let (client, drops) = try await host.client(local: true)
        defer { client.disconnect() }

        let gate = host.stall()
        do {
            _ = try await client.request(timeout: 0.2) { .stateFetch(id: $0) }
            Issue.record("expected the request to time out")
        } catch RemoteHostClientError.timeout {}
        gate.signal()

        // The same connection answers once the host is free; its late reply went nowhere.
        #expect(try await Self.fetchState(client) != nil)
        #expect(drops.current.isEmpty)
    }

    @Test func aPairedHostThatDoesNotAnswerInTimeIsDropped() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        let (client, drops) = try await host.client(local: false)
        defer { client.disconnect() }

        let gate = host.stall()
        defer { gate.signal() }
        await #expect(throws: RemoteHostClientError.self) { _ = try await client.request(timeout: 0.2) { .stateFetch(id: $0) } }
        try await eventually("the paired client to drop") { drops.current.contains { $0.contains("timed out") } }
    }

    // MARK: Client write queue

    @Test func aFullWriteQueueRefusesARequestAndKeepsTheLocalConnection() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        let (client, drops) = try await host.client(local: true)
        defer { client.disconnect() }

        // 12 requests of 900 KB while the host reads nothing: more than the 8 MiB queue holds.
        let gate = host.stall()
        let text = String(repeating: "a", count: 900_000)
        let codes = try await withThrowingTaskGroup(of: String.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    do {
                        _ = try await client.request(timeout: 60) { id in
                            .nativeThread(id: id, agentID: AgentID(), request: .send(
                                expectedSessionID: "acme", generation: "0", operationID: UUID(), text: text, delivery: .followUp, images: nil))
                        }
                        return "answered"
                    } catch RemoteHostClientError.rejected(let code, _) where code == "not_sent" {
                        gate.signal() // the first refusal lets the host read the rest
                        return code
                    } catch {
                        return "\(error)"
                    }
                }
            }
            return try await group.reduce(into: []) { $0.append($1) }
        }
        gate.signal()
        #expect(codes.contains("not_sent"))
        #expect(codes.allSatisfy { $0 == "answered" || $0 == "not_sent" }, "\(codes)")
        #expect(try await Self.fetchState(client) != nil)
        #expect(drops.current.isEmpty)
    }

    // MARK: Large state

    @Test func aWorkspaceOverTheRemoteFrameCapReachesTheLocalAppAndKeepsEveryLink() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        let (local, localDrops) = try await host.client(local: true)
        defer { local.disconnect() }
        let (paired, pairedDrops) = try await host.client(local: false)
        defer { paired.disconnect() }
        let pushed = Locked<[ShepherdState]>([])
        local.onStateChanged = { state in pushed.withValue { $0.append(state) } }

        // About 1.5 MB of workspace: over the 1 MiB a paired client reads in one frame.
        let spaces = (0..<300).map { Space(name: "acme-\($0)-" + String(repeating: "x", count: 5_000), path: "/tmp/acme-\($0)") }
        try await host.scratch.server.putState(ShepherdState(spaces: spaces))

        try await eventually("the local app to get the whole workspace") { pushed.current.last?.spaces.count == 300 }
        // A fresh local connection reads it in its handshake.
        let (again, _) = try await host.client(local: true)
        again.disconnect()
        #expect(try await Self.fetchState(local)?.spaces.count == 300)
        #expect(localDrops.current.isEmpty)
        // The paired client is skipped, as before, and keeps its link: the host still answers it.
        do {
            _ = try await paired.nativeThread(agentID: AgentID(), request: .snapshot())
            Issue.record("expected the host to refuse an unknown agent")
        } catch RemoteHostClientError.rejected(let code, _) {
            #expect(code == "native_unavailable")
        }
        #expect(pairedDrops.current.isEmpty)
    }

    // MARK: Slow reader

    @Test func aLocalAppThatStopsReadingHoldsItsTerminalInsteadOfDropping() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        // About 16 MB of output, far past every queue between the PTY and the app.
        let shell = try await host.scratch.shell("yes acme-output | head -c 16000000; echo; echo FLOOD_DONE; cat")
        let (client, drops) = try await host.client(local: true)
        defer { client.disconnect() }

        // The app's main thread is busy: nothing it was handed is finished.
        let held = Locked<[@Sendable () -> Void]>([])
        let reading = Locked(false)
        let tail = Locked(Data())
        client.onOutputConsumed = { _, data, done in
            if reading.current {
                tail.withValue { $0.append(data); if $0.count > 4096 { $0 = $0.suffix(4096) } }
                done()
            } else {
                held.withValue { $0.append(done) }
            }
        }
        _ = try await client.attach(sessionID: shell.id, cols: 80, rows: 24)

        try await eventually("the host to hold the terminal for the app", timeout: .seconds(60)) {
            host.scratch.server.localAppBacklog.heldTerminals == 1
        }
        #expect(host.scratch.server.localAppBacklog.bytes < SessionServer.maxQueuedLocalReplyBytes)

        // The app catches up: the terminal runs again and the rest of the flood arrives.
        reading.withValue { $0 = true }
        for done in held.current { done() }
        try await eventually("the flood to finish", timeout: .seconds(60)) {
            String(decoding: tail.current, as: UTF8.self).contains("FLOOD_DONE")
        }
        #expect(host.scratch.server.localAppBacklog.heldTerminals == 0)
        #expect(drops.current.isEmpty)
    }

    @Test func aPairedClientThatStopsReadingIsDroppedAsBefore() async throws {
        let host = try Host()
        defer { host.scratch.stop() }
        // No end: loopback TCP buffers grow to megabytes, and the host must still give up on it.
        let shell = try await host.scratch.shell("yes acme-output")
        let (client, _) = try await host.client(local: false)
        defer { client.disconnect() }
        client.onOutputConsumed = { _, _, _ in }
        _ = try await client.attach(sessionID: shell.id, cols: 80, rows: 24)
        // The host gives up on it (the client, its reads paused, hears so only once it reads again).
        try await eventually("the host to drop the stalled paired client") { host.scratch.server.remoteClientCount == 0 }
    }
}
