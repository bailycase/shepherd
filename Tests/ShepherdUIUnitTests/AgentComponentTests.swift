import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The Agents components' pure parts: duration text, the elapsed schedule's ticks, inline Markdown
/// spans, what cards and strip segments say, and the strip's click targets.
@Suite("Agents components")
struct AgentComponentTests {
    @Test(arguments: [
        (0.0, "0s", "0s"), (48.9, "48s", "48s"), (60, "1m", "1m 00s"), (242, "4m", "4m 02s"),
        (2241, "37m", "37m 21s"), (3600, "1h", "1h 00m"), (3720, "1h", "1h 02m"), (-5, "0s", "0s"),
        (14.7, "14s", "14s"), (59.9, "59s", "59s"), (62, "1m", "1m 02s"),
        (3599, "59m", "59m 59s"), (86_399, "23h", "23h 59m"), (86_400, "1d", "24h 00m"),
    ])
    func durationsReadAsTheBoardsWriteThem(seconds: Double, short: String, long: String) {
        #expect(SHDuration.text(seconds, .short) == short)
        #expect(SHDuration.text(seconds, .long) == long)
    }

    /// Short text changes every second for a minute, then on whole minutes (then hours) counted
    /// from the start, never from when the view appeared.
    @Test(arguments: [
        (0.0, 1.0), (12.4, 13), (59.5, 60), (60, 120), (61.2, 120), (3599, 3600), (3600, 7200), (90_000, 172_800), (-3, 1),
    ])
    func shortTicksLandWhereTheTextChanges(elapsed: Double, next: Double) {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = SHElapsedSchedule(start: start, style: .short)
        #expect(schedule.boundary(after: start.addingTimeInterval(elapsed)) == start.addingTimeInterval(next))
    }

    @Test func longTicksEverySecondForAnHourThenEveryMinute() {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = SHElapsedSchedule(start: start, style: .long)
        #expect(schedule.boundary(after: start.addingTimeInterval(2241.5)) == start.addingTimeInterval(2242))
        #expect(schedule.boundary(after: start.addingTimeInterval(3661)) == start.addingTimeInterval(3720))
    }

    @Test func entriesStartNowAndFollowTheBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(58.5)
        let entries = Array(SHElapsedSchedule(start: start).entries(from: now, mode: .normal).prefix(4))
        #expect(entries == [now, start.addingTimeInterval(59), start.addingTimeInterval(60), start.addingTimeInterval(120)])
    }

    /// A whole second of the reference clock, with `fraction` of the next past it.
    private static func moment(_ fraction: Double) -> Date { Date(timeIntervalSinceReferenceDate: 800_000_000 + fraction) }

    /// Aligned, a tick lands on a whole second of the clock: at or after the moment the text
    /// changes, and less than a second after it.
    @Test(arguments: [0.0, 0.25, 0.73], [12.4, 150.4, 4_000.4])
    func alignedTicksFallOnWholeSeconds(fraction: Double, elapsed: Double) {
        let start = Self.moment(fraction)
        let now = start.addingTimeInterval(elapsed)
        let anchored = SHElapsedSchedule(start: start).boundary(after: now)
        let aligned = SHElapsedSchedule(start: start, aligned: true).boundary(after: now)
        let seconds = aligned.timeIntervalSinceReferenceDate
        #expect(seconds == seconds.rounded())
        #expect(aligned >= anchored && aligned.timeIntervalSince(anchored) < 1)
    }

    @Test(arguments: [0.0, 0.25, 0.73])
    func alignedEntriesStrictlyIncrease(fraction: Double) {
        let start = Self.moment(fraction)
        let entries = Array(SHElapsedSchedule(start: start, aligned: true).entries(from: start.addingTimeInterval(0.4), mode: .normal).prefix(120))
        #expect(entries.count == 120)
        #expect(zip(entries, entries.dropFirst()).allSatisfy { $0 < $1 })
    }

    /// Clocks counting from different moments tick together once aligned, and apart otherwise. The
    /// first tick each draws after being mounted can land a second apart (the nearer boundary);
    /// every one after is shared.
    @Test func clocksStartedApartShareTheirTicks() {
        let (early, late) = (Self.moment(0.2), Self.moment(0.8))
        let mounted = Self.moment(5.5), shared = Self.moment(7)
        func ticks(_ start: Date, aligned: Bool) -> [Date] {
            Array(SHElapsedSchedule(start: start, aligned: aligned).entries(from: mounted, mode: .normal).prefix(50)).filter { $0 >= shared }
        }
        #expect(ticks(early, aligned: true).count >= 40)
        #expect(ticks(early, aligned: true).prefix(40) == ticks(late, aligned: true).prefix(40))
        #expect(ticks(early, aligned: false).prefix(40) != ticks(late, aligned: false).prefix(40))
    }

    @Test func theDefaultScheduleIsUnchanged() {
        let start = Self.moment(0.25)
        let schedule = SHElapsedSchedule(start: start)
        #expect(!schedule.aligned)
        #expect(schedule == SHElapsedSchedule(start: start, style: .short, aligned: false))
        #expect(schedule != SHElapsedSchedule(start: start, aligned: true))
        #expect(schedule.boundary(after: start.addingTimeInterval(12.4)) == start.addingTimeInterval(13))
    }

    /// The runs of `text` as (characters, is code, is strong, is a link).
    @MainActor private func runs(_ text: String) -> [(String, Bool, Bool, Bool)] {
        let attributed = SHInlineMarkup.attributed(text)
        return attributed.runs.map { run in
            let intent = run.inlinePresentationIntent ?? []
            return (String(attributed[run.range].characters), intent.contains(.code), intent.contains(.stronglyEmphasized), run.link != nil)
        }
    }

    @MainActor @Test func codeSpansAndEmphasisRenderAsTheThreadDoes() {
        let spans = runs("Collides with `Tokens.textSecondary`. **Rename** or [read](https://example.com)?")
        #expect(spans.map(\.0) == ["Collides with ", "Tokens.textSecondary", ". ", "Rename", " or ", "read", "?"])
        #expect(spans.map(\.1) == [false, true, false, false, false, false, false])
        #expect(spans.map(\.2) == [false, false, false, true, false, false, false])
        #expect(spans.map(\.3) == [false, false, false, false, false, true, false])
    }

    @MainActor @Test(arguments: ["no markup at all", "an `unpaired backtick", "two\nlines  kept"])
    func textWithoutMarkupStaysAsWritten(_ text: String) {
        let spans = runs(text)
        #expect(spans.allSatisfy { !$0.1 && !$0.2 && !$0.3 })
        #expect(spans.map(\.0).joined() == text)
    }

    @Test func aTrayHeaderReadsAsItsTitleThenItsTally() {
        let summary = SHSubagentTraySummary(title: "3 subagents", cells: [.running, .queued, .done],
                                            tally: [.init("1 running", state: .running), .init("1 waiting on parent"), .init("1 done")])
        #expect(summary.accessibilityLabel == "3 subagents, 1 running, 1 waiting on parent, 1 done")
    }

    /// Only a run still going can be steered and stopped; one waiting on its parent draws as queued, so it counts as going.
    @Test(arguments: [(AgentState.running, true), (.queued, true), (.done, false), (.failed, false)])
    func aTrayRowIsLiveUntilItsRunEnds(state: AgentState, live: Bool) {
        let run = SHSubagentTrayRun(id: "w", name: "worker", state: state, line: .waiting(""))
        #expect(run.isLive == live)
        #expect(run.accessibilityLabel == "worker", "the app hands in the spoken label; the name stands in without one")
    }
}
