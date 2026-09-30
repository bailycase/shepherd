import Foundation
import Network
import Testing
import ShepherdTestSupport
@testable import ShepherdSessions

@Suite(.integrationTimeLimit)
struct CLIProxyAPIConnectionTests {
    @Test func connectionDiscoveryIsAtomicPrivateAndNeverFollowsRedirects() async throws {
        let root = try makeScratchDirectory("cpa")
        defer { try? FileManager.default.removeItem(at: root) }
        let pi = PiSetup(engine: PiEngine(command: ["/usr/bin/false"], packageDirectory: nil, version: nil, node: .onPath("node")),
                         home: root.appendingPathComponent("pi"), userHome: root.path)
        let store = CLIProxyAPIStore(pi: pi)
        #expect(try await store.snapshot() == nil)
        let server = try ProxyServer()
        defer { server.stop() }
        try await server.start()
        let address = "http://127.0.0.1:\(try #require(server.port))/v1"
        let file = pi.home.appendingPathComponent(CLIProxyAPIStore.fileName)
        server.reply.withValue { $0 = (200, #"{"data":[{"id":"gpt-test","owned_by":"openai"}]}"#, nil) }
        let snapshot = try await store.connect(server: address, key: "!literal-$KEY")
        #expect(snapshot.enabled && snapshot.modelCount == 1)
        #expect(server.requests.current.last?.contains("Authorization: Bearer !literal-$KEY") == true)
        let saved = try Data(contentsOf: file)
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600)
        #expect(pi.importedState().survey().missingSignIns(for: ["cliproxyapi/gpt-test"]).isEmpty)

        for reply in [(401, "secret echoed by server", Optional<String>.none),
                      (200, #"{"data":[]}"#, nil),
                      (302, "", address + "/elsewhere")] {
            server.reply.withValue { $0 = reply }
            let count = server.requests.current.count
            do {
                _ = try await store.refresh()
                Issue.record("A refused, empty or redirected discovery must fail")
            } catch {
                #expect(!String(describing: error).contains("secret echoed"))
                #expect(!String(describing: error).contains("!literal-$KEY"))
            }
            #expect(try Data(contentsOf: file) == saved)
            #expect(server.requests.current.count == count + 1)
        }
        let disabled = try await store.disable()
        #expect(!disabled.enabled)
        #expect(!CLIProxyAPIStore.configured(in: pi.files))
        #expect(pi.importedState().survey().missingSignIns(for: ["cliproxyapi/gpt-test"]) == ["cliproxyapi"])
        #expect(disabled.modelCount == 1)
        server.reply.withValue { $0 = (200, #"{"data":[{"id":"new-model"}]}"#, nil) }
        #expect(try await store.connect(server: address, key: "").enabled)
        try await store.forget()
        #expect(try await store.snapshot() == nil)
        #expect(!FileManager.default.fileExists(atPath: file.path))
        #expect(pi.importedState().survey().missingSignIns(for: ["cliproxyapi/gpt-test"]) == ["cliproxyapi"])
    }
}

private final class ProxyServer: @unchecked Sendable {
    let reply = Locked<(Int, String, String?)>((200, "", nil))
    let requests = Locked<[String]>([])
    private let listener: NWListener
    private let connections = Locked<[NWConnection]>([])
    var port: UInt16? { listener.port?.rawValue }

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws {
        listener.newConnectionHandler = { [self] connection in
            connections.withValue { $0.append(connection) }
            connection.start(queue: .global())
            receive(connection, bytes: Data())
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { [listener] state in
                switch state {
                case .ready: listener.stateUpdateHandler = nil; continuation.resume()
                case .failed(let error): listener.stateUpdateHandler = nil; continuation.resume(throwing: error)
                default: break
                }
            }
            listener.start(queue: .global())
        }
    }

    private func receive(_ connection: NWConnection, bytes: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [self] data, _, done, _ in
            let bytes = bytes + (data ?? Data())
            let text = String(decoding: bytes, as: UTF8.self)
            guard text.contains("\r\n\r\n") else {
                if !done { receive(connection, bytes: bytes) }
                return
            }
            requests.withValue { $0.append(text) }
            let (status, body, location) = reply.current
            let redirect = location.map { "Location: \($0)\r\n" } ?? ""
            let response = "HTTP/1.1 \(status) Test\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\(redirect)\r\n\(body)"
            connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    func stop() {
        listener.cancel()
        for connection in connections.current { connection.cancel() }
    }
}
