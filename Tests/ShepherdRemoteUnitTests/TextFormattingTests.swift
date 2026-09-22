import Foundation
import Testing
@testable import ShepherdRemote

@Suite("Durations, clock, and counts")
struct TextFormattingTests {
    @Test(arguments: [
        (10.21, false, "10.2s"), (0.4, false, "0.4s"), (48, false, "48s"), (59.96, false, "60s"),
        (48.9, true, "48s"), (64, false, "1m 04s"), (3599, false, "59m 59s"), (3725, false, "1h 02m"),
        (-3, false, "0s"), (0, true, "0s"),
    ] as [(Double, Bool, String)])
    func durationText(seconds: Double, live: Bool, expected: String) {
        #expect(nativeDurationText(seconds, live: live) == expected)
    }

    @Test(arguments: [(0.0, "0s"), (48, "48s"), (37 * 60 + 21, "37m"), (7300, "2h"), (-5, "0s")] as [(Double, String)])
    func shortDurationUsesOneUnit(seconds: Double, expected: String) {
        #expect(nativeSubagentShortDuration(seconds) == expected)
    }

    @Test func subagentHeaderDurationIsTheLiveFormat() {
        #expect(nativeSubagentDurationText(37 * 60 + 21) == "37m 21s")
        #expect(nativeSubagentDurationText(48.7) == "48s")
    }

    @Test func ageTextNeverGoesNegative() {
        #expect(nativeAgeText(Board.nowMS - 4000, now: Board.now) == "4s ago")
        #expect(nativeAgeText(Board.nowMS + 5000, now: Board.now) == "0s ago")
    }

    @Test(arguments: [(999, "999"), (1_000, "1k"), (42_400, "42k"), (581_000, "581k"), (1_600_000, "1.6m"), (2_000_000, "2m")])
    func compactTokensReadLikeTheBoard(tokens: Int, expected: String) {
        #expect(nativeCompactTokens(tokens) == expected)
    }

    @Test func clockTextIsTwelveHourWithOptionalMeridiem() {
        let utc = TimeZone(identifier: "UTC")!
        #expect(nativeClockText(1_758_539_340_000, timeZone: utc) == "11:09 AM")
        #expect(nativeClockText(1_758_539_340_000, meridiem: false, timeZone: utc) == "11:09")
        #expect(nativeClockText(1_758_582_540_000, timeZone: utc) == "11:09 PM")
    }

    @Test func turnTimeIsTheClockPlusAnyDurationOfASecondOrMore() {
        let start = Board.nowMS
        #expect(nativeTurnTimeText(startedAt: nil, endedAt: 5) == nil)
        #expect(nativeTurnTimeText(startedAt: start, endedAt: nil) == nativeClockText(start))
        #expect(nativeTurnTimeText(startedAt: start, endedAt: start + 400) == nativeClockText(start), "sub-second turns show no 0s")
        #expect(nativeTurnTimeText(startedAt: start, endedAt: start + (45 * 60 + 12) * 1000) == nativeClockText(start) + " · 45m 12s")
    }

    @Test func headTruncationKeepsTheFilename() {
        let path = "Sources/ShepherdApp/DesktopNativeThreadView.swift"
        #expect(nativeHeadTruncated(path, max: 33) == "…pp/DesktopNativeThreadView.swift")
        #expect(nativeHeadTruncated(path, max: 20).count == 20)
        #expect(nativeHeadTruncated(path, max: path.count) == path)
        #expect(nativeHeadTruncated("", max: 5) == "")
    }

    @Test(arguments: [0, 1])
    func degenerateWidthsLeaveThePathAlone(max: Int) {
        #expect(nativeHeadTruncated("abc", max: max) == "abc")
    }

    @Test func firstSentenceStopsAtSentencePunctuationFollowedBySpace() {
        #expect(nativeFirstSentence("One. Two.") == "One.")
        #expect(nativeFirstSentence("Really?! Yes.") == "Really?!")
        #expect(nativeFirstSentence("v1.2 shipped today. Next.") == "v1.2 shipped today.")
        #expect(nativeFirstSentence("no  end\nhere") == "no end here")
        #expect(nativeFirstSentence("") == "")
    }

    @Test func firstSentenceTailTruncatesToTheLimit() {
        let text = nativeFirstSentence(String(repeating: "a", count: 100), limit: 10)
        #expect(text == "aaaaaaaaa…" && text.count == 10)
        #expect(nativeFirstSentence("abcd efgh ijkl", limit: 6) == "abcd…", "trailing space before the ellipsis is trimmed")
    }
}

@Suite("Agent pill")
struct AgentPillTests {
    @Test(arguments: [
        (false, false, false, false, NativeAgentPill.idle),
        (true, false, false, false, .running),
        (true, true, false, false, .needsApproval),
        (false, true, false, true, .needsApproval),
        (true, true, true, false, .error),
        (false, false, true, true, .error),
        (false, false, false, true, .stopped),
        (true, false, false, true, .running),
    ])
    func errorOutranksAQuestionWhichOutranksRunningWhichOutranksStopped(
        running: Bool, awaiting: Bool, error: Bool, stopped: Bool, expected: NativeAgentPill
    ) {
        #expect(nativeAgentPill(running: running, awaitingAnswer: awaiting, error: error, stopped: stopped) == expected)
    }

    @Test func labelsMatchTheSpec() {
        let pills: [NativeAgentPill] = [.idle, .running, .needsApproval, .error, .stopped]
        #expect(pills.map(\.label) == ["Idle", "Running", "Needs you", "Error", "Stopped"])
    }
}
