import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

/// The Agents components' pure parts: duration text, the elapsed schedule's ticks, inline code
/// spans, and the card's spoken summary.
@Suite("Agents components")
struct AgentComponentTests {
    @Test(arguments: [
        (0.0, "0s", "0s"), (48.9, "48s", "48s"), (60, "1m", "1m 00s"), (242, "4m", "4m 02s"),
        (2241, "37m", "37m 21s"), (3600, "1h", "1h 00m"), (3720, "1h", "1h 02m"), (-5, "0s", "0s"),
    ])
    func durationsReadAsTheBoardsWriteThem(seconds: Double, short: String, long: String) {
        #expect(NWDuration.text(seconds, .short) == short)
        #expect(NWDuration.text(seconds, .long) == long)
    }

    /// Short text changes every second for a minute, then on whole minutes (then hours) counted
    /// from the start, never from when the view appeared.
    @Test(arguments: [
        (0.0, 1.0), (12.4, 13), (59.5, 60), (60, 120), (61.2, 120), (3599, 3600), (3600, 7200), (-3, 1),
    ])
    func shortTicksLandWhereTheTextChanges(elapsed: Double, next: Double) {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = NWElapsedSchedule(start: start, style: .short)
        #expect(schedule.boundary(after: start.addingTimeInterval(elapsed)) == start.addingTimeInterval(next))
    }

    @Test func longTicksEverySecondForAnHourThenEveryMinute() {
        let start = Date(timeIntervalSince1970: 1_000)
        let schedule = NWElapsedSchedule(start: start, style: .long)
        #expect(schedule.boundary(after: start.addingTimeInterval(2241.5)) == start.addingTimeInterval(2242))
        #expect(schedule.boundary(after: start.addingTimeInterval(3661)) == start.addingTimeInterval(3720))
    }

    @Test func entriesStartNowAndFollowTheBoundaries() {
        let start = Date(timeIntervalSince1970: 1_000)
        let now = start.addingTimeInterval(58.5)
        let entries = Array(NWElapsedSchedule(start: start).entries(from: now, mode: .normal).prefix(4))
        #expect(entries == [now, start.addingTimeInterval(59), start.addingTimeInterval(60), start.addingTimeInterval(120)])
    }

    @Test func inlineCodeSplitsOnPairedBackticks() {
        let spans = NWInlineMarkup.spans("Collides with `Tokens.textSecondary`. Rename?")
        #expect(spans.map(\.text) == ["Collides with ", "Tokens.textSecondary", ". Rename?"])
        #expect(spans.map(\.code) == [false, true, false])
    }

    @Test(arguments: ["no code at all", "an `unpaired backtick", "``"])
    func textWithoutACodeSpanStaysPlain(_ text: String) {
        #expect(NWInlineMarkup.spans(text).allSatisfy { !$0.code })
        #expect(NWInlineMarkup.spans(text).map(\.text).joined() == (text == "``" ? "" : text))
    }

    @Test func aCardReadsAsNameRoleStateAndDetail() {
        let run = NWSubagentRun(id: "d", name: "desktop", role: "worker", state: .running, detail: "edit ThreadView.swift")
        #expect(run.accessibilityLabel == "desktop, worker, Running, edit ThreadView.swift")
        let paused = NWSubagentRun(id: "p", name: "docs", state: .queued, stateLabel: "Paused", detail: "")
        #expect(paused.accessibilityLabel == "docs, Paused")
    }
}
