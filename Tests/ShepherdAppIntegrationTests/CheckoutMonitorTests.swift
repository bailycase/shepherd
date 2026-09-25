import Foundation
import ShepherdCore
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The header's branch chip: each local agent's checkout read off the main thread, after the
/// events that change it, never once per request.
@Suite("Checkout monitor", .mainActorExclusive)
@MainActor
struct CheckoutMonitorTests {
    /// A new agent's checkout is read at once; selecting it again reads the files it changed.
    @Test func anAgentsBranchAndChangedFilesReachTheWorkspace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["file.txt": "before\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]), readingCheckouts: true)
        let server = app.server
        try await eventuallyOnMain("the first read") {
            server.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 0)
        }

        try "after\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        vm.selectAgent(agent.agent.id)

        try await eventuallyOnMain("the changed files") {
            server.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 2)
        }
        #expect(vm.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 2))
    }

    /// Requests for one agent coalesce: a burst due later reads once, a request made while a read
    /// runs reads once more after it, and at most `maxConcurrent` agents read at a time.
    @Test func requestsCoalesceIntoOneReadPerAgent() async throws {
        let reads = Reads()
        let writes = Locked<[AgentID]>([])
        let monitor = CheckoutMonitor(read: { cwd in await reads.read(cwd) }) { id, _ in writes.withValue { $0.append(id) } }
        let ids = (0..<6).map { _ in AgentID() }
        monitor.directory = { id in ids.firstIndex(of: id).map { "/agent-\($0)" } }

        monitor.sync(agents: ids)
        try await eventuallyOnMain("four reads to start") { reads.started.count == CheckoutMonitor.maxConcurrent }
        #expect(Set(reads.started) == Set((0..<4).map { "/agent-\($0)" }), "the rest wait their turn")
        for _ in 0..<5 { monitor.refresh(ids[0], after: .milliseconds(20)) }
        reads.open()

        try await eventuallyOnMain("every agent read, and the burst once more") { writes.current.count == 7 }
        #expect(reads.started.count == 7)
        #expect(writes.current.filter { $0 == ids[0] }.count == 2)
    }
}

/// Reads held until the test opens the gate; after that they answer at once.
private final class Reads: Sendable {
    private struct Gate {
        var started: [String] = []
        var held: [CheckedContinuation<Void, Never>] = []
        var isOpen = false
    }

    private let gate = Locked(Gate())
    var started: [String] { gate.current.started }

    func read(_ cwd: String) async -> AgentCheckout? {
        await withCheckedContinuation { continuation in
            let resume = gate.withValue { gate in
                gate.started.append(cwd)
                if !gate.isOpen { gate.held.append(continuation) }
                return gate.isOpen
            }
            if resume { continuation.resume() }
        }
        return AgentCheckout(branch: "main", changedFiles: 0)
    }

    func open() {
        let held = gate.withValue { gate in
            gate.isOpen = true
            defer { gate.held.removeAll() }
            return gate.held
        }
        held.forEach { $0.resume() }
    }
}
