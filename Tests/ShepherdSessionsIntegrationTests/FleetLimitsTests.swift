import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdSessions

/// A provider's rate limit is the fleet's (sign-ins are shared): the Mac whose thread was limited tells every Mac, and a thread or dispatch for
/// that provider waits on each of them until the limit lifts, while another provider's work starts now.
@Suite("Fleet: provider limits", .serialized)
struct FleetLimitsTests {
    typealias D = FleetDispatchTests

    static let rateLimited = #"429 {"type":"error","error":{"type":"rate_limit_error","message":"Your account is rate limited. Retry after 90 seconds."}}"#

    /// What `mac` holds of the fleet's limits.
    static func limits(_ mac: D.Mac) async throws -> [FleetLimitStatus] { try await mac.local.fleetRead().snapshot.limits }

    @Test func aLimitSeenOnOneMacHoldsADispatchForThatProviderOnTheOtherAndLetsAnotherProviderThrough() async throws {
        // B is the busy one, so Auto sends B's work to A.
        let (a, b, _) = try await D.pair(busyA: 10, busyB: 90)
        defer { a.stop(); b.stop() }
        #expect(try await Self.limits(b).isEmpty)

        // A thread on A got a 429: A holds Anthropic and says so to B at once, not at its next sample.
        a.server.queue.sync { a.server.fleet?.providerFailed(provider: "anthropic", error: Self.rateLimited) }
        try await D.wait("B to hear that Anthropic is limited") { try await Self.limits(b).first?.provider == "anthropic" }
        let seconds = try #require(try await Self.limits(b).first?.seconds)
        #expect(seconds > 80 && seconds <= 90, "the retry time the error asked for, from when B heard it")

        // New work for Anthropic from B waits, and says why.
        let held = FleetUserThread(spaceID: b.space.id, task: "Summarise the failing orders import.", model: "anthropic/claude-sonnet-4")
        let record = try #require(try await b.local.fleetAction(.sendThread(held)).dispatch)
        #expect(record.state == .waitingRoom && record.limitProvider == "anthropic" && record.targetHostID == nil)
        try await D.wait("B's page to count it") { try await Self.limits(b).first?.waiting == 1 }

        // Another provider's work starts now, on the Mac Auto picked.
        let other = FleetUserThread(spaceID: b.space.id, task: "Profile the orders import.", model: "stub/model-a")
        let started = try #require(try await b.local.fleetAction(.sendThread(other)).dispatch)
        #expect(started.limitProvider == nil && started.targetHostName == "MacBook Pro" && [.preparing, .running].contains(started.state))
        try await D.wait("A to run it") { !a.dispatched.isEmpty }
        #expect(a.dispatched.count == 1, "the held thread has not started anywhere")
        #expect(b.sent().first { $0.id == record.id }?.state == .waitingRoom)

        // The limit lifts on both Macs' clocks: the held thread goes by itself.
        a.clock.advance(120)
        b.clock.advance(120)
        b.server.queue.sync { b.server.fleet?.dispatch.evaluate() }
        try await D.wait("the held thread to be placed") {
            let now = b.sent().first { $0.id == record.id }
            return now?.state != .waitingRoom && now?.limitProvider == nil
        }
        #expect(try await Self.limits(b).isEmpty)
        try await D.wait("A to run both threads") { a.dispatched.count == 2 }
    }

    @Test func anErrorThatIsNotALimitMarksNothingAndAnErrorWithNoTimeHoldsForTheDefault() async throws {
        let (a, b, _) = try await D.pair()
        defer { a.stop(); b.stop() }
        a.server.queue.sync { a.server.fleet?.providerFailed(provider: "openai", error: #"401 {"error":{"message":"Incorrect API key provided"}}"#) }
        a.server.queue.sync { a.server.fleet?.providerFailed(provider: "anthropic", error: #"529 {"type":"error","error":{"type":"overloaded_error","message":"Overloaded"}}"#) }
        let limits = try await Self.limits(a)
        #expect(limits.map(\.provider) == ["anthropic"])
        let left = try #require(limits.first?.seconds)
        #expect(left > FleetProviderLimits.defaultHold - 5 && left <= FleetProviderLimits.defaultHold)
    }

    @Test func aLimitEndsByItsOwnTimeOnEveryMacAndNothingRelaysItBackToKeepItAlive() async throws {
        let (a, b, _) = try await D.pair()
        defer { a.stop(); b.stop() }
        a.server.queue.sync { a.server.fleet?.providerFailed(provider: "anthropic", error: Self.rateLimited) }
        try await D.wait("B to hear it") { try await Self.limits(b).count == 1 }
        // Both clocks pass the hold: nothing relays the limit back and forth to keep it alive.
        a.clock.advance(100)
        b.clock.advance(100)
        a.server.queue.sync { a.server.fleet?.pressure.tick() }
        try await D.wait("B to see it end") { try await Self.limits(b).isEmpty }
        #expect(try await Self.limits(a).isEmpty)
    }
}
