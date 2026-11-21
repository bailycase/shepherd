import Darwin
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
@Suite("Fleet dispatch", .mainActorExclusive)
@MainActor
struct FleetDispatchTests {
    nonisolated static let repoKey = "github.com/acme/web"

    // MARK: Fixtures

    /// Waits for `condition`, which may read from a client.
    static func wait(_ what: String, timeout: Duration = defaultWaitTimeout, _ condition: @MainActor () async throws -> Bool) async throws {
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
        // A seed of thousands of loose objects is packed first: a local clone copies them one by one.
        if extra.count > 100 { try git(["repack", "-a", "-d", "-q"], in: seed) }
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
        /// Where this Mac's clones go first (it isn't there until a test makes it).
        let developer: URL
        let token: String
        let settings: Locked<HostSettings>
        var server: SessionServer { host.server }
        var peersFile: URL { host.dir.appendingPathComponent("fleet/peers.json") }

        /// `dir` and `port` restart a Mac over its own files. `repoKey: nil` is a Mac whose checkout isn't known by any key.
        /// `checkout: false` is a Mac with no checkout of the repository and no space for it. A clone on a Mac goes under its own scratch
        /// `Developer` folder (made by a test that wants it there), never the real one.
        init(_ name: String, origin: Origin, busy: UInt64 = 20, repoKey: String? = FleetDispatchTests.repoKey, dir: URL? = nil, port: UInt16 = 0,
             sendWork: Bool = true, cap: Int = HostSettings.fleetThreadCapDefault, checkout: Bool = true,
             uncommitted: FleetUncommittedChanges = .sendThem, links: SessionServer.FleetLinkOptions? = nil, gate: FleetTestGate? = nil,
             mcp: [String: String] = [:], lacking: Set<String> = [], noXcode: Bool = false, isolatedPi: Bool = false,
             prepare: (@Sendable (SessionServer) async -> Void)? = nil) async throws {
            self.name = name
            meter = FleetPressureIntegrationTests.Meter(busy: busy)
            settings = Locked(HostSettings(fleetThreadsCanSend: sendWork, fleetThreadCap: cap, fleetUncommitted: uncommitted))
            let scratch = try dir ?? makeScratchDirectory("dispatch")
            // A Mac of its own pi home: the conversations of two Macs never meet in one folder (a move writes one).
            let host = try ScratchServer(dir: scratch, pi: isolatedPi ? PiSetup(engine: PiSetup.app.engine, home: scratch.appendingPathComponent("pi"), userHome: scratch.path) : .app)
            let server = host.server
            // Before the listener opens: what the host offers is read when a peer says hello.
            await prepare?(server)
            server.configureFleet(name: name, advertises: false)
            let (meter, clock) = (meter, clock)
            var sources = meter.sources
            // A test that holds this Mac's readings back holds back its answer to `fleetPressureNow`.
            if let gate { sources.pause = { _ in await gate.pass() } }
            let held = sources
            // pi's MCP file on this Mac, and what its login shell can't find (`lacking`, `noXcode`).
            if !mcp.isEmpty {
                let servers = mcp.map { #""\#($0.key)": {"command": "\#($0.value)"}"# }.sorted().joined(separator: ",")
                try Data(#"{"mcpServers": {\#(servers)}}"#.utf8).write(to: server.pi.files.mcpConfig)
            }
            if let links { server.fleetLinkOptions = links }
            server.configureFleet(clock: { clock.now }, pressure: { queue, facts in
                FleetPressure(queue: queue, clock: { clock.now }, sampler: FleetPressureSampler(sources: held), localFacts: facts,
                              probe: { commands in FleetProbeResult(missingCommands: Set(commands).intersection(lacking), noXcode: noXcode) }, hardware: { (name, "M4 Pro") }, interval: 3_600)
            })
            let folder = scratch.appendingPathComponent("web", isDirectory: true)
            self.folder = folder
            developer = scratch.appendingPathComponent("Developer", isDirectory: true)
            server.configureFleetClones(developerFolder: developer)
            if checkout, !FileManager.default.fileExists(atPath: folder.path) {
                try git(["clone", "-q", origin.url.path, folder.path], in: scratch)
                try git(["config", "user.name", "Shepherd Tests"], in: folder)
                try git(["config", "user.email", "tests@example.com"], in: folder)
                try await server.addSpace(Space(name: "acme-web", path: folder.path, repoKey: repoKey))
            }
            let tokenURL = scratch.appendingPathComponent("remote-token")
            let socket = scratch.appendingPathComponent("h.sock").path
            let port = try await RestartablePort.listen(port) { try server.startRemoteListener(port: $0, tokenURL: tokenURL) }
            token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try server.startLocalListener(path: socket, tokenURL: tokenURL)
            await MainActor.run {
                server.serveThreads(ThreadHosting(defaults: {
                    ThreadHosting.Defaults(model: "stub/model-a", thinking: .medium, serviceTier: .standard, worktreeBaseMode: .head, worktreeFetchBeforeCreate: false)
                }, launch: { AgentLaunchSettings() }, shell: { SessionCommand(argv: ["/bin/sh"], env: [:]) }))
            }
            // Serving threads installs the host's own window relay, which a test's updater stands in for.
            await prepare?(server)
            let settings = settings
            server.setFleetHostSettings { [weak server] change in
                let now = settings.withValue { $0.apply(change); return $0 }
                server?.fleetHostSettingsChanged(now)
            }
            server.fleetHostSettingsChanged(settings.current)
            server.startFleetAndWait()
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
            server.queue.sync { server.rpcThread(forAgent: agent)?.stop(explicit: true) { _ in } }
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

        func call(timeout: Duration = .seconds(10), _ make: (Int) -> ExtensionMessage) async throws -> ExtensionReply {
            let id = Self.nextID.withValue { $0 += 1; return $0 }
            try `extension`.send(make(id))
            while true {
                let reply = try await read(timeout: timeout)
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
                     originOfB: ((Origin) throws -> Origin)? = nil, checkoutB: Bool = true,
                     uncommittedA: FleetUncommittedChanges = .sendThem, mcp: [String: String] = [:], lackingB: Set<String> = [],
                     noXcodeB: Bool = false, isolatedPi: Bool = false) async throws -> (a: Mac, b: Mac, origin: Origin) {
        try StubPi.installAsEngine()
        let origin = try makeOrigin(extra: originExtra)
        let a = try await Mac("MacBook Pro", origin: origin, busy: busyA, sendWork: sendWork, cap: cap, uncommitted: uncommittedA, mcp: mcp, isolatedPi: isolatedPi)
        let b = try await Mac("Mac mini", origin: try originOfB?(origin) ?? origin, busy: busyB, repoKey: repoKeyB, sendWork: sendWork, checkout: checkoutB,
                              mcp: mcp, lacking: lackingB, noXcode: noXcodeB, isolatedPi: isolatedPi)
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
        #expect(result.text.contains("Branch fleet/fix-flaky-payment-test: 0 commits ahead of origin/main, not on origin"))
        try await Self.wait("both records to finish") { a.sent().first?.state == .done && b.taken().first?.state == .done }
        #expect(a.sent().first?.resultBranchFacts?.branch == "fleet/fix-flaky-payment-test")
        let read = try await parent.status(info)
        #expect(read.state == "done" && read.activity != "working")
        #expect(a.dispatched.isEmpty, "nothing ran on the sender")
    }

    @Test func aDispatchWithNoCommitsReportsUncommittedWorkInItsResultAndCloseReply() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("Update checkout notes.", title: "Checkout notes", host: "Mac mini"))
        try await eventuallyOnMain("the receiver to run the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        try await eventuallyOnMain("the stub to start in the worktree") {
            StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == thread.id.rawValue }
        }
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the receiver to report working") { b.taken().first?.activity == "working" }

        try Data("updated notes\n".utf8).write(to: worktree.appendingPathComponent("README.md"))
        try Data("staged notes\n".utf8).write(to: worktree.appendingPathComponent("apps/web/index.js"))
        try git(["add", "apps/web/index.js"], in: worktree)
        try Data("more notes\n".utf8).write(to: worktree.appendingPathComponent("apps/web/index.js"))
        try Data().write(to: worktree.appendingPathComponent("new notes.txt"))
        try Data().write(to: worktree.appendingPathComponent("ignored.log"))
        try Data().write(to: b.folder.appendingPathComponent("outside.txt"))
        let status = try git(["status", "--porcelain=v1"], in: worktree)
        try b.report(thread.id, .done)

        let result = try #require(await parent.nextMessage())
        #expect(result.text.contains("Branch fleet/checkout-notes: 0 commits ahead of origin/main, not on origin, 0 files changed (+0 -0). Uncommitted in the checkout on Mac mini: 3 files (2 modified, 1 untracked). Counts include any edits sent with the dispatch."))
        #expect(!result.text.contains("new notes.txt") && !result.text.contains("updated notes"))
        try await eventuallyOnMain("the sender to finish delivery") { a.sent().first?.state == .done }
        let facts = try #require(try await parent.status(info).branchFacts)
        #expect(facts.ahead == 0 && facts.filesChanged == 0 && facts.uncommittedModified == 2 && facts.uncommittedUntracked == 1)
        #expect(try git(["status", "--porcelain=v1"], in: worktree) == status, "reporting leaves the index and worktree alone")

        // The close reply describes what is kept now, not the earlier result snapshot.
        try Data().write(to: worktree.appendingPathComponent("later notes.txt"))
        let beforeClose = try git(["status", "--porcelain=v1"], in: worktree)
        let closed = try parent.info(try await parent.call { .fleetDispatchClose(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID) })
        let report = try #require(closed.closeReport)
        #expect(report.contains("Kept the checkout, branches, and saved conversation, including 4 uncommitted files in the checkout"))
        #expect(try git(["status", "--porcelain=v1"], in: worktree) == beforeClose)
        #expect(try Self.head(worktree) == origin.sha)
    }

    @Test func aDispatchThatMakesNoEditsReportsTheUncommittedWorkItReceived() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Data("sender notes\n".utf8).write(to: a.folder.appendingPathComponent("README.md"))
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("Read checkout notes.", title: "Read notes", host: "Mac mini"))
        try await eventuallyOnMain("the receiver to run the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try Self.head(worktree) == origin.sha)
        #expect(try git(["status", "--porcelain=v1"], in: worktree) == " M README.md\n")
        try await eventuallyOnMain("the stub to start in the worktree") {
            StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == thread.id.rawValue }
        }
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the receiver to report working") { b.taken().first?.activity == "working" }
        try b.report(thread.id, .done)

        let result = try #require(await parent.nextMessage())
        #expect(result.text.contains("Uncommitted in the checkout on Mac mini: 1 file (1 modified). Counts include any edits sent with the dispatch."))
        try await eventuallyOnMain("the sender to finish delivery") { a.sent().first?.state == .done }
        let closed = try parent.info(try await parent.call { .fleetDispatchClose(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID) })
        let report = try #require(closed.closeReport)
        #expect(report.contains("including 1 uncommitted file in the checkout;"))
        #expect(report.contains("Counts include any edits sent with the dispatch."))
    }

