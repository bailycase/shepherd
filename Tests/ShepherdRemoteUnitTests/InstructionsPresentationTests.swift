import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ Instructions' words: how old a save reads, a history row's date and a file's note.
@Suite("Instructions presentation")
struct InstructionsPresentationTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        (30.0, "just now"), (120, "2m ago"), (3_599, "59m ago"), (7_200, "2h ago"),
    ])
    func aRecentSaveReadsAsItsAge(secondsAgo: Double, text: String) {
        #expect(InstructionsPresentation.age(Self.now.timeIntervalSince1970 - secondsAgo, now: Self.now, locale: Self.posix) == text)
    }

    @Test func anOlderSaveReadsAsItsDay() {
        let september19 = 1_789_819_200.0 // 2026-09-19 12:00 UTC
        #expect(InstructionsPresentation.day(september19, locale: Self.posix, timeZone: Self.utc) == "Sep 19")
        #expect(InstructionsPresentation.age(september19, now: Self.now, locale: Self.posix, timeZone: Self.utc) == "Sep 19")
        #expect(InstructionsPresentation.day(september19 - 17 * 86_400, locale: Self.posix, timeZone: Self.utc) == "Sep 02")
    }

    /// Today's saves read as the time on a 24-hour clock, older ones as their day.
    @Test func aHistoryRowDatesASaveTodayByItsTime() {
        let morning = 1_789_974_720.0 // 2026-09-21 07:12 UTC
        #expect(InstructionsPresentation.historyDate(morning, now: Self.now, locale: Self.posix, timeZone: Self.utc) == "07:12")
        #expect(InstructionsPresentation.historyDate(morning + 12 * 3_600, now: Self.now.addingTimeInterval(6 * 3_600),
                                                     locale: Self.posix, timeZone: Self.utc) == "19:12")
        #expect(InstructionsPresentation.historyDate(1_789_819_200, now: Self.now, locale: Self.posix, timeZone: Self.utc) == "Sep 19")
    }

    @Test func aFilesNoteSaysWhatItIsForAndItsSize() {
        #expect(InstructionsPresentation.fileNote(.agents, text: String(repeating: "word ", count: 20)) == "how you work · 100 characters")
        #expect(InstructionsPresentation.fileNote(.agents, text: "a") == "how you work · 1 character")
        #expect(InstructionsPresentation.fileNote(.appendSystem, text: "", sentence: true) == "Overrides everything · 0 characters")
    }
}
