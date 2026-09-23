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

/// Inline code in a subagent's words (a question, a result): backtick spans become mono on
/// `bgHover`. A plain scan, no Markdown parse; an unpaired backtick stays literal.
public enum NWInlineMarkup {
    /// The text split into plain and code spans, in order; empty spans are dropped.
    public static func spans(_ text: String) -> [(text: String, code: Bool)] {
        var spans: [(String, Bool)] = []
        var rest = Substring(text)
        while let open = rest.firstIndex(of: "`"),
              let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            let before = rest[..<open]
            let code = rest[rest.index(after: open)..<close]
            if !before.isEmpty { spans.append((String(before), false)) }
            if !code.isEmpty { spans.append((String(code), true)) }
            rest = rest[rest.index(after: close)...]
        }
        if !rest.isEmpty { spans.append((String(rest), false)) }
        return spans
    }

    @MainActor public static func attributed(_ text: String, codeSize: CGFloat = 11.5) -> AttributedString {
        var result = AttributedString()
        for span in spans(text) {
            var part = AttributedString(span.text)
            if span.code {
                part.font = .nwMono(codeSize)
                part.backgroundColor = .nw.bgHover
            }
            result += part
        }
        return result
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
