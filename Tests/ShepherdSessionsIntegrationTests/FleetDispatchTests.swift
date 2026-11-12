import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// Dispatch end to end between two real scratch hosts that share an origin: a thread on one Mac sends
/// work to the other, which makes a fresh worktree at the pinned commit, runs a thread there (a stub pi)
/// and sends the result back to the parent through the parent's host, with no app attached. Each Mac
/// has its own counters, clock and pi home; the threads' pis are the stub engine.
@Suite("Fleet dispatch", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct FleetDispatchTests {
    nonisolated static let repoKey = "github.com/acme/web"

    // MARK: Fixtures

    /// Waits for `condition`, which may read from a client.
    static func wait(_ what: String, timeout: Duration = .seconds(30), _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if try await condition() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        if try await condition() { return }
        throw WireError("timed out waiting for \(what)")
    }

    /// A bare origin with one commit, and that commit.
    struct Origin {
        var url: URL
        var sha: String
    }

    static func makeOrigin(extra: [String: String] = [:]) throws -> Origin {
        let seed = try makeScratchRepo(files: ["README.md": "# acme-web\n", "apps/web/index.js": "console.log('hi')\n", ".gitignore": "*.log\n"].merging(extra) { $1 })
        let origin = try makeScratchDirectory("origin").appendingPathComponent("origin.git")
        try git(["clone", "-q", "--bare", seed.path, origin.path], in: seed)
        return Origin(url: origin, sha: try git(["rev-parse", "HEAD"], in: seed).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    static func head(_ folder: URL) throws -> String {
        try git(["rev-parse", "HEAD"], in: folder).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A scratch host in a fleet: a checkout of the origin that is a space with the repo's key, its own counters
    /// and clock, a stub pi for its threads, and the settings the app would hold.
    final class Mac: @unchecked Sendable {
        let host: ScratchServer
        let port: UInt16
        let name: String
        let local: RemoteHostClient
        let meter: FleetPressureIntegrationTests.Meter
        let clock = FleetPressureIntegrationTests.TestClock()
        let folder: URL
        let token: String
        let settings: Locked<HostSettings>
        var server: SessionServer { host.server }
        var peersFile: URL { host.dir.appendingPathComponent("fleet/peers.json") }

        /// `dir` and `port` restart a Mac over its own files. `repoKey: nil` is a Mac whose checkout isn't known by any key.
        init(_ name: String, origin: Origin, busy: UInt64 = 20, repoKey: String? = FleetDispatchTests.repoKey, dir: URL? = nil, port: UInt16 = 0,
             sendWork: Bool = true, cap: Int = HostSettings.fleetThreadCapDefault) async throws {
            self.name = name
            meter = FleetPressureIntegrationTests.Meter(busy: busy)
            settings = Locked(HostSettings(fleetThreadsCanSend: sendWork, fleetThreadCap: cap))
            let scratch = try dir ?? makeScratchDirectory("dispatch")
            let host = try ScratchServer(dir: scratch)
            let server = host.server
            server.configureFleet(name: name, advertises: false)
            let (meter, clock) = (meter, clock)
            server.configureFleet(clock: { clock.now }, pressure: { queue, facts in
                FleetPressure(queue: queue, clock: { clock.now }, sampler: FleetPressureSampler(sources: meter.sources), localFacts: facts,
                              probe: { _ in FleetProbeResult() }, hardware: { (name, "M4 Pro") }, interval: 3_600)
            })
            let folder = scratch.appendingPathComponent("web", isDirectory: true)
            self.folder = folder
            if !FileManager.default.fileExists(atPath: folder.path) {
                try git(["clone", "-q", origin.url.path, folder.path], in: scratch)
                try git(["config", "user.name", "Shepherd Tests"], in: folder)
                try git(["config", "user.email", "tests@example.com"], in: folder)
                try await server.addSpace(Space(name: "acme-web", path: folder.path, repoKey: repoKey))
            }
            let tokenURL = scratch.appendingPathComponent("remote-token")
            let socket = scratch.appendingPathComponent("h.sock").path
            let port = try server.startRemoteListener(port: port, tokenURL: tokenURL)
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try server.startLocalListener(path: socket, tokenURL: tokenURL)
            await MainActor.run {
                server.serveThreads(ThreadHosting(defaults: {
                    ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard, worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
                }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
            }
            let settings = settings
            server.setFleetHostSettings { [weak server] change in
                let now = settings.withValue { $0.apply(change); return $0 }
                server?.fleetHostSettingsChanged(now)
            }
            server.fleetHostSettingsChanged(settings.current)
            server.setFleetEnabled(true)
            let local = RemoteHostClient(localSocket: socket)
            _ = try await local.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.port, self.local) = (host, port, local)
        }

        func stop(keepFiles: Bool = false) {
            local.disconnect()
            host.stop(keepFiles: keepFiles)
        }

        func hostID() async throws -> UUID { try #require(try await local.fleetRead().snapshot.hostID) }

        func pair(with other: Mac) async throws {
            let code = try #require(try await other.local.fleetAction(.startJoin).join).code
            try #require(try await local.fleetAction(.pair(host: "127.0.0.1", port: other.port, code: code)).paired)
        }

        /// Stop, as the thread's own view of it (the abort request ends here).
        func pressStop(_ agent: AgentID) {
            server.queue.sync { server.rpcThread(forAgent: agent)?.stop { _ in } }
        }

        /// This Mac's own space.
        var space: Space { server.state.spaces[0] }

        /// A thread of this Mac's space whose pi is the stub, with the panes connection a real pi would hold.
        @MainActor func parent(_ name: String = "Ship checkout") async throws -> Parent {
            let (agent, tab) = Fixture.agent(in: space, name: name)
            try await server.addAgent(agent, withTab: tab)
            return Parent(agent: agent, extension: try ExtensionClient(path: host.socketPath), mac: self)
        }

        /// The records this Mac holds as the sender (task and result included), and as the receiver.
        func sent() -> [FleetDispatchRecord] { server.queue.sync { Array(server.fleet?.dispatch.outbound.values ?? [:].values) } }
        func taken() -> [FleetDispatchRecord] { server.queue.sync { (server.fleet?.dispatch.inbound.values ?? [:].values).map(\.record) } }

        /// The threads this Mac runs for other Macs.
        var dispatched: [Agent] { server.state.agents.filter { $0.dispatchedFrom != nil } }

        func connectAsPeer(_ other: Mac) async throws -> RemoteHostClient {
            let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: other.peersFile)) as? [String: Any])
            let peers = try #require(file["peers"] as? [[String: Any]])
            let token = try #require(peers.first { $0["name"] as? String == name }?["myToken"] as? String)
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: other.name, capabilities: [], expectingHostID: nil, fetchesState: false)
            return client
        }

        /// Sets the thread's status as its pi's status extension would.
        func report(_ agent: AgentID, _ status: AgentStatus) throws {
            let client = try ExtensionClient(path: host.socketPath)
            try client.send(.helloAgent(agentID: agent))
            try client.send(.setAgentStatus(agentID: agent, status: status))
            statusClients.withValue { $0.append(client) }
        }

        private let statusClients = Locked<[ExtensionClient]>([])
    }

    /// A thread on a Mac and its panes connection: what `fleet_*` tools speak over.
    @MainActor struct Parent {
        var agent: Agent
        var `extension`: ExtensionClient
        var mac: Mac
        private static let nextID = Locked(100)

        /// The next line the host wrote to this thread's pi.
        func read(timeout: Duration = .seconds(10)) async throws -> ExtensionReply {
            let client = Unchecked(value: `extension`)
            return try await blocking { try client.value.readReply(timeout: timeout) }
        }

        func hello() throws { try `extension`.send(.helloAgent(agentID: agent.id)) }

        func call(_ make: (Int) -> ExtensionMessage) async throws -> ExtensionReply {
            let id = Self.nextID.withValue { $0 += 1; return $0 }
            try `extension`.send(make(id))
            while true {
                let reply = try await read()
                switch reply {
                case .fleetHosts(id, _), .fleetDispatch(id, _), .error(id, _, _): return reply
                default: continue
                }
            }
        }

        @discardableResult
        func dispatch(_ task: String = "Fix the flaky payment test.", key: String? = nil, title: String? = nil, host: String? = nil) async throws -> ExtensionReply {
            try await call { .fleetDispatch(id: $0, agentID: agent.id, dispatchID: key, task: task, title: title, host: host, model: nil, thinking: nil) }
        }

        func info(_ reply: ExtensionReply) throws -> FleetDispatchInfo {
            guard case .fleetDispatch(_, let info) = reply else { throw WireError("not a dispatch: \(reply)") }
            return info
        }

        func status(_ info: FleetDispatchInfo) async throws -> FleetDispatchInfo {
            try self.info(try await call { .fleetDispatchStatus(id: $0, agentID: agent.id, dispatchID: info.dispatchID) })
        }

        func cancel(_ info: FleetDispatchInfo) async throws -> FleetDispatchInfo {
            try self.info(try await call { .fleetDispatchCancel(id: $0, agentID: agent.id, dispatchID: info.dispatchID) })
        }

        /// The next message the host pushed to this thread's pi, if one arrives within `timeout`.
        func nextMessage(timeout: Duration = .seconds(10)) async -> (text: String, delivery: AgentMessageDelivery)? {
            while let reply = try? await read(timeout: timeout) {
                if case .message(_, let text, let delivery) = reply { return (text, delivery) }
            }
            return nil
        }
    }

    /// Two paired Macs sharing an origin, each holding what the other reported (the repo, its load).
    static func pair(busyA: UInt64 = 20, busyB: UInt64 = 20, sendWork: Bool = true, cap: Int = HostSettings.fleetThreadCapDefault,
                     originExtra: [String: String] = [:], repoKeyB: String? = repoKey,
                     originOfB: ((Origin) throws -> Origin)? = nil) async throws -> (a: Mac, b: Mac, origin: Origin) {
        try StubPi.installAsEngine()
        let origin = try makeOrigin(extra: originExtra)
        let a = try await Mac("MacBook Pro", origin: origin, busy: busyA, sendWork: sendWork, cap: cap)
        let b = try await Mac("Mac mini", origin: try originOfB?(origin) ?? origin, busy: busyB, repoKey: repoKeyB, sendWork: sendWork)
        try await a.pair(with: b)
        try await waitForReports(a, b)
        return (a, b, origin)
    }

    static func waitForReports(_ a: Mac, _ b: Mac) async throws {
        for (one, other) in [(a, b), (b, a)] {
            let id = try await other.hostID()
            try await Self.wait("\(one.name) to hold \(other.name)'s report and a link") {
                let snapshot = try await one.local.fleetRead().snapshot
                guard snapshot.peers.contains(where: { $0.hostID == id && $0.link == .connected }),
                      let held = snapshot.macs.first(where: { $0.hostID == id }) else { return false }
                return held.sample != nil && held.readiness != nil
            }
        }
    }

    // MARK: The headline: sent, run, and the result lands in the parent

    @Test func aDispatchRunsOnTheOtherMacAndItsResultWakesTheParentWithNoAppAttached() async throws {
        let (a, b, origin) = try await Self.pair(busyA: 90, busyB: 10)
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let aID = try await a.hostID()
        // No app on either Mac from here on: the hosts do all of it.
        a.local.disconnect(); b.local.disconnect()

        let info = try parent.info(try await parent.dispatch("Fix the flaky payment test.", key: "call-1", title: "Fix flaky payment test"))
        #expect(info.host == "Mac mini" && ["preparing", "running"].contains(info.state))

        // B made a fresh worktree at the pinned commit on its own branch and started a thread there, marked as sent.
        try await Self.wait("B to run the dispatched thread") { !b.dispatched.isEmpty }
        let thread = try #require(b.dispatched.first)
        #expect(thread.dispatchedFrom?.hostID == aID && thread.dispatchedFrom?.hostName == "MacBook Pro")
        #expect(thread.dispatchedFrom?.agentID == parent.agent.id && thread.dispatchedFrom?.agentTitle == "Ship checkout")
        #expect(thread.worktreeBranch == "fleet/fix-flaky-payment-test" && thread.name == "Fix flaky payment test")
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try Self.head(worktree) == origin.sha, "the pinned commit")
        #expect(try git(["branch", "--show-current"], in: worktree).trimmingCharacters(in: .whitespacesAndNewlines) == "fleet/fix-flaky-payment-test")
        try await eventuallyOnMain("the stub pi to start in the worktree") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == thread.id.rawValue } }

        // Both records follow it, and the sender learns the thread's id from the Mac that made it.
        try await Self.wait("A to follow the dispatch as running") { a.sent().first?.state == .running && a.sent().first?.remoteAgentID == thread.id }
        #expect(a.sent().first?.reasonCodes.first?.code == .mostRoom && a.sent().first?.targetHostName == "Mac mini")
        #expect(b.taken().first?.state == .running)

        // The thread works and settles; its last message and branch go back to the parent as a task.
        try b.report(thread.id, .working)
        try await Self.wait("B to see the thread working") { b.server.queue.sync { b.server.fleet?.dispatch.inbound.values.first?.startedWorking } == true }
        try b.report(thread.id, .done)
        let result = try #require(await parent.nextMessage())
        #expect(result.delivery == .task)
        #expect(result.text.hasPrefix("[from: Fix flaky payment test on Mac mini, an agent, not the user."), "the result is framed as another agent's words")
        #expect(result.text.contains("Result from Fix flaky payment test on Mac mini:"))
        #expect(result.text.contains("Branch fleet/fix-flaky-payment-test: 0 commits ahead of the start, not on origin"))
        try await Self.wait("both records to finish") { a.sent().first?.state == .done && b.taken().first?.state == .done }
        #expect(a.sent().first?.resultBranchFacts?.branch == "fleet/fix-flaky-payment-test")
        #expect(a.dispatched.isEmpty, "nothing ran on the sender")
    }

    // MARK: Idempotency

    @Test func aRetriedToolCallNamesTheDispatchItAlreadyMadeAndNothingStartsTwice() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let first = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        let second = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        #expect(first.dispatchID == second.dispatchID)
        let other = try parent.info(try await parent.dispatch(key: "call-2", host: "Mac mini"))
        #expect(other.dispatchID != first.dispatchID, "another call is another dispatch")
        try await Self.wait("B to run both") { b.dispatched.count == 2 }
        #expect(a.sent().count == 2 && b.taken().count == 2)
    }

    @Test func aCreateThatArrivesAgainReturnsTheThreadItStartedAndAnotherMacCannotTakeItOver() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        let create = FleetDispatchCreate(dispatchID: UUID(), task: "Look at the logs.", title: "Logs", repoKey: Self.repoKey, commitSHA: origin.sha,
                                         from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentTitle: "Ship checkout"))
        let first = try await viaA.fleetDispatchCreate(create)
        let again = try await viaA.fleetDispatchCreate(create)
        #expect(first.id == again.id && first.state == .preparing)
        try await Self.wait("one thread") { b.dispatched.count == 1 }
        // Created twice, the thread is made once, on one branch.
        #expect(b.server.state.agents.filter { $0.dispatchedFrom?.dispatchID == create.dispatchID }.count == 1)
        // A create that says it comes from another Mac than the one that authenticated is refused.
        var forged = create
        forged.dispatchID = UUID()
        forged.from.hostID = UUID()
        await #expect(throws: RemoteHostClientError.self) { try await viaA.fleetDispatchCreate(forged) }
    }

    // MARK: Guardrails

    @Test func threadsMaySendOnlyWhenTheSettingIsOnAndFleetIsOn() async throws {
        let (a, b, _) = try await Self.pair(sendWork: false)
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        #expect(HostSettings().fleetThreadsCanSend == false, "off until the person turns it on (Q5)")
        let refused = try await parent.dispatch(key: "off")
        guard case .error(_, FleetDispatchCode.sendOff, _) = refused else { Issue.record("sent with the setting off: \(refused)"); return }
        #expect(a.sent().isEmpty && b.dispatched.isEmpty)

        a.settings.withValue { $0.apply(.fleetThreadsCanSend(true)) }
        a.server.fleetHostSettingsChanged(a.settings.current)
        _ = try parent.info(try await parent.dispatch(key: "on", host: "Mac mini"))

        a.server.setFleetEnabled(false)
        try await Self.wait("Fleet to be off") { try await a.local.fleetRead().snapshot.enabled == false }
        guard case .error(_, FleetDispatchCode.fleetOff, _) = try await parent.dispatch(key: "fleet-off") else { Issue.record("sent with Fleet off"); return }
        guard case .error(_, FleetDispatchCode.fleetOff, _) = try await parent.call({ .fleetListHosts(id: $0, agentID: parent.agent.id) }) else {
            Issue.record("listed hosts with Fleet off")
            return
        }
    }

    @Test func aDispatchedThreadAndAMissionWorkerCannotSendWork() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // A thread sent from A: its pi (here, a panes connection on B) is refused, whatever B's own settings say.
        b.settings.withValue { $0.apply(.fleetThreadsCanSend(true)) }
        b.server.fleetHostSettingsChanged(b.settings.current)
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        _ = try await viaA.fleetDispatchCreate(FleetDispatchCreate(dispatchID: UUID(), task: "x", title: "x", repoKey: Self.repoKey, commitSHA: origin.sha,
                                                                  from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentTitle: "Ship")))
        try await Self.wait("a dispatched thread") { !b.dispatched.isEmpty }
        let sent = try #require(b.dispatched.first)
        let dispatched = Parent(agent: sent, extension: try ExtensionClient(path: b.host.socketPath), mac: b)
        try dispatched.hello()
        guard case .error(_, FleetDispatchCode.fleetScope, _) = try await dispatched.dispatch(key: "chain") else { Issue.record("a dispatched thread sent work on"); return }
        guard case .error(_, FleetDispatchCode.fleetScope, _) = try await dispatched.call({ .fleetListHosts(id: $0, agentID: sent.id) }) else {
            Issue.record("a dispatched thread listed the fleet")
            return
        }

        // A mission's worker is refused the same way (the rest of the table is `FleetDispatchScopeTests`).
        let worker = try await a.parent("Station")
        let mission = try await a.server.createMission(draft: .init(title: "Retained", goal: "Keep worker ownership"))
        _ = try await a.server.setMissionRun(id: mission.id, expectedRevision: mission.revision,
                                             run: MissionRun(model: "test/model", phase: .stopped, attempts: [MissionAttempt(agentID: worker.agent.id, status: .running)]))
        try worker.hello()
        guard case .error(_, FleetDispatchCode.fleetScope, _) = try await worker.dispatch(key: "mission") else { Issue.record("a mission worker sent work"); return }

        #expect(a.sent().isEmpty && b.dispatched.count == 1)
    }

    @Test func theFourthConcurrentDispatchIsHeldUntilOneEnds() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        var infos: [FleetDispatchInfo] = []
        for call in 1...3 { infos.append(try parent.info(try await parent.dispatch("Task \(call).", key: "call-\(call)", host: "Mac mini"))) }
        let fourth = try parent.info(try await parent.dispatch("Task 4.", key: "call-4", host: "Mac mini"))
        #expect(fourth.state == "heldLimit", "the per-thread cap is 3")
        try await Self.wait("B to run three") { b.dispatched.count == 3 }
        #expect(b.dispatched.count == 3, "the fourth was not sent")

        // One ends: the held one goes.
        let ended = try await parent.cancel(infos[0])
        #expect(ended.state == "cancelled")
        try await Self.wait("the held dispatch to be placed and sent") { b.dispatched.count == 4 }
        let released = try await parent.status(fourth)
        #expect(released.state != "heldLimit")
    }

    @Test func theCapIsTheSyncedSettingAndCountsPerThread() async throws {
        let (a, b, _) = try await Self.pair(cap: 1)
        defer { a.stop(); b.stop() }
        let one = try await a.parent("One"), two = try await a.parent("Two")
        try one.hello(); try two.hello()
        #expect(try one.info(try await one.dispatch(key: "a", host: "Mac mini")).state != "heldLimit")
        #expect(try one.info(try await one.dispatch("Second.", key: "b", host: "Mac mini")).state == "heldLimit")
        #expect(try two.info(try await two.dispatch("Another thread's.", key: "c", host: "Mac mini")).state != "heldLimit", "the cap is per thread")
    }

    @Test func aTargetWithEightRunningDispatchesAnswersWaitingRoomAndKeepsNothing() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        // B already runs as many as it admits.
        b.server.queue.sync {
            for number in 0..<FleetDispatchProtocol.admissionLimit {
                var record = FleetDispatchRecord(parentHostID: aID, parentHostName: "MacBook Pro", state: .running, title: "Held \(number)", task: "", repoKey: Self.repoKey, createdAt: 1)
                record.remoteAgentID = AgentID()
                b.server.fleet?.dispatch.inbound[record.id] = FleetDispatch.Inbound(record: record)
            }
        }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(key: "ninth", host: "Mac mini"))
        #expect(info.state == "waitingRoom", "the sender waits and decides again")
        #expect(b.taken().count == FleetDispatchProtocol.admissionLimit && b.dispatched.isEmpty)

        // A place frees up: the sender sends it, and the same id starts exactly once.
        b.server.queue.sync {
            if let id = b.server.fleet?.dispatch.inbound.keys.first { b.server.fleet?.dispatch.inbound[id]?.record.state = .done }
            a.server.fleet?.dispatch.evaluate()
        }
        a.server.queue.sync { a.server.fleet?.dispatch.evaluate() }
        try await Self.wait("the waiting dispatch to start on B") { b.dispatched.count == 1 }
        _ = origin
    }

    // MARK: Stop and delete

    @Test func stopOnTheParentCancelsItsDispatchesThereAndNothingWakesItBack() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        // The parent has a live pi, so Stop reaches its thread the way the app's does.
        let spawn = AgentSpawn(agent: parent.agent, cwd: a.folder.path, settings: AgentLaunchSettings())
        _ = try #require(try await a.server.respawnAgent(spawn))
        let info = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        try await Self.wait("B to run it") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)

        a.pressStop(parent.agent.id)
        try await Self.wait("A's record to end cancelled") { a.sent().first?.state == .cancelled }
        try await Self.wait("B to cancel its copy") { b.taken().first?.state == .cancelled }
        // The thread finishing now delivers nothing to the parent.
        try b.report(thread.id, .working)
        try b.report(thread.id, .done)
        #expect(await parent.nextMessage(timeout: .milliseconds(500)) == nil)
        let after = try await parent.status(info)
        #expect(a.sent().first?.state == .cancelled && after.state == "cancelled")
    }

    @Test func closingTheParentCancelsItsDispatchesToo() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        try await Self.wait("B to run it") { b.taken().first?.state == .running }
        try await a.server.deleteAgent(parent.agent.id)
        try await Self.wait("both ends to cancel") { a.sent().first?.state == .cancelled && b.taken().first?.state == .cancelled }
    }

    // MARK: Refusals with codes

    @Test func aMacWithoutTheRepoIsRefusedWhenNamedAndNeverRerouted() async throws {
        let (a, b, _) = try await Self.pair(repoKeyB: "github.com/acme/other")
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        guard case .error(_, FleetDispatchCode.repoMissing, _) = try await parent.dispatch(key: "named", host: "Mac mini") else { Issue.record("named Mac without the repo accepted"); return }
        #expect(a.sent().first?.state == .failed && a.sent().first?.failure == FleetDispatchCode.repoMissing && b.dispatched.isEmpty)
    }

    @Test func aReceiverThatLacksTheRepoOrHasItTwiceRefusesWithTheCode() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        func create(_ key: String) -> FleetDispatchCreate {
            FleetDispatchCreate(dispatchID: UUID(), task: "x", title: "x", repoKey: key, commitSHA: origin.sha,
                                from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentTitle: "Ship"))
        }
        do { _ = try await viaA.fleetDispatchCreate(create("github.com/acme/nowhere")); Issue.record("an unknown repo was accepted") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetDispatchCode.repoMissing) }
        // A second folder that is the same repository: the receiver names both and starts nothing.
        let second = try makeScratchDirectory("second").appendingPathComponent("web")
        try git(["clone", "-q", origin.url.path, second.path], in: b.folder)
        try await b.server.addSpace(Space(name: "acme-web-copy", path: second.path, repoKey: Self.repoKey))
        do { _ = try await viaA.fleetDispatchCreate(create(Self.repoKey)); Issue.record("an ambiguous repo was accepted") }
        catch RemoteHostClientError.rejected(let code, let message) { #expect(code == FleetDispatchCode.repoAmbiguous && message.contains("acme-web") && message.contains("acme-web-copy")) }
        #expect(b.taken().isEmpty && b.dispatched.isEmpty)
    }

    @Test func aCommitTheTargetCannotReachFromItsOriginEndsTheDispatchWithTheCodeAndStartsNothing() async throws {
        // B's origin is another repository, a copy from before the commit that A pushes to its own.
        let (a, b, _) = try await Self.pair(originOfB: { origin in
            let elsewhere = try makeScratchDirectory("elsewhere").appendingPathComponent("origin.git")
            try git(["clone", "-q", "--bare", origin.url.path, elsewhere.path], in: origin.url)
            return Origin(url: elsewhere, sha: origin.sha)
        })
        defer { a.stop(); b.stop() }
        try "more\n".write(to: a.folder.appendingPathComponent("MORE.md"), atomically: true, encoding: .utf8)
        try git(["add", "."], in: a.folder)
        try git(["commit", "-qm", "more"], in: a.folder)
        try git(["push", "-q", "origin", "main"], in: a.folder)

        let parent = try await a.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        try await Self.wait("the dispatch to fail") { a.sent().first?.state == .failed }
        #expect(a.sent().first?.failure == FleetDispatchCode.commitUnreachable)
        #expect(b.taken().first?.failure == FleetDispatchCode.commitUnreachable && b.dispatched.isEmpty && b.sent().isEmpty)
    }

    @Test func aSenderWithChangesOnlyASnapshotCarriesIsHeldAndNothingIsSent() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()

        // An edit, then an untracked file, then a commit origin doesn't have.
        try "changed\n".write(to: a.folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        guard case .error(_, FleetDispatchCode.needsBundle, _) = try await parent.dispatch(key: "edit", host: "Mac mini") else { Issue.record("edit sent"); return }
        try git(["checkout", "--", "README.md"], in: a.folder)
        try "new\n".write(to: a.folder.appendingPathComponent("NOTES.md"), atomically: true, encoding: .utf8)
        guard case .error(_, FleetDispatchCode.needsBundle, _) = try await parent.dispatch(key: "untracked", host: "Mac mini") else { Issue.record("untracked sent"); return }
        try git(["add", "NOTES.md"], in: a.folder)
        try git(["commit", "-qm", "notes"], in: a.folder)
        guard case .error(_, FleetDispatchCode.needsBundle, _) = try await parent.dispatch(key: "unpushed", host: "Mac mini") else { Issue.record("unpushed commit sent"); return }
        #expect(b.dispatched.isEmpty && b.taken().isEmpty)

        // Pushed, and with only an ignored file beside it, it goes.
        try git(["push", "-q", "origin", "main"], in: a.folder)
        try "log\n".write(to: a.folder.appendingPathComponent("build.log"), atomically: true, encoding: .utf8)
        let info = try parent.info(try await parent.dispatch(key: "clean", host: "Mac mini"))
        #expect(["preparing", "running"].contains(info.state))
        try await Self.wait("B to run it") { b.dispatched.count == 1 }
    }

    // MARK: Results held for a parent whose pi is away

    @Test func aResultForAParentWhosePiIsAwayWaitsAndIsDeliveredOnceWhenItIsBack() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch(key: "call-1", title: "Fix flaky payment test", host: "Mac mini"))
        try await Self.wait("B to run it") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        // The parent's pi goes away before the thread finishes.
        parent.extension.closeConnection()
        try await Self.wait("A to see the pi gone") { a.server.queue.sync { a.server.fleet != nil } }
        try b.report(thread.id, .working)
        try await Self.wait("B to see it working") { b.server.queue.sync { b.server.fleet?.dispatch.inbound.values.first?.startedWorking } == true }
        try b.report(thread.id, .done)
        try await Self.wait("A to hold the result for delivery") { a.sent().first?.state == .delivering }

        // Its pi comes back: the held result goes once.
        let back = Parent(agent: parent.agent, extension: try ExtensionClient(path: a.host.socketPath), mac: a)
        try back.hello()
        let result = try #require(await back.nextMessage())
        #expect(result.text.contains("Result from Fix flaky payment test on Mac mini:"))
        try await Self.wait("the record to finish") { a.sent().first?.state == .done }
        #expect(await back.nextMessage(timeout: .milliseconds(400)) == nil, "never delivered twice")
    }

    // MARK: Restarts (Q9)

    @Test func aTargetThatRestartsKeepsItsDispatchRunningAndNothingIsSentAgain() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop() }
        let parent = try await a.parent()
        try parent.hello()
        _ = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        try await Self.wait("B to run it") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)

        let restarted = try await Mac("Mac mini", origin: origin, dir: dir, port: port)
        defer { restarted.stop() }
        try await Self.wait("A to follow the dispatch on the restarted Mac") {
            restarted.taken().first?.state == .running && a.sent().first?.state == .running
        }
        #expect(restarted.dispatched.count == 1 && restarted.dispatched.first?.id == thread.id, "re-followed, never re-sent")
        #expect(a.sent().count == 1)

        // The thread finishes after the restart, and the result still reaches the parent.
        try restarted.report(thread.id, .working)
        try await Self.wait("the restarted Mac to see it working") { restarted.server.queue.sync { restarted.server.fleet?.dispatch.inbound.values.first?.startedWorking } == true }
        try restarted.report(thread.id, .done)
        #expect(await parent.nextMessage() != nil)
    }

    @Test func aSenderThatRestartsHoldsWhatWasNotPlacedAndSendsNothingByItself() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let (dir, port) = (a.host.dir, a.port)
        // The named Mac is gone, so the dispatch waits for it.
        let bID = try await b.hostID()
        _ = bID
        b.stop(keepFiles: true)
        try await Self.wait("A to see B's link down") { try await a.local.fleetRead().snapshot.peers.first?.link != .connected }
        let waiting = try parent.info(try await parent.dispatch(key: "call-1", host: "Mac mini"))
        #expect(waiting.state == "waitingWake")
        a.stop(keepFiles: true)

        let restartedA = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port)
        defer { restartedA.stop() }
        try await Self.wait("the record to come back held") { restartedA.sent().first?.state == .heldRestart }
        // B returns; nothing is sent by itself.
        let restartedB = try await Mac("Mac mini", origin: origin, dir: b.host.dir, port: b.port)
        defer { restartedB.stop() }
        try await Self.waitForReports(restartedA, restartedB)
        restartedA.server.queue.sync { restartedA.server.fleet?.dispatch.evaluate(); restartedA.server.fleet?.dispatch.linkChanged() }
        try await Self.wait("the links to settle") { restartedA.server.queue.sync { restartedA.server.fleet?.isConnected(restartedB.server.fleet?.identity.hostID ?? UUID()) } == true }
        #expect(restartedA.sent().first?.state == .heldRestart && restartedB.dispatched.isEmpty && restartedB.taken().isEmpty)
    }

    // MARK: What a thread is told

    @Test func fleetHostsListsEveryMacWithItsRoomItsToolsAndWhetherItHasTheRepo() async throws {
        let (a, b, _) = try await Self.pair(busyA: 90, busyB: 10)
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        guard case .fleetHosts(_, let hosts) = try await parent.call({ .fleetListHosts(id: $0, agentID: parent.agent.id) }) else { Issue.record("no list"); return }
        let here = try #require(hosts.first { $0.isThisMac }), mini = try #require(hosts.first { $0.name == "Mac mini" })
        #expect(here.name == "MacBook Pro" && mini.connected && mini.hasRepo == true && mini.problems.isEmpty)
        #expect(mini.room == "most room" && here.room != "most room")
    }
}
