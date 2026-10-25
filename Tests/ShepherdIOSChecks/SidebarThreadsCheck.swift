import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The sidebar's pins and Move to Space against the real MobileHosts and real TCP hosts (tokens in memory, scratch
// preferences). Two hosts each hold an agent with the SAME id, so a request that searched by agent id, or went to the
// wrong host, would be seen. Built and run by run.sh on macOS.
@main
struct SidebarThreadsCheck {
    @MainActor
    static func main() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("shepherd-sidebar-check-\(UUID())")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let defaults = UserDefaults(suiteName: scratch.appendingPathComponent("defaults").path)!

        let shared = AgentID(rawValue: "same-id")
        let home = Space(id: SpaceID(rawValue: "home"), name: "Home", path: "/src/home")
        let other = Space(id: SpaceID(rawValue: "other"), name: "Other", path: "/src/other")
        let reserved = Space(id: SpaceID(rawValue: "reserved"), name: "Reserved", path: "/", hidden: true)
        func state(_ agents: [AgentID]) -> ShepherdState {
            ShepherdState(spaces: [home, other, reserved], agents: agents.map {
                Agent(id: $0, name: $0.rawValue, spaceID: home.id, tabID: TabID(rawValue: "t-\($0.rawValue)"), status: .idle)
            })
        }
        let studio = try ActionHost(state: state([shared, AgentID(rawValue: "keep")]))
        let build = try ActionHost(state: state([shared]))

