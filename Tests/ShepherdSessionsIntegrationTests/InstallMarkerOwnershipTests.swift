import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The install marker (`host-update-handoff`) belongs to the install attempt that wrote it: only that attempt's answer may change it. Each
/// scenario is an ordering of installs and late answers that once cleared or set the marker for the wrong attempt.
@Suite("Install marker ownership", .mainActorExclusive)
@MainActor
struct InstallMarkerOwnershipTests {
    enum Marker { case none, unknown, handedOff }

    enum Scenario: CaseIterable {
        case lateUnsupportedFromASupersededHeldInstall
        case installWhenIdleBecomesInstall
        case directCompletionFromANonOwner
        case lateAnswerAfterACancel
        case appQuitsAfterSendThenTheHostRestarts
        case retryAfterSend
    }

    /// A host whose updater holds every install until the test answers it, and a patience that ends when the test says.
    final class Rig {
        typealias Install = @Sendable (HostUpdateStatus) -> Void
        let mac: FleetDispatchTests.Mac
        let offer = UUID()
        let installs = Locked<[Install]>([])
        let timeouts = Locked<[@Sendable () -> Void]>([])
        var host: ScratchServer { mac.host }
        var server: SessionServer { mac.server }

        /// A Mac of a fleet of one (the host offers fleet updates only as a member), restarted over its own files by `dir` and `port`.
        init(origin: FleetDispatchTests.Origin, dir: URL? = nil, port: UInt16 = 0) async throws {
            let (offer, installs, timeouts) = (offer, installs, timeouts)
            mac = try await FleetDispatchTests.Mac("Mac mini", origin: origin, dir: dir, port: port, links: LinkRouting().options, prepare: { server in
                server.onRemoteHostUpdate = { request, authorized, completion in
                    nonisolated(unsafe) let authorized = authorized, completion = completion
                    Task {
                        guard await authorized() else { return }
                        if case .install = request { installs.withValue { $0.append { status in completion(status) } }; return }
                        var status = HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: .available, offerID: offer, canInstall: true)
                        if case .installWhenIdle = request { status.waitingForIdle = true }
                        completion(status)
                    }
                }
            })
            let server = mac.server
            server.queue.sync {
                server.idleInstallInterval = 0.02
                server.installAnswerTimer = { fire in timeouts.withValue { $0.append(fire) } }
            }
        }

        /// The host's answer to `request` from `requester`, once the updater has given it. An install is held by the updater: its answer
        /// comes when the test gives it, so none is waited for (`held`: the request becomes one).
        @discardableResult
        func ask(_ request: RemoteHostUpdateRequest, as requester: SessionServer.HostUpdateRequester, held: Bool = false) async throws -> HostUpdateStatus? {
            let reply = Locked<[HostUpdateStatus?]>([])
            let refusal = server.queue.sync {
                server.serveHostUpdate(request, requester: requester, alive: { true }) { status in reply.withValue { $0.append(status) } }
            }
            #expect(refusal == nil)
            if case .install = request { return nil }
            if held { return nil }
            try await FleetDispatchTests.wait("the host to answer") { !reply.current.isEmpty }
            return reply.current[0]
        }

        func marker() async throws -> Marker {
            guard let status = try await ask(.status, as: .peer(UUID())) else { throw WireError("no status") }
            switch status.installHandedOff {
            case nil: return .unknown
            case true?: return .handedOff
            case false?: return .none
            }
        }

        func waitForInstalls(_ count: Int) async throws {
            let installs = installs
            try await FleetDispatchTests.wait("\(count) install(s) to reach the updater") { installs.current.count == count }
        }

        /// The updater answers the `index`th install it holds.
        func answer(_ index: Int, _ phase: HostUpdateStatus.Phase) {
            installs.current[index](HostUpdateStatus(version: "1", build: "2", channel: "nightly", phase: phase))
            server.queue.sync {}
        }

        func runTheTimeout() throws {
            guard let fire = timeouts.current.first else { throw WireError("the host never began waiting for an answer") }
            server.queue.sync { fire() }
        }

