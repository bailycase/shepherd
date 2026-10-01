import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

/// What an extension command the user ran says back, as the host projects it: the row's shape
/// and where history places it.
@Suite("Command notices on the host")
struct CommandNoticeProjectionTests {
    typealias Notice = RPCThreadState.CommandNotice

    static func notice(_ level: RPCThreadState.NoticeLevel, _ text: String = "Done", at time: Double = 30, number: Int = 10) -> Notice {
        Notice(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000\(number)")!, level: level, text: text, at: time)
    }

    @Test(arguments: [(RPCThreadState.NoticeLevel.info, "custom"), (.warning, "warning"), (.error, "error")])
    func aNoticeSaysItsLevelByItsRole(level: RPCThreadState.NoticeLevel, role: String) {
        let row = RPCThreadState.message(Self.notice(level))
        #expect(row.role == role)
        #expect(row.entryID == "n:00000000-0000-0000-0000-000000000010")
        #expect(row.blocks == [NativeThreadBlock(kind: .text, text: "Done")])
        #expect(row.timestamp == nil, "it never stretches the turn it lands in")
    }

    /// Clients draw a role they have no row for as a note named by it.
    @Test(arguments: [(RPCThreadState.NoticeLevel.info, "Done"), (.warning, "warning · Done"), (.error, "error · Done")])
    func everyClientDrawsANoticeAsANote(level: RPCThreadState.NoticeLevel, line: String) {
        let items = nativeTurnItems([RPCThreadState.message(Self.notice(level))])
        #expect(items == [.note(line)])
    }

    @Test func noticesAreInterleavedWithQuestionsByWhenTheyHappened() {
        let history = QuestionRecordStoreTests.turn
        let question = QuestionRecordStoreTests.question("a", endedAt: 31)
        let rows = [
            (at: question.endedAt, row: RPCThreadState.message(question)),
            (at: 36.0, row: RPCThreadState.message(Self.notice(.warning, "Careful", at: 36, number: 11))),
            (at: 90.0, row: RPCThreadState.message(Self.notice(.info, "Later", at: 90, number: 12))),
        ]
        let placed = RPCThreadState.interleave(rows, into: history)
        #expect(placed.map(\.entryID) == ["user:10", "assistant:20", "t:call", "q:a", "n:00000000-0000-0000-0000-000000000011",
                                          "assistant:40", "n:00000000-0000-0000-0000-000000000012"])
        #expect(placed.compactMap { $0.blocks.first?.text } == ["Careful", "Later"])
    }

    @Test func noQuestionsOrNoticesLeaveHistoryAlone() {
        #expect(RPCThreadState.interleave([(at: Double, row: NativeThreadMessage)](), into: QuestionRecordStoreTests.turn) == QuestionRecordStoreTests.turn)
    }

    @Test func aNoticeIsClippedToItsLimitOnAWholeCharacter() {
        let text = String(repeating: "é", count: RPCThreadState.noticeBytes)
        let clipped = RPCThreadState.clippedText(text, limit: RPCThreadState.noticeBytes)
        #expect(clipped.utf8.count == RPCThreadState.noticeBytes)
        #expect(clipped.allSatisfy { $0 == "é" })
        #expect(RPCThreadState.clippedText("short", limit: 64) == "short")
    }
}
