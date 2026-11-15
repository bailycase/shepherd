import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Stands in for a Mac's app, whose Sparkle installs an update (`SessionServer.onRemoteHostUpdate`): it answers what the host relays as
/// Sparkle's driver does, and moves one step each time a test says (`advance`), so every stage of an update can be looked at. It records
/// what it was asked, in order.
final class FakeUpdater: @unchecked Sendable {
    private struct State {
        var status: HostUpdateStatus
        var asked: [RemoteHostUpdateRequest] = []
        /// What the app reports once it relaunched on the new build.
        var newBuild: String
        /// Its feed has nothing newer than it runs.
        var feedHasNothing = false
    }
    private let state: Locked<State>
    let offer: UUID

    init(build: String = "671", newBuild: String = "675", offer: UUID = UUID(), phase: HostUpdateStatus.Phase = .idle) {
        self.offer = offer
        state = Locked(State(status: HostUpdateStatus(version: "0.9.0", build: build, channel: "nightly", phase: phase), newBuild: newBuild))
    }

    var asked: [RemoteHostUpdateRequest] { state.current.asked }
    var status: HostUpdateStatus { state.current.status }

    /// Installs it as the host's updater.
    func install(on server: SessionServer) {
        server.onRemoteHostUpdate = { [self] request, authorized, completion in
            nonisolated(unsafe) let authorized = authorized, completion = completion
            Task {
                guard await authorized() else { return }
                completion(handle(request))
            }
        }
    }

    /// Its feed has nothing newer: the next step of a check says so.
    func feedOffersNothing() { state.withValue { $0.feedHasNothing = true } }

    func handle(_ request: RemoteHostUpdateRequest) -> HostUpdateStatus {
        state.withValue { state in
            state.asked.append(request)
            switch request {
            case .status: break
            case .check:
                state.status.waitingForIdle = false
                state.status.phase = .checking
                state.status.offerID = nil
            case .install(let offerID, let consent):
                guard consent, state.status.phase == .available, state.status.offerID == offerID else { state.status.error = "Confirm the current update."; break }
                state.status.phase = .downloading
                state.status.waitingForIdle = false
                state.status.canInstall = false
            case .installWhenIdle(let offerID, let consent):
                guard consent, state.status.phase == .available, state.status.offerID == offerID else { state.status.error = "Confirm the current update."; break }
                state.status.waitingForIdle = true
                state.status.canInstall = false
            case .cancel:
                guard state.status.phase == .available || state.status.phase == .downloading else { break }
                state.status.phase = .idle
                state.status.waitingForIdle = false
                state.status.offerID = nil
            }
            return state.status
        }
    }

    /// The updater moves on: its check found the offer, the download is done and it installs, then the app is back on the new build.
    func advance() {
        state.withValue { state in
            switch state.status.phase {
            case .checking where state.feedHasNothing:
                state.status.phase = .upToDate
            case .checking:
                state.status.phase = .available
                state.status.offerID = offer
                state.status.offeredVersion = "0.9.1"
                state.status.canInstall = true
            case .downloading: state.status.phase = .installing
            case .installing:
                state.status.phase = .idle
                state.status.build = state.newBuild
                state.status.offerID = nil
            default: break
            }
        }
    }

    /// The first step, once the host's check reached the updater: the job shows "checking" as it begins, a moment before the updater is asked.
    func answerTheCheck() async throws {
        try await waitFor("check") { if case .check = $0 { true } else { false } }
        advance()
    }

    func waitFor(_ what: String, _ request: @escaping @Sendable (RemoteHostUpdateRequest) -> Bool) async throws {
        try await eventually("the updater to be asked to \(what)") { asked.contains(where: request) }
    }

    var sawInstallNow: Bool { asked.contains { if case .install = $0 { true } else { false } } }
    var sawInstallWhenIdle: Bool { asked.contains { if case .installWhenIdle = $0 { true } else { false } } }
}

/// Updating Shepherd on another Mac of the fleet (`fleet.update.v1`): between real scratch hosts, with a fake updater for the Mac's app. Each
/// test says what it proves.
@Suite("Fleet updates", .mainActorExclusive)
@MainActor
struct FleetUpdateTests {
    typealias Mac = FleetDispatchTests.Mac

