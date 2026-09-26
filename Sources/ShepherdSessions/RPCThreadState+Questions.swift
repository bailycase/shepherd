import Foundation
import ShepherdProtocol

/// The record of pi's questions (QuestionAnswered): once a question ends (answered, dismissed,
/// or its timeout passed), the thread keeps it where pi asked, as a row of role "question". pi's
/// session holds no UI dialogs, so the host keeps them per pi session beside the origins
/// (`ThreadOriginStore`) and places them into pi's history on every refresh.
extension RPCThreadState {
    /// Records how `dialog` ended: `answer` is what the user sent, nil when its timeout passed.
    /// A question that could not be shown here (over the size limit), or one asked in the session
    /// before this one, is not recorded.
    func recordQuestion(_ dialog: NativeThreadDialog, answer: NativeDialogAnswer?) {
        // Asked before the session changed (`/new`, `/resume`), it belongs to the one it left.
        guard let asked = askedAt.removeValue(forKey: dialog.id), dialog.unavailable == nil else { return }
        let now = Date().timeIntervalSince1970 * 1000
        var record = NativeQuestionRecord(kind: dialog.kind, question: Self.clippedText(dialog.title), outcome: .expired,
                                          askedAt: asked)
        switch answer {
        case .select(let value), .input(let value), .editor(let value):
            record.outcome = .answered
            record.answer = Self.clippedText(value)
        case .confirm(let value):
            record.outcome = .answered
            record.confirmed = value
        case .cancel:
            record.outcome = .dismissed
        case nil:
            record.outcome = .expired
        }
        // A timeout ended it when pi gave up, which is where pi carried on.
        let ended = answer == nil ? dialog.timeout.map { record.askedAt + $0 } ?? now : now
        let question = ThreadOriginStore.Question(id: dialog.id, record: record, endedAt: min(ended, now))
        questions.removeAll { $0.id == dialog.id }
        questions.append(question)
        if questions.count > ThreadOriginStore.questionLimit { questions.removeFirst(questions.count - ThreadOriginStore.questionLimit) }
        saveOrigins()
        live.removeAll { $0.kind == .question(dialog.id) }
        live.append(LiveItem(kind: .question(dialog.id), value: Self.message(question), raw: nil, ended: true))
    }

    /// A question's row: "q:<dialog id>", stamped when it ended.
    static func message(_ question: ThreadOriginStore.Question) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "q:\(question.id)", role: "question", blocks: [], timestamp: question.endedAt,
                            question: question.record)
    }

    /// pi's history with the session's questions placed where pi asked them: each before the
    /// first message that started once the question ended (a tool call counts from its
    /// start), so it lands after the call that asked it and before pi's next reply, where the
    /// live thread showed it. A question from before a compaction's kept messages went with
    /// what was summarized.
    static func interleave(_ questions: [ThreadOriginStore.Question], into history: [NativeThreadMessage]) -> [NativeThreadMessage] {
        guard !questions.isEmpty else { return history }
        let ordered = questions.sorted { $0.endedAt < $1.endedAt }
        let compacted = history.contains { $0.role == "compactionSummary" }
        var result: [NativeThreadMessage] = []
        result.reserveCapacity(history.count + ordered.count)
        var next = 0
        var placedAny = false
        for row in history {
            let start = row.role == "toolResult" ? row.startedAt ?? row.timestamp : row.timestamp
            if let start {
                while next < ordered.count, ordered[next].endedAt <= start {
                    if placedAny || !compacted { result.append(message(ordered[next])) }
                    next += 1
                }
            }
            result.append(row)
            placedAny = true
        }
        while next < ordered.count {
            result.append(message(ordered[next]))
            next += 1
        }
        return result
    }

    /// Text a record keeps: up to the thread's per-message limit.
    static func clippedText(_ text: String) -> String {
        let raw = Array(text.utf8)
        guard raw.count > textLimit else { return text }
        var end = textLimit
        while end > 0, raw[end] & 0xC0 == 0x80 { end -= 1 }
        return String(decoding: raw[0..<end], as: UTF8.self)
    }
}
