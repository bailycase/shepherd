import SwiftUI

#if os(macOS)
import AppKit

/// A Project paragraph of plain words, set by the text system with no line-break strategy.
///
/// The boards wrap as CSS does, filling each line. SwiftUI's `Text` was observed to break "…a partner would / embed." as
/// "…a partner / would embed." at the same width and font, so a plain paragraph in a Project thread is an `NSTextField` label whose
/// paragraph style sets `lineBreakStrategy = []` (selectable, one static-text accessibility node, as `Text` is). Paragraphs with links,
/// task chips, code or emphasis keep `Text` and its chip hit targets.
struct NWPlainParagraph: View {
    let text: String
    let size: NWProseSize
    let lineSpacing: CGFloat
    @Environment(\.self) private var environment

    var body: some View {
        let scale = ThemeStore.shared.textScale
        let color = Color.nw.textPrimary.resolve(in: environment)
        NWPlainParagraphLabel(text: text, points: (NWTextStyle.body.size - size.step) * scale, lineSpacing: lineSpacing,
                              color: NSColor(cgColor: color.cgColor) ?? .labelColor)
    }

    /// The words are one run with nothing the styler added (no link, font, color, emphasis, code or strikethrough).
    static func isPlain(_ text: AttributedString) -> Bool {
        text.runs.count == 1 && text.runs.allSatisfy {
            $0.link == nil && $0.font == nil && $0.foregroundColor == nil && $0.backgroundColor == nil && $0.underlineStyle == nil
                && $0.strikethroughStyle == nil && $0.baselineOffset == nil && $0.inlinePresentationIntent == nil
        }
    }
}

private struct NWPlainParagraphLabel: NSViewRepresentable {
    let text: String
    let points: CGFloat
    let lineSpacing: CGFloat
    let color: NSColor

    func makeNSView(context: Context) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: "")
        label.isSelectable = true
        label.drawsBackground = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    func updateNSView(_ label: NSTextField, context: Context) {
        let style = NSMutableParagraphStyle()
        style.lineBreakStrategy = []
        style.lineSpacing = lineSpacing
        let font = NSFont(name: NWFonts.postScriptName(mono: false, weight: .regular), size: points) ?? .systemFont(ofSize: points)
        let attributed = NSAttributedString(string: text, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: style])
        if label.attributedStringValue != attributed { label.attributedStringValue = attributed }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView label: NSTextField, context: Context) -> CGSize? {
        // A nil or infinite width is the paragraph on one line; a finite one wraps at it. The label measures itself either way.
        let width = proposal.width.flatMap { $0.isFinite ? $0 : nil }
        let fitted = label.sizeThatFits(NSSize(width: width ?? .greatestFiniteMagnitude, height: .greatestFiniteMagnitude))
        return CGSize(width: width ?? fitted.width.rounded(.up), height: fitted.height.rounded(.up))
    }
}
#else
struct NWPlainParagraph: View {
    let text: String
    let size: NWProseSize
    let lineSpacing: CGFloat
    var body: some View { Text(text).nwText(.body, size: size) }
    static func isPlain(_ text: AttributedString) -> Bool { false }
}
#endif
