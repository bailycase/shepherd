import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// App/iOS/Hosts/MobileHosts.swift against real TCP listeners, with tokens in memory (never the
// Keychain) and a scratch preferences domain. Built and run by run.sh on macOS.
@main
struct MobileHostsCheck {
    @MainActor
    static func main() async throws {
        // A suite named by an absolute path is that plist, so nothing lands in ~/Library/Preferences.
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-ios-check-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        func scratchDefaults(_ name: String) -> UserDefaults {
            let suite = scratch.appendingPathComponent(name).path
            return UserDefaults(suiteName: suite)!
        }
        let defaults = scratchDefaults("defaults")

        // The first client's single host migrates as a record, without its token (there is no token shared by every client any more):
        // it says no token is saved, and its old key goes.
        defaults.set(Data(#"{"name":"Old Mac","host":"127.0.0.1","port":1}"#.utf8), forKey: MobileHosts.legacyKey)
        let tokens = HostTokens.memory()
        let migrated = MobileHosts(defaults: defaults, tokens: tokens)
        check(migrated.hosts.count == 1, "legacy host migrated")
        let legacy = migrated.hosts[0]
        check(legacy.record.name == "Old Mac" && legacy.record.address == "127.0.0.1" && legacy.record.port == 1, "legacy record kept")
        try check(tokens.read(legacy.id) == nil, "no token is moved")
        check(defaults.data(forKey: MobileHosts.legacyKey) == nil, "legacy key removed")
        check(MobileHosts(defaults: defaults, tokens: tokens).hosts.map(\.record) == [legacy.record], "migration is saved once")

        // A new host needs a token; records never carry one.
        let hosts = MobileHosts(defaults: defaults, tokens: tokens, pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        do {
            try hosts.add(RemoteHostEntry(name: "x", address: "127.0.0.1", port: "7433", token: nil))
            fatalError("a host without a token was added")
        } catch {}
        check(hosts.hosts.count == 1, "nothing added without a token")
        let old = hosts.host(legacy.id)!

        let server = try Listener()
        let space = Space(name: "space", path: "/tmp")
        let agent = Agent(name: "live agent", spaceID: space.id, tabID: TabID(), status: .working)
        let pushed = ShepherdState(spaces: [space], agents: [agent])
        let serving = Task.detached { server.serve(connections: 2, pushed: pushed) }

        let liveID = try hosts.add(RemoteHostEntry(name: " Studio ", address: "127.0.0.1", port: String(server.port), token: "test-token"))
        let saved = try JSONSerialization.jsonObject(with: defaults.data(forKey: MobileHosts.recordsKey)!) as! [[String: Any]]
        check(saved.count == 2 && saved.allSatisfy { Set($0.keys) == ["id", "name", "address", "port", "routes"] }, "records hold no token")
        try check(tokens.read(liveID) == "test-token", "token saved apart")
        let live = hosts.host(liveID)!
        check(live.name == "Studio" && live.phase == .disconnected, "nothing connects in the background")

        // Foreground: the live host connects and adopts pushed state; the other one fails.
        hosts.setForeground(true)
        try await waitUntil("live host connected with pushed state") { live.phase == .connected && live.state.agents == [agent] }
        check(live.session != nil && live.connectedClient != nil, "a live session")
        try await waitUntil("unreachable host failed") { old.phase.failure != nil }

        // Background drops every socket; foreground reconnects with a new session.
        let firstSession = live.session
        hosts.setForeground(false)
        check(hosts.hosts.allSatisfy { $0.phase == .disconnected && $0.session == nil }, "background disconnects")
        hosts.setForeground(true)
        try await waitUntil("reconnected") { live.phase == .connected && live.session != nil && live.session != firstSession }

        // A failing host retries on its own; disconnecting stops it.
        try await waitUntil("unreachable host retried") { old.phase == .connecting || old.phase.failure != nil }
        hosts.disconnect(old.id)
        try await Task.sleep(for: .milliseconds(200))
        check(old.phase == .disconnected, "a stopped host stays stopped")

        // Renaming keeps the connection; forgetting drops the record and the token.
        let session = live.session
        try hosts.edit(liveID, RemoteHostEntry(name: "Renamed", address: "127.0.0.1", port: String(server.port), token: nil))
        check(live.name == "Renamed" && live.session == session && live.phase == .connected, "a rename keeps the connection")
        try hosts.forget(liveID)
        try check(hosts.host(liveID) == nil && tokens.read(liveID) == nil, "forget removes host and token")
        check(MobileHosts(defaults: defaults, tokens: tokens).hosts.map(\.id) == [old.id], "forget is saved")
        await serving.value

        // A host that refuses the token says so, and waits for Edit or Retry instead of retrying
        // on its own (the backoff here is 20 ms, so a retry would show well within the wait).
        let refusing = try Listener()
        let refusals = Locked(0)
        let refusingTask = Task.detached { refusing.refuse(connections: 2, count: refusals) }
        let refusedID = try hosts.add(RemoteHostEntry(name: "Wrong", address: "127.0.0.1", port: String(refusing.port), token: "wrong-token"))
        let refused = hosts.host(refusedID)!
        try await waitUntil("the refused token shown") { refused.phase.failure?.kind == .tokenRefused }
        try await Task.sleep(for: .milliseconds(300))
        check(refusals.value == 1 && refused.phase.failure?.kind == .tokenRefused, "a refused token is not retried on its own")
        hosts.retry(refusedID)
        try await waitUntil("Retry tries once more") { refusals.value == 2 && refused.phase.failure?.kind == .tokenRefused }
        await refusingTask.value

        // A host that no longer accepts the old shared token says to pair again: no retry on its own, and nothing for Retry to fix.
        let retired = try Listener()
        let retiredCount = Locked(0)
        let retiredTask = Task.detached { retired.refuse(connections: 1, count: retiredCount, code: RemoteProtocol.sharedTokenRetiredCode, message: RemoteProtocol.sharedTokenRetiredMessage) }
        let retiredID = try hosts.add(RemoteHostEntry(name: "Mac mini", address: "127.0.0.1", port: String(retired.port), token: "old-shared-token"))
        let retiredHost = hosts.host(retiredID)!
        try await waitUntil("the old shared token's refusal shown") { retiredHost.phase.failure?.kind == .sharedTokenRetired }
        try await Task.sleep(for: .milliseconds(300))
        check(retiredCount.value == 1 && retiredHost.phase.failure?.retries == false, "a retired shared token is not retried on its own")
        check(retiredHost.phase.failure?.message(host: "Mac mini") == "Mac mini no longer accepts the old shared token. Pair again with a code.", "it says to pair again")
        await retiredTask.value
        print("PASS: MobileHosts migration, records without tokens, several hosts over real TCP, pushes, background and foreground, retry and stop, rename, forget, a refused token waits, a retired shared token says to pair again")
    }

    static func check(_ condition: @autoclosure () throws -> Bool, _ what: String) rethrows {
        guard try condition() else { fatalError("FAILED: \(what)") }
    }

    @MainActor
    static func waitUntil(_ what: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        fatalError("timed out: \(what)")
    }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A host that answers hello and the state fetch, pushes one state, and holds the socket until
/// the client closes it.
final class Listener: @unchecked Sendable {
    let fd: Int32
    let port: UInt16

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(fd >= 0 && bound == 0 && listen(fd, 4) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
    }

    deinit { close(fd) }

    func serve(connections: Int, pushed: ShepherdState) {
        for _ in 0..<connections {
            let client = accept(fd, nil, nil)
            precondition(client >= 0)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            do {
                guard case .hello(let id, let token, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)),
                      token == "test-token" else { fatalError("expected hello with the token") }
                try write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.nativeThreadCapability]))
                guard case .stateFetch(let fetch) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)) else {
                    fatalError("expected a state fetch")
                }
                try write(client, .state(id: fetch, state: ShepherdState()))
                try write(client, .stateChanged(state: pushed))
                _ = try? readLine(client)
            } catch {
                fatalError("host failed: \(error)")
            }
            close(client)
        }
    }

    /// Refuses each hello the way a host refuses a wrong token (a final reply, then close),
    /// counting the connections.
    func refuse(connections: Int, count: Locked<Int>, code: String = RemoteProtocol.unauthorizedCode, message: String = "bad token") {
        for _ in 0..<connections {
            let client = accept(fd, nil, nil)
            precondition(client >= 0)
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            count.value += 1
            do {
                guard case .hello(let id, _, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)) else {
                    fatalError("expected hello")
                }
                try write(client, .error(id: id, code: code, message: message))
            } catch {
                fatalError("refusing host failed: \(error)")
            }
            close(client)
        }
    }

    private func readLine(_ fd: Int32) throws -> Data {
        var line = Data()
        var byte: UInt8 = 0
        while Darwin.read(fd, &byte, 1) == 1 {
            if byte == 10 { return line }
            line.append(byte)
        }
        throw CocoaError(.fileReadUnknown)
    }

    private func write(_ fd: Int32, _ reply: RemoteReply) throws {
        let data = try NDJSON.encode(reply)
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}
