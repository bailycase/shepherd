import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol

// The check uses isolated memory instead of touching the user's Keychain.
// HostConnection and RemoteHostClient below are the production implementations.
enum HostTokenStore {
    static var token: String?
    static func read() throws -> String? { token }
    static func save(_ value: String) throws { token = value }
    static func remove() throws { token = nil }
}

@main
struct HostConnectionCheck {
    @MainActor
    static func main() async throws {
        let suite = "shepherd.ios.check.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let connection = HostConnection(defaults: defaults)
        for port in ["0", "65536", "invalid"] {
            do {
                try connection.save(name: "test", host: "127.0.0.1", port: port, token: "test-token")
                fatalError("invalid port accepted")
            } catch {}
        }
        precondition(connection.configuration == nil)
        precondition(HostTokenStore.token == nil)

        let listener = socket(AF_INET, SOCK_STREAM, 0)
        precondition(listener >= 0)
        defer { close(listener) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        precondition(bound == 0 && listen(listener, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &length) }
        }
        let port = UInt16(bigEndian: address.sin_port)
        let space = Space(name: "test space", path: "/tmp")
        let agent = Agent(name: "live agent", spaceID: space.id, tabID: TabID(), status: .working)
        let pushed = ShepherdState(spaces: [space], agents: [agent])

        let server = Task.detached {
            // First handshake is deliberately delayed so cancellation can supersede it.
            // The second and third connections exercise reconnect and foreground resume.
            for attempt in 0..<3 {
                let fd = accept(listener, nil, nil)
                precondition(fd >= 0)
                var one: Int32 = 1
                _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                if attempt == 0 { usleep(200_000) }
                do {
                    guard case .hello(let id, let token, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(fd)) else {
                        fatalError("expected hello")
                    }
                    precondition(token == "test-token")
                    try writeReply(fd, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: []))
                    guard case .stateFetch(let id) = try NDJSON.decode(RemoteRequest.self, from: readLine(fd)) else {
                        fatalError("expected state fetch")
                    }
                    try writeReply(fd, .state(id: id, state: ShepherdState()))
                    try writeReply(fd, .stateChanged(state: pushed))
                    // Wait until the client backgrounds or forgets this host.
                    _ = try? readLine(fd)
                } catch {
                    precondition(attempt == 0, "unexpected connection failure: \(error)")
                }
                close(fd)
            }
        }

        try connection.save(name: " test host ", host: "127.0.0.1", port: String(port), token: "test-token")
        precondition(connection.phase == .disconnected)
        let data = defaults.data(forKey: HostConnection.defaultsKey)!
        let saved = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        precondition(Set(saved.keys) == ["name", "host", "port"])
        precondition(HostConnection(defaults: defaults).configuration == connection.configuration)
        connection.setForeground(true)
        try await Task.sleep(for: .milliseconds(50))
        connection.stop()
        precondition(connection.phase == .disconnected)
        connection.reconnect()
        try await waitUntil { connection.phase == .connected && connection.state.agents == [agent] }
        connection.setForeground(false)
        precondition(connection.phase == .disconnected)
        try await Task.sleep(for: .milliseconds(50))
        precondition(connection.phase == .disconnected)
        connection.setForeground(true)
        try await waitUntil { connection.phase == .connected && connection.state.agents == [agent] }
        try connection.forget()
        precondition(connection.configuration == nil && connection.state.agents.isEmpty)
        precondition(defaults.data(forKey: HostConnection.defaultsKey) == nil && HostTokenStore.token == nil)
        await server.value

        try connection.save(name: "unreachable", host: "127.0.0.1", port: "1", token: "test-token")
        try await waitUntil { if case .failed = connection.phase { return true }; return false }
        connection.stop()
        try await Task.sleep(for: .milliseconds(1200))
        precondition(connection.phase == .disconnected, "stopped retry changed connection state")
        try connection.forget()
        print("PASS: configuration validation/persistence, real TCP state pushes, superseded handshake, foreground reconnect, failure, retry cancellation, forget")
    }

    @MainActor
    static func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<250 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("timed out waiting for connection state")
    }

    static func readLine(_ fd: Int32) throws -> Data {
        var result = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 { return result }
            result.append(byte)
        }
        throw NSError(domain: "check", code: 1)
    }

    static func writeReply(_ fd: Int32, _ reply: RemoteReply) throws {
        let data = try NDJSON.encode(reply)
        var offset = 0
        while offset < data.count {
            let count = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!.advanced(by: offset), data.count - offset) }
            guard count > 0 else { throw NSError(domain: "check", code: 2) }
            offset += count
        }
    }
}
