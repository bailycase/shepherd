import Foundation
import Testing
@testable import ShepherdUI

@Suite("Glance")
struct GlanceTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    static func item(_ agent: String, _ state: SHGlance.State, minutesAgo: Double, options: [String] = [],
                     session: Bool = true) -> SHGlance.Item {
        SHGlance.Item(host: "h", agent: agent, title: agent, state: state, hostName: "This Mac",
                      since: now.addingTimeInterval(-minutesAgo * 60), options: options,
                      dialogID: state == .needsYou ? "d" : nil,
                      session: session ? SHGlance.Session(piSessionID: "p", generation: "g") : nil)
    }

    /// The Watch drops what finished before the cut; what runs, asks or failed stays.
    @Test func theWatchKeepsOnlyRecentlyFinishedWork() {
        let glance = SHGlance(items: [
            Self.item("done-old", .done, minutesAgo: 57),
            Self.item("done-new", .done, minutesAgo: 1),
            Self.item("failed-old", .failed, minutesAgo: 57),
            Self.item("run", .running, minutesAgo: 90),
        ], hosts: [], updated: Self.now)
        let kept = glance.finished(after: Self.now.addingTimeInterval(-15 * 60))
        #expect(Set(kept.items.map(\.agent)) == ["done-new", "failed-old", "run"])
    }

    /// The card leads with what needs you longest, then failures, then the longest run; done last.
    @Test func itemsRankByUrgencyThenTime() {
        let glance = SHGlance(items: [
            Self.item("done-old", .done, minutesAgo: 30),
            Self.item("run-short", .running, minutesAgo: 2),
            Self.item("ask-new", .needsYou, minutesAgo: 1),
            Self.item("failed", .failed, minutesAgo: 9),
            Self.item("run-long", .running, minutesAgo: 37),
            Self.item("ask-old", .needsYou, minutesAgo: 5),
            Self.item("done-new", .done, minutesAgo: 2),
        ], hosts: [], updated: Self.now)
        #expect(glance.items.map(\.agent) == ["ask-old", "ask-new", "failed", "run-long", "run-short", "done-new", "done-old"])
        #expect(glance.urgent == .needsYou)
        #expect(glance.summary == "2 need you · 1 failed · 2 working")
    }

    /// At most two answers as buttons, the first the one primary, then Reply…; without a session
    /// or a question to answer, only Reply… (and a running thread can't be stopped).
    @Test func actionsOfferOnlyWhatThePhoneCanDo() {
        let ask = Self.item("a", .needsYou, minutesAgo: 1, options: ["Compare first", "Clean checkout", "Third"])
        #expect(ask.actions == [.answer("Compare first", recommended: true), .answer("Clean checkout", recommended: false), .reply])
        #expect(ask.actions.filter(\.isPrimary).count == 1)
        #expect(Self.item("a", .needsYou, minutesAgo: 1).actions == [.reply])
        #expect(Self.item("r", .running, minutesAgo: 1).actions == [.steer, .stop])
        #expect(Self.item("r", .running, minutesAgo: 1, session: false).actions == [.steer])
        #expect(Self.item("r", .running, minutesAgo: 1).actions(stale: true) == [.open])
    }

    @Test func staleAfterFiveMinutesWithTheHostsItCannotReach() {
        let glance = SHGlance(items: [], hosts: [.init(name: "build-01", online: true), .init(name: "This Mac", online: false)],
                              updated: Self.now)
        #expect(!glance.isStale(at: Self.now.addingTimeInterval(SHGlance.staleAfter)))
        #expect(glance.isStale(at: Self.now.addingTimeInterval(SHGlance.staleAfter + 1)))
        #expect(glance.unreachable == "This Mac")
        #expect(glance.hostsLine == "build-01 online · This Mac offline")
        #expect(glance.summary == "Nothing running")
    }

    /// A list shares its rows out most urgent first, a head counting as a row, and says how many
    /// it left out.
    @MainActor @Test func listsShareTheirRowsMostUrgentFirst() {
        let glance = SHGlance(items: (0..<3).map { Self.item("ask\($0)", .needsYou, minutesAgo: Double($0)) }
            + (0..<4).map { Self.item("run\($0)", .running, minutesAgo: Double($0)) }, hosts: [], updated: Self.now)
        let groups = SHGlanceList(glance, rows: SHGlanceMetrics.mediumRows, stale: false, now: Self.now).groups
        #expect(groups.map(\.title) == ["Needs you", "Working"])
        #expect(groups.map(\.items.count) == [3, 1])
        #expect(groups.map(\.hidden) == [0, 3])
    }

    /// A Live Activity's content stays under ActivityKit's 4 KB with long words everywhere, and
    /// keeps the most urgent whole.
    @Test func theWatchContentStaysUnderFourKilobytes() throws {
        let long = String(repeating: "word ", count: 60)
        var items = (0..<40).map { index in
            var item = Self.item("run-\(UUID().uuidString)", .running, minutesAgo: Double(index))
            item.title = long
            item.command = long
            item.result = long
            item.goal = long
            return item
        }
        var ask = Self.item("ask", .needsYou, minutesAgo: 1, options: ["Compare first", "Clean checkout"])
        ask.question = long
        items.append(ask)
        let glance = SHGlance(items: items, hosts: [.init(name: "This Mac", online: true)], updated: Self.now).forActivity()
        #expect(glance.items.first?.agent == "ask")
        #expect(glance.items.count == SHGlanceMetrics.watchRows + 1)
        #expect(glance.summary == "1 needs you · 40 working")
        #expect(try JSONEncoder().encode(glance).count < 4096)
    }
}
