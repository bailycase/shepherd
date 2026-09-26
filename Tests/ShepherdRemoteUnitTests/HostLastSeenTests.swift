import Foundation
import Testing
@testable import ShepherdRemote

@Suite("Host last seen")
struct HostLastSeenTests {
    static let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()
    static let locale = Locale(identifier: "en_US_POSIX")
    /// 2026-09-25 15:30 UTC.
    static let now = Date(timeIntervalSince1970: 1_790_350_200)

    static func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }

    /// Times are the locale's (en_US puts a narrow no-break space before AM and PM).
    @Test(arguments: [
        (ago(8.3), "today 7:12\u{202F}AM", "7:12\u{202F}AM"),
        (ago(20.8), "yesterday 6:42\u{202F}PM", "yesterday 6:42\u{202F}PM"),
        (ago(24 * 5), "Sep 20", "Sep 20"),
        (ago(24 * 400), "Aug 21, 2025", "Aug 21, 2025"),
    ] as [(Date, String, String)])
    func aHostIsLastSeenTodayYesterdayOrOnItsDay(seen: Date, text: String, short: String) {
        #expect(HostLastSeen.text(seen, now: Self.now, calendar: Self.calendar, locale: Self.locale) == text)
        #expect(HostLastSeen.short(seen, now: Self.now, calendar: Self.calendar, locale: Self.locale) == short)
    }

    @Test func anUnreachableHostsRowSaysWhenItWasLastSeenAndAConnectedOneDoesNot() {
        var laptop = NewThreadRulesTests.laptop
        laptop.lastSeen = Self.ago(8.3)
        var studio = NewThreadRulesTests.studio
        studio.lastSeen = Self.ago(1)
        let rows = NewThreadRows.hosts([studio, laptop], selected: nil, now: Self.now, calendar: Self.calendar, locale: Self.locale)
        #expect(rows.map(\.detail) == ["connected · 2 threads running", "unreachable · last seen 7:12\u{202F}AM"])
    }

    @Test func onlyAHostThatIsNotConnectedCarriesWhenItWasLastSeen() {
        let seen = Self.ago(2)
        let offline = FleetHost(id: FleetTests.build, name: "build-01", address: "build.local", port: 7433,
                                phase: .failed(RemoteHostFailure(kind: .unreachable, detail: "refused")), state: .init(), lastSeen: seen)
        let online = FleetHost(id: FleetTests.studio, name: "Studio", address: "studio.local", port: 7433, phase: .connected,
                               state: .init(), lastSeen: seen)
        let model = FleetModel(hosts: [online, offline], digests: [:])
        #expect(model.hosts.map(\.lastSeen) == [nil, seen])
    }
}
