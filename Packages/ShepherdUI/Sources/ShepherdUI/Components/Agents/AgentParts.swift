import SwiftUI

/// The subagent glyph (`arrow.triangle.branch`), in its run's state color.
public struct NWBranchGlyph: View {
    let state: AgentState
    let size: CGFloat
    let color: Color?

    /// `color` overrides the state's color.
    public init(_ state: AgentState, size: CGFloat = 14, color: Color? = nil) {
        self.state = state
        self.size = size
        self.color = color
    }

    public var body: some View {
        Image(systemName: "arrow.triangle.branch")
            .font(.system(size: size - 3, weight: .medium))
            .foregroundStyle(color ?? state.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A subagent's words (a question, a result) as inline Markdown: emphasis and links as the thread
/// shows them, code spans mono on `bgHover`, links in `running`. Text that does not parse stays
/// plain.
public enum NWInlineMarkup {
    @MainActor public static func attributed(_ text: String, codeSize: CGFloat = 11.5) -> AttributedString {
        guard var result = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .nwMono(codeSize)
                result[run.range].backgroundColor = .nw.bgHover
            }
            if run.link != nil { result[run.range].foregroundColor = .nw.running }
        }
        return result
    }
}

/// `NWInlineMarkup` text that parses only when its text changes, not on every render of the
/// view around it (a card's reply keystrokes, an inspector's polls).
struct NWInlineText: View, Equatable {
    let text: String
    let codeSize: CGFloat

    nonisolated static func == (a: NWInlineText, b: NWInlineText) -> Bool {
        a.text == b.text && a.codeSize == b.codeSize
    }

    var body: some View {
        Text(NWInlineMarkup.attributed(text, codeSize: codeSize))
    }
}

/// The mono caps label over a brief's blocks ("GOAL", "RESULT").
struct NWBriefLabel: View {
    let text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.nwMono(10))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(color ?? .nw.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}
