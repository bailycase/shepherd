import Darwin
import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// `RemoteHostClient` against a scripted host on a socketpair: a cancelled read lets go of its
/// waiter and a late reply never ends the connection (RI-14); pushed output waits in bounded
/// hops and the socket is left unread while the phone's main thread is behind, so the host
/// backs up instead of the phone's memory (RI-01); a newer whole state replaces one still
/// waiting (RI-04). Built and run by run.sh on macOS.
@main
struct RemoteClientBackpressureCheck {
    @MainActor
    static func main() async throws {
        var pair: [Int32] = [-1, -1]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &pair) == 0)
        let clientFD = pair[0], hostFD = pair[1]
        precondition(fcntl(clientFD, F_SETFL, O_NONBLOCK) == 0)
        let host = ScriptedHost(fd: hostFD)
        let client = RemoteHostClient(socketOpen: { _, _ in clientFD })
        let received = Received()
        client.onOutputConsumed = { _, data, completion in received.output(data, completion: completion) }
        client.onStateChanged = { received.state($0) }
        client.onSessionExited = { _, _ in received.sawExit() }
        client.onDisconnected = { received.disconnected($0) }
        host.start()
        _ = try await client.connect(host: "fixture", port: 1, token: "t", clientName: "check")
        check(client.capabilities.contains(RemoteProtocol.nativeThreadCapability), "handshake carried the host's capabilities")

        // RI-14: a read whose screen went away stops waiting at once; its reply, when it comes,
        // is dropped, and the connection goes on serving.
        host.hold = true
        // Detached: waiting for the host below holds the main thread.
        let abandoned = Task.detached { try await client.nativeThread(agentID: AgentID(rawValue: "a"), request: .snapshot()) }
        precondition(host.waitForRequest(timeout: 3), "the snapshot request reached the host")
        abandoned.cancel()
        let cancelled = await withTaskGroup(of: Bool.self) { group in
            group.addTask { (try? await abandoned.value) == nil }
            group.addTask { try? await Task.sleep(for: .seconds(2)); return false }
            let first = await group.next() ?? false
            group.cancelAll()
            return first
        }
        check(cancelled, "a cancelled read stops waiting before the host answers")
        host.hold = false
        host.releaseHeld()
        try? await Task.sleep(for: .milliseconds(100))
        guard case .snapshot = try await client.nativeThread(agentID: AgentID(rawValue: "a"), request: .snapshot()) else {
            fatalError("the connection serves after a late reply")
        }
        check(received.disconnectReason == nil, "a late reply to a cancelled read keeps the connection")

        host.hold = true
        let abandonedDigest = Task.detached { () -> Bool in
            do { _ = try await client.fleetDigest(agentID: AgentID(rawValue: "a")); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        check(try await eventually("the digest is held by the host") { host.heldCount == 1 }, "digest reached the host")
        abandonedDigest.cancel()
        check(await abandonedDigest.value, "digest cancellation releases its waiter without waiting for the timeout")
        host.hold = false
        host.releaseHeld()
        guard case .digest = try await client.fleetDigest(agentID: AgentID(rawValue: "a")) else {
            fatalError("digest connection failed after cancellation and late reply")
        }
        check(received.disconnectReason == nil, "cancelled digest and its late reply preserve the connection")

        // SF-01: hold actual downstream consumption, not the main callback. Main remains free.
        received.holdOutput = true
        let total = 6 * 1024 * 1024
        let writer = Thread {
            host.push(.stateChanged(state: Self.state("one")))
            host.push(.stateChanged(state: Self.state("two")))
            host.push(.stateChanged(state: Self.state("three")))
            let session = SessionID()
            var sent = 0
            while sent < total {
                let chunk = min(64 * 1024, total - sent)
                host.push(.output(sessionID: session, data: Data(repeating: UInt8(ascii: "x"), count: chunk)))
                sent += chunk
                host.written = sent
            }
            host.push(.sessionExited(sessionID: session, code: 0))
        }
        writer.start()
        let stalled = try await eventually("the host backs up behind the stalled parser") {
            host.blocked && host.written >= RemoteHostClient.pauseReadsAtBytes / 2
        }
        check(stalled, "parser gate: written=\(host.written), blocked=\(host.blocked), hops=\(received.hops), bytes=\(received.outputBytes)")
        check(host.written < total && !received.exited, "parser stall bounds transport and keeps exit behind output")
        check(received.hops == 1, "main stays free but no second output is delivered before parser consumption")
        received.releaseOutput()
        check(try await eventually("every pushed byte and ordered exit drain") { received.exited }, "ordered output/exit drained")
        check(received.outputBytes == total, "no output byte is lost or repeated (\(received.outputBytes) of \(total))")
        check(received.largestHop <= RemoteHostClient.deliveryBudgetBytes + 64 * 1024,
              "one hop carries at most the delivery budget and one frame (\(received.largestHop))")
        check(received.hops > 1, "the flood arrived over several hops (\(received.hops))")
        let names = received.stateNames
        check(names.last == "three", "the final state arrived (\(names))")

        // IO-06: small non-output-only events must hit the count bound even below the byte cap.
        client.onNativeThreadChanged = { _ in received.hint() }
        let a = AgentID(), b = AgentID()
        for large in [false, true] {
            let blocker = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { blocker.wait() }
            host.written = 0
            let events = large ? 256 : 10_000
            let before = received.hints
            Thread {
                for index in 0..<events {
                    if large { host.push(.stateChanged(state: Self.state(String(repeating: "x", count: 32 * 1024)))) }
                    host.push(.nativeThreadChanged(agentID: index.isMultiple(of: 2) ? a : b))
                    host.written = index + 1
                }
            }.start()
            await Task.detached {
                defer { blocker.signal() }
                let stalled = try! await Self.eventually("nonterminal-only pushes back up") {
                    host.blocked && host.written >= (large ? 100 : RemoteHostClient.pauseReadsAtEvents)
                }
                Self.check(stalled && host.written < events, "nonterminal backlog is bounded by content and count")
            }.value
            check(try await eventually("nonterminal flood drains") { received.hints == before + events }, "all ordered nonterminal events drained")
            check(received.largestEventBatch <= RemoteHostClient.deliveryBudgetEvents,
                  "nonterminal delivery batches respect the event count budget")
        }
        // Independent optional design invalidations must survive coalescing in either order.
        client.onDesignChanged = { received.design($0, revision: $1, comments: $2) }
        received.holdOutput = true
        host.push(.output(sessionID: SessionID(), data: Data([1])))
        let beforeHints = received.hops
        check(try await eventually("output gates design delivery") { received.hops > beforeHints }, "output gate installed")
        let designA = DesignID(), designB = DesignID(), designC = DesignID()
        for event: RemoteReply in [
            .designChanged(designID: designA, revision: 1, commentsRevision: nil),
            .designChanged(designID: designA, revision: nil, commentsRevision: 2),
            .designChanged(designID: designA, revision: 3, commentsRevision: nil),
            .designChanged(designID: designA, revision: nil, commentsRevision: 4),
            .designChanged(designID: designB, revision: nil, commentsRevision: 5),
            .designChanged(designID: designB, revision: 6, commentsRevision: nil),
            .designChanged(designID: designB, revision: nil, commentsRevision: 7),
            .designChanged(designID: designB, revision: 8, commentsRevision: nil),
            .designChanged(designID: designC, revision: 9, commentsRevision: nil),
            .designChanged(designID: designA, revision: nil, commentsRevision: 10)
        ] { host.push(event) }
        _ = try await client.nativeThread(agentID: AgentID(rawValue: "a"), request: .snapshot())
        check(received.designs.isEmpty, "hints remain behind the held delivery")
        received.releaseOutput()
        check(try await eventually("coalesced design hints drain") { received.designs.count == 4 }, "design hints drained")
        let hints = received.designs
        check(hints[0].0 == designA && hints[0].1 == 3 && hints[0].2 == 4, "board-first keeps both latest fields")
        check(hints[1].0 == designB && hints[1].1 == 8 && hints[1].2 == 7, "comments-first keeps both latest fields")
        check(hints[2].0 == designC && hints[2].1 == 9 && hints[2].2 == nil, "different design owns its invalidation")
        check(hints[3].0 == designA && hints[3].1 == nil && hints[3].2 == 10, "never coalesce across another owner")
        client.disconnect()
        try await checkReconnectFence()
        print("PASS: parser/push budgets, independent design hints, pre-consumer reconnect fences, cancellable digest reads")
    }

    @MainActor
    static func checkReconnectFence() async throws {
        let oldAgent = AgentID(rawValue: "old"), newAgent = AgentID(rawValue: "new")
        let stale: [RemoteReply] = [
            .stateChanged(state: state("old")),
            .output(sessionID: SessionID(), data: Data("old".utf8)),
            .browserDrive(.handBack(agentID: oldAgent))
        ]
        for oldEvent in stale {
            var first: [Int32] = [-1, -1], second: [Int32] = [-1, -1]
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &first) == 0)
            precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &second) == 0)
            for fd in [first[0], second[0]] { precondition(fcntl(fd, F_SETFL, O_NONBLOCK) == 0) }
            let sockets = SocketSequence([first[0], second[0]])
            let host = ScriptedHost(fd: first[1]), replacement = ScriptedHost(fd: second[1])
            let client = RemoteHostClient(socketOpen: { _, _ in sockets.next() })
            let received = Received()
            received.holdOutput = true
            client.onOutputConsumed = { _, bytes, completion in received.output(bytes, completion: completion) }
            client.onStateChanged = { received.state($0) }
            client.onBrowserDrive = { received.control($0) }
            client.onDisconnected = { received.disconnected($0) }
            host.start(); replacement.start()
            _ = try await client.connect(host: "fixture", port: 1, token: "t", clientName: "old")
            let blocker = DispatchSemaphore(value: 0)
            DispatchQueue.main.async { blocker.wait() }
            try await Task.detached {
                defer { blocker.signal() }
                host.push(oldEvent)
                // Reply handling is queue-local: this proves the pushed batch was captured
                // behind blocked main before teardown, not merely left unread in the socket.
                _ = try await client.nativeThread(agentID: oldAgent, request: .snapshot())
                client.disconnect()
                _ = try? await client.request { .stateFetch(id: $0) }
                _ = try await client.connect(host: "fixture", port: 1, token: "t", clientName: "new")
                let session = SessionID()
                replacement.push(.output(sessionID: session, data: Data([1])))
                replacement.push(.stateChanged(state: Self.state("new")))
                replacement.push(.browserDrive(.handBack(agentID: newAgent)))
                replacement.push(.output(sessionID: session, data: Data([2])))
                _ = try await client.nativeThread(agentID: newAgent, request: .snapshot())
            }.value
            check(try await eventually("new connection delivers its first output") { received.hops >= 1 }, "new connection is live")
            _ = try await client.nativeThread(agentID: newAgent, request: .snapshot())
            check(received.hops == 1 && received.outputBytes == 1, "old batch never invokes output or retires the new output gate")
            check(received.stateNames.isEmpty && received.controls.isEmpty, "old state and command batches never reach current handlers")
            check(received.disconnectReason == nil, "old disconnect notification is fenced too")
            received.releaseOutput()
            check(try await eventually("new connection drains after consumption") { received.hops == 2 }, "new output completion resumes delivery")
            check(received.outputBytes == 2 && received.stateNames == ["new"], "only new output/state delivered exactly once")
            check(received.controls == [.handBack(agentID: newAgent)], "only the new command reached its owner")
            client.disconnect()
        }
    }

    @discardableResult
    static func eventually(_ message: String, _ condition: @escaping @Sendable () -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now + .seconds(15)
        while !condition() {
            guard ContinuousClock.now < deadline else { print("timeout: \(message)"); return false }
            await Task.yield()
        }
        return true
    }

    static func state(_ name: String) -> ShepherdState {
        let space = Space(name: "web", path: "/tmp/web")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(LeafPane(cwd: space.path)))
        return ShepherdState(spaces: [space], tabs: [tab], agents: [Agent(name: name, spaceID: space.id, tabID: tab.id)])
    }

    static func check(_ condition: Bool, _ what: String) {
        guard !condition else { return }
        print("FAIL: \(what)")
        exit(1)
    }
}

