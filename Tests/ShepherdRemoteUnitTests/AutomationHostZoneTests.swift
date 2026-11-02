import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// Schedules run in the host's time zone, so a client previews and shows them there, not in its own.
@Suite("Automation triggers: the host's time zone")
struct AutomationHostZoneTests {
    static let newYork = TimeZone(identifier: "America/New_York")!
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    static let english = Locale(identifier: "en_US")
    /// 2025-01-15 13:00 UTC: 08:00 in New York, 22:00 in Tokyo.
    static let now = Date(timeIntervalSince1970: 1_736_946_000)

    static var dailyAtNine: AutomationTriggerForm {
        var form = AutomationTriggerForm()
        form.kind = .schedule
        form.scheduleKind = .daily
        (form.hour, form.minute) = (9, 0)
        return form
    }

    @Test func theEditorPreviewsInTheHostsZoneNotTheDevices() {
        let host = AutomationHostZone(identifier: "America/New_York", device: Self.tokyo)
        #expect(host.known && host.timeZone == Self.newYork && host.calendar.timeZone == Self.newYork)
        let next = Self.dailyAtNine.check(now: Self.now, calendar: host.calendar, locale: Self.english).next
        #expect(next == "Today 09:00", "09:00 in New York is an hour away")
        // The device's own zone would have said tomorrow: the bug this guards.
        var tokyo = Calendar(identifier: .gregorian)
        tokyo.timeZone = Self.tokyo
        #expect(Self.dailyAtNine.check(now: Self.now, calendar: tokyo, locale: Self.english).next == "Jan 16 09:00")
        #expect(host.footnote(next: next!, hostName: "build-01", device: Self.tokyo, locale: Self.english)
            == "Next run Today 09:00 (Eastern Time, build-01's time zone).")
        #expect(host.note(hostName: "build-01", device: Self.tokyo, locale: Self.english) == "Times are Eastern Time, build-01's time zone.")
    }

    @Test func aHostInTheDevicesZoneNeedsNoNote() {
        let host = AutomationHostZone(identifier: "Asia/Tokyo", device: Self.tokyo)
        #expect(host.footnote(next: "Today 09:00", hostName: "build-01", device: Self.tokyo) == "Next run Today 09:00.")
        #expect(host.note(hostName: "build-01", device: Self.tokyo) == nil)
    }

    @Test(arguments: [nil, "Not/AZone"])
    func anUnknownZoneFallsBackToTheDevicesAndSaysSo(_ identifier: String?) {
        let host = AutomationHostZone(identifier: identifier, device: Self.tokyo)
        #expect(!host.known && host.timeZone == Self.tokyo)
        #expect(host.footnote(next: "Today 09:00", hostName: "build-01", device: Self.tokyo)
            == "Next run Today 09:00. Times are build-01's time zone.")
        #expect(host.note(hostName: "build-01", device: Self.tokyo) == nil)
    }

    @Test func theDetailsNextRunReadsInTheHostsZone() throws {
        var automation = AutomationTriggerPresentationTests.triggered(.schedule(AutomationSchedule(rrule: "FREQ=DAILY;BYHOUR=9;BYMINUTE=0")))
        var host = AutomationPresentationTests.host([automation], name: "build-01")
        host.triggers = true
        let key = AutomationKey(host: host.id, automation: automation.id)
        // 09:00 New York on Jan 15 is 14:00 UTC.
        let status = AutomationTriggerStatus(state: .active, nextRunAt: 1_736_949_600, timeZone: "America/New_York")
        let model = AutomationsModel(hosts: [host], runs: [key: []], statuses: [key: status])
        let zone = AutomationHostZone(identifier: status.timeZone, device: Self.tokyo)
        let detail = try #require(model.detail(key, runs: [], status: status, now: Self.now, timeZone: zone.timeZone, locale: Self.english))
        #expect(detail.trigger?.next == "Today 09:00")
        let local = try #require(model.detail(key, runs: [], status: status, now: Self.now, timeZone: Self.tokyo, locale: Self.english))
        #expect(local.trigger?.next == "Today 23:00", "the same moment, read in the device's zone, is another hour")
    }

    @Test func theSpeedPinIsSavedAndShown() {
        var form = Self.dailyAtNine
        form.model = "anthropic/claude-sonnet"
        form.speed = ServiceTier.fast.rawValue
        #expect(form.settings.serviceTier == "fast")
        #expect(AutomationTriggerText.model(form.settings) == "anthropic/claude-sonnet · Fast")
        form.speed = ""
        #expect(AutomationTriggerText.model(form.settings) == "anthropic/claude-sonnet")
    }
}
