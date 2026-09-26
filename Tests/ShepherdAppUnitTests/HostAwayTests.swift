import Foundation
import ShepherdRemote
import Testing
@testable import ShepherdApp

/// A remote agent's pane says its host is reconnecting only while Shepherd is trying a host that
/// was connected earlier this launch (NWStatus › A host reconnecting).
@Suite("Host away banner")
@MainActor
struct HostAwayTests {
    private static let seen = Date(timeIntervalSince1970: 1_000_000)

    @Test func onlyAHostSeenThisLaunchAndBeingRetriedReadsAsReconnecting() {
        let seen: Date? = Self.seen
        let cases: [(RemoteHostStore.Phase, Date?, Bool)] = [
            (.connecting, seen, true),
            (.failed(RemoteHostFailure(kind: .lost, detail: "eof")), seen, true),
            (.failed(RemoteHostFailure(kind: .unreachable, detail: "refused")), seen, true),
            (.failed(RemoteHostFailure(kind: .tokenRefused, detail: "bad token")), seen, false),
            (.connecting, nil, false),
            (.failed(RemoteHostFailure(kind: .lost, detail: "eof")), nil, false),
            (.connected, seen, false),
            (.disconnected, seen, false),
        ]
        for (phase, lastSeen, away) in cases {
            #expect(HostAway.reconnecting(phase, lastSeen: lastSeen) == away, "\(phase), seen: \(lastSeen != nil)")
        }
    }

    @Test(arguments: [(TimeInterval(30), "just now"), (TimeInterval(180), "3m ago"), (TimeInterval(3 * 3_600 + 60), "3h ago")])
    func theMessageSaysWhenTheHostWasLastSeen(elapsed: TimeInterval, age: String) {
        #expect(HostAway.message(lastSeen: Self.seen, now: Self.seen.addingTimeInterval(elapsed))
            == "Last seen \(age). Remote agents resume when it’s back.")
    }
}