        let tokens = HostTokens.memory()
        let hosts = MobileHosts(defaults: defaults, tokens: tokens, pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let studioID = try hosts.add(RemoteHostEntry(name: "Studio", address: "127.0.0.1", port: String(studio.port), token: ActionHost.token))
        let buildID = try hosts.add(RemoteHostEntry(name: "build-01", address: "127.0.0.1", port: String(build.port), token: ActionHost.token))
        hosts.setForeground(true)
        try await waitUntil("both hosts connected") { hosts.hosts.allSatisfy { $0.phase == .connected && !$0.state.agents.isEmpty } }

        // A visible form owns its original handshake/client, not a saved host id that can be rebound.
        let finalizing = AgentRef(host: studioID, agent: shared)
        let retained = FinalizeStore(ref: finalizing)
        await retained.begin(hosts: hosts)
        check(retained.canFinalize, "a connected original form is usable")
        let firstSession = hosts.host(studioID)?.session
        try hosts.edit(studioID, RemoteHostEntry(name: "Replacement", address: "127.0.0.1", port: String(build.port), token: ActionHost.token))
        try await waitUntil("replacement handshake") { hosts.host(studioID)?.phase == .connected && hosts.host(studioID)?.session != firstSession }
        await retained.start(hosts: hosts)
        check(studio.finalizations == 0 && build.finalizations == 0 && retained.operationID == nil,
              "a retained form sends nothing to the replacement same-id host")
        let fresh = FinalizeStore(ref: finalizing)
        await fresh.begin(hosts: hosts)
        await fresh.start(hosts: hosts)
        check(studio.finalizations == 0 && build.finalizations == 1 && fresh.operation?.finished == true,
              "a fresh form on the replacement has a positive exact-client path")
        fresh.reset()
        check(fresh.operationID == nil, "a proved terminal operation releases its form")
        build.useWrongOperationID()
        await fresh.begin(hosts: hosts)
        await fresh.start(hosts: hosts)
        let unknown = fresh.operationID
        check(unknown != nil && fresh.operation == nil, "a mismatched operation reply is not adopted")
        fresh.reset()
        check(fresh.operationID == unknown, "Reset cannot erase a submitted operation whose outcome is unknown")
        let replacementSession = hosts.host(studioID)?.session
        try hosts.edit(studioID, RemoteHostEntry(name: "Studio", address: "127.0.0.1", port: String(studio.port), token: ActionHost.token))
        try await waitUntil("original host reconnects") { hosts.host(studioID)?.phase == .connected && hosts.host(studioID)?.session != replacementSession }

        // Pins are this device's: kept in its preferences, restored by a new store, never sent to a host.
        let sidebar = SidebarThreads(hosts: hosts, defaults: defaults)
        let studioThread = AgentRef(host: studioID, agent: shared)
        let keep = AgentRef(host: studioID, agent: AgentID(rawValue: "keep"))
        sidebar.togglePin(keep)
        sidebar.togglePin(studioThread)
        check(sidebar.isPinned(studioThread) && !sidebar.isPinned(AgentRef(host: buildID, agent: shared)),
              "a pin names its host: the same agent id on another host is not pinned")
        check(SidebarThreads(hosts: hosts, defaults: defaults).state.pins.map(\.agent.rawValue) == ["keep", "same-id"],
              "pins are saved in pin order and restored")
        check(studio.received.isEmpty && build.received.isEmpty, "pinning sends nothing to any host")

        // Move to Space goes to the thread's own host only, with the exact space; a refusal is the host's reason.
        try await AgentActions.move(studioThread, to: other.id, hosts: hosts)
        check(studio.received == [.move(spaceID: other.id)], "Studio got exactly one move (\(studio.received))")
        check(build.received.isEmpty, "build-01, which has an agent with the same id, got nothing (\(build.received))")
        do {
            try await AgentActions.move(studioThread, to: reserved.id, hosts: hosts)
            fatalError("FAILED: a refused move reported success")
        } catch {
            check(String(describing: error).contains("Choose an existing"), "the host's refusal is shown (\(error))")
        }
        check(build.received.isEmpty, "a refused move reached no other host")

        // A host going offline keeps its pins (the Mac's rule); a connected host losing the thread drops that pin only.
        hosts.disconnect(studioID)
        try await waitUntil("Studio offline") { hosts.host(studioID)?.phase == .disconnected }
        check(sidebar.state.pins.count == 2, "an offline host keeps its pins")
        hosts.retry(studioID)
        try await waitUntil("Studio back") { hosts.host(studioID)?.phase == .connected }
        studio.push(state([AgentID(rawValue: "keep")]))
        try await waitUntil("a deleted thread's pin goes") { sidebar.state.pins.map(\.agent.rawValue) == ["keep"] }

        // Offline, the actions refuse without sending; forgetting a host takes its pins.
        hosts.disconnect(studioID)
        try await waitUntil("Studio offline again") { hosts.host(studioID)?.phase == .disconnected }
        let before = studio.received.count
        do {
            try await AgentActions.move(keep, to: other.id, hosts: hosts)
            fatalError("FAILED: a move on an offline host reported success")
        } catch {
            check(String(describing: error).contains("offline"), "an offline host says so (\(error))")
        }
        check(studio.received.count == before, "nothing was sent while offline")
        try hosts.forget(studioID)
        try await waitUntil("forgetting a host takes its pins") { sidebar.state.pins.isEmpty }
        check(defaults.data(forKey: SidebarThreads.pinsKey).flatMap { try? JSONDecoder().decode([FleetRef].self, from: $0) } == [],
              "the forgotten pins are gone from the preferences too")
        hosts.setForeground(false)
        print("PASS: retained Finalize refuses replacement, fresh Finalize reaches its exact client, unknown operation survives Reset")
        print("PASS: sidebar pins per device and host, restored in order, kept offline, dropped with their thread or host; Move to Space reaches only its own host with the exact space, refusals and offline shown, nothing sent elsewhere")
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

/// A host that answers hello and the state fetch, pushes state on demand, records each agent action it receives, and
/// refuses a move to a hidden space as SessionServer does. Accepts connections until the process ends.
final class ActionHost: @unchecked Sendable {
    static let token = "check-token"
    let fd: Int32
    let port: UInt16
    private let lock = NSLock()
    private var actions: [RemoteAgentAction] = []
    private var current: ShepherdState
    private var clients: [Int32] = []

    var received: [RemoteAgentAction] { lock.withLock { actions } }

    init(state: ShepherdState) throws {
        current = state
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
        Thread.detachNewThread { [self] in acceptLoop() }
    }

    /// The host's state changed: every connected client hears it.
    func push(_ state: ShepherdState) {
        let live = lock.withLock { current = state; return clients }
        for client in live { try? write(client, .stateChanged(state: state)) }
    }

    private var finalizeCount = 0
    private var wrongOperationID = false
    var finalizations: Int { lock.withLock { finalizeCount } }
    func useWrongOperationID() { lock.withLock { wrongOperationID = true } }

    private func acceptLoop() {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            var one: Int32 = 1
            _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            Thread.detachNewThread { [self] in serve(client) }
        }
    }

    private func serve(_ client: Int32) {
        defer {
            lock.withLock { clients.removeAll { $0 == client } }
            close(client)
        }
        do {
            guard case .hello(let id, let token, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)),
                  token == Self.token else { return }
            try write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [
                RemoteProtocol.agentActionsCapability, RemoteProtocol.moveThreadCapability, RemoteProtocol.worktreeActionsCapability,
                // Finalize checks the worktree setup first, which the client sends only to a host that advertises it.
                RemoteProtocol.worktreeSetupCapability,
            ]))
            while true {
                let request = try NDJSON.decode(RemoteRequest.self, from: readLine(client))
                switch request {
                case .stateFetch(let id):
                    let state = lock.withLock { clients.append(client); return current }
                    try write(client, .state(id: id, state: state))
                case .agentAction(let id, _, let action):
                    lock.withLock { actions.append(action) }
                    if case .move(let space) = action, lock.withLock({ current.spaces.first { $0.id == space }?.hidden }) != false {
                        try write(client, .error(id: id, code: "no_such_space", message: "Choose an existing, non-reserved space on this host."))
                    } else {
                        try write(client, .ok(id: id))
                    }
                case .agentQuery(let id, _, let query):
                    let result: RemoteAgentResult
                    switch query {
                    case .worktreeSetup:
                        result = .worktreeSetup(.init(repoPath: "/fixture", checks: ["git": .pass("fixture")], repoSettings: [:]))
                    case .worktreeInfo:
                        result = .worktreeInfo(.init(path: "/fixture", branch: "feature", warning: nil,
                            defaults: .init(base: "nightly", title: "Fixture", body: "", autoCommit: false, deleteLocalBranch: false,
                                            autoMergePR: false, mergeMethod: "squash"), generateDescription: false))
                    case .worktreeCommitCount: result = .worktreeCommitCount(1)
                    case .finalizeWorktree(let operation, _):
                        let wrong = lock.withLock { finalizeCount += 1; return wrongOperationID }
                        result = .worktreeOperation(.init(id: wrong ? UUID() : operation, finished: true, progress: []))
                    default: continue
                    }
                    try write(client, .agentResult(id: id, result: result))
                default:
                    continue
                }
            }
        } catch {
            return
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
