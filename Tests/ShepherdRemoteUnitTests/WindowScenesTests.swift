import Foundation
import Testing
@testable import ShepherdRemote

/// Several windows over one set of hosts (iPad): when the hosts stay connected, which threads
/// "Send to…" offers, and how sent text lands in a composer.
@Suite("Window scenes")
struct WindowScenesTests {
    // MARK: Presence

    @Test(arguments: [
        ([WindowPhase.active], true as Bool?),
        ([.background, .active], true),
        ([.inactive, .active, .background], true),
        ([.background], false),
        ([.background, .background], false),
        ([], false),
        ([.inactive], nil),
        ([.inactive, .background], nil),
    ])
    func hostsStayConnectedWhileAnyWindowIsActive(phases: [WindowPhase], expected: Bool?) {
        #expect(WindowPresence.foreground(phases) == expected)
    }

    // MARK: Targets

    private let a = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    private let b = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!
    private let c = UUID(uuidString: "00000000-0000-0000-0000-00000000000C")!
    private let d = UUID(uuidString: "00000000-0000-0000-0000-00000000000D")!

    @Test func sendToListsTheThreadsOtherWindowsShowInWindowOrder() {
        let targets = WindowTargets.others([(a, "one"), (b, "two"), (c, "three")], from: a, excluding: "one")
        #expect(targets == [WindowTarget(window: b, thread: "two"), WindowTarget(window: c, thread: "three")])
    }

    @Test func sendToSkipsTheSourceThreadWindowsWithoutAThreadAndRepeats() {
        let windows: [(window: UUID, thread: String?)] = [(a, "one"), (b, nil), (c, "one"), (d, "two")]
        #expect(WindowTargets.others(windows, from: b, excluding: nil) == [WindowTarget(window: a, thread: "one"),
                                                                          WindowTarget(window: d, thread: "two")])
        #expect(WindowTargets.others(windows, from: a, excluding: "one") == [WindowTarget(window: d, thread: "two")])
    }

    @Test func aLoneWindowHasNoTargets() {
        #expect(WindowTargets.others([(a, "one")], from: a, excluding: nil).isEmpty)
    }

    // MARK: Insertion

    @Test(arguments: [
        ("Use these boards as the spec.", "", "Use these boards as the spec."),
        ("Use these boards.", "  \n", "Use these boards."),
        ("Use these boards.", "Restyle the thread", "Restyle the thread\n\nUse these boards."),
        ("Use these boards.", "Restyle the thread\n\n  ", "Restyle the thread\n\nUse these boards."),
        ("\n\nfirst\n  indented\n\n", "", "first\n  indented"),
        ("  \n ", "Keep me", "Keep me"),
        ("", "", ""),
    ])
    func sentTextFollowsTheDraftAfterABlankLine(text: String, draft: String, expected: String) {
        #expect(ComposerInsertion.inserting(text, into: draft) == expected)
    }
}
