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
        /// The Mac's app is closed: the host answers for it, as it does with no app open.
        var appClosed = false
        /// The app quits the moment it takes an install, before anyone looks at it again: a look afterwards never sees it download.
        var quitsOnInstall = false
        /// This many installs are answered with the offer unchanged, and nothing starts.
        var ignoredInstalls = 0
        /// Runs once, after the next request is answered.
        var afterNext: (@Sendable () -> Void)?
        /// The next request is carried out and its answer never sent: the Mac's host goes before it reaches the asker.
        var swallowNext: (@Sendable (RemoteHostUpdateRequest) -> Bool)?
        var swallowed = 0
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
                let answer = handle(request)
                let swallowed = state.withValue { state -> Bool in
                    guard let matches = state.swallowNext, matches(request) else { return false }
                    (state.swallowNext, state.swallowed) = (nil, state.swallowed + 1)
                    return true
                }
                if swallowed { return }
                let after = state.withValue { state in defer { state.afterNext = nil }; return state.afterNext }
                completion(answer)
                after?()
            }
        }
    }

    /// Its feed has nothing newer: the next step of a check says so.
    func feedOffersNothing() { state.withValue { $0.feedHasNothing = true } }

    /// An install is taken and nothing starts: the offer is still there, as it is when Sparkle lost the choice it held.
    func ignoreInstall(times: Int = .max) { state.withValue { $0.ignoredInstalls = times } }

    /// Something happens right after the next request is answered: the asker's Mac slept, say.
    func afterNextRequest(_ body: @escaping @Sendable () -> Void) { state.withValue { $0.afterNext = body } }

    /// The next request that `matches` is carried out by the updater, but its answer is never sent.
    func swallowAnswer(to matches: @escaping @Sendable (RemoteHostUpdateRequest) -> Bool) { state.withValue { $0.swallowNext = matches } }
    var swallowedAnswers: Int { state.current.swallowed }

    /// The app quits the moment it takes an install.
    func quitOnInstall() { state.withValue { $0.quitsOnInstall = true } }

    /// The app quits to install: the host answers for it until the app is back.
    func quitApp() { state.withValue { $0.appClosed = true } }

    /// The app is back on `build`, with nothing under way.
    func relaunch(build: String) {
        state.withValue { state in
            state.appClosed = false
            state.status = HostUpdateStatus(version: state.status.version, build: build, channel: state.status.channel, phase: .idle)
        }
    }

    func handle(_ request: RemoteHostUpdateRequest) -> HostUpdateStatus {
        state.withValue { state in
            state.asked.append(request)
            if state.appClosed {
                var closed = HostUpdateStatus(version: state.status.version, build: state.status.build, channel: "", phase: .unsupported)
                closed.error = SessionServer.hostUpdateWindowClosed
                return closed
            }
            if state.ignoredInstalls > 0, case .install = request { state.ignoredInstalls -= 1; return state.status }
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
                if state.quitsOnInstall { defer { state.appClosed = true }; return state.status }
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

    // MARK: Ending in a visible state

    /// An app closed while the install still waits for the Mac's threads handed nothing to an installer: the person is told to open it, the
    /// wait that is left on its host is let go, and it is neither "relaunching" nor an install that failed.
    @Test func anAppClosedWhileTheInstallWaitsForThreadsNeedsToBeOpened() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        _ = try await Self.busy(b)
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)

        updater.quitApp()
        try await Self.waitForStage(.needsApp, on: a, of: id)
        #expect(try await Self.job(a, id)?.message == "Open Shepherd on Mac mini to update it.")
        try await FleetDispatchTests.wait("the host to let go of its wait") { b.server.queue.sync { !b.server.isWaitingForIdleInstall } }
    }

    /// With no thread working any more, the host sends the install it held and the app quits to install: that is the Mac relaunching, and the host
    /// says so (`installHandedOff`), which a look that comes after the app quit can't otherwise tell from an app that was closed.
    @Test func anAppThatQuitsAfterTheHostSentItsInstallIsRelaunching() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        try await Self.settle(pi)
        try await updater.waitFor("install the held offer") { if case .install = $0 { true } else { false } }

        updater.quitApp()
        #expect(try await b.local.hostUpdate(.status).installHandedOff == true, "the host says the install was handed over")
        try await Self.waitForStage(.relaunching, on: a, of: id)
        #expect(try await Self.job(a, id)?.message == nil)
        updater.relaunch(build: "675")
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// The host held the install for a thread and sent it when the thread settled; the app quit to install before this host looked again, so it
    /// never saw "downloading". Held for threads, then handed over: a host that says nothing of its handoff (one from before the field) is not
    /// a closed app, so the Mac is waited for until it is back on the new build.
    @Test func aHostFromBeforeTheHandoffFieldThatInstalledWhileUnseenIsRelaunching() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        b.server.queue.sync { b.server.omitsInstallHandoff = true }
        updater.quitOnInstall()
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        try await Self.settle(pi)
        try await Self.waitForStage(.relaunching, on: a, of: id)
        updater.relaunch(build: "675")
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// The handoff was seen, then the Mac's host restarted and forgot it while the app was still gone: the job doesn't take back what it saw.
    @Test func aHostThatRestartsAfterTheHandoffWasSeenDoesNotReverseIt() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        updater.quitOnInstall()
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        try await Self.settle(pi)
        try await Self.waitForStage(.relaunching, on: a, of: id)
        // The stage is only "relaunching" once a look read the handoff: a dropped link shows "waiting" while the install is held.
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { updater.install(on: $0) })
        defer { b2.stop() }
        // The restarted host knows of no handoff; the job looks at it that way before the app is back.
        let looks = updater.asked.count
        try await FleetDispatchTests.wait("a look at the restarted host") { updater.asked.count > looks }
        try await Self.waitForStage(.relaunching, on: a, of: id)
        updater.relaunch(build: "675")
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// The host sent its install and the app quit to install, then the host restarted before the job looked: the job never saw the handoff. The
    /// host keeps it across the restart, or the job would read the app that quit to install as one that was closed.
    @Test func aHostThatRestartsBeforeTheHandoffWasSeenIsRelaunching() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        b.server.queue.sync { b.server.idleInstallInterval = 0.02 }
        updater.quitOnInstall()
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        // The job's next look is seconds away: the handoff and the restart both come first.
        a.server.queue.sync { a.server.fleet?.updates.interval = .seconds(3) }
        let looks = updater.asked.filter { $0 == .status }.count
        try await FleetDispatchTests.wait("a look after the pause") { updater.asked.filter { $0 == .status }.count > looks }
        try await Self.settle(pi)
        try await updater.waitFor("install the held offer") { if case .install = $0 { true } else { false } }

        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { updater.install(on: $0) })
        defer { b2.stop() }
        #expect(try await b2.local.hostUpdate(.status).installHandedOff == true, "the restarted host still says the install was handed over")
        try await Self.waitForStage(.relaunching, on: a, of: id)
        updater.relaunch(build: "675")
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// No thread works any more but the host hasn't sent its install yet: an app that quits now handed nothing to an installer. Zero busy threads
    /// is not a handoff, so the person is told to open the app, and the wait that is left on its host is let go.
    @Test func anAppThatQuitsBeforeTheHostSentItsInstallNeedsToBeOpened() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        let pi = try await Self.busy(b)
        b.server.queue.sync { b.server.idleInstallInterval = 3600 }   // the host doesn't send the install itself in this test
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)
        try await Self.settle(pi)
        try await FleetDispatchTests.wait("the job to know the threads settled") { try await Self.job(a, id)?.threads == 0 }

        updater.quitApp()
        try await Self.waitForStage(.needsApp, on: a, of: id)
        #expect(!updater.sawInstallNow)
        try await FleetDispatchTests.wait("the host to let go of its wait") { b.server.queue.sync { !b.server.isWaitingForIdleInstall } }
    }

    /// The link drops during a look at a Mac whose install waits for its threads, and the Mac's app is closed when it is back. No installer had
    /// the offer, so the job asks the person to open the app; it doesn't read the drop as the Mac relaunching.
    @Test func aLinkThatDropsWhileTheInstallWaitsForThreadsDoesNotMakeAClosedAppRelaunching() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        _ = try await Self.busy(b)
        b.server.queue.sync { b.server.idleInstallInterval = 3600 }
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)

        updater.swallowAnswer { $0 == .status }   // a look the link drops under
        try await FleetDispatchTests.wait("a look the host never answers") { updater.swallowedAnswers == 1 }
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        updater.quitApp()
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { updater.install(on: $0) })
        defer { b2.stop() }
        try await Self.waitForStage(.needsApp, on: a, of: id)
    }

    /// A Mac's host restarted while its app held the offer for idle threads: the host lost its wait. The job looks at the offer again and
    /// goes on, instead of reading "checking" until it gives up hours later.
    @Test func aHostThatRestartedWhileItsAppHeldTheOfferIsAskedAgain() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        _ = try await Self.busy(b)
        b.server.queue.sync { b.server.idleInstallInterval = 3600 }   // the old host's last look at its threads must not send the install as it stops
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.waitingForThreads, on: a, of: id)

        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { updater.install(on: $0) })
        defer { b2.stop() }
        // Its app still holds the offer, which the new host knows nothing of: the job checks again, and the threads are idle now.
        try await FleetDispatchTests.wait("the Mac to be checked again") { updater.asked.filter { $0 == .check }.count == 2 }
        updater.advance()
        try await Self.waitForStage(.downloading, on: a, of: id)
    }

    /// The same, when the host restarts after its app holds the offer but before the answer that says so reaches the job: the job never saw the
    /// wait, and still looks at the offer again instead of reading "checking" until it gives up hours later.
    @Test func aHostThatRestartedBeforeTheJobSawTheWaitIsAskedAgain() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        _ = try await Self.busy(b)
        b.server.queue.sync { b.server.idleInstallInterval = 3600 }
        Self.quicken(a)
        try await Self.start(a, id, .idle)
        try await Self.waitForStage(.checking, on: a, of: id)
        updater.swallowAnswer { if case .installWhenIdle = $0 { true } else { false } }   // the app holds the offer; the answer is lost
        try await updater.answerTheCheck()
        try await FleetDispatchTests.wait("the app to hold the offer") { updater.swallowedAnswers == 1 }
        #expect(updater.status.waitingForIdle)

        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { updater.install(on: $0) })
        defer { b2.stop() }
        try await FleetDispatchTests.wait("the Mac to be checked again") { updater.asked.filter { $0 == .check }.count == 2 }
        updater.advance()
        try await Self.waitForStage(.downloading, on: a, of: id)
    }

    /// A Mac that began to install and never comes back on another build, whether its link is up or not, ends the job with a reason.
    @Test func aMacThatNeverFinishesInstallingEndsTheJobAsFailed() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        updater.advance()   // installing, and it stays so
        try await Self.waitForStage(.installing, on: a, of: id)
        // Past the patience a Mac that went to install is given, seen look by look.
        for _ in 0..<25 {
            let looks = updater.asked.count
            a.clock.advance(25)
            try await FleetDispatchTests.wait("a look at the Mac") { updater.asked.count > looks }
        }
        try await Self.waitForStage(.failed, on: a, of: id)
        #expect(try await Self.job(a, id)?.message?.contains("Mac mini") == true)
    }

    /// This host slept while a Mac installed, and the Mac is on the new build when it wakes: the job reads that before it calls the Mac stuck.
    @Test func aHostThatSleptThroughASuccessfulInstallReportsUpdated() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        updater.advance()
        try await Self.waitForStage(.installing, on: a, of: id)

        let clock = a.clock
        updater.afterNextRequest { clock.advance(11 * 60); updater.advance() }   // it installed while this host was asleep
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// This host slept in the middle of a look at the Mac, and the look fails when it wakes (the link is gone): the time asleep isn't time the Mac was
    /// seen doing nothing, so the Mac that comes back on the new build is Updated, not Failed.
    @Test func aHostThatSleptDuringALookThatFailedReportsUpdatedWhenTheMacIsBack() async throws {
        let updater = FakeUpdater()
        let (a, b, origin) = try await Self.fleet(updaterB: updater)
        defer { a.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        updater.advance()
        try await Self.waitForStage(.installing, on: a, of: id)

        updater.swallowAnswer { $0 == .status }
        try await FleetDispatchTests.wait("a look the host never answers") { updater.swallowedAnswers == 1 }
        let (dir, port) = (b.host.dir, b.port)
        a.clock.advance(11 * 60)   // this host sleeps, and the link is gone when it wakes
        b.stop(keepFiles: true)
        let relaunched = FakeUpdater(build: "675", phase: .idle)
        let b2 = try await Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { relaunched.install(on: $0) })
        defer { b2.stop() }
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// The time this host slept isn't time the Mac was seen doing nothing: a Mac still installing when it wakes gets its patience again.
    @Test func aHostThatSleptIsNotSlowToWakeUpOnAMacStillInstalling() async throws {
        let updater = FakeUpdater()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        updater.advance()
        try await Self.waitForStage(.installing, on: a, of: id)

        let clock = a.clock
        updater.afterNextRequest { clock.advance(11 * 60) }
        let looks = updater.asked.count
        try await FleetDispatchTests.wait("looks at the Mac after it woke") { updater.asked.count > looks + 3 }
        #expect(try await Self.job(a, id)?.stage == .installing)
        updater.advance()
        try await Self.waitForStage(.updated, on: a, of: id)
    }

    /// An offer the Mac keeps taking an install for without starting it ends the job, not a spinner that asks its feed for ever.
    @Test func aMacThatTakesTheInstallAndNeverStartsItEndsTheJobAsFailed() async throws {
        let updater = FakeUpdater()
        updater.ignoreInstall()
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.failed, on: a, of: id)
        #expect(try await Self.job(a, id)?.message?.contains("Mac mini") == true)
        #expect(updater.asked.filter { if case .install = $0 { true } else { false } }.count == FleetUpdates.installAttempts)
    }

    /// An offer that is still there after an install was asked for isn't a stall yet: the Mac may be about to begin. The install is asked again
    /// at a later look, not at once, so a Mac that takes a moment still gets it.
    @Test func anInstallIsAskedAgainAtALaterLookNotAtOnce() async throws {
        let updater = FakeUpdater()
        updater.ignoreInstall(times: FleetUpdates.installAttempts - 1)
        let (a, b, _) = try await Self.fleet(updaterB: updater)
        defer { a.stop(); b.stop() }
        let id = try await b.hostID()
        Self.quicken(a)
        try await Self.start(a, id, .now)
        try await Self.waitForStage(.checking, on: a, of: id)
        try await updater.answerTheCheck()
        try await Self.waitForStage(.downloading, on: a, of: id)
        let asked = updater.asked
        let installs = asked.indices.filter { if case .install = asked[$0] { true } else { false } }
        #expect(installs.count == FleetUpdates.installAttempts)
        for (earlier, later) in zip(installs, installs.dropFirst()) { #expect(later - earlier > 1, "a look at the Mac came between the two installs") }
    }

    /// A request to another Mac that times out takes the whole link down, so the host's own "the updater didn't answer" must come first.
    @Test func theAskerWaitsLongerThanTheHostDoes() {
        #expect(RemoteHostUpdateRequest.askerTimeout > RemoteHostUpdateRequest.hostReplyDeadline)
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

