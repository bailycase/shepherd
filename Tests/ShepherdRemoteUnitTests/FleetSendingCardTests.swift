import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// The "Sending with uncommitted changes" card (FleetStates) and the words for a snapshot that couldn't go, from the dispatch record alone.
@Suite("Fleet sending card")
struct FleetSendingCardTests {
    static func record(bytes: UInt64? = 2_800_000, sent: UInt64? = 1_800_000, files: Int? = 3, warning: Bool = false, state: FleetDispatchState = .preparing) -> FleetDispatchRecord {
        FleetDispatchRecord(parentHostID: UUID(), parentHostName: "MacBook Pro", targetHostName: "Mac mini", state: state, title: "Fix flaky payment test", task: "",
                            repoKey: "github.com/acme/payments-api", commitSHA: "4e1c9a2ffffffffffffffffffffffffffffffff0", snapshotBytes: bytes, snapshotProgress: sent,
                            snapshotFiles: files, sendWarning: warning, createdAt: 1)
    }

    @Test func theCardSaysWhatWasSentWhereAndHowFarItHasGone() throws {
        let card = try #require(FleetSendingCard.make(Self.record()))
        #expect(card.title == "Fix flaky payment test" && card.host == "Mac mini" && card.state == "Starting")
        #expect(card.summary == "Sent payments-api at 4e1c9a2 plus 3 uncommitted files. Mac mini applies them to a new worktree and checks they match before the agent starts.")
        #expect(card.progress == "1.8 of 2.8 MB")
        #expect(abs((card.fraction ?? 0) - 1.8 / 2.8) < 0.001 && card.warning == nil)
    }

    @Test func aWarmDispatchHasNothingToSendAndSaysSo() throws {
        let card = try #require(FleetSendingCard.make(Self.record(bytes: 0, sent: 0, files: 1)))
        #expect(card.progress == "nothing to send" && card.fraction == 1)
        #expect(card.summary.contains("plus 1 uncommitted file."))
        let none = try #require(FleetSendingCard.make(Self.record(bytes: 0, sent: 0, files: 0)))
        #expect(!none.summary.contains("plus"))
    }

    @Test func aSnapshotAboveTheWarningSizeSaysSoAndProgressNeverPassesTheTotal() throws {
        let card = try #require(FleetSendingCard.make(Self.record(bytes: 1_400_000_000, sent: 9_000_000_000, warning: true)))
        #expect(card.warning == "Over 1.1 GB, so this will take a while." && card.fraction == 1)
    }

    @Test func onlyAPreparingRecordWithASnapshotDrawsTheCard() {
        #expect(FleetSendingCard.make(Self.record(state: .running)) == nil)
        #expect(FleetSendingCard.make(Self.record(bytes: nil)) == nil)
    }

    @Test func theDispatchesRowCarriesTheCardWhileThePageShowsThatRecord() {
        let row = FleetPagePresentation.dispatchRow(Self.record(), now: Date(timeIntervalSince1970: 100))
        #expect(row.sending?.progress == "1.8 of 2.8 MB")
        #expect(FleetPagePresentation.dispatchRow(Self.record(state: .running), now: Date(timeIntervalSince1970: 100)).sending == nil)
    }

    @Test func aSnapshotThatCouldntGoIsToldInWordsWithTheBiggestPath() {
        #expect(FleetSendingCard.tooLargeWords("6200000000;node_modules/big.bin:3100000000;a.bin:100") == "Too big to send (6.2 GB), mostly node_modules/big.bin (3.1 GB)")
        #expect(FleetSendingCard.tooLargeWords(nil) == "Too big to send")
        var record = Self.record(state: .failed)
        record.failure = FleetDispatchCode.snapshotMismatch
        #expect(FleetPagePresentation.dispatchRow(record, now: Date(timeIntervalSince1970: 100)).reason == "The files didn't arrive intact, so nothing started")
    }
}
