#if os(macOS)
import AppKit
import SwiftUI

/// AppKit lays out selectable code without SwiftUI resolving every syntax run on each chunk.
struct NWNativeCodeText: NSViewRepresentable {
    let code: String
    let highlighted: AttributedString?
    let scale: CGFloat
    let lineSpacing: CGFloat
    @Environment(\.colorScheme) private var colorScheme

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField(labelWithString: "")
        field.isSelectable = true
        field.maximumNumberOfLines = 0
        field.lineBreakMode = .byClipping
        field.cell?.wraps = false
        field.cell?.isScrollable = false
        return field
    }

    func updateNSView(_ field: NSTextField, context: Context) {
        field.appearance = NSAppearance(named: colorScheme == .dark ? .darkAqua : .aqua)
        let points = NWTextStyle.code.size * scale
        let font = NSFont(name: NWFonts.postScriptName(mono: true, weight: .regular), size: points)
            ?? .monospacedSystemFont(ofSize: points, weight: .regular)
        if field.font != font { field.font = font }
        let value = Self.attributedCode(code, highlighted: highlighted, font: font, lineSpacing: lineSpacing)
        if field.attributedStringValue != value { field.attributedStringValue = value }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSTextField, context: Context) -> CGSize? {
        nsView.intrinsicContentSize
    }

    static func attributedCode(_ code: String, highlighted: AttributedString?, font: NSFont,
                               lineSpacing: CGFloat) -> NSAttributedString {
        let text = highlighted.map { NSMutableAttributedString(attributedString: NSAttributedString($0)) }
            ?? NSMutableAttributedString(string: code)
        let range = NSRange(location: 0, length: text.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byClipping
        text.addAttributes([.font: font, .foregroundColor: NSColor(Color.nw.textPrimary),
                            .paragraphStyle: paragraph], range: range)
        let key = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name)
        var colors: [Color: NSColor] = [:]
        text.enumerateAttribute(key, in: range) { value, run, _ in
            guard let color = value as? Color else { return }
            let native = colors[color] ?? NSColor(color)
            colors[color] = native
            text.addAttribute(.foregroundColor, value: native, range: run)
        }
        text.removeAttribute(key, range: range)
        return text
    }
}
#endif
