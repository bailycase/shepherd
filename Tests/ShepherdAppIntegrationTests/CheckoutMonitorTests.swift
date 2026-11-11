import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import ShepherdSessions
@testable import ShepherdApp

/// The header's branch chip: each local agent's checkout read off the main thread, after the
/// events that change it, never once per request.
@Suite("Checkout monitor", .mainActorExclusive)
@MainActor
struct CheckoutMonitorTests {
    /// A new agent's checkout is read at once; showing it again reads the files it changed.
    @Test func anAgentsBranchAndChangedFilesReachTheWorkspace() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["file.txt": "before\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let server = app.server
        try await eventuallyOnMain("the first read") {
            server.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 0)
        }

        try "after\n".write(to: repo.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        try "fresh\n".write(to: repo.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)
        vm.selectAgent(agent.agent.id)
        // What the app, active, tells its host as the selection lands (`syncFocusedThread`).
        app.remoteHosts.focusLocalThread(agent.agent.id)

        try await eventuallyOnMain("the changed files") {
            server.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 2)
        }
        #expect(vm.state.agents.first?.checkout == AgentCheckout(branch: "main", changedFiles: 2))
    }

    /// A branch card's switch (git run by the app) and a review's load (read by the host) move the
    /// chip at once, with no turn, tool or selection to read the checkout after.
    @Test func aBranchSwitchOrAReviewLoadMovesTheChipAtOnce() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: ["file.txt": "before\n"])
        defer { try? FileManager.default.removeItem(at: repo) }
        try sh("git branch feature", in: repo)
        let space = Fixture.space(path: repo.path)
        let agent = Fixture.agent(in: space)
        let id = agent.agent.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let server = app.server
        func branch() -> String? { server.state.agents.first?.checkout?.branch }
        try await eventuallyOnMain("the first read") { branch() == "main" }

        let cwd = repo.path
        vm.branchGit(id, "Couldn’t switch") { try BranchGit.switchBranch(cwd: cwd, to: "feature") }
        try await eventuallyOnMain("the switch on the chip") { branch() == "feature" && vm.state.agents.first?.checkout?.branch == "feature" }

        try sh("git switch -q main", in: repo)
        _ = try await app.remoteHosts.agentQuery(try #require(vm.localRef(id)), query: .changesList(scope: .uncommitted, options: ChangesOptions()))
        try await eventuallyOnMain("the review's load on the chip") { branch() == "main" }
    }

    /// Distinct checkouts keep the concurrency cap and one follow-up read for a refresh burst.
    @Test func requestsCoalesceIntoOneReadPerCheckout() async throws {
        let reads = Reads()
        let writes = Locked<[AgentID]>([])
        let monitor = CheckoutMonitor(read: { cwd in await reads.read(cwd) }) { ids, _, _ in writes.withValue { $0.append(contentsOf: ids) } }
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
        var deliveries = 0
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { ids, _, _ in
            deliveries += 1
            writes.withValue { $0.append(contentsOf: ids) }
        }
        let ids = (0..<20).map { _ in AgentID() }
        monitor.directory = { $0 == ids[0] ? "/shared/./repo" : "/shared/repo" }
        monitor.sync(agents: Array(ids.dropLast()))
        try await eventuallyOnMain("one shared read") { reads.started.count == 1 }
        monitor.sync(agents: ids)
        reads.open()
        try await eventuallyOnMain("all agents share the result") { writes.current.count == ids.count }
        #expect(reads.started == ["/shared/repo"])
        #expect(deliveries == 1)
        for id in ids { monitor.refresh(id) }
        try await eventuallyOnMain("one coalesced refresh") { writes.current.count == ids.count * 2 }
        #expect(reads.started.count == 2)
        #expect(deliveries == 2)
    }

    @Test func movedAndRemovedAgentsDoNotReceiveTheOldCheckout() async throws {
        let reads = Reads()
        defer { reads.open() }
        let writes = Locked<[(AgentID, String)]>([])
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { ids, cwd, _ in writes.withValue { $0.append(contentsOf: ids.map { ($0, cwd) }) } }
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
        var deliveries = 0
        var directories: [AgentID: String] = [:]
        let monitor = CheckoutMonitor(read: { await reads.read($0) }) { ids, cwd, _ in
            deliveries += 1
            if holdFirst {
                holdFirst = false
                for await _ in gate {}
            }
            // Like the server, recheck membership at the mutation boundary.
            writes.append(contentsOf: ids.filter { directories[$0] == cwd })
        }
        let initial = [AgentID(), AgentID()], joined = AgentID()
        directories = Dictionary(uniqueKeysWithValues: initial.map { ($0, "/shared") })
        monitor.directory = { directories[$0] }
        monitor.sync(agents: initial)
        try await eventuallyOnMain("first delivery held") { deliveries == 1 }
        let retained = initial[0]
        let removed = initial[1]
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
        let submitted = ContinuousClock.now
        let (result, readDuration) = await Task.detached {
            let start = ContinuousClock.now
            let result = CheckoutStatus.read(cwd: root.path, executable: script.path, timeout: 0.05)
            return (result, start.duration(to: .now))
        }.value
        // The command's deadline includes its process cleanup, not unrelated main-actor
        // work before this task is scheduled or after its completed result is delivered.
        print("hung checkout read: command=\(readDuration), roundTrip=\(submitted.duration(to: .now))")
        #expect(result == nil)
        #expect(readDuration < .seconds(3))
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
