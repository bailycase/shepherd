import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The iPad overview's Running now and Finished cards (iPadOverview).
@Suite("Fleet: the iPad overview's rows")
struct FleetOverviewTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    /// Thursday 24 September 2026, 14:47 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_261_220)

    static func ms(_ date: Date) -> Double { date.timeIntervalSince1970 * 1000 }

    static func row(_ id: String, activity: String? = nil, subagents: Int = 0, asking: Int = 0, host: String? = nil,
                    status: AgentStatus = .working, at: Date? = nil) -> FleetThreadRow {
        FleetThreadRow(ref: FleetRef(host: FleetTests.studio, agent: AgentID(rawValue: id)), title: id, status: status,
                       detail: "", activity: activity, clock: at.map { .ago(ms($0)) }, hostName: "Studio", hostTag: host,
                       worktree: false, offline: false, subagents: subagents, subagentsAsking: asking)
    }

    @Test func aDigestCountsTheSubagentsStillRunningAndThoseAsking() {
        let digest = FleetTests.digest(FleetTests.snapshot(running: true, subagents: [
            Fixture.run("worker"),
            Fixture.run("reviewer", state: "paused", needsAttention: true),
            Fixture.run("tests", state: "complete"),
        ]))
        #expect(digest.subagentsLive == 2)
        #expect(digest.subagentsAsking == 1)
    }

    @Test(arguments: [
        (row("a", activity: "swift test --filter toolPreview"), "swift test --filter toolPreview"),
        (row("b", subagents: 3, asking: 1), "3 subagents · 1 needs you"),
        (row("c", subagents: 1), "1 subagent"),
        (row("d", activity: "swift build", subagents: 2, host: "This Mac"), "swift build · This Mac"),
        (row("e"), "running"),
        (row("f", host: "build-01"), "build-01"),
    ] as [(FleetThreadRow, String)])
    func aRunningRowSaysWhatItDoesNow(row: FleetThreadRow, now: String) {
        #expect(row.now == now)
    }

    @Test func aRunningThreadCarriesItsSubagentsIntoItsRowAndASettledOneDoesNot() {
        let digest = FleetTests.digest(FleetTests.snapshot(running: true, subagents: [
            Fixture.run("worker"), Fixture.run("reviewer", state: "paused", needsAttention: true),
        ]))
        let model = FleetModel(hosts: [FleetTests.host(FleetTests.studio, "Studio", agents: [
            FleetTests.agent("busy", .working), FleetTests.agent("quiet", .done),
        ])], digests: [FleetTests.ref("busy"): digest, FleetTests.ref("quiet"): digest])
        #expect(model.running.map(\.subagents) == [2])
        #expect(model.running.map(\.subagentsAsking) == [1])
        #expect(model.finished.map(\.subagents) == [0])
    }

    @Test func finishedThreadsGroupByTheDayTheyLastMovedNewestFirstWithUntimedOnesLast() {
        let rows = [
            Self.row("today", status: .done, at: Self.now.addingTimeInterval(-3_600)),
            Self.row("untimed", status: .done),
            Self.row("yesterday", status: .done, at: Self.now.addingTimeInterval(-86_400)),
            Self.row("monday", status: .done, at: Self.now.addingTimeInterval(-3 * 86_400)),
            Self.row("old", status: .done, at: Self.now.addingTimeInterval(-12 * 86_400)),
        ]
        let days = FleetFinishedDay.days(rows, now: Self.now, calendar: Self.calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Monday", "Sep 12", "Earlier"])
        #expect(days.map { $0.rows.map(\.title) } == [["today"], ["yesterday"], ["monday"], ["old"], ["untimed"]])
    }

    @Test(arguments: [
        (-3_600.0, "1:47"),
        (-2 * 86_400.0, "Tue"),
        (-9 * 86_400.0, "Sep 15"),
    ] as [(TimeInterval, String)])
    func aFinishedRowIsStampedWithItsTimeTodayItsWeekdayThisWeekAndItsDateBefore(offset: TimeInterval, stamp: String) {
        #expect(FleetFinishedDay.stamp(Self.ms(Self.now.addingTimeInterval(offset)), now: Self.now, calendar: Self.calendar) == stamp)
    }
}