    // MARK: Fixtures

    /// Two paired Macs that share an origin, each with a fake updater (A's and B's). `open` and `blocked` say which can dial the other.
    static func fleet(_ routingA: LinkRouting = LinkRouting(), _ routingB: LinkRouting = LinkRouting(), updaterA: FakeUpdater = FakeUpdater(),
                      updaterB: FakeUpdater = FakeUpdater(), pairing: Bool = true) async throws -> (a: Mac, b: Mac, origin: FleetDispatchTests.Origin) {
        try StubPi.installAsEngine()
        let origin = try FleetDispatchTests.makeOrigin(extra: [:])
        let a = try await Mac("MacBook Pro", origin: origin, links: routingA.options, prepare: { updaterA.install(on: $0) })
        let b = try await Mac("Mac mini", origin: origin, links: routingB.options, prepare: { updaterB.install(on: $0) })
        if pairing {
            try await a.pair(with: b)
            try await FleetDispatchTests.waitForReports(a, b)
        }
        return (a, b, origin)
    }

    /// The jobs a Mac carries out, quick to look at again.
    static func quicken(_ mac: Mac) {
        mac.server.queue.sync { mac.server.fleet?.updates.interval = .milliseconds(20) }
    }

    static func job(_ mac: Mac, _ target: UUID) async throws -> FleetUpdateStatus? {
        try await mac.local.fleetRead().snapshot.updates.first { $0.hostID == target }
    }

    static func waitForStage(_ stage: FleetUpdateStatus.Stage, on mac: Mac, of target: UUID) async throws {
        try await FleetDispatchTests.wait("\(mac.name)'s update to be \(stage)") { try await job(mac, target)?.stage == stage }
    }

    static func start(_ asker: Mac, _ target: UUID, _ when: FleetUpdateWhen = .idle) async throws {
        _ = try await asker.local.fleetAction(.update(hostID: target, .start(when: when)))
    }

    /// An update run end to end from `asker` to the Mac `target` runs, whose updater is `updater`: its own words, in order, and the job's stages.
    static func runUpdate(from asker: Mac, to target: Mac, updater: FakeUpdater) async throws {
        quicken(asker)
        let id = try await target.hostID()
        try await start(asker, id)
        try await waitForStage(.checking, on: asker, of: id)
        try await updater.answerTheCheck()   // its feed offers a build
        try await waitForStage(.downloading, on: asker, of: id)
        updater.advance()   // downloaded: it installs
        try await waitForStage(.installing, on: asker, of: id)
        updater.advance()   // and is back on the new build
        try await waitForStage(.updated, on: asker, of: id)
        let ended = try #require(try await job(asker, id))
        #expect(ended.fromBuild == "671" && ended.offered == "0.9.1")
        // The Mac was asked for its own check, then to install; nothing without nobody working there to wait for.
        let asked = updater.asked
        #expect(asked.first == .check)
        #expect(asked.contains(.install(offerID: updater.offer, authorized: true)))
        #expect(!updater.sawInstallWhenIdle, "with nothing working there is nothing to wait for")
    }

    // MARK: Over the link

    /// A Mac that can't be dialed asks and is asked over the connection the other opened: status, check and install reach the Mac's own updater
    /// and its real status comes back, both ways, with no client of either Mac in between.
    @Test func aMacUpdatesAnotherOverTheLinkWhicheverMacOpenedIt() async throws {
        let (updaterA, updaterB) = (FakeUpdater(), FakeUpdater())
        let (open, blocked) = (LinkRouting(), LinkRouting())
        let (a, b, _) = try await Self.fleet(open, blocked, updaterA: updaterA, updaterB: updaterB, pairing: false)
        defer { a.stop(); b.stop() }
        blocked.refuse(port: a.port)
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)
        // One connection carries both ways: the MacBook's own to the mini.
        let (miniViaLink, bookViaLink) = (try await FleetLinkTests.link(b, to: a).viaItsLink, try await FleetLinkTests.link(a, to: b).viaItsLink)
        #expect(miniViaLink && !bookViaLink)
        let (miniTakes, bookTakes) = (try await FleetLinkTests.peerStatus(a, b).takesUpdates, try await FleetLinkTests.peerStatus(b, a).takesUpdates)
        #expect(miniTakes == true && bookTakes == true)

