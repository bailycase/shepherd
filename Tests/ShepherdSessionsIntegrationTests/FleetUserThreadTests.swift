import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdSessions

/// A thread the person starts in New thread (`FleetAction.sendThread`): Auto puts it on the Mac with the most room, a named Mac that is asleep
/// holds it until that Mac is back, and a thread that stays on this Mac isn't a dispatch at all.
@Suite("Fleet: a thread started in New thread", .serialized)
struct FleetUserThreadTests {
    typealias D = FleetDispatchTests

    @Test func autoStartsTheThreadOnTheMacWithMoreRoomAndItShowsAsSentByYou() async throws {
        let (a, b, _) = try await D.pair(busyA: 90, busyB: 10)
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        let thread = FleetUserThread(spaceID: a.space.id, task: "Profile the orders import and cut its memory in half.", host: nil)

        let result = try await a.local.fleetAction(.sendThread(thread))
        let record = try #require(result.dispatch)
        #expect(record.kind == .userThread && record.targetHostName == "Mac mini" && record.parentAgentID == nil)
        #expect(record.reasonCodes.first?.code == .mostRoom)
        #expect(record.task.isEmpty, "the reply, like the log, leaves the task out")

        // The Mac that took it runs a thread nobody's thread sent: its header reads "sent by you".
        try await D.wait("B to run the thread") { !b.dispatched.isEmpty }
        let running = try #require(b.dispatched.first)
        let from = try #require(running.dispatchedFrom)
        #expect(from.hostID == aID && from.hostName == "MacBook Pro" && from.agentID == nil && from.dispatchID == thread.dispatchID)
        let sentBy = FleetSentBy(from, host: "Mac mini", viewer: aID)
        #expect(sentBy.sentByLine == "sent by you" && sentBy.goesBackLine == nil)
        #expect(a.dispatched.isEmpty, "nothing started on the Mac that sent it")
        try await D.wait("A to follow it as running") { a.sent().first?.state == .running && a.sent().first?.remoteAgentID == running.id }
    }

    @Test func autoKeepsTheThreadOnThisMacWhenItHasTheRoomAndMakesNoRecord() async throws {
        let (a, b, _) = try await D.pair(busyA: 10, busyB: 90)
        defer { a.stop(); b.stop() }
        let result = try await a.local.fleetAction(.sendThread(FleetUserThread(spaceID: a.space.id, task: "Regenerate the API client.")))
        #expect(result.dispatch == nil, "the app starts it as it always did")
        #expect(a.sent().isEmpty && b.taken().isEmpty && b.dispatched.isEmpty)
    }

    @Test func aNamedMacThatIsAsleepHoldsTheThreadAndStartsItWhenItWakes() async throws {
        let (a, b, origin) = try await D.pair()
        defer { a.stop() }
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        try await D.wait("A to see B's link down") { try await a.local.fleetRead().snapshot.peers.first?.link != .connected }

        let thread = FleetUserThread(spaceID: a.space.id, task: "Profile the orders import.", host: "Mac mini")
        let waiting = try #require(try await a.local.fleetAction(.sendThread(thread)).dispatch)
        #expect(waiting.state == .waitingWake)
        #expect(a.sent().first?.state == .waitingWake, "it never moves to another Mac")
        #expect(a.dispatched.isEmpty)

        let woken = try await D.Mac("Mac mini", origin: origin, dir: dir, port: port)
        defer { woken.stop() }
        try await D.wait("the thread to start on Mac mini once it is back", timeout: .seconds(60)) { !woken.dispatched.isEmpty }
        #expect(woken.dispatched.first?.dispatchedFrom?.agentID == nil)
        #expect(a.dispatched.isEmpty)
    }

    @Test func aThreadNamedForThisMacIsNeverSentAndAnUnknownSpaceIsRefused() async throws {
        let (a, b, _) = try await D.pair()
        defer { a.stop(); b.stop() }
        #expect(try await a.local.fleetAction(.sendThread(FleetUserThread(spaceID: a.space.id, task: "x", host: "MacBook Pro"))).dispatch == nil)
        // A named Mac that doesn't have the repository is refused, never rerouted.
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await a.local.fleetAction(.sendThread(FleetUserThread(spaceID: SpaceID(rawValue: "nope"), task: "x", host: "Mac mini")))
        }
        #expect(a.sent().isEmpty)
    }

    @Test func retryingASendWithTheSameIDMakesNoSecondThread() async throws {
        let (a, b, _) = try await D.pair(busyA: 90, busyB: 10)
        defer { a.stop(); b.stop() }
        let thread = FleetUserThread(spaceID: a.space.id, task: "Profile the orders import.")
        let first = try await a.local.fleetAction(.sendThread(thread)).dispatch
        let second = try await a.local.fleetAction(.sendThread(thread)).dispatch
        #expect(first?.id == second?.id)
        try await D.wait("B to run it") { !b.dispatched.isEmpty }
        #expect(a.sent().count == 1 && b.dispatched.count == 1)
    }

    @Test func theCardActionsCancelAndRetryADispatchThatWaits() async throws {
        let (a, b, _) = try await D.pair()
        defer { a.stop() }
        b.stop(keepFiles: true)
        try await D.wait("A to see B's link down") { try await a.local.fleetRead().snapshot.peers.first?.link != .connected }
        let waiting = try #require(try await a.local.fleetAction(.sendThread(FleetUserThread(spaceID: a.space.id, task: "Profile the orders import.", host: "Mac mini"))).dispatch)
        #expect(waiting.state == .waitingWake)

        // Stop: the record ends and nothing is ever sent.
        let stopped = try await a.local.fleetAction(.cancelDispatch(id: waiting.id)).dispatch
        #expect(stopped?.state == .cancelled)
        // Retrying one that is no longer waiting is refused with its state.
        await #expect(throws: RemoteHostClientError.self) { _ = try await a.local.fleetAction(.retryDispatch(id: waiting.id, host: nil)) }
        // An unknown dispatch is refused too.
        await #expect(throws: RemoteHostClientError.self) { _ = try await a.local.fleetAction(.cancelDispatch(id: UUID())) }
    }
}