/// What the client delivered, counted under a lock: callbacks land on main, the checks read
/// from other threads.
final class Received: @unchecked Sendable {
    private let lock = NSLock()
    private var bytes = 0
    private var hopCount = 0
    private var largest = 0
    private var names: [String] = []
    private var exit = false
    private var reason: String?
    private var designHints: [(DesignID, UInt64?, UInt64?)] = []
    private var controlPushes: [BrowserDrivePush] = []
    var designs: [(DesignID, UInt64?, UInt64?)] { lock.lock(); defer { lock.unlock() }; return designHints }
    var controls: [BrowserDrivePush] { lock.lock(); defer { lock.unlock() }; return controlPushes }
    func design(_ id: DesignID, revision: UInt64?, comments: UInt64?) {
        lock.lock(); defer { lock.unlock() }; designHints.append((id, revision, comments))
    }
    func control(_ push: BrowserDrivePush) { lock.lock(); defer { lock.unlock() }; controlPushes.append(push) }
    private var hintCount = 0
    private var eventBatch = 0
    private var largestBatch = 0
    var hints: Int { lock.lock(); defer { lock.unlock() }; return hintCount }
    var largestEventBatch: Int { lock.lock(); defer { lock.unlock() }; return largestBatch }
    func hint() {
        lock.lock(); hintCount += 1; lock.unlock()
        event()
    }
    private func event() {
        lock.lock()
        let first = eventBatch == 0
        eventBatch += 1
        largestBatch = max(largestBatch, eventBatch)
        lock.unlock()
        if first { DispatchQueue.main.async { self.lock.lock(); self.eventBatch = 0; self.lock.unlock() } }
    }

