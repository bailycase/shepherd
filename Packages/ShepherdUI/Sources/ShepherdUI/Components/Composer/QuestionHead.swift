import SwiftUI

// The head every Mac question starts with (QuestionAsk, QuestionPick, QuestionStates): who is
// asking in lantern, then Hide the question. The agent's own question and a subagent's share it;
// only the glyph and the name differ. Hidden, a question shrinks to one line
// (QuestionStates › hidden) that still holds the composer's place.

public enum NWQuestionHeadMetrics {
    public static let height: CGFloat = 26
    public static let spacing: CGFloat = 7
    public static let glyph: CGFloat = 13
    public static let hideButton: CGFloat = 26
    /// The hidden line's glyph and the room between its parts.
    public static let hiddenGlyph: CGFloat = 14
    public static let hiddenSpacing: CGFloat = 10
}

/// Who asks: the agent itself, or one of its subagents by name.
public enum NWQuestionAsker: Equatable, Sendable {
    case agent
    case subagent(String)

    /// "Agent is asking", or "reviewer is asking" for a subagent.
    public var title: String {
        switch self {
        case .agent: return "Agent is asking"
        case .subagent(let name):
            let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(name.isEmpty ? "Subagent" : name) is asking"
        }
    }
}

/// The asker's glyph in lantern: a question mark for the agent, the branch for a subagent.
struct NWQuestionAskerGlyph: View {
    let asker: NWQuestionAsker
    let size: CGFloat

    var body: some View {
        let color = Color.nw.lanternText
        switch asker {
        case .agent:
            Image(systemName: "questionmark.circle")
                .font(.system(size: size, weight: .medium))
                .foregroundStyle(color)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        case .subagent:
            NWBranchGlyph(.attention, size: size, color: color)
        }
    }
}

/// The head: the asker's glyph and "Agent is asking" in `lanternText`, then "1 / N" when several
/// questions wait, and Hide the question.
public struct NWQuestionHead: View {
    let asker: NWQuestionAsker
    let count: Int
    let hide: () -> Void

    public init(_ asker: NWQuestionAsker, count: Int = 1, hide: @escaping () -> Void) {
        self.asker = asker
        self.count = count
        self.hide = hide
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWQuestionHeadMetrics.spacing) {
            HStack(spacing: NWQuestionHeadMetrics.spacing) {
                NWQuestionAskerGlyph(asker: asker, size: NWQuestionHeadMetrics.glyph)
                Text(asker.title).font(.nwSans(12, .semibold)).foregroundStyle(nw.lanternText).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(asker.title)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.m)
            if count > 1 {
                Text("1 / \(count)").font(.nw(.micro)).foregroundStyle(nw.textTertiary).monospacedDigit()
                    .nwContentTransition(.numeric())
                    .nwTransition(.content)
            }
            Button(action: hide) { Image(systemName: "chevron.down") }
                .buttonStyle(.nwIcon(size: NWQuestionHeadMetrics.hideButton))
                .help("Hide the question")
                .accessibilityLabel("Hide the question")
        }
        // Another question queuing behind this one counts up.
        .nwAnimation(.content, value: count)
        .frame(height: NWQuestionHeadMetrics.height)
    }
}

/// A hidden question: one line with its glyph, the question (truncating), a small Answer and
/// Show the question, either of which brings the whole question back.
public struct NWQuestionHiddenLine: View {
    let asker: NWQuestionAsker
    let question: String
    let show: () -> Void

    public init(_ asker: NWQuestionAsker, question: String, show: @escaping () -> Void) {
        self.asker = asker
        self.question = question
        self.show = show
    }

    public var body: some View {
        HStack(spacing: NWQuestionHeadMetrics.hiddenSpacing) {
            NWQuestionAskerGlyph(asker: asker, size: NWQuestionHeadMetrics.hiddenGlyph)
            Text(question).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(asker.title): \(question)")
            Button("Answer", action: show)
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Answer the question")
            Button(action: show) { Image(systemName: "chevron.up") }
                .buttonStyle(.nwIcon(size: NWQuestionHeadMetrics.hideButton))
                .help("Show the question")
                .accessibilityLabel("Show the question")
        }
        .frame(minHeight: NWQuestionHeadMetrics.height)
        .accessibilityElement(children: .contain)
    }
}
