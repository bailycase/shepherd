import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// Pressure and readiness between real scratch hosts: samples flow from each Mac to the others it
/// is paired with, a sample the sender stops refreshing goes stale at 15 seconds by the
/// receiver's own clock, and a host that nobody watches never samples. The clock is injected and
/// no test sleeps: a tick is asked for, never waited out.
@Suite("Fleet pressure", .integrationTimeLimit)
struct FleetPressureIntegrationTests {
    /// A clock the test moves.
    final class TestClock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        init(_ date: Date = Date(timeIntervalSince1970: 1_790_000_000)) { self.date = date }
        var now: Date { lock.lock(); defer { lock.unlock() }; return date }
        func advance(_ seconds: TimeInterval) { lock.lock(); date.addTimeInterval(seconds); lock.unlock() }
    }

    /// A Mac's counters: each CPU reading moves `busy` ticks of every 100, so its CPU reads that share.
    final class Meter: @unchecked Sendable {
        private let lock = NSLock()
        private var ticks = FleetCPUTicks(user: 0, system: 0, idle: 0, nice: 0)
        private var reads = 0
        let busy: UInt64
        init(busy: UInt64) { self.busy = busy }

        var cpuReads: Int { lock.lock(); defer { lock.unlock() }; return reads }

        func nextTicks() -> FleetCPUTicks {
            lock.lock(); defer { lock.unlock() }
            reads += 1
            ticks.user += busy
            ticks.idle += 100 - busy
            return ticks
        }

        var sources: FleetPressureSources {
            FleetPressureSources(cpuTicks: { self.nextTicks() }, memory: { FleetMemoryPages(free: 1_000, inactive: 500, speculative: 0, pageSize: 1 << 20) },
                                 totalMemoryBytes: { 4_000 << 20 }, cpuCount: { 8 }, thermal: { .nominal }, power: { (false, nil) }, pause: { _ in })
        }
    }

    /// A scratch host in a fleet with a counter of its own, a clock of its own and a readiness probe that says git is missing.
    final class Mac: @unchecked Sendable {
        let host: ScratchServer
        let port: UInt16
        let name: String
        let local: RemoteHostClient
        let sharedToken: String
        let meter: Meter
        let clock: TestClock
        var server: SessionServer { host.server }
        var peersFile: URL { host.dir.appendingPathComponent("fleet/peers.json") }

        /// `mcpConfig` stands in for pi's MCP file, and `probe` for the login shell.
        init(_ name: String, busy: UInt64, clock: TestClock = TestClock(), mcpConfig: URL? = nil,
             probe: @escaping FleetReadiness.Probe = { _ in FleetProbeResult(noGit: true) }) async throws {
            self.name = name
            self.meter = Meter(busy: busy)
            self.clock = clock
            let host = try ScratchServer()
            let server = host.server
            server.configureFleet(name: name, advertises: false)
            let meter = meter
            let ownFacts: (@Sendable () -> FleetLocalFacts)? = mcpConfig.map { url in { @Sendable in FleetLocalFacts(mcpConfig: url) } }
            server.configureFleet(clock: { clock.now }, pressure: { queue, facts in
                // An hour between ticks: the timer's first tick is the only one that fires; the tests ask for the rest.
                FleetPressure(queue: queue, clock: { clock.now }, sampler: FleetPressureSampler(sources: meter.sources),
                              localFacts: ownFacts ?? facts,
                              probe: probe, hardware: { (name, "M4 Pro") }, interval: 3_600)
            })
            let tokenURL = host.dir.appendingPathComponent("remote-token")
            let socket = host.dir.appendingPathComponent("h.sock").path
            let port = try server.startRemoteListener(port: 0, tokenURL: tokenURL)
            let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            try server.startLocalListener(path: socket, tokenURL: tokenURL)
            server.setFleetEnabled(true)
            let local = RemoteHostClient(localSocket: socket)
            _ = try await local.connect(host: "", port: 0, token: token, clientName: "Shepherd")
            (self.host, self.port, self.sharedToken, self.local) = (host, port, token, local)
        }

        func stop(keepFiles: Bool = false) {
            local.disconnect()
            host.stop(keepFiles: keepFiles)
        }

        func read() async throws -> FleetSnapshot { try await local.fleetRead().snapshot }

        func pair(with other: Mac) async throws {
            let code = try #require(try await other.local.fleetAction(.startJoin).join).code
            try #require(try await local.fleetAction(.pair(host: "127.0.0.1", port: other.port, code: code)).paired)
        }

        func hostID() async throws -> UUID { try #require(try await read().hostID) }

        /// Whether the host's timer runs.
        var isSampling: Bool { server.queue.sync { server.fleet?.pressure.isSampling ?? false } }

        /// Takes a sample now (the timer's job, asked for).
        func tick() { server.queue.async { self.server.fleet?.pressure.tick() } }

        /// What this Mac holds of `other`.
        func state(of other: UUID) async throws -> FleetMacState? { try await read().macs.first { $0.hostID == other } }

        /// A client authenticated as the Mac `other` is (with the token `other` presents to this one).
        func connectAsPeer(_ other: Mac) async throws -> RemoteHostClient {
            let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: other.peersFile)) as? [String: Any])
            let peers = try #require(file["peers"] as? [[String: Any]])
            let token = try #require(peers.first { $0["name"] as? String == name }?["myToken"] as? String)
            let client = RemoteHostClient()
            _ = try await client.connect(host: "127.0.0.1", port: port, token: token, clientName: other.name, capabilities: [],
                                         expectingHostID: nil, fetchesState: false)
            return client
        }
    }

    /// Two paired Macs, each holding a link to the other.
    static func pair(_ a: Mac, _ b: Mac) async throws {
        try await a.pair(with: b)
        for (one, other) in [(a, b), (b, a)] {
            try await eventually("\(one.name) to hold a link to \(other.name)") {
                try await one.read().peers.contains { $0.name == other.name && $0.link == .connected }
            }
        }
    }

    // MARK: Samples flow

    @Test func pairedMacsPushTheirSamplesAndReadinessToEachOther() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())

        try await eventually("B to hold A's sample and report") {
            guard let held = try await b.state(of: aID) else { return false }
            return held.sample != nil && held.readiness != nil
        }
        try await eventually("A to hold B's sample and report") {
            guard let held = try await a.state(of: bID) else { return false }
            return held.sample != nil && held.readiness != nil
        }
        let atB = try #require(try await b.state(of: aID)), atA = try #require(try await a.state(of: bID))
        #expect(abs(try #require(atB.sample).cpuUtilization - 0.30) < 1e-9, "what A measured crossed to B")
        #expect(abs(try #require(atA.sample).cpuUtilization - 0.60) < 1e-9)
        #expect(atB.sample?.cpuCount == 8 && atB.sample?.availableMemoryBytes == 1_500 << 20)
        #expect(atB.readiness?.model == "MacBook Pro" && atB.readiness?.chip == "M4 Pro")
        #expect(atB.readiness?.missing == [FleetMissingTool(kind: .git)], "readiness is the facts the host found")
        #expect(atB.sampleAge == 0, "stamped on arrival by B's own clock")

        // Each Mac also has its own.
        let own = try #require(try await a.state(of: aID))
        #expect(abs(try #require(own.sample).cpuUtilization - 0.30) < 1e-9)
    }

    @Test func aNewSampleReplacesTheOldAndRestampsIt() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let aID = try await a.hostID()
        try await eventually("B to hold A's sample") { try await b.state(of: aID)?.sample != nil }

        b.clock.advance(10)
        #expect(try await b.state(of: aID)?.sampleAge == 10)
        let reads = a.meter.cpuReads
        a.tick()
        try await eventually("a fresh sample to reach B") { try await b.state(of: aID)?.sampleAge == 0 }
        #expect(a.meter.cpuReads > reads)
    }

    // MARK: Stale

    @Test func aSampleGoesStaleAtFifteenSecondsOnTheReceiversClock() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let aID = try await a.hostID()
        try await eventually("B to hold A's sample") { try await b.state(of: aID)?.sample != nil }

        let held = try #require(try await b.state(of: aID))
        let sample = try #require(held.sample)
        b.clock.advance(15)
        var age = try #require(try await b.state(of: aID)?.sampleAge)
        #expect(age == 15 && FleetRoom.skip(sample, age: age) == nil, "fifteen seconds is still counted")
        b.clock.advance(0.5)
        age = try #require(try await b.state(of: aID)?.sampleAge)
        #expect(FleetRoom.skip(sample, age: age) == .stale)

        // The page says so too, and the Mac is not counted though its link is up.
        let page = FleetPagePresentation.make(snapshot: try await b.read(), weight: { _ in .normal })
        let card = try #require(page.cards.first { $0.id == aID })
        #expect(card.statusText == "Connected" && card.room.text == "Not counted" && card.cpu == nil)

        // A fresh one brings it back.
        a.tick()
        try await eventually("a fresh sample to bring A back") {
            let age = try await b.state(of: aID)?.sampleAge ?? 99
            return age == 0
        }
        let back = FleetPagePresentation.make(snapshot: try await b.read(), weight: { _ in .normal })
        #expect(back.cards.first { $0.id == aID }?.cpu?.text == "30%")
    }

    @Test func aSendersClockNeverMatters() async throws {
        // B's clock is an hour ahead of A's: what B holds of A is aged by B's clock alone.
        let a = try await Mac("MacBook Pro", busy: 30, clock: TestClock(Date(timeIntervalSince1970: 1_790_000_000)))
        let b = try await Mac("Mac mini", busy: 60, clock: TestClock(Date(timeIntervalSince1970: 1_790_003_600)))
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let aID = try await a.hostID()
        try await eventually("B to hold A's sample") { try await b.state(of: aID)?.sample != nil }
        #expect(try await b.state(of: aID)?.sampleAge == 0)
        #expect(FleetRoom.skip(try #require(try await b.state(of: aID)?.sample), age: 0) == nil)
    }

    // MARK: Readiness follows what it is made of

    @Test func aNewMCPServerWhoseCommandIsMissingShowsUpAtTheNextSampleAndNotBefore() async throws {
        let dir = try makeScratchDirectory("mcp")
        defer { try? FileManager.default.removeItem(at: dir) }
        let config = dir.appendingPathComponent("mcp.json")
        try Data(#"{"mcpServers": {"fetch": {"command": "npx"}}}"#.utf8).write(to: config)
        let probes = Locked(0)
        let a = try await Mac("MacBook Pro", busy: 30, mcpConfig: config, probe: { commands in
            probes.withValue { $0 += 1 }
            // The fake login shell finds every command but muse.
            return FleetProbeResult(missingCommands: Set(commands).intersection(["muse"]))
        })
        let b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        try await eventually("B to hold A's report") { try await b.state(of: aID)?.readiness != nil }
        #expect(try await b.state(of: aID)?.readiness?.missing == [])

        // Nothing changed: the next samples don't ask the shell again.
        let before = probes.current
        a.tick()
        try await eventually("a second sample") { a.meter.cpuReads >= 4 }
        #expect(probes.current == before, "the report is made again only when its inputs change, and daily")

        try Data(#"{"mcpServers": {"fetch": {"command": "npx"}, "muse": {"command": "muse"}}}"#.utf8).write(to: config)
        a.tick()
        try await eventually("the new server's missing command to reach B") {
            try await b.state(of: aID)?.readiness?.missing == [FleetMissingTool(kind: .binary, name: "muse")]
        }
        _ = bID
        let page = FleetPagePresentation.make(snapshot: try await b.read(), weight: { _ in .normal })
        #expect(page.cards.first { $0.id == aID }?.ready.text == "muse CLI isn’t installed")
    }

    @Test func aDailyRecheckRemakesTheReportEvenWithNothingChanged() async throws {
        let probes = Locked(0)
        let a = try await Mac("MacBook Pro", busy: 30, probe: { _ in probes.withValue { $0 += 1 }; return FleetProbeResult() })
        defer { a.stop() }
        _ = try await a.local.fleetAction(.watching(true))
        try await eventually("the first report") { probes.current == 1 }
        a.tick()
        try await eventually("a second sample") { a.meter.cpuReads >= 4 }
        #expect(probes.current == 1)
        a.clock.advance(FleetPressure.readinessLifetime + 1)
        a.tick()
        try await eventually("the daily recheck") { probes.current == 2 }
    }

    // MARK: Who may speak, and what they may say

    @Test func aPeerCanAskForASampleAndPushOneAndItIsKeptUnderWhoItAuthenticatedAs() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let aID = try await a.hostID()

        let asA = try await b.connectAsPeer(a)
        defer { asA.disconnect() }
        #expect(asA.capabilities.contains(RemoteProtocol.fleetPressureCapability))
        // `a` presents A's token to B: asking B for a sample.
        let answer = try await asA.fleetPressureNow()
        #expect(abs(answer.sample.cpuUtilization - 0.60) < 1e-9, "B answers with its own reading")
        #expect(answer.readiness?.model == "Mac mini" || answer.readiness == nil)

        // A pushes nonsense: it is kept clamped, under the Mac that authenticated, never one it names.
        try await asA.fleetPressure(FleetPressureSample(cpuUtilization: 7, cpuCount: 99_999, totalMemoryBytes: 10, availableMemoryBytes: 1_000, activeAgents: -5))
        let kept = try #require(try await b.state(of: aID)?.sample)
        #expect(kept.cpuUtilization == 1 && kept.cpuCount == 1024 && kept.availableMemoryBytes == 10 && kept.activeAgents == 0)
    }

    @Test func aMacHoldingOnlyTheSharedTokenCantReportLoad() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let client = RemoteHostClient()
        _ = try await client.connect(host: "127.0.0.1", port: b.port, token: b.sharedToken, clientName: "phone")
        defer { client.disconnect() }
        for attempt in [
            { try await client.fleetPressure(FleetPressureSample(cpuUtilization: 0, cpuCount: 1, totalMemoryBytes: 1, availableMemoryBytes: 1)) },
            { try await client.fleetReadiness(FleetReadinessReport()) },
            { _ = try await client.fleetPressureNow() },
        ] as [() async throws -> Void] {
            do { try await attempt(); Issue.record("a client that is no fleet Mac spoke for one") }
            catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.forbidden) }
        }
    }

    @Test func removingAMacForgetsWhatItSaid() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let (aID, bID) = (try await a.hostID(), try await b.hostID())
        try await eventually("A to hold B's sample") { try await a.state(of: bID)?.sample != nil }
        _ = try await a.local.fleetAction(.remove(hostID: bID))
        #expect(try await a.state(of: bID) == nil)
        try await eventually("B to leave A's fleet too") { try await b.read().peers.isEmpty }
        #expect(try await b.state(of: aID) == nil)
    }

    // MARK: Nobody asking

    @Test func aHostWithNoPeerAndNoViewerNeverSamples() async throws {
        let a = try await Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        _ = try await a.read()
        #expect(!a.isSampling && a.meter.cpuReads == 0, "an idle host never reads a counter")
        #expect(try await a.read().macs.isEmpty)
    }

    @Test func theFleetPageWatchingStartsSamplingAndStopsWhenItGoes() async throws {
        let a = try await Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        let aID = try await a.hostID()
        _ = try await a.local.fleetAction(.watching(true))
        try await eventually("this Mac to be sampled") { try await a.state(of: aID)?.sample != nil }
        #expect(a.isSampling)
        _ = try await a.local.fleetAction(.watching(false))
        #expect(!a.isSampling)
        let reads = a.meter.cpuReads
        #expect(try await a.read().macs.count == 1 && a.meter.cpuReads == reads, "reading the snapshot takes no sample")
    }

    @Test func aWatcherThatDisconnectsStopsTheSampling() async throws {
        let a = try await Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        let socket = a.host.dir.appendingPathComponent("h.sock").path
        let viewer = RemoteHostClient(localSocket: socket)
        _ = try await viewer.connect(host: "", port: 0, token: a.sharedToken, clientName: "Shepherd")
        _ = try await viewer.fleetAction(.watching(true))
        try await eventually("sampling to start") { a.isSampling }
        viewer.disconnect()
        try await eventually("sampling to stop with its viewer") { !a.isSampling }
    }

    @Test func theAppIsToldAboutNewSamplesOnlyWhileItWatches() async throws {
        let a = try await Mac("MacBook Pro", busy: 30)
        defer { a.stop() }
        // The app's own connection: the host pushes settings pages to the apps that list local threads.
        let app = RemoteHostClient(localSocket: a.host.dir.appendingPathComponent("h.sock").path)
        _ = try await app.connect(host: "", port: 0, token: a.sharedToken, clientName: "Shepherd",
                                  capabilities: RemoteProtocol.clientCapabilities + [RemoteProtocol.localThreadsCapability])
        defer { app.disconnect() }
        let pushes = Locked(0)
        app.onSettingsChanged = { page in if page == .fleetPressure { pushes.withValue { $0 += 1 } } }
        a.tick()
        try await eventually("a tick to land") { a.meter.cpuReads > 0 }
        #expect(pushes.current == 0, "nobody watches, so nothing is pushed")
        _ = try await app.fleetAction(.watching(true))
        try await eventually("the app to be told") { pushes.current > 0 }
    }

    @Test func samplingStopsWhenTheLastLinkDrops() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop() }
        try await Self.pair(a, b)
        try await eventually("A to sample for its peer") { a.isSampling }
        b.stop()
        try await eventually("A to stop sampling with no peer and no viewer") { !a.isSampling }
    }

    // MARK: Retry

    @Test func retryTriesAKnownMacAndRefusesOneThatIsntInTheFleet() async throws {
        let a = try await Mac("MacBook Pro", busy: 30), b = try await Mac("Mac mini", busy: 60)
        defer { a.stop(); b.stop() }
        try await Self.pair(a, b)
        let bID = try await b.hostID()
        _ = try await a.local.fleetAction(.reconnect(hostID: bID))
        try await eventually("the link to hold") { try await a.read().peers.first?.link == .connected }
        do { _ = try await a.local.fleetAction(.reconnect(hostID: UUID())); Issue.record("retried a Mac that isn't in the fleet") }
        catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetProtocol.Code.invalid) }
    }
}
