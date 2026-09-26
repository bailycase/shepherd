import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// What the thread keeps of pi's questions (QuestionAnswered): once a question ends, a row of
/// role "question" where pi asked it, served to every client and kept per pi session across a
/// relaunch. The stub's "question" turn asks from an `ask_user` tool call and waits.
@Suite("Question records", .integrationTimeLimit)
struct QuestionRecordTests {
    /// Sends "question" (or "question-timeout") and returns the snapshot once pi asks.
    private func ask(_ pi: PiAgent, _ prompt: String = "question") async throws -> NativeThreadSnapshot {
        _ = try await pi.send(prompt, from: try await pi.ready())
        return try await pi.snapshot("pi to ask") { !$0.dialogs.isEmpty }
    }

    private func answer(_ pi: PiAgent, _ answer: NativeDialogAnswer, from s: NativeThreadSnapshot) async throws -> NativeThreadResult {
        let dialog = try #require(s.dialogs.first)
        return try await pi.request(.answer(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(),
                                            dialogID: dialog.id, answer: answer))
    }

    /// Once the run settles with the question recorded.
    private func settled(_ pi: PiAgent) async throws -> NativeThreadSnapshot {
        try await pi.snapshot("the run to settle with its question recorded") { s in
            !s.running && s.messages.contains { $0.question != nil } && s.messages.last?.role == "assistant"
        }
    }

    @Test func anAnsweredQuestionStaysWherePiAskedIt() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let asking = try await ask(pi)
        #expect(!(asking.messages + asking.provisional).contains { $0.question != nil }, "nothing is recorded while pi waits")
        let dialog = try #require(asking.dialogs.first)
        let option = try #require(dialog.options?.first)
        #expect(try await answer(pi, .select(value: option), from: asking).failureCode == nil)

        let done = try await settled(pi)
        let turn = Array(done.messages.suffix(5))
        #expect(turn.map(\.role) == ["user", "assistant", "toolResult", "question", "assistant"],
                "after the call that asked, before pi's next reply")
        let row = turn[3]
        #expect(row.entryID == "q:\(dialog.id)")
        #expect(row.blocks.isEmpty, "older clients have nothing to draw")
        let record = try #require(row.question)
        #expect(record == NativeQuestionRecord(kind: .select, question: "How should I handle Horizon's uncommitted edits?",
                                               answer: option, outcome: .answered, askedAt: record.askedAt))
        let answeredAt = try #require(row.timestamp)
        #expect(record.askedAt > 0 && record.askedAt <= answeredAt)
        #expect(turn[4].blocks.first?.text == "Going with Compare, keep what's unique, then go through GitHub (Recommended)")
        #expect(done.provisional.isEmpty, "the live row moved into history under the same id")

        let presented = nativeTurnPresentation(nativeTurns(done.messages).last?.messages ?? [], live: false)
        #expect(presented.items.contains { $0 == .question(NativeQuestionRecordRow(
            id: row.entryID, question: record.question, title: "Compare, keep what's unique, then go through GitHub",
            answered: true, answeredAt: answeredAt)) })
    }

    @Test(arguments: [(Optional(NativeDialogAnswer.cancel), "question", NativeQuestionRecord.Outcome.dismissed),
                      (Optional<NativeDialogAnswer>.none, "question-timeout", .expired)])
    func aQuestionNobodyAnsweredIsRecordedAsNotAnswered(_ reply: NativeDialogAnswer?, prompt: String,
                                                       outcome: NativeQuestionRecord.Outcome) async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let asking = try await ask(pi, prompt)
        if let reply { #expect(try await answer(pi, reply, from: asking).failureCode == nil) }
        let done = try await settled(pi)
        let record = try #require(done.messages.first { $0.question != nil }?.question)
        #expect(record.outcome == outcome && record.answer == nil && record.confirmed == nil)
        #expect(done.dialogs.isEmpty)
    }

    /// Stop refuses the question pi waits on (the Mac's dock has no Dismiss); the thread
    /// records it as not answered, where pi asked it.
    @Test func aQuestionRefusedByStopIsRecordedAsNotAnswered() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        let asking = try await ask(pi)
        let dialog = try #require(asking.dialogs.first)
        let op = UUID()
        #expect(try await pi.request(.abort(expectedSessionID: asking.piSessionID, generation: asking.generation,
                                            operationID: op)) == .accepted(operationID: op))

        let done = try await settled(pi)
        let turn = Array(done.messages.suffix(5))
        #expect(turn.map(\.role) == ["user", "assistant", "toolResult", "question", "assistant"])
        #expect(turn[3].entryID == "q:\(dialog.id)")
        let record = try #require(turn[3].question)
        #expect(record.outcome == .dismissed && record.answer == nil && record.confirmed == nil)
        #expect(done.dialogs.isEmpty)
    }

    /// A question asked before pi moved to another session (`/new`, `/resume`) belongs to the
    /// one it left, so answering it records nothing in the new one.
    @Test func aQuestionFromTheSessionBeforeIsNotRecordedInTheNextOne() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let pi = try await PiAgent.launch(on: h)
        _ = try await pi.send("select-newsession", from: try await pi.ready())
        let switched = try await pi.snapshot("the new session with the question still open") {
            $0.piSessionID == "stub-session-2" && !$0.dialogs.isEmpty
        }
        #expect(try await answer(pi, .select(value: "Allow"), from: switched).failureCode == nil)

        let after = try await pi.snapshot("the question answered") { $0.dialogs.isEmpty }
        #expect(!(after.messages + after.provisional).contains { $0.question != nil })
    }

    @Test func aRemoteClientSeesTheRecord() async throws {
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host)
        let asking = try await ask(pi)
        let option = try #require(asking.dialogs.first?.options?.last)
        _ = try await answer(pi, .select(value: option), from: asking)
        let local = try await settled(pi)

        let client = try await remote.typed()
        let s = try #require(try await client.nativeThread(agentID: pi.agent.id, request: .snapshot()).snapshotValue)
        let row = try #require(s.messages.first { $0.question != nil })
        #expect(row == local.messages.first { $0.question != nil })
        #expect(row.question?.answer == "Leave Horizon alone")
    }

    /// pi's session keeps no UI dialogs; the host keeps its records per pi session beside the
    /// origins, and a relaunch places them again where pi asked.
    @Test func theRecordSurvivesARelaunch() async throws {
        let dir = try makeScratchDirectory("relaunch")
        let messages = dir.appendingPathComponent("pi-session.json").path
        var h = try ScratchServer(dir: dir)
        var pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": messages])
        let asking = try await ask(pi)
        _ = try await answer(pi, .select(value: try #require(asking.dialogs.first?.options?.first)), from: asking)
        let before = try await settled(pi)
        let row = try #require(before.messages.first { $0.question != nil })
        h.stop(keepFiles: true)

        h = try ScratchServer(dir: dir)
        defer { h.stop() }
        pi = try await PiAgent.launch(on: h, env: ["STUB_PI_MESSAGES_FILE": messages])
        let after = try await pi.snapshot("the resumed history") { s in s.messages.contains { $0.entryID == row.entryID } }
        #expect(after.messages.suffix(5).map(\.entryID) == before.messages.suffix(5).map(\.entryID), "in the same place")
        #expect(after.messages.first { $0.entryID == row.entryID } == row)
    }
}