    var holdOutput = false // Main actor configures the gate before output delivery.
    private var outputCompletion: (@Sendable () -> Void)?

    func output(_ data: Data, completion: @escaping @Sendable () -> Void) {
        lock.lock()
        bytes += data.count
        hopCount += 1
        largest = max(largest, data.count)
        if holdOutput { outputCompletion = completion }
        lock.unlock()
        if !holdOutput { completion() }
    }
    func releaseOutput() {
        lock.lock()
        holdOutput = false
        let finish = outputCompletion
        outputCompletion = nil
        lock.unlock()
        finish?()
    }
    func state(_ state: ShepherdState) {
        lock.lock()
        names.append(state.agents.first?.name ?? "?")
        lock.unlock()
        event()
    }
    func disconnected(_ why: String) { lock.lock(); reason = why; lock.unlock() }
    func sawExit() { lock.lock(); exit = true; lock.unlock() }
    var outputBytes: Int { lock.lock(); defer { lock.unlock() }; return bytes }
    var hops: Int { lock.lock(); defer { lock.unlock() }; return hopCount }
    var largestHop: Int { lock.lock(); defer { lock.unlock() }; return largest }
    var stateNames: [String] { lock.lock(); defer { lock.unlock() }; return names }
    var exited: Bool { lock.lock(); defer { lock.unlock() }; return exit }
    var disconnectReason: String? { lock.lock(); defer { lock.unlock() }; return reason }
}

