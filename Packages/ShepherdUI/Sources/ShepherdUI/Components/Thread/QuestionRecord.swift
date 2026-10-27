import SwiftUI

// What the thread keeps of a question once it is answered (QuestionAnswered, QuestionStates ›
// QuestionRecord): where pi asked, one quiet line with the question, and the answer as the
// user's bubble. pi's turn carries on under it.

public enum SHQuestionRecordMetrics {
    public static let glyph: CGFloat = 12
    /// Between the line's glyph, "Agent asked:" and the question.
    public static let spacing: CGFloat = 7
    /// On touch the question wraps rather than truncating at a phone's width.
    public static let touchQuestionLines = 3
}

/// The record: a 12pt question glyph, "Agent asked:" in `textTertiary`, and the question in
/// `textSecondary` medium on one line; 8pt below, the answer as an `SHUserBubble` (the option's
/// title in semibold, text under it) with its time and "answered" beneath, shown like every
/// bubble's time (`revealed`). Not answered, the line ends "· not answered" and has no bubble.
/// On the Mac the line is one line, the question truncating; on touch the question wraps to
/// three lines, since a phone's width would leave only its first words.
public struct SHQuestionRecord: View {
    let question: String
    let title: String?
    let text: String?
    let answered: Bool
    let timestamp: String?
    let revealed: Bool

    public init(question: String, title: String? = nil, text: String? = nil, answered: Bool, timestamp: String? = nil,
                revealed: Bool = false) {
        self.question = question
        self.title = title
        self.text = text
        self.answered = answered
        self.timestamp = timestamp
        self.revealed = revealed
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(alignment: .firstTextBaseline, spacing: SHQuestionRecordMetrics.spacing) {
                Image(systemName: "questionmark.circle")
                    .font(.system(size: SHQuestionRecordMetrics.glyph))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
                Text("Agent asked:").foregroundStyle(sh.textTertiary).layoutPriority(1)
                #if os(iOS)
                // Wrapping, the "not answered" rides the question's last line.
                let asked = Text(question).fontWeight(.medium).foregroundStyle(sh.textSecondary)
                let unanswered = Text(answered ? "" : "\u{00A0} ·\u{00A0}not answered").foregroundStyle(sh.textTertiary)
                Text("\(asked)\(unanswered)")
                    .lineLimit(SHQuestionRecordMetrics.touchQuestionLines).truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                #else
                Text(question).fontWeight(.medium).foregroundStyle(sh.textSecondary)
                    .lineLimit(1).truncationMode(.tail)
                    .help(question)
                if !answered {
                    Text("· not answered").foregroundStyle(sh.textTertiary).layoutPriority(1)
                }
                #endif
            }
            .font(.sh(.ui, weight: .regular))
            .accessibilityElement(children: .combine)
            if answered {
                SHUserBubble(text ?? "", title: title, timestamp: timestamp, revealed: revealed)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
