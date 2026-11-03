import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Home's progressive publication and quiet-read reuse (`HomeFeed`), launch and reconnect
// readiness (`MobileReadiness`), and the review's retention bounds (`ReviewRetention`), against
// the real MobileHosts and real TCP hosts. Built and run by run.sh on macOS.
@main
struct MobileFreshnessCheck {
    @MainActor
    static func main() async throws {
        retention()
        try await readiness()
        try await home()
        print("PASS: review cache cost plateaus and LRU-evicts; offscreen retention keeps viewers and the newest few")
        print("PASS: readiness reports onboarding, live and failure once per launch; reconnects signpost without reporting again")
        print("PASS: Home publishes an early digest while a later read is held, hosts stay independent; reconnect reuse only on a verified pi session, generation and revision")
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

    // MARK: Review retention

    static func retention() {
        // One file's hunks per revision, the same size each time: the cost stops growing at the budget.
        var cache = ReviewCostCache<Int, String>(budget: 10_000)
        var costs: [Int] = []
        for revision in 0..<200 {
            cache.insert("rev \(revision)", cost: 1_000, for: revision)
            costs.append(cache.cost)
        }
        check(costs.max() == 10_000 && costs.suffix(150).allSatisfy { $0 == 10_000 }, "cache cost plateaus at the budget (\(costs.max()!))")
        check(cache.count == 10 && cache.value(for: 199) != nil && cache.value(for: 189) == nil, "the oldest revisions go first")
        // A lookup keeps an entry: 190 survives the next insert, 191 goes in its place.
        _ = cache.value(for: 190)
        cache.insert("rev 200", cost: 1_000, for: 200)
        check(cache.value(for: 190) != nil && cache.value(for: 191) == nil, "a revision looked at again is kept over an older one")
        cache.insert("huge", cost: 50_000, for: -1)
        check(cache.value(for: -1) == nil && cache.cost <= 10_000, "one entry over the whole budget is not kept")
        cache.removeAll()
        check(cache.cost == 0 && cache.count == 0, "removeAll empties the cost")

        // Reviews 0…49 shown in turn; 3 is on screen in another window: only the newest two
        // others keep their data.
        let recent = Array(0..<50)
        let shed = ReviewRetention.overflow(recent: recent, keep: 2, shown: { $0 == 3 || $0 == 49 })
        check(!shed.contains(49) && !shed.contains(48) && !shed.contains(47) && !shed.contains(3) && shed.count == 46,
              "shown reviews and the two newest others keep their data (\(shed.count) shed)")
        check(ReviewRetention.overflow(recent: [1, 2], keep: 2, shown: { _ in false }).isEmpty, "a few reviews keep everything")
    }

    // MARK: Readiness

    @MainActor
    static func readiness() async throws {
        // No hosts: onboarding is what the app is for, at once.
        let empty = scratchDefaults()
        let none = MobileHosts(defaults: empty, tokens: .memory(), pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        var reports = 0
        let onboarding = MobileReadiness(hosts: none) { reports += 1 }
        check(onboarding.launchMilestone == .onboarding && onboarding.reported && reports == 1, "no hosts reports onboarding")

        // A refusing host only: the failure (with Retry) is the launch's usable screen.
        let refusing = try FeedHost(agents: [], refuses: true)
        let refusedDefaults = scratchDefaults()
        let refusedHosts = MobileHosts(defaults: refusedDefaults, tokens: .memory(), pause: { _ in try await Task.sleep(for: .seconds(3600)) })
        _ = try refusedHosts.add(RemoteHostEntry(name: "Refuses", address: "127.0.0.1", port: String(refusing.port), token: FeedHost.token))
        reports = 0
        let failed = MobileReadiness(hosts: refusedHosts) { reports += 1 }
        check(failed.launchMilestone == nil && reports == 0, "nothing is reported before the foreground connects")
        refusedHosts.setForeground(true)
        try await waitUntil("refusal reported") { failed.launchMilestone == .failed }
        check(reports == 1, "a failure reports once")

        // A live host: connected with its state is usable; reconnects after it never report again.
        let host = try FeedHost(agents: [agent("a", .idle, lastActiveAt: 1)])
        let defaults = scratchDefaults()
        let hosts = MobileHosts(defaults: defaults, tokens: .memory(), pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        _ = try hosts.add(RemoteHostEntry(name: "Live", address: "127.0.0.1", port: String(host.port), token: FeedHost.token))
        reports = 0
        let live = MobileReadiness(hosts: hosts) { reports += 1 }
        hosts.setForeground(true)
        try await waitUntil("live reported") { live.launchMilestone == .live }
        for round in 1...3 {
            hosts.setForeground(false)
            try await waitUntil("background \(round)") { hosts.hosts.allSatisfy { $0.phase == .disconnected } }
            hosts.setForeground(true)
            try await waitUntil("reconnect \(round)") { live.reconnects == round }
        }
        check(reports == 1 && live.reported, "repeated foregrounds report full display only once (\(reports))")
        check(live.cachedShown == 3, "each reconnect began over the last known threads (\(live.cachedShown))")
        hosts.setForeground(false)
        refusedHosts.setForeground(false)
    }

    // MARK: Home

    @MainActor
    static func home() async throws {
        let early = AgentID(rawValue: "early"), held = AgentID(rawValue: "held")
        let quiet = AgentID(rawValue: "quiet"), legacy = AgentID(rawValue: "legacy"), other = AgentID(rawValue: "other")
        let studio = try FeedHost(agents: [agent("early", .working, lastActiveAt: 10), agent("held", .working, lastActiveAt: 10),
                                           agent("quiet", .idle, lastActiveAt: 5), agent("legacy", .idle, lastActiveAt: nil)])
        let build = try FeedHost(agents: [agent("other", .working, lastActiveAt: 10), agent("other-held", .working, lastActiveAt: 10)])
        build.hold(AgentID(rawValue: "other-held"))
        studio.hold(held)
        // build-01 holds its one read too: no host ends its sweep, so whatever shows was published mid-sweep.
        let build2 = AgentID(rawValue: "other-held")
        let defaults = scratchDefaults()
        let hosts = MobileHosts(defaults: defaults, tokens: .memory(), pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let studioID = try hosts.add(RemoteHostEntry(name: "Studio", address: "127.0.0.1", port: String(studio.port), token: FeedHost.token))
        let buildID = try hosts.add(RemoteHostEntry(name: "build-01", address: "127.0.0.1", port: String(build.port), token: FeedHost.token))
        hosts.setForeground(true)
        try await waitUntil("both connected") { hosts.hosts.allSatisfy { $0.phase == .connected && !$0.state.agents.isEmpty } }
        let feed = HomeFeed.of(hosts)
        func doing(_ host: UUID, _ agent: AgentID) -> String? {
            feed.model.recents.first { $0.ref == FleetRef(host: host, agent: agent) }?.doing
        }
        let sweep = Task { await feed.refresh() }
        try await waitUntil("the held read reaches the host") { studio.asked(held) == 1 }
        try await waitUntil("the early digest shows while the later read is held") { doing(studioID, early) == "Thinking" }
        try await waitUntil("another host publishes on its own") { doing(buildID, other) == "Thinking" }
        check(doing(studioID, held) == nil && doing(buildID, build2) == nil, "the held threads have no digest yet")
        build.release(build2)
        studio.release(held)
        await sweep.value
        check(doing(studioID, held) == "Thinking", "the held digest lands once released")
        // Quiet threads are read a few per poll: all of them read by now on this connection.
        await feed.refresh()
        check(studio.asked(quiet) == 1 && studio.asked(legacy) == 1, "quiet threads are read once per connection")

        // A reconnect: a running thread whose pi session, generation and revision are unchanged
        // answers `unchanged` and keeps its digest; an idle one (a preview, no revision) is read again.
        hosts.disconnect(studioID)
        hosts.retry(studioID)
        try await waitUntil("Studio back") { hosts.host(studioID)?.phase == .connected }
        await feed.refresh()
        check(studio.asked(early) == 1 && studio.unchanged(early) >= 1, "an unchanged running thread is not paged again (\(studio.asked(early)))")
        check(studio.asked(quiet) == 2 && studio.asked(legacy) == 2, "previews carry no revision: read again (\(studio.asked(quiet)))")
        check(doing(studioID, early) == "Thinking", "the kept digest still shows")

        // Its pi restarted while away (a new generation, the same revision number): never taken
        // as unchanged; read whole on the next sweep.
        studio.setGeneration("g2")
        hosts.disconnect(studioID)
        hosts.retry(studioID)
        try await waitUntil("Studio back again") { hosts.host(studioID)?.phase == .connected }
        await feed.refresh()
        await feed.refresh()
        check(studio.asked(early) == 2, "another generation's equal revision is read whole (\(studio.asked(early)))")
        check(!studio.mutated && !build.mutated, "Home sent only reads")
        hosts.setForeground(false)
    }

    static func agent(_ id: String, _ status: AgentStatus, lastActiveAt: Double?) -> Agent {
        Agent(id: AgentID(rawValue: id), name: id, spaceID: SpaceID(rawValue: "home"), tabID: TabID(rawValue: "t-\(id)"),
              status: status, lastActiveAt: lastActiveAt)
    }

    static func scratchDefaults() -> UserDefaults {
        let name = "shepherd-freshness-check-\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }
}

// What HomeFeed reads from the app's other files, which this check does not compile.
extension FleetRef {
    var agentRef: AgentRef { AgentRef(host: host, agent: agent) }
}

extension AgentRef {
    var fleetRef: FleetRef { FleetRef(host: host, agent: agent) }
}

@MainActor
final class MobileDesigns {
    private static let shared = MobileDesigns()
    static func of(_ hosts: MobileHosts) -> MobileDesigns { shared }
    var serving: Set<UUID> = []
}

/// A host that answers hello, its state, and thread snapshots (working threads running, quiet
/// ones idle) as a preview-capable host; a held agent's snapshot waits for `release`.
final class FeedHost: @unchecked Sendable {
    static let token = "check-token"
    let port: UInt16
    private let fd: Int32
    private let refuses: Bool
    private let lock = NSLock()
    private var agents: [Agent]
    private var counts: [AgentID: Int] = [:]
    private var held: [AgentID: DispatchSemaphore] = [:]
    private var mutations = 0

    init(agents: [Agent], refuses: Bool = false) throws {
        self.agents = agents
        self.refuses = refuses
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = in_addr_t(INADDR_LOOPBACK).bigEndian
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        precondition(fd >= 0 && bound == 0 && listen(fd, 8) == 0)
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        self.fd = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                var one: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                Thread.detachNewThread { [self] in serve(client) }
            }
        }
    }

    /// Full snapshots sent, and `unchanged` answers.
    func asked(_ agent: AgentID) -> Int { lock.withLock { counts[agent] ?? 0 } }
    func unchanged(_ agent: AgentID) -> Int { lock.withLock { unchangedCounts[agent] ?? 0 } }
    func setGeneration(_ generation: String) { lock.withLock { self.generation = generation } }
    private var unchangedCounts: [AgentID: Int] = [:]
    private var generation = "g"
    var mutated: Bool { lock.withLock { mutations > 0 } }
    func hold(_ agent: AgentID) { lock.withLock { held[agent] = DispatchSemaphore(value: 0) } }
    func release(_ agent: AgentID) { lock.withLock { held.removeValue(forKey: agent) }?.signal() }
    func setState(_ agents: [Agent]) { lock.withLock { self.agents = agents } }

    private func serve(_ client: Int32) {
        defer { close(client) }
        do {
            guard case .hello(let id, let token, _, _, _) = try NDJSON.decode(RemoteRequest.self, from: readLine(client)) else { return }
            guard token == Self.token, !refuses else {
                try write(client, .error(id: id, code: RemoteProtocol.unauthorizedCode, message: "bad token"))
                return
            }
            try write(client, .helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [
                RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeThreadPreviewCapability,
            ]))
            while true {
                let request = try NDJSON.decode(RemoteRequest.self, from: readLine(client))
                switch request {
                case .stateFetch(let id):
                    let state = lock.withLock { ShepherdState(spaces: [Space(id: SpaceID(rawValue: "home"), name: "Home", path: "/src")], agents: agents) }
                    try write(client, .state(id: id, state: state))
                case .nativeThread(let id, let agentID, let command):
                    guard case .snapshot(_, _, let after) = command else {
                        lock.withLock { mutations += 1 }
                        try write(client, .nativeThread(id: id, result: .failure(code: "check", message: "reads only")))
                        continue
                    }
                    let (gate, running, generation) = lock.withLock {
                        (held[agentID], agents.first { $0.id == agentID }?.status == .working, self.generation)
                    }
                    // A running pi answers `unchanged` at its revision; a preview always sends the page.
                    if running, after == 1 {
                        lock.withLock { unchangedCounts[agentID, default: 0] += 1 }
                        try write(client, .nativeThread(id: id, result: .unchanged(piSessionID: agentID.rawValue, generation: generation, revision: 1)))
                        continue
                    }
                    lock.withLock { counts[agentID, default: 0] += 1 }
                    let reply = { [self] in
                        let snapshot = NativeThreadSnapshot(piSessionID: agentID.rawValue, generation: generation, revision: 1, running: running,
                                                            supportedActions: [], dialogsSupported: false, dialogs: [], messages: [],
                                                            provisional: [], clipped: false, runtime: "rpc")
                        try? write(client, .nativeThread(id: id, result: .snapshot(value: snapshot)))
                    }
                    // A held read answers later on its own thread, so the connection keeps serving.
                    if let gate { Thread.detachNewThread { gate.wait(); reply() } } else { reply() }
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

    private let writing = NSLock()
    private func write(_ fd: Int32, _ reply: RemoteReply) throws {
        let data = try NDJSON.encode(reply)
        let written = writing.withLock { data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress!, data.count) } }
        guard written == data.count else { throw CocoaError(.fileWriteUnknown) }
    }
}
