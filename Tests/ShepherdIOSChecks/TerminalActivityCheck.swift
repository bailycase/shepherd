import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The real iOS activity store over ActionHost's loopback connection. Poll ticks are released
/// explicitly: exact request counts do not depend on a wall-clock polling interval or sleeps.
@MainActor
enum TerminalActivityCheck {
    static func run(defaults: UserDefaults) async throws {
        let agentID = AgentID(rawValue: "terminal-check")
        let thread = PaneID(rawValue: "thread")
        let pane = PaneID(rawValue: "shell")
        let replacementPane = PaneID(rawValue: "replacement")
        let session = SessionID(rawValue: "shell-session")
        let space = SpaceID(rawValue: "home")
        let tab = TabID(rawValue: "terminal-tab")
        func state(_ terminal: LeafPane? = nil) -> ShepherdState {
            let root = PaneNode.leaf(LeafPane(id: thread, cwd: "/fixture", agentID: agentID))
            let layout = terminal.map { PaneNode.split(axis: .horizontal, ratio: 0.5, first: root, second: .leaf($0)) } ?? root
            return ShepherdState(spaces: [Space(id: space, name: "Home", path: "/fixture")],
                                 tabs: [Tab(id: tab, spaceID: space, order: 0, layout: layout)],
                                 agents: [Agent(id: agentID, name: "Terminal check", spaceID: space, tabID: tab, paneID: thread)])
        }
        let server = try ActionHost(state: state(), terminalActivity: true)
        let oldServer = try ActionHost(state: state(LeafPane(id: pane, sessionID: session, cwd: "/fixture")))
        let hosts = MobileHosts(defaults: defaults, tokens: .memory())
        let id = try hosts.add(RemoteHostEntry(name: "Terminals", address: "127.0.0.1", port: String(server.port), token: ActionHost.token))
        let oldID = try hosts.add(RemoteHostEntry(name: "Old host", address: "127.0.0.1", port: String(oldServer.port), token: ActionHost.token))
        hosts.setForeground(true)
        defer { hosts.setForeground(false) }
        await until("both terminal hosts connected") { hosts.hosts.allSatisfy { $0.phase.isConnected && !$0.state.tabs.isEmpty } }
        let host = hosts.host(id)!
        let ref = AgentRef(host: id, agent: agentID)
        let clock = PollGate()
        let terminals = MobileTerminals(pause: { await clock.pause($0) })

        await returns("no terminals returns without a watcher") { await terminals.watchActivity(ref, host: host) }
        check(server.terminalRequests == 0 && clock.waiting == 0, "a thread-only layout makes no terminal requests or timers")
        await returns("older host returns without a watcher") {
            await terminals.watchActivity(AgentRef(host: oldID, agent: agentID), host: hosts.host(oldID)!)
        }
        check(oldServer.terminalRequests == 0 && clock.waiting == 0, "terminal presence does not bypass the capability gate")

        // A terminal without a shell yet still counts. The thread and another window share one poll.
        server.push(state(LeafPane(id: pane, cwd: "/fixture")))
        await until("the first terminal arrives in pushed state") { MobileTerminals.hasTerminals(ref, host: host) }
        let first = Task { await terminals.watchActivity(ref, host: host) }
        let second = Task { await terminals.watchActivity(ref, host: host) }
        defer { first.cancel(); second.cancel() }
        await until("two holders share the first completed poll") { clock.holders == 2 && clock.polls == 1 }
        check(server.terminalRequests == 1, "first terminal starts exactly one immediate request for both holders")
        check(terminals.activity[ref] == [:], "a not-yet-started shell can answer with no activity")

        // Losing one window must not stop the other. An idle shell must continue being queried.
        first.cancel()
        await first.value
        await until("one holder remains") { clock.holders == 1 }
        server.push(state(LeafPane(id: pane, sessionID: session, cwd: "/fixture")))
        await until("the shell session is pushed") { host.state.tabs.first?.layout.leaves.last?.sessionID == session }
        clock.tick()
        await until("the remaining holder completes the next poll") { clock.polls == 1 && terminals.activity[ref]?[pane] != nil }
        check(server.terminalRequests == 2 && terminals.activity[ref]?[pane]?.isRunning == false,
              "idle shells remain watched after another window leaves")

        // Hold an old reply while the last terminal disappears. Clearing must stop every old
        // poll even if another window's cancelled task has not unwound its holder yet.
        server.holdTerminals()
        clock.tick()
        await until("the old activity reply is held") { server.heldTerminalRequests == 1 }
        check(server.terminalRequests == 3, "one controlled tick made exactly one held request")
        server.push(state())
        await until("the last terminal removal is pushed") { !MobileTerminals.hasTerminals(ref, host: host) }
        await returns("last removal ends watching") { await terminals.watchActivity(ref, host: host) }
        check(terminals.activity[ref] == nil && clock.polls == 0, "last removal clears obsolete activity and its poll")
        clock.tick()
        await returns("another empty holder also returns") { await terminals.watchActivity(ref, host: host) }
        check(server.terminalRequests == 3, "empty layouts send nothing, including with an old holder still unwinding")

        // Restart on the same connection before that old holder exits: its defer must not
        // decrement or cancel the replacement loop. The stale reply cannot refill old activity.
        server.push(state(LeafPane(id: replacementPane, sessionID: SessionID(rawValue: "replacement-session"), cwd: "/fixture")))
        await until("a replacement terminal is pushed") { MobileTerminals.hasTerminals(ref, host: host) }
        let replacement = Task { await terminals.watchActivity(ref, host: host) }
        defer { replacement.cancel() }
        await until("replacement activity is read") { clock.polls == 1 && terminals.activity[ref]?[replacementPane] != nil }
        check(server.terminalRequests == 4 && server.heldTerminalRequests == 1, "the new loop reads while the cancelled old poll is still in flight")
        server.releaseTerminals()
        second.cancel()
        await second.value
        await until("only the replacement holder remains") { clock.holders == 1 }
        clock.tick()
        await until("replacement survives old holder cleanup") { clock.polls == 1 && server.terminalRequests == 5 }
        check(terminals.activity[ref]?.count == 1 && terminals.activity[ref]?[replacementPane] != nil,
              "the late old reply cannot refill activity; the replacement remains live with exactly its own activity")
        replacement.cancel()
        await replacement.value
        await until("the last visible holder releases its poll") { clock.waiting == 0 }
        check(server.terminalRequests == 5, "last holder cancellation sends no extra requests")

        hosts.setForeground(false)
        await until("background disconnects the hosts") { hosts.hosts.allSatisfy { !$0.phase.isConnected } }
        await returns("disconnected terminal layout returns") { await terminals.watchActivity(ref, host: host) }
        check(server.terminalRequests == 5 && clock.waiting == 0, "a disconnected host starts no activity loop")
        print("PASS: terminal activity: zero requests without terminals, first terminal starts one shared loop, idle shells stay watched, last removal clears safely, stale holders/replies cannot replace a new loop")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message)
    }

    private static func until(_ message: String, _ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !predicate() {
            precondition(ContinuousClock.now < deadline, "timed out: \(message)")
            await Task.yield()
        }
    }

    private static func returns(_ message: String, _ work: @escaping @MainActor () async -> Void) async {
        var finished = false
        let task = Task { await work(); finished = true }
        defer { task.cancel() }
        await until(message) { finished }
        await task.value
    }
}

