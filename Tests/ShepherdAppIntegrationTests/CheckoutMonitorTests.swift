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

    /// Distinct checkouts keep the concurrency cap and one follow-up read for a refresh burst.
    @Test func requestsCoalesceIntoOneReadPerCheckout() async throws {
        let reads = Reads()
        let writes = Locked<[AgentID]>([])
        let monitor = CheckoutMonitor(read: { cwd in await reads.read(cwd) }) { id, _, _ in writes.withValue { $0.append(id) } }
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

    @Test func agentsSharingACheckoutJoinOneReadAndOneFollowUp() async throws {
        let reads = Reads()
        defer { reads.open() }
        let writes = Locked<[AgentID]>([])
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { id, _, _ in writes.withValue { $0.append(id) } }
        let ids = (0..<20).map { _ in AgentID() }
        monitor.directory = { $0 == ids[0] ? "/shared/./repo" : "/shared/repo" }
        monitor.sync(agents: Array(ids.dropLast()))
        try await eventuallyOnMain("one shared read") { reads.started.count == 1 }
        monitor.sync(agents: ids)
        reads.open()
        try await eventuallyOnMain("all agents share the result") { writes.current.count == ids.count }
        #expect(reads.started == ["/shared/repo"])
        for id in ids { monitor.refresh(id) }
        try await eventuallyOnMain("one coalesced refresh") { writes.current.count == ids.count * 2 }
        #expect(reads.started.count == 2)
    }

    @Test func movedAndRemovedAgentsDoNotReceiveTheOldCheckout() async throws {
        let reads = Reads()
        defer { reads.open() }
        let writes = Locked<[(AgentID, String)]>([])
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { id, cwd, _ in writes.withValue { $0.append((id, cwd)) } }
        let moved = AgentID(), removed = AgentID(), retained = AgentID()
        var directories = [moved: "/old", removed: "/old", retained: "/old"]
        monitor.directory = { directories[$0] }
        monitor.sync(agents: [moved, removed, retained])
        try await eventuallyOnMain("old checkout read") { reads.started == ["/old"] }
        directories[moved] = "/new"
        directories[removed] = nil
        monitor.sync(agents: [moved, retained])
        reads.open()
        try await eventuallyOnMain("current checkouts delivered") { writes.current.count == 2 }
        #expect(writes.current.contains { $0.0 == moved && $0.1 == "/new" })
        #expect(writes.current.contains { $0.0 == retained && $0.1 == "/old" })
    }

    @Test func membershipChangesDuringDeliveryGetFreshResults() async throws {
        let reads = Reads()
        reads.open()
        let (gate, release) = AsyncStream<Void>.makeStream()
        defer { release.finish() }
        var writes: [AgentID] = []
        var holdFirst = true
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { id, _, _ in
            writes.append(id)
            if holdFirst {
                holdFirst = false
                for await _ in gate {}
            }
        }
        let initial = [AgentID(), AgentID()], joined = AgentID()
        var directories = Dictionary(uniqueKeysWithValues: initial.map { ($0, "/shared") })
        monitor.directory = { directories[$0] }
        monitor.sync(agents: initial)
        try await eventuallyOnMain("first delivery held") { writes.count == 1 }
        let retained = try #require(writes.first)
        let removed = try #require(initial.first { $0 != retained })
        directories[removed] = nil
        directories[joined] = "/shared"
        monitor.sync(agents: [retained, joined])
        release.finish()
        try await eventuallyOnMain("joined agent receives the follow-up") { writes.contains(joined) && writes.count == 3 }
        #expect(!writes.contains(removed))
        #expect(reads.started.count == 2)
    }

    @Test func aHungGitReadHasADeadline() async throws {
        let root = try makeScratchDirectory("slow-git")
        defer { try? FileManager.default.removeItem(at: root) }
        let script = root.appendingPathComponent("slow-git")
        try "#!/bin/sh\nexec /bin/sleep 60\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: script.path)
        let start = ContinuousClock.now
        let result = await Task.detached {
            CheckoutStatus.read(cwd: root.path, executable: script.path, timeout: 0.05)
        }.value
        #expect(result == nil)
        #expect(start.duration(to: .now) < .seconds(3))
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
