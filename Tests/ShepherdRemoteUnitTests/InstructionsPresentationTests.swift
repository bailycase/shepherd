import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ Instructions' host rules: what each chip says, how old a save reads, and which
/// files a host holds.
@Suite("Instructions presentation")
struct InstructionsPresentationTests {
    static let local = InstructionsSnapshot(agents: "- a\n- b\n", appendSystem: "rule\n", directory: "~/i")
    static let now = Date(timeIntervalSince1970: 1_790_000_000) // 2026-09-21 14:13:20 UTC
    static let posix = Locale(identifier: "en_US_POSIX")
    static let utc = TimeZone(identifier: "UTC")!

    static func host(agents: String = "- a\n- b\n", append: String = "rule\n") -> InstructionsHostFiles {
        .loaded(InstructionsSnapshot(agents: agents, appendSystem: append, directory: "~/i"))
    }

    static func chip(_ files: InstructionsHostFiles, same: Bool, pending: Bool = false, kept: Bool = false,
                     syncedAt: Date? = nil) -> InstructionsChip {
        InstructionsPresentation.hostChip(files, local: local, file: .agents, sameEverywhere: same, pending: pending,
                                          keptDifferent: kept, syncedAt: syncedAt, now: now)
    }

    @Test func withSameOnEveryHostAChipReportsTheSync() {
        #expect(Self.chip(Self.host(), same: true) == InstructionsChip(.done, "synced"))
        #expect(Self.chip(Self.host(), same: true, syncedAt: Self.now.addingTimeInterval(-120)) == InstructionsChip(.done, "synced 2m ago"))
        // Both files count: a difference in the other one is still out of sync.
        #expect(Self.chip(Self.host(append: "other\n"), same: true) == InstructionsChip(.attention, "differs · 1 line"))
        #expect(Self.chip(.offline, same: true, pending: true) == InstructionsChip(.quiet, "offline · will sync"))
        #expect(Self.chip(.offline, same: true) == InstructionsChip(.quiet, "offline"))
    }

    @Test func perHostAChipComparesTheOpenFileWithThisMac() {
        #expect(Self.chip(Self.host(append: "other\n"), same: false) == InstructionsChip(.done))
        #expect(Self.chip(Self.host(agents: "- a\n- c\n- d\n"), same: false) == InstructionsChip(.attention, "differs · 2 lines"))
        #expect(Self.chip(Self.host(agents: "- a\n"), same: false, kept: true) == InstructionsChip(.quiet, "kept different"))
        #expect(Self.chip(.offline, same: false, pending: true) == InstructionsChip(.quiet, "offline"))
    }

