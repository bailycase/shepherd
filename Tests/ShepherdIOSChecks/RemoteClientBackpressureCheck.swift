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
        client.onOutput = { _, data in received.output(data) }
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

        // RI-01 and RI-04: hold the main thread, flood it, and watch the host stall.
        let blocker = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { blocker.wait() }
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
        // Detached: the main thread is held, and this must not wait behind it; it frees main
        // itself, since this task resumes there.
        let (stalled, writtenWhileHeld) = await Task.detached { () -> (Bool, Int) in
            try? await Task.sleep(for: .seconds(1))
            let written = host.written
            blocker.signal()
            return (written < total, written)
        }.value
        check(stalled, "the host's writes stall while the phone cannot drain its backlog (\(writtenWhileHeld) of \(total) written)")
        let drained = await Task.detached { () -> Bool in
            for _ in 0..<200 {
                if received.exited { return true }
                try? await Task.sleep(for: .milliseconds(50))
            }
            return false
        }.value
        check(drained, "every pushed byte and the exit after them land once main is free")
        check(received.outputBytes == total, "no output byte is lost or repeated (\(received.outputBytes) of \(total))")
        check(received.largestHop <= RemoteHostClient.deliveryBudgetBytes + 64 * 1024,
              "one hop carries at most the delivery budget and one frame (\(received.largestHop))")
        check(received.hops > 1, "the flood arrived over several hops (\(received.hops))")
        let names = received.stateNames
        check(names.last == "three" && names.count <= 2, "a newer whole state replaced the one waiting (\(names))")
        client.disconnect()
        print("PASS: cancelled reads let go, late replies are dropped, pushes are bounded and states coalesce")
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

    func output(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        bytes += data.count
        hopCount += 1
        largest = max(largest, data.count)
    }
    func state(_ state: ShepherdState) {
        lock.lock(); defer { lock.unlock() }
        names.append(state.agents.first?.name ?? "?")
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

/// The host's end of the socketpair: answers hello and the state fetch, answers a snapshot
/// request at once or holds it (`hold`), and pushes whatever it is handed with blocking writes.
final class ScriptedHost: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    /// One frame at a time on the wire; a blocked write holds only this.
    private let writeLock = NSLock()
    private var held: [Int] = []
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

    init(fd: Int32) { self.fd = fd }

    func start() {
        Thread { self.serve() }.start()
    }

    func waitForRequest(timeout: TimeInterval) -> Bool {
        requested.wait(timeout: .now() + timeout) == .success
    }

    /// Answers every held snapshot request.
    func releaseHeld() {
        lock.lock()
        let ids = held
        held = []
        lock.unlock()
        for id in ids { push(.nativeThread(id: id, result: .snapshot(value: Self.snapshot))) }
    }

    func push(_ reply: RemoteReply) {
        let line = try! NDJSON.encode(reply)
        writeLock.lock(); defer { writeLock.unlock() }
        var offset = 0
        while offset < line.count {
            let n = line.withUnsafeBytes { raw in Darwin.write(fd, raw.baseAddress!.advanced(by: offset), line.count - offset) }
            if n < 0, errno == EINTR { continue }
            precondition(n > 0, "host write failed: errno \(errno)")
            offset += n
        }
    }

    private func serve() {
        var buffer = LineBuffer()
        var bytes = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = Darwin.read(fd, &bytes, bytes.count)
            if n <= 0 { return }
            for line in try! buffer.append(Data(bytes: bytes, count: n)) {
                let request = try! NDJSON.decode(RemoteRequest.self, from: line)
                switch request {
                case .hello(let id, _, _, _, _):
                    push(.helloOk(id: id, protocolVersion: RemoteProtocol.version, capabilities: [RemoteProtocol.nativeThreadCapability]))
                case .stateFetch(let id):
                    push(.state(id: id, state: ShepherdState()))
                case .nativeThread(let id, _, _):
                    if hold {
                        lock.lock(); held.append(id); lock.unlock()
                    } else {
                        push(.nativeThread(id: id, result: .snapshot(value: Self.snapshot)))
                    }
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
