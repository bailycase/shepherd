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
        try await TerminalActivityCheck.run(defaults: UserDefaults(suiteName: scratch.appendingPathComponent("terminals").path)!)

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

        // Closing is optimistic: lists (`threadState`) lose the thread at once while the host's state keeps it
        // until the host retires it; a refusal shows it again, and the host retiring it clears the hiding.
        let studioHost = hosts.host(studioID)!
        studioHost.setClosing(keep.agent, true)
        check(!studioHost.threadState.agents.contains { $0.id == keep.agent } && studioHost.state.agents.contains { $0.id == keep.agent },
              "a closing thread leaves lists while the host still has it")
        studioHost.setClosing(keep.agent, false)
        check(studioHost.threadState.agents.map(\.id) == [keep.agent], "a refused close shows the row again")
        studioHost.setClosing(keep.agent, true)
        studio.push(state([]))
        try await waitUntil("the host retires the closing thread") { studioHost.state.agents.isEmpty }
        check(studioHost.closingAgents.isEmpty, "a retired thread is no longer hidden")
        studio.push(state([keep.agent]))
        try await waitUntil("the host has the agent again") { studioHost.threadState.agents.map(\.id) == [keep.agent] }

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

        // Done is the host's: leaving a finished thread tells its own host which completion was seen, only when the host
        // keeps it (completionSeenCapability). build-01 lacks it, so its finished thread stays this device's alone.
        func finished(_ id: AgentID) -> ShepherdState {
            var done = state([id, AgentID(rawValue: "keep")])
            done.agents[0].status = .done
            done.agents[0].completedAt = 1_700
            return done
        }
        let seenHost = try ActionHost(state: finished(shared), completionSeen: true)
        let seenID = try hosts.add(RemoteHostEntry(name: "mini", address: "127.0.0.1", port: String(seenHost.port), token: ActionHost.token))
        build.push(finished(shared))
        func model() -> FleetModel {
            FleetModel(hosts: hosts.hosts.map { FleetHost(id: $0.id, name: $0.name, address: "", port: 0, phase: $0.phase, state: $0.threadState) },
                       digests: [:])
        }
        try await waitUntil("both finished threads in Done") { sidebar.groups(model()).done.count == 2 }
        sidebar.select(AgentRef(host: seenID, agent: shared))
        sidebar.select(AgentRef(host: buildID, agent: shared))
        try await waitUntil("mini told the completion was seen") { seenHost.received == [.markSeen(upTo: 1_700)] }
        sidebar.select(AgentRef(host: seenID, agent: AgentID(rawValue: "keep")))
        check(build.received.isEmpty, "a host without the capability is never told (\(build.received))")
        check(seenHost.received == [.markSeen(upTo: 1_700)], "mini heard once, about its own thread (\(seenHost.received))")
        try await RenameCheck.run(hosts: hosts)
        hosts.setForeground(false)
        print("PASS: Done marks reach only the thread's own host that keeps them, never one without the capability")
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
    private let writing = NSLock()
    private var actions: [RemoteAgentAction] = []
    private var current: ShepherdState
    private var clients: [Int32] = []
    private let terminalActivity: Bool
    private var terminalReads = 0
    private var holdsTerminals = false
    private var heldTerminals: [(Int32, RemoteReply)] = []

    var received: [RemoteAgentAction] { lock.withLock { actions } }
    var terminalRequests: Int { lock.withLock { terminalReads } }
    var heldTerminalRequests: Int { lock.withLock { heldTerminals.count } }
    func holdTerminals() { lock.withLock { holdsTerminals = true } }
    func releaseTerminals() {
        let pending = lock.withLock {
            holdsTerminals = false
            defer { heldTerminals.removeAll() }
            return heldTerminals
        }
        for (client, reply) in pending { try? write(client, reply) }
    }

    private let completionSeen: Bool
    /// How the host answers a rename: at once, with a refusal, or when `releaseRenames` says (the state it pushes then has the name).
    enum RenameMode { case accept, refuse, hold }
    private var renameMode = RenameMode.accept
    private var heldRenames: [(client: Int32, id: Int, agent: AgentID, name: String)] = []
    func setRenames(_ mode: RenameMode) { lock.withLock { renameMode = mode } }
    func releaseRenames() {
        let pending = lock.withLock {
            renameMode = .accept
            defer { heldRenames.removeAll() }
            return heldRenames
        }
        for held in pending { applyRename(held.agent, held.name, then: { try? write(held.client, .ok(id: held.id)) }) }
    }

    /// The host takes the name: its state has it, every client hears the state, then `then` answers the request.
    private func applyRename(_ agent: AgentID, _ name: String, then answer: () -> Void) {
        var next = lock.withLock { current }
        guard let index = next.agents.firstIndex(where: { $0.id == agent }) else { return answer() }
        next.agents[index].name = name
        push(next)
        answer()
    }

    init(state: ShepherdState, terminalActivity: Bool = false, completionSeen: Bool = false) throws {
        current = state
        self.terminalActivity = terminalActivity
        self.completionSeen = completionSeen
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
            ] + (terminalActivity ? [RemoteProtocol.terminalActivityCapability] : [])
              + (completionSeen ? [RemoteProtocol.completionSeenCapability] : [])))
            while true {
                let request = try NDJSON.decode(RemoteRequest.self, from: readLine(client))
                switch request {
                case .stateFetch(let id):
                    let state = lock.withLock {
                        if !clients.contains(client) { clients.append(client) }
                        return current
                    }
                    try write(client, .state(id: id, state: state))
                case .agentAction(let id, let agent, .rename(let name)):
                    let mode = lock.withLock {
                        actions.append(.rename(name: name))
                        if renameMode == .hold { heldRenames.append((client, id, agent, name)) }
                        return renameMode
                    }
                    switch mode {
                    case .accept: applyRename(agent, name) { try? write(client, .ok(id: id)) }
                    case .refuse: try write(client, .error(id: id, code: "rename_failed", message: "The host could not save the name."))
                    case .hold: break
                    }
                case .agentAction(let id, _, let action):
                    lock.withLock { actions.append(action) }
                    if case .move(let space) = action, lock.withLock({ current.spaces.first { $0.id == space }?.hidden }) != false {
                        try write(client, .error(id: id, code: "no_such_space", message: "Choose an existing, non-reserved space on this host."))
                    } else {
                        try write(client, .ok(id: id))
                    }
                case .agentQuery(let id, let agentID, .terminals):
                    let reply: RemoteReply? = lock.withLock {
                        terminalReads += 1
                        let agent = current.agents.first { $0.id == agentID }
                        let layout = current.tabs.first { $0.id == agent?.tabID }?.layout
                        let tabs = layout.map { TerminalPanel.tabs(in: $0, thread: agent?.paneID) } ?? []
                        let rows = tabs.compactMap { tab in
                            tab.leaf.sessionID.map {
                                RemoteTerminalActivity(paneID: tab.id, sessionID: $0, process: "zsh", command: nil, outputSequence: 1)
                            }
                        }
                        let reply = RemoteReply.agentResult(id: id, result: .terminals(rows))
                        if holdsTerminals {
                            holdsTerminals = false
                            heldTerminals.append((client, reply))
                            return nil
                        }
                        return reply
                    }
                    if let reply { try write(client, reply) }
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
        let written = writing.withLock { data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) } }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}