    @Test func aHostThatCannotAnswerSaysWhy() {
        #expect(Self.chip(.unsupported, same: true) == InstructionsChip(.quiet, "needs update"))
        #expect(Self.chip(.checking, same: false) == InstructionsChip(.working, "checking…"))
        #expect(Self.chip(.failed("timeout"), same: true) == InstructionsChip(.failed, "couldn't read"))
        #expect(InstructionsPresentation.hostChip(Self.host(), local: nil, file: .agents, sameEverywhere: true, pending: false,
                                                  keptDifferent: false, syncedAt: nil) == InstructionsChip(.working, "checking…"))
    }

    @Test func thisMacIsTheReferencePerHostAndReportsTheSyncOtherwise() {
        #expect(InstructionsPresentation.localChip(sameEverywhere: false, allSynced: false) == InstructionsChip(.done))
        #expect(InstructionsPresentation.localChip(sameEverywhere: true, allSynced: true) == InstructionsChip(.done, "synced"))
        #expect(InstructionsPresentation.localChip(sameEverywhere: true, allSynced: false) == InstructionsChip(.quiet, "not synced"))
    }

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

    static func saved(_ snapshot: InstructionsSnapshot, at time: Double) -> InstructionsSnapshot {
        var snapshot = snapshot
        snapshot.history = [InstructionHistoryEntry(id: UUID(), file: .appendSystem, savedAt: time, summary: "Added “rule”")]
        return snapshot
    }

    static func row(_ files: InstructionsHostFiles, lastKnown: InstructionsSnapshot? = nil, kept: Bool = false,
                    lastConnected: Date? = nil) -> InstructionsHostRow {
        InstructionsPresentation.hostRow(files, lastKnown: lastKnown, local: local, file: .agents, keptDifferent: kept,
                                         lastConnected: lastConnected, now: now, locale: posix, timeZone: utc)
    }

    @Test func thisMacsRowSaysWhenItChangedAndWhatItHolds() {
        let row = InstructionsPresentation.localRow(Self.saved(Self.local, at: Self.now.timeIntervalSince1970 - 120),
                                                    now: Self.now, locale: Self.posix, timeZone: Self.utc)
        #expect(row == InstructionsHostRow(detail: "edited 2m ago", note: "AGENTS · APPEND"))
        #expect(InstructionsPresentation.localRow(Self.local, now: Self.now).detail == "no saves yet")
    }

    @Test func aHostsRowComparesTheOpenFileWithThisMac() {
        let september19 = 1_789_819_200.0
        let differs = Self.saved(InstructionsSnapshot(agents: "- a\n- c\n- d\n", appendSystem: "rule\n", directory: "~/i"), at: september19)
        #expect(Self.row(.loaded(differs)) == InstructionsHostRow(detail: "edited Sep 19", note: "2 lines differ", noteTone: .attention))
        #expect(Self.row(.loaded(differs), kept: true) == InstructionsHostRow(detail: "edited Sep 19", note: "kept different"))
        // Only the open file counts: the other one has its own line.
        #expect(Self.row(Self.host(append: "other\n")) == InstructionsHostRow(detail: "no saves yet", note: "matches This Mac"))
    }

    @Test func anOfflineHostsRowSaysWhenItWasLastSeenAndHowItLastCompared() {
        let seen = Date(timeIntervalSince1970: 1_789_974_720) // 07:12 today
        #expect(Self.row(.offline, lastKnown: Self.local, lastConnected: seen)
                == InstructionsHostRow(detail: "last seen 07:12", note: "matched This Mac"))
        #expect(Self.row(.offline, lastKnown: InstructionsSnapshot(agents: "- a\n", directory: "~/i"), lastConnected: seen)
                == InstructionsHostRow(detail: "last seen 07:12", note: "1 line differed"))
        #expect(Self.row(.offline) == InstructionsHostRow(detail: "offline"))
        #expect(Self.row(.unsupported).detail == "needs update")
        #expect(Self.row(.failed("timeout")) == InstructionsHostRow(detail: "couldn't read", noteTone: .failed))
    }

    @Test(arguments: [
        // Every host read and alike: counted, This Mac included.
        (["- a\n", "- a\n"], "Same on all three hosts."),
        (["- a\n"], "Same on both hosts."),
        ([], "Only on This Mac."),
        // Any difference is named.
        (["- a\n", "- b\n"], "Differs on horizon."),
        (["- b\n", "- b\n"], "Differs on build-01 and horizon."),
    ])
    func theOtherFilesLineComparesEveryHost(copies: [String], line: String) {
        let names = ["build-01", "horizon"]
        let hosts = copies.enumerated().map { (name: names[$0.offset], text: Optional($0.element)) }
        #expect(InstructionsPresentation.otherFileLine(local: "- a\n", hosts: hosts) == line)
    }

    @Test func hostsThatDriftedAreNamed() {
        #expect(InstructionsPresentation.drifted(["build-01"]) == "build-01 differs from This Mac.")
        #expect(InstructionsPresentation.drifted(["build-01", "horizon", "studio"]) == "build-01, horizon and studio differ from This Mac.")
    }

    @Test func theOtherFilesLineNamesAHostItCannotRead() {
        let hosts: [(name: String, text: String?)] = [("build-01", "- a\n"), ("horizon", nil)]
        #expect(InstructionsPresentation.otherFileLine(local: "- a\n", hosts: hosts) == "Same on This Mac and build-01; horizon isn't connected.")
        #expect(InstructionsPresentation.otherFileLine(local: "- a\n", hosts: [("build-01", nil), ("horizon", nil)])
                == "Same on This Mac; build-01 and horizon aren't connected.")
    }

    @Test func aHostSaysWhichFilesItHolds() {
        #expect(InstructionsPresentation.filesHeld(Self.local) == "AGENTS · APPEND")
        #expect(InstructionsPresentation.filesHeld(InstructionsSnapshot(agents: "a", directory: "~")) == "AGENTS")
        #expect(InstructionsPresentation.filesHeld(InstructionsSnapshot(appendSystem: "r", directory: "~")) == "APPEND")
        #expect(InstructionsPresentation.filesHeld(InstructionsSnapshot(agents: " \n", directory: "~")) == "no files")
    }

    @Test func aKeptDifferenceIsRememberedByBothSides() {
        let kept = InstructionsPresentation.fingerprint(host: "- docker\n", local: "- a\n")
        #expect(kept == InstructionsPresentation.fingerprint(host: "- docker\n", local: "- a\n"))
        #expect(kept != InstructionsPresentation.fingerprint(host: "- docker!\n", local: "- a\n"))
        #expect(kept != InstructionsPresentation.fingerprint(host: "- docker\n", local: "- b\n"))
        #expect(InstructionsPresentation.fingerprint(host: "ab", local: "") != InstructionsPresentation.fingerprint(host: "a", local: "b"))
    }
}