private final class SocketSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var descriptors: [Int32]
    init(_ descriptors: [Int32]) { self.descriptors = descriptors }
    func next() -> Int32 {
        lock.lock(); defer { lock.unlock() }
        return descriptors.removeFirst()
    }
}

/// The host's end of the socketpair: answers hello and the state fetch, answers a snapshot
/// request at once or holds it (`hold`), and pushes whatever it is handed with blocking writes.
final class ScriptedHost: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    /// One frame at a time on the wire; a blocked write holds only this.
    private let writeLock = NSLock()
    private var held: [RemoteReply] = []
    var heldCount: Int { lock.lock(); defer { lock.unlock() }; return held.count }
    private var requests = 0
    private let requested = DispatchSemaphore(value: 0)
    var hold: Bool {
        get { lock.lock(); defer { lock.unlock() }; return holding }
        set { lock.lock(); holding = newValue; lock.unlock() }
    }
    var written: Int {
        get { lock.lock(); defer { lock.unlock() }; return writtenBytes }
        set { lock.lock(); writtenBytes = newValue; lock.unlock() }
    }
    private var holding = false
    private var writtenBytes = 0
    private var writeBlocked = false
    var blocked: Bool { lock.lock(); defer { lock.unlock() }; return writeBlocked }

    init(fd: Int32) {
        self.fd = fd
        precondition(fcntl(fd, F_SETFL, O_NONBLOCK) == 0)
    }

    func start() {
        Thread { self.serve() }.start()
    }

    func waitForRequest(timeout: TimeInterval) -> Bool {
        requested.wait(timeout: .now() + timeout) == .success
    }

    /// Answers every held snapshot request.
    func releaseHeld() {
        lock.lock()
        let replies = held
        held = []
        lock.unlock()
        for reply in replies { push(reply) }
    }

    func push(_ reply: RemoteReply) {
        let line = try! NDJSON.encode(reply)
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        while offset < line.count {
            let n = line.withUnsafeBytes { raw in Darwin.send(fd, raw.baseAddress!.advanced(by: offset), line.count - offset, MSG_DONTWAIT) }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                lock.lock(); writeBlocked = true; lock.unlock()
                var writable = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&writable, 1, 1000)
                continue
            }
            lock.lock(); writeBlocked = false; lock.unlock()
            precondition(n > 0, "host write failed: errno \(errno)")
            offset += n
        }
    }

    private func serve() {
        var buffer = LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                var readable = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&readable, 1, 1000)
                continue
            }
            if n <= 0 { return }
            for line in try! buffer.append(Data(bytes: bytes, count: n)) {
                let request = try! NDJSON.decode(RemoteRequest.self, from: line)
                switch request {
                case .hello(let id, _, _, _, _):
                    push(.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.nativeThreadCapability, RemoteProtocol.nativeFleetDigestCapability]))
                case .stateFetch(let id):
                    push(.state(id: id, state: ShepherdState()))
                case .nativeThread(let id, _, _):
                    if hold {
                        lock.lock(); held.append(.nativeThread(id: id, result: .snapshot(value: Self.snapshot))); lock.unlock()
                    } else {
                        push(.nativeThread(id: id, result: .snapshot(value: Self.snapshot)))
                    }
                    requested.signal()
                case .fleetDigest(let id, _, _, _):
                    let reply = RemoteReply.fleetDigest(id: id, result: .digest(FleetDigest(Self.snapshot)))
                    if hold { lock.lock(); held.append(reply); lock.unlock() }
                    else { push(reply) }
                    requested.signal()
                default:
                    break
                }
            }
        }
    }

    static let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false, supportedActions: [],
                                               dialogsSupported: true, dialogs: [], messages: [], provisional: [], clipped: false,
                                               runtime: "rpc")
}