/// Optimistic rename against the real MobileHosts and a real TCP host: shown at once, never written into the host's state,
/// held through stale snapshots, the latest name wins, and a refusal restores the host's name with its reason.
@MainActor
enum RenameCheck {
    static func run(hosts: MobileHosts) async throws {
        let id = AgentID(rawValue: "t1")
        let space = Space(id: SpaceID(rawValue: "home"), name: "Home", path: "/src/home")
        let old = ShepherdState(spaces: [space], agents: [Agent(id: id, name: "old name", spaceID: space.id, tabID: TabID(rawValue: "t"), status: .idle)])
        let server = try ActionHost(state: old)
        let hostID = try hosts.add(RemoteHostEntry(name: "rename-host", address: "127.0.0.1", port: String(server.port), token: ActionHost.token))
        guard let host = hosts.host(hostID) else { fatalError("FAILED: the rename host was not added") }
        try await SidebarThreadsCheck.waitUntil("rename host connected") { host.phase == .connected && !host.state.agents.isEmpty }
        let ref = AgentRef(host: hostID, agent: id)
        var failures: [String] = []
        let failed: @MainActor (AgentActions.Failure) -> Void = { failures.append($0.description) }
        func shown() -> [String] { [host.agent(id)?.name ?? "", host.threadState.agents.first?.name ?? ""] }

        server.setRenames(.hold)
        try AgentActions.rename(ref, to: "Fresh", hosts: hosts, failed: failed)
        SidebarThreadsCheck.check(shown() == ["Fresh", "Fresh"], "the thread and the lists show the name at once (\(shown()))")
        SidebarThreadsCheck.check(host.state.agents.first?.name == "old name", "the host's snapshot is not written")
        server.push(old)
        try await Task.sleep(for: .milliseconds(150))
        SidebarThreadsCheck.check(shown() == ["Fresh", "Fresh"], "a snapshot from before the rename does not undo it")
        try AgentActions.rename(ref, to: "Latest", hosts: hosts, failed: failed)
        SidebarThreadsCheck.check(shown() == ["Latest", "Latest"], "the newest name shows at once")
        server.releaseRenames()
        try await SidebarThreadsCheck.waitUntil("the host ends on the latest name and the overlay leaves") {
            host.state.agents.first?.name == "Latest" && !host.pendingRenames.isPending(id)
        }
        SidebarThreadsCheck.check(server.received.filter { if case .rename = $0 { true } else { false } } == [.rename(name: "Fresh"), .rename(name: "Latest")],
                                  "one request in flight at a time, in order (\(server.received))")
        SidebarThreadsCheck.check(failures.isEmpty, "no failure reported (\(failures))")

        server.setRenames(.refuse)
        try AgentActions.rename(ref, to: "Doomed", hosts: hosts, failed: failed)
        SidebarThreadsCheck.check(shown() == ["Doomed", "Doomed"], "a refused name shows until the host answers")
        try await SidebarThreadsCheck.waitUntil("the refusal restores the host's name") { shown() == ["Latest", "Latest"] && !failures.isEmpty }
        SidebarThreadsCheck.check(failures == ["The host could not save the name."], "the host's reason is reported (\(failures))")

        hosts.disconnect(hostID)
        try await SidebarThreadsCheck.waitUntil("rename host offline") { host.phase == .disconnected }
        do {
            try AgentActions.rename(ref, to: "Offline", hosts: hosts, failed: failed)
            fatalError("FAILED: a rename on an offline host reported success")
        } catch {
            SidebarThreadsCheck.check(shown() == ["Latest", "Latest"], "an offline host shows nothing optimistic")
        }
        print("PASS: rename shows at once, is never written into the host's state, survives stale snapshots, the latest name wins in order, a refusal restores the name with its reason")
    }
}
