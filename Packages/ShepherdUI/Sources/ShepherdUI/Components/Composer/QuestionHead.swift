import SwiftUI

// The head every Mac question starts with (QuestionAsk, QuestionPick, QuestionStates): "Agent is
// asking" in lantern, then Hide the question. Hidden, a question shrinks to one line
// (QuestionStates › hidden, in `NWQuestionDockHidden`) that still holds the composer's place.

public enum NWQuestionHeadMetrics {
    public static let height: CGFloat = 26
    public static let spacing: CGFloat = 7
    public static let glyph: CGFloat = 13
    public static let hideButton: CGFloat = 26
    /// The hidden line's glyph and the room between its parts.
    public static let hiddenGlyph: CGFloat = 14
    public static let hiddenSpacing: CGFloat = 10
}

/// The agent's glyph in lantern: a question mark.
struct NWQuestionAskerGlyph: View {
    let size: CGFloat

    var body: some View {
        Image(systemName: "questionmark.circle")
            .font(.system(size: size, weight: .medium))
            .foregroundStyle(Color.nw.lanternText)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The head: a question mark and "Agent is asking" in `lanternText`, then "1 / N" when several
/// questions wait, and Hide the question.
public struct NWQuestionHead: View {
    /// What every question says it is: the agent's own, since a subagent asks its parent.
    public static let title = "Agent is asking"

    let count: Int
    let hideHelp: String
    let hide: () -> Void

    /// `hideHelp`: Hide the question's tooltip, with its key when it has one.
    public init(count: Int = 1, hideHelp: String = "Hide the question", hide: @escaping () -> Void) {
        self.count = count
        self.hideHelp = hideHelp
        self.hide = hide
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NWQuestionHeadMetrics.spacing) {
            HStack(spacing: NWQuestionHeadMetrics.spacing) {
                NWQuestionAskerGlyph(size: NWQuestionHeadMetrics.glyph)
                Text(Self.title).font(.nwSans(12, .semibold)).foregroundStyle(nw.lanternText).lineLimit(1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.title)
            .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.m)
            if count > 1 {
                Text("1 / \(count)").font(.nw(.micro)).foregroundStyle(nw.textTertiary).monospacedDigit()
                    .nwContentTransition(.numeric())
                    .nwTransition(.content)
            }
            Button(action: hide) { Image(systemName: "chevron.down") }
                .buttonStyle(.nwIcon(size: NWQuestionHeadMetrics.hideButton))
                .help(hideHelp)
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
    let question: String
    let showHelp: String
    let show: () -> Void

    public init(question: String, showHelp: String = "Show the question", show: @escaping () -> Void) {
        self.question = question
        self.showHelp = showHelp
        self.show = show
    }

    public var body: some View {
        HStack(spacing: NWQuestionHeadMetrics.hiddenSpacing) {
            NWQuestionAskerGlyph(size: NWQuestionHeadMetrics.hiddenGlyph)
            Text(NWProseInline.attributed(question)).font(.nw(.headline)).foregroundStyle(Color.nw.textPrimary)
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityLabel("\(NWQuestionHead.title): \(question)")
            Button("Answer", action: show)
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Answer the question")
            Button(action: show) { Image(systemName: "chevron.up") }
                .buttonStyle(.nwIcon(size: NWQuestionHeadMetrics.hideButton))
                .help(showHelp)
                .accessibilityLabel("Show the question")
        }
        .frame(minHeight: NWQuestionHeadMetrics.height)
        .accessibilityElement(children: .contain)
    }
}