        // The MacBook asks the mini: a plain request on the connection it opened.
        try await Self.runUpdate(from: a, to: b, updater: updaterB)
        // The mini asks the MacBook: a call over the connection the MacBook opened.
        try await Self.runUpdate(from: b, to: a, updater: updaterA)
    }

    /// The job is about the Mac that was asked, and says what that Mac's updater did: each Mac installs what its own feed offers.
    @Test func aMacsOwnUpdaterDecidesWhatItInstalls() async throws {
        let (updaterA, updaterB) = (FakeUpdater(), FakeUpdater(offer: UUID()))
        let (a, b, _) = try await Self.fleet(updaterA: updaterA, updaterB: updaterB)
        defer { a.stop(); b.stop() }
        try await Self.runUpdate(from: a, to: b, updater: updaterB)
        #expect(updaterA.asked.isEmpty, "the MacBook's own updater was never asked")
        // A feed with nothing newer ends the job there, without an install.
        let again = FakeUpdater(phase: .upToDate)
        again.install(on: b.server)
        again.feedOffersNothing()
        let id = try await b.hostID()
        try await Self.start(a, id)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await again.answerTheCheck()
        try await Self.waitForStage(.upToDate, on: a, of: id)
        #expect(!again.sawInstallNow && !again.sawInstallWhenIdle)
        #expect(try await Self.job(a, id)?.message?.contains("nothing newer") == true)
    }

    // MARK: The gate

    /// A Mac with a thread working: its id, and the thread held there until the test lets it settle.
    nonisolated static func busy(_ mac: Mac) async throws -> PiAgent {
        let pi = try await PiAgent.launch(on: mac.host)
        _ = try await pi.send("slow", from: try await pi.ready())
        _ = try await pi.snapshot { $0.running && !$0.provisional.isEmpty }
        mac.server.queue.sync { mac.server.idleInstallInterval = 0.02 }
        return pi
    }

    nonisolated static func settle(_ pi: PiAgent) async throws {
        pi.release(1)
        pi.release(2)
        _ = try await pi.snapshot { !$0.running }
    }

    /// A thread working on the Mac makes the update wait for it: the offer is held, the job says how many threads it waits for, and the host
    /// installs by itself once they have settled.
    @Test func theGateWaitsForTheMacsBusyThread() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        #expect(await b.server.hostUpdateBusyThreads() == 1)

        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        #expect(try await Self.job(a, id)?.threads == 1)
        #expect(updater.sawInstallWhenIdle && !updater.sawInstallNow)
        #expect(await b.server.hostUpdateBusyThreads() == 1 && !updater.sawInstallNow, "still waiting while the thread works")

        try await Self.settle(pi)
        try await updater.waitFor("install the held offer") { if case .install = $0 { true } else { false } }
        try await Self.waitForStage(.downloading, on: a, of: id)
        let waited = b.server.queue.sync { b.server.isWaitingForIdleInstall }
        #expect(!waited, "the wait ended with the install")
    }

    /// Update now doesn't wait: the host installs with the thread working (its agents are checkpointed and carry on, as on any update).
    @Test func nowDoesNotWaitForTheBusyThread() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        _ = try await Self.busy(b)

        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await updater.waitFor("install now") { if case .install = $0 { true } else { false } }
        #expect(!updater.sawInstallWhenIdle)
        #expect(await b.server.hostUpdateBusyThreads() == 1, "it did not wait for the thread")
        try await Self.waitForStage(.downloading, on: a, of: id)
    }

    /// An install held for idle threads is let go by a cancel, and the host stops waiting: nothing installs when the threads settle.
    @Test func cancelLetsGoOfAnInstallThatWaitsForThreads() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        Self.quicken(a)
        try await Self.start(a, id)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        let waiting = b.server.queue.sync { b.server.isWaitingForIdleInstall }
        #expect(waiting)

        _ = try await a.local.fleetAction(.update(hostID: id, .cancel))
        #expect(try await Self.job(a, id) == nil, "Cancel puts the job away")
        try await updater.waitFor("let go of the offer") { $0 == .cancel }
        let stillWaiting = b.server.queue.sync { b.server.isWaitingForIdleInstall }
        #expect(!stillWaiting)
        #expect(updater.status.phase == .idle && !updater.status.waitingForIdle)
        try await Self.settle(pi)
        #expect(!updater.sawInstallNow, "nothing installs once the wait was cancelled")
    }

    // MARK: Who may ask

    /// A device asks a Mac of its fleet to update itself through the Mac it reads from; a client that isn't paired can't.
    @Test func aDeviceMayAskAndAnUnpairedClientMayNot() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let (phone, client) = try await FleetDeviceViewTests.phone(port: a.port, local: a.local)
        defer { phone.stop() }
        #expect(client.capabilities.contains(RemoteProtocol.fleetUpdateViewCapability))
        #expect(!client.capabilities.contains(RemoteProtocol.fleetUpdateCapability), "a device is no member")

        // Nobody that hasn't said hello gets anywhere: nothing starts.
        let stranger = try RawRemote(port: a.port)
        try stranger.send(.fleetAction(id: 7, action: .update(hostID: id, .start(when: .now))))
        guard case .error(_, let code, _) = try await stranger.next() else { Issue.record("an unpaired client was answered"); return }
        #expect(code == "unauthenticated")
        #expect(try await Self.job(a, id) == nil && updater.asked.isEmpty)

        // The device does, and reads the job as the Mac that holds it says.
        Self.quicken(a)
        let started = try await client.fleetAction(.update(hostID: id, .start(when: .idle))).snapshot
        #expect(started.updates.first?.hostID == id)
        try await FleetDispatchTests.wait("the device to read the job") { try await client.fleetRead().snapshot.updates.first?.stage == .checking }
        #expect(try await client.fleetRead().snapshot.app == ShepherdEdition.current.displayName)
        // It may stop it too.
        _ = try await client.fleetAction(.update(hostID: id, .cancel))
        #expect(try await client.fleetRead().snapshot.updates.isEmpty)
    }

    // MARK: An older Mac

    /// A Mac without `fleet.update.v1` is never sent the request: it is marked as one the person updates there.
    @Test func anOlderMacWithoutTheCapabilityIsNeverAsked() async throws {
        let (updaterA, updaterB) = (FakeUpdater(), FakeUpdater())
        let (a, b, _) = try await Self.fleet(updaterA: updaterA, updaterB: updaterB)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        #expect(try await FleetLinkTests.peerStatus(a, b).takesUpdates == true)
        let without = Set(RemoteProtocol.capabilities).subtracting([RemoteProtocol.fleetUpdateCapability, RemoteProtocol.fleetUpdateViewCapability])
        a.server.queue.sync { a.server.fleet?.dispatch.capabilityOverride = { _ in without } }
        try await FleetDispatchTests.wait("the Mac to be marked as one it can't update") { try await FleetLinkTests.peerStatus(a, b).takesUpdates == false }

        do {
            _ = try await a.local.fleetAction(.update(hostID: id, .start(when: .now)))
            Issue.record("an older Mac was asked to update")
        } catch RemoteHostClientError.rejected(let code, let message) {
            #expect(code == "unsupported" && message.contains("Mac mini") && message.contains("Update it there"))
        }
        #expect(try await Self.job(a, id) == nil && updaterB.asked.isEmpty)
    }

    // MARK: Asleep, and relaunching

    /// A Mac that is asleep starts when it wakes; one that goes away to install is relaunching and the job ends when it is back on another build.
    @Test func aMacThatIsAsleepStartsWhenItWakesAndOneThatRelaunchesIsFollowedBack() async throws {
        let (updaterA, updaterB) = (FakeUpdater(), FakeUpdater())
        let (a, b, origin) = try await Self.fleet(updaterA: updaterA, updaterB: updaterB)
        defer { a.stop() }
        let id = try await b.hostID()
        let (dir, port) = (b.host.dir, b.port)
        // The mini sleeps.
        b.stop(keepFiles: true)
        try await FleetDispatchTests.wait("the MacBook to see it asleep") { try await FleetLinkTests.peerStatus(a, id: id).link != .connected }
        Self.quicken(a)
        try await Self.start(a, id)
        try await Self.waitForStage(.waitingToWake, on: a, of: id)
        #expect(updaterB.asked.isEmpty)

        // It wakes (the same Mac, on its own files and port): the job begins.
        let woke = FakeUpdater()
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { woke.install(on: $0) })
        defer { b2.stop() }
        try await Self.waitForStage(.checking, on: a, of: id)
        try await woke.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        woke.advance()
        try await Self.waitForStage(.installing, on: a, of: id)
        #expect(try await Self.job(a, id)?.fromBuild == "671")

        // It goes away to install: relaunching until it is back, and back on another build ends the job.
        b2.stop(keepFiles: true)
        try await Self.waitForStage(.relaunching, on: a, of: id)
        let relaunched = FakeUpdater(build: "675", phase: .idle)
        let b3 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { relaunched.install(on: $0) })
        defer { b3.stop() }
        try await Self.waitForStage(.updated, on: a, of: id)
        // Check looks at the Mac again once it is back (the page's row changes).
        #expect(relaunched.asked.contains(.status))
    }

    // MARK: A Mac with no app

    /// With no Shepherd app open, the host opens its own to run Sparkle for a request that needs it, and waits for it to connect; a status is
    /// answered without that. A host that can't open the app says so, and the job tells the person to open it.
    @Test func aHostWithNoAppOpensItForARequestThatNeedsItAndSaysSoWhenItCant() async throws {
        let host = try RemoteHost()
        defer { host.stop() }
        await MainActor.run { host.server.relayWindowRequestsToApp() }
        let opened = Locked(0)
        let tokenURL = host.host.dir.appendingPathComponent("local-token")
        let socket = host.host.dir.appendingPathComponent("h.sock").path
        try host.server.startLocalListener(path: socket, tokenURL: tokenURL)
        let app = RemoteHostClient(localSocket: socket)
        defer { app.disconnect() }
        let relayed = Locked<[RemoteHostUpdateRequest]>([])
        app.onAppRelay = { [weak app] token, job in
            guard case .hostUpdate(let request) = job else { return }
            relayed.withValue { $0.append(request) }
            app?.appRelayAnswer(token: token, result: .hostUpdate(status: HostUpdateStatus(version: "0.9.0", build: "671", channel: "nightly", phase: .checking)))
        }
        let local = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        host.server.openAppForUpdate = {
            opened.withValue { $0 += 1 }
            _ = try? await app.connect(host: "", port: 0, token: local, clientName: "Shepherd")
            return true
        }
        let client = try await host.typed()
        defer { client.disconnect() }

        // A status doesn't open anything.
        #expect(try await client.hostUpdate(.status).error == SessionServer.hostUpdateWindowClosed)
        #expect(opened.current == 0 && relayed.current.isEmpty)
        // A check does: the app starts, connects, and answers.
        let answered = try await client.hostUpdate(.check)
        #expect(opened.current == 1 && relayed.current == [.check] && answered.phase == .checking)
        // The app is there now: the next request needs no launch.
        _ = try await client.hostUpdate(.status)
        #expect(opened.current == 1)
    }

    @Test func aHostThatCannotOpenItsAppSaysToOpenShepherdThere() async throws {
        let updaterA = FakeUpdater()
        let (a, b) = try await Self.fleetWithoutApp(updaterA: updaterA)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        // The fixture's own connection to the mini stands in for an app that answers relays: it goes, so the mini has no app open.
        b.local.disconnect()
        Self.quicken(a)
        try await Self.start(a, id)
        try await Self.waitForStage(.needsApp, on: a, of: id)
        #expect(try await Self.job(a, id)?.message == "Open Shepherd on Mac mini to update it.")
    }

    /// B's host has no app and no way to open one; A has an updater of its own.
    static func fleetWithoutApp(updaterA: FakeUpdater) async throws -> (a: Mac, b: Mac) {
        try StubPi.installAsEngine()
        let origin = try FleetDispatchTests.makeOrigin(extra: [:])
        let a = try await Mac("MacBook Pro", origin: origin, prepare: { updaterA.install(on: $0) })
        let b = try await Mac("Mac mini", origin: origin, prepare: { server in
            server.openAppForUpdate = { false }
            await MainActor.run { server.relayWindowRequestsToApp() }
        })
        try await a.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, b)
        return (a, b)
    }
}