    @Test func theResultAndReadReportThePushedDispatchBranchNotTheCheckedOutHead() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("Use branch fix/payment if available.", title: "Investigate flaky payments from dashboard", host: "Mac mini"))
        try await eventuallyOnMain("the receiving Mac to run the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let branch = try #require(thread.worktreeBranch)
        #expect(branch == "fleet/investigate-flaky-payments-from")
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        try await eventuallyOnMain("the stub to start in the worktree") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == thread.id.rawValue } }
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the sender to know the thread is working") { a.sent().first?.activity == "working" }

        // Push from B only, then leave the checkout detached at the base. The PR branch still holds the work.
        try "payments\n".write(to: worktree.appendingPathComponent("PAYMENTS.md"), atomically: true, encoding: .utf8)
        try git(["add", "PAYMENTS.md"], in: worktree)
        try git(["commit", "-qm", "Add payment notes"], in: worktree)
        let pushed = try Self.head(worktree)
        try git(["push", "-q", "origin", branch], in: worktree)
        try git(["update-ref", "-d", "refs/remotes/origin/\(branch)"], in: worktree)
        try git(["switch", "-q", "--detach", origin.sha], in: worktree)
        try b.report(thread.id, .done)

        let result = try #require(await parent.nextMessage())
        #expect(result.text.contains("Branch \(branch): 1 commit ahead of origin/main, pushed to origin, 1 file changed (+1 -0)."))
        try await eventuallyOnMain("the sender to finish delivery") { a.sent().first?.state == .done }
        let read = try await parent.status(info)
        var expected = FleetBranchFacts(branch: branch, head: pushed, ahead: 1, pushed: true, filesChanged: 1, insertions: 1,
                                        uncommittedModified: 0, uncommittedUntracked: 0)
        expected.comparedTo = "origin/main"
        #expect(read.branchFacts == expected)
        #expect(try Self.head(a.folder) == origin.sha)
    }

    @Test func theDispatchResultExcludesUpstreamCommitsAfterAFastForward() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // Configure nightly without checking it out: the sender's current branch and origin's default are main.
        try git(["push", "-q", "origin", "HEAD:nightly"], in: a.folder)
        var space = a.space
        space.worktreeBase = "origin/nightly"
        try await a.server.updateSpace(space)
        // Reach the scratch checkout through a tilde path without creating anything in the real home.
        space.path = "~" + String(repeating: "/..", count: (NSHomeDirectory() as NSString).pathComponents.count - 1) + a.folder.path
        let (agent, tab) = Fixture.agent(in: space)
        try await a.server.addAgent(agent, withTab: tab)
        let parent = Parent(agent: agent, extension: try ExtensionClient(path: a.host.socketPath), mac: a)
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(host: "Mac mini"))
        try await eventuallyOnMain("the receiver to start") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let branch = try #require(thread.worktreeBranch)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the receiver to report working") { b.taken().first?.activity == "working" }

        try git(["switch", "-q", "nightly"], in: a.folder)
        try "upstream\n".write(to: a.folder.appendingPathComponent("UPSTREAM.md"), atomically: true, encoding: .utf8)
        try git(["add", "UPSTREAM.md"], in: a.folder)
        try git(["commit", "-qm", "Advance nightly"], in: a.folder)
        try git(["push", "-q", "origin", "nightly"], in: a.folder)
        try git(["fetch", "-q", "origin", "nightly"], in: worktree)
        try git(["merge", "--ff-only", "origin/nightly"], in: worktree)
        try "dispatch\n".write(to: worktree.appendingPathComponent("PAYMENTS.md"), atomically: true, encoding: .utf8)
        try git(["add", "PAYMENTS.md"], in: worktree)
        try git(["commit", "-qm", "Add payment notes"], in: worktree)
        try git(["push", "-q", "origin", branch], in: worktree)
        try b.report(thread.id, .done)

        let result = try #require(await parent.nextMessage())
        #expect(result.text.contains("1 commit ahead of origin/nightly, pushed to origin, 1 file changed (+1 -0)."))
        try await eventuallyOnMain("result delivery") { a.sent().first?.state == .done }
        let facts = try #require(try await parent.status(info).branchFacts)
        #expect(facts.ahead == 1 && facts.filesChanged == 1 && facts.insertions == 1 && facts.pushed)
        #expect(a.sent().first?.commitSHA == origin.sha, "the start pin did not change")
    }

    @Test func anUnreachableOriginDoesNotReportAStaleTrackingRefAsPushed() throws {
        let origin = try Self.makeOrigin()
        let checkout = try makeScratchDirectory("report").appendingPathComponent("checkout")
        try git(["clone", "-q", origin.url.path, checkout.path], in: origin.url)
        let branch = "fleet/check-payments"
        try git(["branch", branch, origin.sha], in: checkout)
        try git(["update-ref", "refs/remotes/origin/\(branch)", origin.sha], in: checkout)
        try git(["remote", "set-url", "origin", checkout.appendingPathComponent("no-such-origin").path], in: checkout)

        let facts = FleetDispatchGit.branchFacts(worktree: checkout.path, branch: branch, start: origin.sha)
        #expect(facts.head == origin.sha && facts.ahead == 0)
        #expect(facts.originCheckFailed == true && !facts.pushed)
        #expect(facts.uncommittedModified == 0 && facts.uncommittedUntracked == 0 && facts.uncommittedCheckFailed == nil)

        try Data().write(to: checkout.appendingPathComponent("new notes.txt"))
        let noBranch = FleetDispatchGit.branchFacts(worktree: checkout.path, branch: "fleet/missing", start: origin.sha)
        #expect(noBranch == FleetBranchFacts(branch: "fleet/missing", uncommittedModified: 0, uncommittedUntracked: 1))
        let noCheckout = FleetDispatchGit.branchFacts(worktree: checkout.appendingPathComponent("missing").path, branch: branch, start: origin.sha)
        #expect(noCheckout == FleetBranchFacts(branch: branch, uncommittedCheckFailed: true))
    }

    @Test func aProviderErrorMarksTheDispatchFailedOnBothMacs() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("flaky-hold", host: "Mac mini"))
        try await eventuallyOnMain("the receiving Mac to start the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        try await eventuallyOnMain("the stub to start in the worktree") { StubPi.launches().contains { $0.env["SHEPHERD_AGENT_ID"] == thread.id.rawValue } }
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the sender to know the thread is working") { a.sent().first?.activity == "working" }
        try await eventuallyOnMain("pi to start the failing turn") { b.server.queue.sync { b.server.rpcThread(forAgent: thread.id)?.running == true } }
        try Data().write(to: worktree.appendingPathComponent("flaky-go"))
        try b.report(thread.id, .done)
        try await eventuallyOnMain("the sender to settle") { a.sent().first?.state.isLive == false }
        try await eventuallyOnMain("the receiver to settle") { b.taken().first?.state.isLive == false }
        let read = try await parent.status(info)
        #expect(b.taken().first?.state == .failed)
        #expect(read.state == "failed" && read.failure == "turn_failed" && read.detail == "529 overloaded")
        #expect(read.resultText == nil && read.activity != "working")
    }

    @Test func anUnexpectedPiExitMarksTheDispatchFailedOnBothMacs() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("flaky-hold", host: "Mac mini"))
        try await eventuallyOnMain("the receiver to start") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        try await Self.wait("pi to run the held turn") {
            await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.running == true }
        }
        let signalled = await b.server.enqueueValue { @Sendable in
            guard let pid = b.server.rpcThread(forAgent: thread.id)?.session.processIdentifier, pid > 0 else { return false }
            return kill(pid, SIGKILL) == 0
        }
        try #require(signalled)
        try await eventuallyOnMain("the pi exit failure to reach the sender") { a.sent().first?.state == .failed }
        #expect(b.taken().first?.state == .failed)
        #expect(b.dispatched.first?.id == thread.id, "the receiving Mac keeps the thread for retry")
        let read = try await parent.status(info)
        #expect(read.state == "failed" && read.failure == "turn_failed")
        #expect(read.detail?.contains("stopped unexpectedly") == true)
        #expect(read.resultText == nil && read.activity != "working")
    }

    @Test func readingARunningDispatchGetsActivityFromTheReceiverEvenWhenTheSenderMissedIt() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let before = SessionServer.nowMilliseconds()
        let info = try parent.info(try await parent.dispatch("flaky-hold", host: "Mac mini"))
        try await eventuallyOnMain("the receiving Mac to start the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the opening turn to start and its status to reach the sender") {
            a.sent().first?.activity == "working" && b.server.queue.sync { b.server.rpcThread(forAgent: thread.id)?.running == true }
        }
        // The outbound log can have a running record without a status; the dispatch is still live on B.
        let dispatchID = try #require(UUID(uuidString: info.dispatchID))
        a.server.queue.sync { a.server.fleet?.dispatch.outbound[dispatchID]?.activity = nil }
        let read = try await parent.status(info)
        #expect(read.state == "running" && read.activity == "working")
        let timestamp = try #require(read.lastThreadEventAt)
        #expect((before...SessionServer.nowMilliseconds()).contains(timestamp))
        #expect(a.sent().first?.lastThreadEventAt == nil, "polling doesn't rewrite the dispatch log")

        // A missing peer link gives back the cached state, not a fresh activity time.
        a.server.queue.sync { a.server.fleet?.dispatch.client = { _ in nil } }
        let offline = try await parent.status(info)
        #expect(offline.state == "running" && offline.lastThreadEventAt == nil)
    }

    @Test func aNamedDispatchRefusesBeforeStartingWhenTheReceiverIsLowOnDisk() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        b.server.queue.sync { b.server.fleet?.dispatch.freeWorktreeBytes = { _ in 0 } }
        let parent = try await a.parent()
        try parent.hello()
        let refused = try await parent.dispatch(key: "disk", host: "Mac mini")
        guard case .error(_, "disk_low", let message) = refused else { Issue.record("Expected low disk refusal, got \(refused)"); return }
        #expect(message.contains("disk space"))
        #expect(b.taken().isEmpty && b.dispatched.isEmpty)
        #expect(a.sent().first?.state == .failed)
    }

    private static func startingDispatch() async throws -> (a: Mac, b: Mac, parent: Parent, info: FleetDispatchInfo, thread: Agent) {
        let (a, b, _) = try await pair(originExtra: ["stub-pi-startup.json": #"{"gate":"release-pi"}"#])
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(host: "Mac mini"))
        try await eventually("both Macs to hold the dispatch as running") { @Sendable in
            let receiverRunning = await b.server.enqueueValue { @Sendable in b.server.fleet?.dispatch.inbound.values.first?.record.state == .running }
            let senderRunning = await a.server.enqueueValue { @Sendable in a.server.fleet?.dispatch.outbound.values.first?.state == .running }
            return receiverRunning && senderRunning
        }
        let thread = try #require(b.dispatched.first)
        let starting = await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.isServable == false }
        try #require(starting)
        return (a, b, parent, info, thread)
    }

    nonisolated private static func receivedTextCount(_ text: String, on mac: Mac, thread: Agent) async -> Int {
        await mac.server.enqueueValue { @Sendable in
            guard let rpc = mac.server.rpcThread(forAgent: thread.id) else { return 0 }
            return (rpc.history + rpc.live.map(\.value)).filter {
                $0.role == "user" && $0.blocks.map(\.text).joined() == text
            }.count
        }
    }

    @Test(.enabled(if: EngineSmoke.engine != nil, "set SHEPHERD_ENGINE_SMOKE to a staged engine"))
    func aFollowUpSentWhileTheReceiversThreadIsStartingIsDeliveredOnceItServes() async throws {
        let engine = try #require(EngineSmoke.engine)
        let (a, b, parent, info, thread) = try await Self.startingDispatch()
        defer { a.stop(); b.stop() }
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        let checked = Locked(false)
        await b.server.enqueueValue { @Sendable in
            guard let dispatch = b.server.fleet?.dispatch else { return }
            let original = dispatch.host.messageThread
            dispatch.host.messageThread = { id, text, delivery in
                let result = await original(id, text, delivery)
                checked.withValue { $0 = true }
                return result
            }
        }
        let script = #"""
            import { createRequire } from "node:module";
            import { join } from "node:path";
            const [pkg, source, dispatch] = process.argv.slice(1);
            const { createJiti } = createRequire(join(pkg, "package.json"))("jiti");
            const jiti = createJiti(source, { alias: { typebox: join(pkg, "node_modules/typebox/build/index.mjs") } });
            const { default: install } = await jiti.import(source);
            let send, shutdown;
            install({ registerTool(tool) { if (tool.name === "fleet_send") send = tool; },
                      on(event, cb) { if (event === "session_shutdown") shutdown = cb; } });
            const abort = new AbortController();
            const timer = setTimeout(() => abort.abort(), 20_000);
            try {
              const result = await send.execute("call", { dispatch, text: "Follow up." }, abort.signal);
              console.log(result.content[0].text);
            } finally { clearTimeout(timer); shutdown?.(); }
            """#
        let source = EngineSmoke.repository.appendingPathComponent("Extensions/shepherd-panes.ts").path
        var env = ProcessInfo.processInfo.environment
        env["SHEPHERD_SOCKET"] = a.host.socketPath
        env["SHEPHERD_AGENT_ID"] = parent.agent.id.rawValue
        env["SHEPHERD_AUTOMATION"] = nil
        let environment = env
        let sending = Task {
            try await blocking {
                try EngineSmoke.runTool(engine.node.path, ["--input-type=module", "-e", script, engine.packageDirectory.path, source, info.dispatchID], environment: environment)
            }
        }
        try await eventuallyOnMain("the first send attempt to reach the still-starting receiver") { checked.current }
        try Data().write(to: worktree.appendingPathComponent("release-pi"))
        let result = try await sending.value
        try #require(result.status == 0, Comment(rawValue: result.output))
        try #require(result.output.contains("followUp sent to dispatch \(info.dispatchID)"), Comment(rawValue: result.output))
        try await eventually("the follow-up to reach the thread") { @Sendable in await Self.receivedTextCount("Follow up.", on: b, thread: thread) > 0 }
        #expect(await Self.receivedTextCount("Follow up.", on: b, thread: thread) == 1)
    }

    @Test func aPreparingDispatchAnswersStartingOnBothMacsAndCanBeMessagedOnceReady() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let preparation = FleetTestGate()
        await preparation.close()
        await b.server.enqueueValue { @Sendable in
            guard let dispatch = b.server.fleet?.dispatch else { return }
            let original = dispatch.host.createThread
            dispatch.host.createThread = { request in
                await preparation.pass()
                return await original(request)
            }
        }
        let parent = try await a.parent()
        try parent.hello()
        let peer = try await b.connectAsPeer(a)
        defer { peer.disconnect() }
        let info = try parent.info(try await parent.dispatch(host: "Mac mini"))
        let id = try #require(UUID(uuidString: info.dispatchID))
        func send(_ text: String) async throws -> ExtensionReply {
            try await parent.call {
                .fleetDispatchMessage(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID, text: text, delivery: .followUp)
            }
        }
        let preparing = "The dispatch is still being prepared."
        do {
            try await eventually("the receiver to reach thread creation") { @Sendable in await preparation.waiting == 1 }
            let held = try await send("Refused by sender.")
            guard case .error(_, "starting", preparing) = held else { throw WireError("expected sender startup refusal, got \(held)") }
            do {
                _ = try await peer.fleetDispatchControl(id, .message(text: "Refused by receiver.", delivery: .followUp))
                Issue.record("receiver accepted a message before it created the thread")
            } catch RemoteHostClientError.rejected(let code, let message) {
                #expect(code == "starting" && message == preparing)
            }
        } catch {
            await preparation.open()
            throw error
        }
        await preparation.open()
        try await eventually("the dispatch to serve on both Macs") { @Sendable in
            let running = await a.server.enqueueValue { @Sendable in a.server.fleet?.dispatch.outbound[id]?.state == .running }
            guard running, let thread = b.dispatched.first else { return false }
            return await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.isServable == true }
        }
        let thread = try #require(b.dispatched.first)
        _ = try parent.info(try await send("Sent once ready."))
        try await eventually("the fresh request to reach the thread") { @Sendable in
            await Self.receivedTextCount("Sent once ready.", on: b, thread: thread) == 1
        }
        #expect(await Self.receivedTextCount("Refused by sender.", on: b, thread: thread) == 0)
        #expect(await Self.receivedTextCount("Refused by receiver.", on: b, thread: thread) == 0)
    }

    @Test func theReceiverRefusesStartingDeadAndMissingThreadsWithoutHoldingTheMessage() async throws {
        let (a, b, _, info, thread) = try await Self.startingDispatch()
        defer { a.stop(); b.stop() }
        let peer = try await b.connectAsPeer(a)
        defer { peer.disconnect() }
        let dispatch = try #require(UUID(uuidString: info.dispatchID))
        func refusal() async throws -> (String, String) {
            do {
                _ = try await peer.fleetDispatchControl(dispatch, .message(text: "Do not deliver.", delivery: .followUp))
                throw WireError("a non-serving thread accepted input")
            } catch RemoteHostClientError.rejected(let code, let message) { return (code, message) }
        }
        let (starting, message) = try await refusal() // The startup gate is still closed.
        #expect(starting == "starting")
        #expect(message == "The thread is still starting. Send it again in a moment.")
        await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.bootstrap(timeout: 0.1) }
        try await eventually("the live pi to miss its readiness deadline") { @Sendable in
            await b.server.enqueueValue { @Sendable in
                guard let rpc = b.server.rpcThread(forAgent: thread.id) else { return false }
                return rpc.session.isAlive && !rpc.isServable && rpc.bootstrapFailure != nil
            }
        }
        #expect(try await refusal().0 == "not_running")
        let session = await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.session.id }
        b.server.killSession(try #require(session))
        try await eventually("the pi to exit while its thread still exists") { @Sendable in
            await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.session.isAlive != true }
        }
        try #require(b.dispatched.contains { $0.id == thread.id })
        #expect(try await refusal().0 == "not_running")
        try await b.server.deleteAgent(thread.id)
        #expect(try await refusal().0 == "not_running")
    }

    @Test(arguments: [false, true])
    func aReadySteerDoesNotWaitAndAMissingAcknowledgementMayMeanDelivered(dropLink: Bool) async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(host: "Mac mini"))
        let dispatch = try #require(UUID(uuidString: info.dispatchID))
        try await eventually("the dispatch to be ready to take input") { @Sendable in
            let running = await a.server.enqueueValue { @Sendable in a.server.fleet?.dispatch.outbound[dispatch]?.state == .running }
            guard running, let thread = b.dispatched.first else { return false }
            return await b.server.enqueueValue { @Sendable in b.server.rpcThread(forAgent: thread.id)?.isServable == true }
        }
        let thread = try #require(b.dispatched.first)
        let peer = try await b.connectAsPeer(a)
        defer { peer.disconnect() }
        let acknowledgement = FleetTestGate()
        await acknowledgement.close()
        await b.server.enqueueValue { @Sendable in
            guard let dispatch = b.server.fleet?.dispatch else { return }
            let original = dispatch.host.messageThread
            dispatch.host.messageThread = { id, text, delivery in
                let result = await original(id, text, delivery)
                if text == "Late acknowledgement." { await acknowledgement.pass() }
                return result
            }
        }
        let sending = Task { @MainActor in
            try await parent.call(timeout: .seconds(15)) {
                .fleetDispatchMessage(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID, text: "Late acknowledgement.", delivery: .followUp)
            }
        }
        do {
            try await eventually("the ready follow-up to arrive before its acknowledgement") { @Sendable in
                guard await acknowledgement.waiting == 1 else { return false }
                return await Self.receivedTextCount("Late acknowledgement.", on: b, thread: thread) == 1
            }
            let began = ContinuousClock.now
            _ = try await peer.fleetDispatchControl(dispatch, .message(text: "Ready steer.", delivery: .steer))
            #expect(ContinuousClock.now - began < .seconds(2), "a ready steer does not wait for the earlier acknowledgement")
            try await eventually("the ready steer to reach the thread") { @Sendable in await Self.receivedTextCount("Ready steer.", on: b, thread: thread) == 1 }
            if dropLink {
                let target = try await b.hostID()
                let link = await a.server.enqueueValue { @Sendable in a.server.fleet?.dispatch.client(target) }
                try #require(link).disconnect()
            }
            let reply = try await sending.value
            guard case .error(_, let code, let message) = reply else { throw WireError("expected a missing acknowledgement, got \(reply)") }
            #expect(code == "unreachable")
            #expect(message == "That Mac didn't answer in time. The message may still arrive.")
        } catch {
            await acknowledgement.open()
            throw error
        }
        await acknowledgement.open()
    }

    @Test func aFollowUpThatSettlesBeforeTheSendReplyDoesNotStayRunning() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(host: "Mac mini"))
        try await eventuallyOnMain("the windowless receiver to start the thread") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the first turn to work") { b.taken().first?.activity == "working" }
        try b.report(thread.id, .done)
        _ = try #require(await parent.nextMessage())
        try await eventuallyOnMain("the first result to settle") { a.sent().first?.state == .done && b.taken().first?.state == .done }
        let prior = b.dispatched.first?.completedAt
        // The status above is reported by hand, so nothing yet says the stub pi has started: the host refuses a message to a thread that isn't servable.
        try await eventuallyOnMain("the receiver's pi to serve the thread") {
            b.server.queue.sync { b.server.rpcThread(forAgent: thread.id)?.isServable == true }
        }

        let gate = FleetTestGate()
        await gate.close()
        b.server.queue.sync {
            if let dispatch = b.server.fleet?.dispatch {
                let message = dispatch.host.messageThread
                dispatch.host.messageThread = { id, text, delivery in
                    let sent = await message(id, text, delivery)
                    await gate.pass()
                    return sent
                }
            }
        }
        let sending = Task { @MainActor in
            try await parent.call { .fleetDispatchMessage(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID, text: "Follow up.", delivery: .followUp) }
        }
        do {
            try await Self.wait("the receiver to hold the send reply") { await gate.waiting == 1 }
            try b.report(thread.id, .working)
            try await eventuallyOnMain("the follow-up to work") { b.dispatched.first?.status == .working }
            try b.report(thread.id, .done)
            try await eventuallyOnMain("the follow-up to settle before the acknowledgement") {
                b.dispatched.first?.status == .done && b.dispatched.first?.completedAt != prior
            }
        } catch {
            await gate.open()
            throw error
        }
        await gate.open()
        _ = try parent.info(try await sending.value)
        _ = try #require(await parent.nextMessage())
        try await eventuallyOnMain("both dispatch records to finish the second turn") { a.sent().first?.state == .done && b.taken().first?.state == .done }
    }

    @Test func ordinaryStopTellsTheThreadToStopItsRetainedBashGroups() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        let spawn = AgentSpawn(agent: parent.agent, cwd: a.folder.path, settings: AgentLaunchSettings())
        _ = try #require(try await a.server.respawnAgent(spawn))
        try parent.extension.send(.helloChildren(agentID: parent.agent.id))
        try await eventuallyOnMain("the parent agent to serve before stopping") {
            a.server.queue.sync { a.server.rpcThread(forAgent: parent.agent.id)?.isServable == true }
        }
        // Ordering on one socket: a Fleet request answered after hello proves the control registration landed.
        _ = try await parent.call { .fleetListHosts(id: $0, agentID: parent.agent.id) }
        a.pressStop(parent.agent.id)
        #expect(try await parent.read() == .stopManagedBash(sweepChildren: true))
    }

    @Test(arguments: ["stop then close", "scoped then close", "delete", "cancel", "close"])
    func explicitTeardownStopsEscapedJobsButNotReadableDecoys(action: String) async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        b.server.queue.sync { b.server.fleet?.dispatch.freeWorktreeBytes = { _ in .max } }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("flaky-hold escaped-job-fixtures fleet-disk-failure", host: "Mac mini"))
        try await eventuallyOnMain("the receiver to start") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let jobs = EscapedJobs(cwd: URL(fileURLWithPath: try #require(thread.worktreePath)))
        let orphan = try await jobs.adopted("orphan"), detached = try await jobs.adopted("session")
        #expect(getpgid(orphan) == orphan && getsid(orphan) != orphan)
        #expect(getsid(detached) == detached)
        var decoys = [pid_t]()
        for name in ["decoy-no-marker", "decoy-other-thread", "decoy-argv"] {
            decoys.append(try await jobs.adopted(name))
        }
        var owned = [orphan, detached]

        switch action {
        case "delete": try await b.server.deleteAgent(thread.id)
        case "cancel": #expect(try await parent.cancel(info).state == "cancelled")
        default:
            try b.report(thread.id, .working)
            try await eventuallyOnMain("the dispatch to work") { b.taken().first?.activity == "working" }
            try Data().write(to: jobs.cwd.appendingPathComponent("flaky-go"))
            try b.report(thread.id, .done)
            try await eventuallyOnMain("the dispatch to settle") { a.sent().first?.state == .failed }
            if action == "stop then close" || action == "scoped then close" {
                let survivors = try await scopeBashSweeps(on: b, thread: thread, jobs: jobs, pressStop: action == "stop then close")
                decoys.append(survivors.decoy)
                owned.append(survivors.next)
                #expect(kill(orphan, 0) == 0 && kill(detached, 0) == 0, "earlier turns' jobs survive scoped cleanup")
            }
            try await eventuallyOnMain("the pi to settle before close") {
                b.server.queue.sync { b.server.rpcThread(forAgent: thread.id)?.piBusy == false }
            }
            let closed = try parent.info(try await parent.call {
                .fleetDispatchClose(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID)
            })
            let report = try #require(closed.closeReport)
            let found = try #require(report.firstMatch(of: /Marked process sweep: ([0-9]+) escapees found;/))
            #expect((Int(found.1) ?? 0) >= 2)
            #expect(report.contains("; 0 marked processes not confirmed stopped."))
        }
        try await eventuallyOnMain("all owned escapees to exit", timeout: .seconds(6)) {
            owned.allSatisfy { kill($0, 0) != 0 }
        }
        #expect(decoys.allSatisfy { kill($0, 0) == 0 })
    }

    private struct EscapedJobs {
        let cwd: URL

        private func adoptedPID(_ name: String) -> pid_t? {
            guard let text = try? String(contentsOf: cwd.appendingPathComponent(name + ".pid"), encoding: .utf8),
                  let pid = pid_t(text), pid > 1 else { return nil }
            var info = proc_bsdinfo()
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) > 0,
                  info.pbi_ppid == 1 else { return nil }
            return pid
        }

        func adopted(_ name: String) async throws -> pid_t {
            try await eventuallyOnMain("\(name) to be reparented to launchd") { adoptedPID(name) != nil }
            let pid = try #require(adoptedPID(name))
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = 1024 * 1024
            var bytes = [UInt8](repeating: 0, count: size)
            try #require(bytes.withUnsafeMutableBytes { sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) } == 0,
                         "the fixture's exec environment must be readable")
            #expect(bytes.prefix(size).split(separator: 0).contains { $0.elementsEqual("STUB_ESCAPED_JOB=\(name)".utf8) })
            return pid
        }
    }

    private func scopeBashSweeps(on mac: Mac, thread: Agent, jobs: EscapedJobs, pressStop: Bool) async throws -> (decoy: pid_t, next: pid_t) {
        let client = try ExtensionClient(path: mac.host.socketPath)
        try client.send(.helloChildren(agentID: thread.id))
        let s = try #require(mac.server.queue.sync { mac.server.rpcThread(forAgent: thread.id)?.session.id })
        let first = UUID(), second = UUID()
        func prompt(_ text: String) async throws {
            await mac.server.sendOpeningPrompt(try #require(OpeningPrompt(text, agentID: thread.id)), sessionID: s)
        }
        let hold = pressStop ? " escaped-abort-hold" : ""
        try await prompt("flaky escaped-job:scoped-first:\(first.uuidString.lowercased()) escaped-job:scoped-second:\(second.uuidString.lowercased()) escaped-job:decoy-other-thread-scope:\(first.uuidString.lowercased())\(hold)")
        let firstPID = try await jobs.adopted("scoped-first")
        let secondPID = try await jobs.adopted("scoped-second")
        let decoy = try await jobs.adopted("decoy-other-thread-scope")
        if pressStop {
            let stopped = await withCheckedContinuation { (done: CheckedContinuation<Bool, Never>) in
                mac.server.queue.async {
                    guard let rpc = mac.server.rpcThread(forAgent: thread.id) else { done.resume(returning: false); return }
                    rpc.stop { done.resume(returning: (try? $0.get()) != nil) }
                }
            }
            try #require(stopped)
        }
        try client.send(.stopBashProcesses(agentID: thread.id, bashScope: first))
        // Drive the next turn while the Stop sweep is still pending. Its scope is not aborted.
        try await prompt("flaky escaped-job:next-turn:\(UUID().uuidString.lowercased())")
        let next = try await jobs.adopted("next-turn")
        try await eventuallyOnMain("the first scoped sweep to send TERM") {
            FileManager.default.fileExists(atPath: jobs.cwd.appendingPathComponent("scoped-first.term").path)
        }
        for _ in 0..<10 { try client.send(.stopBashProcesses(agentID: thread.id, bashScope: second)) }
        try await eventuallyOnMain("the TERM-resistant first scoped job to exit") { kill(firstPID, 0) != 0 }
        #expect(kill(secondPID, 0) == 0, "requests during a scoped sweep wait for the next batch")
        try await eventuallyOnMain("the next scoped batch to exit its target") { kill(secondPID, 0) != 0 }
        #expect(kill(next, 0) == 0 && kill(decoy, 0) == 0)
        return (decoy, next)
    }

    @Test func cancellingADispatchStopsItsBackgroundProcessAndKeepsItsThread() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("flaky-hold fleet-close-background fleet-detached", host: "Mac mini"))
        try await eventuallyOnMain("the receiver to run the dispatch") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        let pidFile = worktree.appendingPathComponent("fleet-child-pid")
        func childPID() -> Int32? { (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) }
        try await eventuallyOnMain("the stub to launch a background child") { childPID() != nil }
        let pid = try #require(childPID())
        #expect(kill(pid, 0) == 0)
        try await b.local.openTerminal(agentID: thread.id, cwd: worktree.path, command: "/bin/sleep 60")
        let tab = try #require(b.server.state.tabs.first { $0.id == thread.tabID })
        let terminal = try #require(tab.layout.leaves.first { $0.agentID == nil }?.sessionID)
        #expect(await b.server.sessionInfo(sessionID: terminal)?.isAlive == true)
        let cancelled = try await parent.cancel(info)
        #expect(cancelled.state == "cancelled")
        try await eventuallyOnMain("the receiver to cancel") { b.taken().first?.state == .cancelled }
        try await eventuallyOnMain("the cancelled dispatch's background child to exit", timeout: .seconds(5)) { kill(pid, 0) != 0 }
        #expect(await b.server.sessionInfo(sessionID: terminal)?.isAlive == true, "cancel does not stop the person's shell")
        #expect(b.dispatched.first?.id == thread.id)
        #expect(try Self.head(worktree) == origin.sha)
    }

    @Test(arguments: ["live host", "record lost during close", "restarted host"])
    func aSettledDispatchClosesItsThreadAndBuildOutputButKeepsTheCheckout(scenario: String) async throws {
        let (a, b, origin) = try await Self.pair(originExtra: [".gitignore": "*.log\n.build/\nDerivedData/\n"])
        let losesRecord = scenario == "record lost during close", restarts = scenario == "restarted host"
        defer { a.stop(); b.stop(keepFiles: restarts) }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("flaky-hold fleet-close-background fleet-disk-failure", host: "Mac mini"))
        let close = { try await parent.call { .fleetDispatchClose(id: $0, agentID: parent.agent.id, dispatchID: info.dispatchID) } }
        try await eventuallyOnMain("the receiving Mac to start") { b.taken().first?.state == .running }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        let pidFile = worktree.appendingPathComponent("fleet-child-pid")
        try await eventuallyOnMain("the stub to launch its background process") {
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap(Int32.init) != nil
        }
        let pid = try #require(Int32(String(contentsOf: pidFile, encoding: .utf8)))
        #expect(kill(pid, 0) == 0)
        guard case .error(_, "not_settled", _) = try await close() else { Issue.record("closed a live thread"); return }
        try b.report(thread.id, .working)
        try await eventuallyOnMain("the receiver to report working") { b.taken().first?.activity == "working" }
        let build = worktree.appendingPathComponent(".build")
        let derived = worktree.appendingPathComponent("DerivedData")
        try FileManager.default.createDirectory(at: build, withIntermediateDirectories: false)
        try Data(repeating: 0x61, count: 8192).write(to: build.appendingPathComponent("workspace-state.json"))
        try FileManager.default.createDirectory(at: derived, withIntermediateDirectories: false)
        try Data("keep unverified output".utf8).write(to: derived.appendingPathComponent("notes.txt"))
        try Data().write(to: worktree.appendingPathComponent("flaky-go"))
        try b.report(thread.id, .done)
        try await eventuallyOnMain("the structured disk error to reach the sender") { a.sent().first?.state == .failed }
        #expect(a.sent().first?.failureDetail?.contains("ENOSPC") == true)
        let cancelled = try await parent.cancel(info)
        #expect(cancelled.state == "failed" && !b.dispatched.isEmpty, "cancel does not close a settled thread")
        if losesRecord {
            await b.server.enqueueValue { @Sendable in
                guard let engine = b.server.fleet?.dispatch else { return }
                let close = engine.host.closeThread
                engine.host.closeThread = { [weak server = b.server] agent, id in
                    let stopped = try await close(agent, id)
                    if let server {
                        await server.enqueueValue { @Sendable in _ = server.fleet?.dispatch.inbound.removeValue(forKey: id) }
                    }
                    return stopped
                }
            }
        }
        let receiver: Mac
        if restarts {
            b.stop(keepFiles: true)
            receiver = try await Mac("Mac mini", origin: origin, dir: b.host.dir, port: b.port)
        } else {
            receiver = b
        }
        defer { if restarts { receiver.stop() } }
        if restarts { try await Self.waitForReports(a, receiver) }
        let reply = try await close()
        if losesRecord {
            guard case .error(_, "unknown_dispatch", _) = reply else { Issue.record("Expected a missing dispatch refusal, got \(reply)"); return }
        } else {
            let report = try #require(try parent.info(reply).closeReport)
            #expect(report.contains("Thread removed") && report.contains("Tracked sessions stopped") && report.contains("bytes freed"))
            #expect(report.contains("Kept the checkout, branches, and saved conversation"))
            if restarts { #expect(report.contains("escaped processes were not checked") && !report.contains("Build output kept")) }
            #expect(try parent.info(try await close()).closeReport == report, "a repeated close returns the same receipt")
        }
        try await eventuallyOnMain("the background process to exit") { kill(pid, 0) != 0 }
        #expect(receiver.dispatched.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: build.path) && FileManager.default.fileExists(atPath: derived.path))
        #expect(FileManager.default.fileExists(atPath: pidFile.path))
        #expect(try Self.head(worktree) == origin.sha)
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
        // Two dispatches of one task arrive together: each gets its own branch and worktree, neither fails on the other's name.
        #expect(Set(b.dispatched.compactMap(\.worktreeBranch)).count == 2 && Set(b.dispatched.compactMap(\.worktreePath)).count == 2)
    }

    /// Two creates of one title arriving together (a worktree takes a while, so the second arrives before the first has
    /// made its branch): each must get its own branch and worktree, and neither may fail on the other's name.
    @Test func twoCreatesOfOneTitleArrivingTogetherGetTheirOwnBranchesAndBothStart() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        func create() -> FleetDispatchCreate {
            FleetDispatchCreate(dispatchID: UUID(), task: "Fix the flaky payment test.", title: "Fix flaky payment test", repoKey: Self.repoKey, commitSHA: origin.sha,
                                from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentTitle: "Ship checkout"))
        }
        let (one, two) = (create(), create())
        async let first = viaA.fleetDispatchCreate(one)
        async let second = viaA.fleetDispatchCreate(two)
        _ = try await (first, second)
        try await Self.wait("both threads to start") { b.dispatched.count == 2 }
        #expect(Set(b.dispatched.compactMap(\.worktreeBranch)).count == 2 && Set(b.dispatched.compactMap(\.worktreePath)).count == 2)
        try await Self.wait("both records to run") { b.taken().count == 2 && b.taken().allSatisfy { $0.state == .running } }
        #expect(b.taken().allSatisfy { $0.failure == nil })
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

    @Test func threadsMaySendOnlyWhenTheSettingIsOn() async throws {
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
    }

    @Test func aThreadThreeDeepCannotSendWorkButStillSeesTheFleet() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // A thread sent from A by a thread two below the one the person started: three deep on B, whatever B's own settings say.
        b.settings.withValue { $0.apply(.fleetThreadsCanSend(true)) }
        b.server.fleetHostSettingsChanged(b.settings.current)
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        _ = try await viaA.fleetDispatchCreate(FleetDispatchCreate(dispatchID: UUID(), task: "x", title: "x", repoKey: Self.repoKey, commitSHA: origin.sha,
                                                                  from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentID: AgentID(),
                                                                                            agentTitle: "Ship", depth: 2)))
        try await Self.wait("a dispatched thread") { !b.dispatched.isEmpty }
        let sent = try #require(b.dispatched.first)
        #expect(sent.threadDepth == 3)
        let dispatched = Parent(agent: sent, extension: try ExtensionClient(path: b.host.socketPath), mac: b)
        try dispatched.hello()
        guard case .error(_, FleetDispatchCode.tooDeep, _) = try await dispatched.dispatch(key: "chain") else { Issue.record("a thread three deep sent work on"); return }
        if case .error(_, let code, _) = try await dispatched.call({ .fleetListHosts(id: $0, agentID: sent.id) }) {
            Issue.record("a thread three deep can't list the fleet: \(code)")
        }
        // A sender three deep is refused by the Mac it sends to as well.
        await #expect(throws: (any Error).self) {
            try await viaA.fleetDispatchCreate(FleetDispatchCreate(dispatchID: UUID(), task: "y", title: "y", repoKey: Self.repoKey, commitSHA: origin.sha,
                                                                   from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentID: AgentID(),
                                                                                             agentTitle: "Ship", depth: 3)))
        }

        // The rest of the table (a project worker, a coordinator, a design's agent, an automation run) is `FleetDispatchScopeTests`.
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
        let (a, b, _) = try await Self.pair()
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
        #expect(info.host == "Mac mini")
        #expect(a.sent().first?.targetHostID == (try await b.hostID()))
        let waiting = try await parent.status(info)
        #expect(waiting.state == "waitingRoom" && waiting.host == "Mac mini")
        #expect(waiting.hostRunningDispatches == FleetDispatchProtocol.admissionLimit)
        #expect(b.taken().count == FleetDispatchProtocol.admissionLimit && b.dispatched.isEmpty)

        // A place frees up: the sender sends it to the named Mac, and the same id starts exactly once.
        b.server.queue.sync {
            if let id = b.server.fleet?.dispatch.inbound.keys.first { b.server.fleet?.dispatch.inbound[id]?.record.state = .done }
        }
        a.server.queue.sync { a.server.fleet?.dispatch.evaluate() }
        let dispatchID = try #require(UUID(uuidString: info.dispatchID))
        try await eventuallyOnMain("the same dispatch to run on B") { b.dispatched.first?.dispatchedFrom?.dispatchID == dispatchID }
        #expect(a.dispatched.isEmpty && b.dispatched.count == 1)
        #expect(a.sent().first?.hostRunningDispatches == nil)
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

    // MARK: What a Mac lacks

    @Test func aMacMissingAnMCPServersCommandStillRunsTheWorkAndTheSenderIsToldWhatItLacked() async throws {
        let (a, b, _) = try await Self.pair(busyA: 90, busyB: 10, mcp: ["bear": "/Applications/Bear.app/bearcli", "fetch": "npx"], lackingB: ["npx"])
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let bID = try await b.hostID()
        // B's report says what it lacks, as a fact; it is not a reason to refuse.
        let report = try #require(try await a.local.fleetRead().snapshot.macs.first { $0.hostID == bID }?.readiness)
        #expect(Set(report.missing) == [FleetMissingTool(kind: .binary, name: "npx"), FleetMissingTool(kind: .binary, name: "bearcli")])
        guard case .fleetHosts(_, let hosts) = try await parent.call({ .fleetListHosts(id: $0, agentID: parent.agent.id) }) else { Issue.record("no list"); return }
        let mini = try #require(hosts.first { $0.name == "Mac mini" })
        #expect(mini.problems.isEmpty && Set(mini.without ?? []) == ["npx", "bearcli"])

        // Named and Auto both place it; the thread runs there, and the sender's reply and record name the servers it started without.
        let named = try parent.info(try await parent.dispatch(key: "named", host: "Mac mini"))
        #expect(named.host == "Mac mini" && named.failure == nil && Set(named.without ?? []) == ["npx", "bearcli"])
        try await Self.wait("B to run the dispatched thread") { !b.dispatched.isEmpty }
        #expect(Set(a.sent().first { $0.id.uuidString.lowercased() == named.dispatchID }?.without ?? []) == ["npx", "bearcli"])
        let auto = try parent.info(try await parent.dispatch("Another task.", key: "auto"))
        #expect(auto.host == "Mac mini" && auto.failure == nil && auto.without?.isEmpty == false)
        #expect(a.sent().allSatisfy { $0.failure == nil })
    }

    @Test func aMacWithoutXcodeTakesAWebRepositoryAndIsRefusedOneWithAnXcodeProject() async throws {
        let web = try await Self.pair(busyA: 90, busyB: 10, noXcodeB: true)
        defer { web.a.stop(); web.b.stop() }
        let parent = try await web.a.parent()
        try parent.hello()
        #expect(try parent.info(try await parent.dispatch(key: "web", host: "Mac mini")).failure == nil)
        try await Self.wait("B to run the web thread") { !web.b.dispatched.isEmpty }

        let ios = try await Self.pair(busyA: 90, busyB: 10, originExtra: ["App.xcodeproj/project.pbxproj": "// acme-ios\n"], noXcodeB: true)
        defer { ios.a.stop(); ios.b.stop() }
        let iosParent = try await ios.a.parent()
        try iosParent.hello()
        guard case .error(_, let code, let message) = try await iosParent.dispatch(key: "ios", host: "Mac mini") else { Issue.record("not refused"); return }
        #expect(code == FleetDispatchCode.hostNotReady && message.contains("Xcode isn't installed"))
        #expect(ios.b.dispatched.isEmpty)
        guard case .fleetHosts(_, let hosts) = try await iosParent.call({ .fleetListHosts(id: $0, agentID: iosParent.agent.id) }) else { Issue.record("no list"); return }
        #expect(hosts.first { $0.name == "Mac mini" }?.problems == ["Xcode"], "fleet_hosts says what stops work for this thread's repository")
    }

    // MARK: Refusals with codes

    @Test func aNamedMacWithoutTheRepoIsNeverRefusedForItAndNeverReroutedItClonesIt() async throws {
        // Mac mini holds another repository's checkout under this space; it has none of acme/web, so it clones it (slice 4f).
        let (a, b, _) = try await Self.pair(repoKeyB: "github.com/acme/other")
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch(key: "named", host: "Mac mini"))
        #expect(info.host == "Mac mini")
        try await Self.wait("Mac mini to run the dispatched thread") { !b.dispatched.isEmpty }
        #expect(a.sent().first?.failure == nil)
        #expect(b.server.state.spaces.contains { $0.repoKey == Self.repoKey } && b.server.state.spaces.contains { $0.repoKey == "github.com/acme/other" })
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
