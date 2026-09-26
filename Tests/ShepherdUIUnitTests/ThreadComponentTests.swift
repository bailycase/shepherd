import Testing
@testable import ShepherdUI

@Suite("Thread components")
struct ThreadComponentTests {
    @Test(arguments: [(0.0, "0s"), (14.7, "14s"), (62, "1m 02s"), (3_720, "1h 02m"), (-3, "0s")] as [(Double, String)])
    func liveElapsedCountsWholeSecondsThenMinutes(seconds: Double, text: String) {
        #expect(NWDuration.text(seconds, .long) == text)
    }

    /// Only thinking with something to open is a disclosure with a chevron: live "Thinking…"
    /// and a thought the model kept back are plain lines, whatever they carry.
    @Test(arguments: [
        (live: true, text: "", kind: .live),
        (live: true, text: "hmm", kind: .live),
        (live: false, text: "", kind: .plain),
        (live: false, text: "Check the labels first.", kind: .disclosure),
    ] as [(live: Bool, text: String, kind: NWThinking.Kind)])
    func thinkingOpensOnlyOntoText(live: Bool, text: String, kind: NWThinking.Kind) {
        #expect(NWThinking.Kind(live: live, text: text) == kind)
        #expect(NWThinking.Kind(live: live, text: text).opens == (kind == .disclosure))
    }

    /// A message's time and a turn's footer are hidden at rest. The pointer over the message
    /// shows them, and so does keyboard focus on one of their controls, a copy confirming, or
    /// VoiceOver running, so they are always reachable.
    @Test(arguments: [
        (hovering: false, focused: false, confirming: false, voiceOver: false, shown: false),
        (hovering: true, focused: false, confirming: false, voiceOver: false, shown: true),
        (hovering: false, focused: true, confirming: false, voiceOver: false, shown: true),
        (hovering: false, focused: false, confirming: true, voiceOver: false, shown: true),
        (hovering: false, focused: false, confirming: false, voiceOver: true, shown: true),
    ])
    func messageDetailsShowOnlyWhenTheMessageIsHoveredOrReachedAnotherWay(
        hovering: Bool, focused: Bool, confirming: Bool, voiceOver: Bool, shown: Bool
    ) {
        #expect(NWMessageDetails.shown(hovering: hovering, focused: focused, confirming: confirming, voiceOver: voiceOver) == shown)
    }
}