        /// An install asked to wait on a busy thread, then sent by the host once the thread settled, and held by the updater.
        func heldInstallSent() async throws {
            let pi = try await PiAgent.launch(on: host)
            _ = try await pi.send("slow", from: try await pi.ready())
            _ = try await pi.snapshot { $0.running && !$0.provisional.isEmpty }
            let held = try await ask(.installWhenIdle(offerID: offer, authorized: true), as: .peer(UUID()))
            #expect(held?.waitingForIdle == true)
            pi.release(1)
            pi.release(2)
            _ = try await pi.snapshot { !$0.running }
            try await waitForInstalls(1)
        }
    }

    @Test(arguments: Scenario.allCases) func theMarkerEndsWithItsOwnersAnswer(_ scenario: Scenario) async throws {
        try StubPi.installAsEngine()
        let origin = try FleetDispatchTests.makeOrigin(extra: [:])
        let rig = try await Rig(origin: origin)
        defer { rig.mac.stop() }
        let install = RemoteHostUpdateRequest.install(offerID: rig.offer, authorized: true)
        switch scenario {
        case .lateUnsupportedFromASupersededHeldInstall:
            try await rig.heldInstallSent()
            try await rig.ask(install, as: .peer(UUID()))
            try await rig.waitForInstalls(2)
            rig.answer(0, .unsupported)
            #expect(try await rig.marker() == .unknown, "the older install's answer leaves the newer one's marker")
            rig.answer(1, .downloading)
            #expect(try await rig.marker() == .handedOff)

        case .installWhenIdleBecomesInstall:
            // Nothing is busy any more, so the second wait is an install: it takes the marker from the held one that is still unanswered.
            try await rig.heldInstallSent()
            try await rig.ask(.installWhenIdle(offerID: rig.offer, authorized: true), as: .peer(UUID()), held: true)
            try await rig.waitForInstalls(2)
            rig.answer(0, .unsupported)
            #expect(try await rig.marker() == .unknown, "the held install's answer leaves the new install's marker")
            rig.answer(1, .installing)
            #expect(try await rig.marker() == .handedOff)
            #expect(rig.installs.current.count == 2, "the old wait did not send a third install")

        case .directCompletionFromANonOwner:
            try await rig.ask(install, as: .client(1))
            try await rig.ask(install, as: .peer(UUID()))
            try await rig.waitForInstalls(2)
            rig.answer(0, .unsupported)
            #expect(try await rig.marker() == .unknown, "an answer for an install that isn't the owner's changes nothing")
            rig.answer(1, .downloading)
            #expect(try await rig.marker() == .handedOff)

        case .lateAnswerAfterACancel:
            try await rig.ask(install, as: .client(1))
            try await rig.waitForInstalls(1)
            try await rig.ask(.cancel, as: .peer(UUID()))
            #expect(try await rig.marker() == .none)
            rig.answer(0, .downloading)
            #expect(try await rig.marker() == .none, "the cancel took the marker from the install it came after")

        case .appQuitsAfterSendThenTheHostRestarts:
            try await rig.heldInstallSent()
            try rig.runTheTimeout()
            rig.answer(0, .unsupported)
            #expect(try await rig.marker() == .unknown, "an answer after the host stopped waiting changes nothing")
            let (dir, port) = (rig.host.dir, rig.mac.port)
            rig.mac.stop(keepFiles: true)
            let restarted = try await Rig(origin: origin, dir: dir, port: port)
            defer { restarted.mac.stop() }
            #expect(try await restarted.marker() == .unknown, "sent and never answered is unknown after a restart, which isn't \"no\"")

        case .retryAfterSend:
            try await rig.heldInstallSent()
            try rig.runTheTimeout()
            #expect(try await rig.marker() == .unknown)
            try await rig.ask(install, as: .peer(UUID()))
            try await rig.waitForInstalls(2)
            rig.answer(0, .unsupported)
            #expect(try await rig.marker() == .unknown, "the first send's late answer doesn't clear the retry's marker")
            rig.answer(1, .installing)
            #expect(try await rig.marker() == .handedOff)
        }
    }
}