/// AsyncStream's cancelled iterator wakes without a real timer. Only the production two-second
/// poll wait is advanced; holder waits remain until their owning task is cancelled.
@MainActor
private final class PollGate {
    private var waits: [UUID: (Duration, AsyncStream<Void>.Continuation)] = [:]
    var polls: Int { waits.values.filter { $0.0 == MobileTerminals.activityInterval }.count }
    var holders: Int { waits.values.filter { $0.0 != MobileTerminals.activityInterval }.count }
    var waiting: Int { waits.count }

    func pause(_ duration: Duration) async {
        let id = UUID()
        let (stream, continuation) = AsyncStream<Void>.makeStream()
        waits[id] = (duration, continuation)
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        waits[id] = nil
    }

    func tick() {
        for (id, wait) in waits where wait.0 == MobileTerminals.activityInterval {
            waits[id] = nil
            wait.1.finish()
        }
    }
}

// The portable check compiles the real MobileTerminals, never UIKit/SwiftTerm or a terminal
// surface. Activity polling must not create or attach one.
@MainActor
final class TerminalSurfaceView {
    var applicationCursor: Bool { fatalError("activity must not access a terminal surface") }
    func feed(_ data: Data) { fatalError("activity must not feed a terminal surface") }
    func latch(control: Bool, option: Bool) { fatalError("activity must not latch terminal keys") }
    func reset() { fatalError("activity must not reset a terminal surface") }
}
