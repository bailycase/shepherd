import SwiftUI

/// The subagent glyph (`arrow.triangle.branch`), in its run's state color.
public struct SHBranchGlyph: View {
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
        Image(systemName: SHGlyph.gitBranch.symbolName)
            .font(.system(size: size - 3, weight: .medium))
            .foregroundStyle(color ?? state.color)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// A subagent's words (a question, a result) as inline Markdown: emphasis and links as the thread
/// shows them, code spans mono on `bgHover`, links in `running`. Text that does not parse stays
/// plain.
public enum SHInlineMarkup {
    @MainActor public static func attributed(_ text: String, codeSize: CGFloat = 11.5) -> AttributedString {
        guard var result = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in result.runs {
            if run.inlinePresentationIntent?.contains(.code) == true {
                result[run.range].font = .shMono(codeSize)
                result[run.range].backgroundColor = .sh.bgHover
            }
            if run.link != nil { result[run.range].foregroundColor = .sh.running }
        }
        return result
    }
}

/// `SHInlineMarkup` text that parses only when its text changes, not on every render of the
/// view around it (a card's reply keystrokes, an inspector's polls).
struct SHInlineText: View, Equatable {
    let text: String
    let codeSize: CGFloat

    nonisolated static func == (a: SHInlineText, b: SHInlineText) -> Bool {
        a.text == b.text && a.codeSize == b.codeSize
    }

    var body: some View {
        Text(SHInlineMarkup.attributed(text, codeSize: codeSize))
    }
}

/// The mono caps label over a brief's blocks ("GOAL", "RESULT").
struct SHBriefLabel: View {
    let text: String
    var color: Color?

    var body: some View {
        Text(text)
            .font(.shMono(10))
            .textCase(.uppercase)
            .tracking(0.5)
            .foregroundStyle(color ?? .sh.textTertiary)
            .accessibilityAddTraits(.isHeader)
    }
}
