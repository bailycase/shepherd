import SwiftUI
import AppKit
import ShepherdDesign
import ShepherdRemote

/// Agent prose: block Markdown on the spec's ramp, capped at the 680pt measure.
struct Prose: View {
    let text: String
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: Metrics.blockSpacing) {
            MarkdownBlocksView(blocks: nativeMarkdownBlocks(text), small: small)
        }
        .frame(maxWidth: Metrics.proseMaxWidth, alignment: .leading)
    }

    /// Inline Markdown: code runs take the code face on `bgHover`. A per-run border cannot be
    /// expressed inside `Text`, so the fill alone marks the span.
    @MainActor
    static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = Fonts.mono(13)
            attributed[run.range].backgroundColor = Tokens.bgHover
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Tokens.accentText
        }
        return attributed
    }
}

/// Headings 15/600, paragraphs body 15 ×1.6, lists with an 18pt marker column (one nested
/// level), quotes on a 2pt rule, fenced code in `CodeBlockView`.
struct MarkdownBlocksView: View {
    let blocks: [NativeMarkdownBlock]
    var small = false
    var nested = false

    private var textFont: Font { small || nested ? Fonts.bodySmall : Fonts.body }
    private var leading: CGFloat { small || nested ? Fonts.bodySmallLeading : Fonts.bodyLeading }

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(let level, let text):
                Text(Prose.inline(text)).font(level <= 2 ? Fonts.sans(small ? 15 : 17, .semibold) : Fonts.title)
                    .foregroundStyle(Tokens.text).lineSpacing(3).textSelection(.enabled)
                    .padding(.top, nested ? 0 : 6)
            case .paragraph(let text):
                Text(Prose.inline(text)).font(textFont).foregroundStyle(Tokens.text)
                    .lineSpacing(leading).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .quote(let text):
                Text(Prose.inline(text)).font(textFont).lineSpacing(leading).italic()
                    .foregroundStyle(Tokens.textSecondary).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Tokens.border.frame(width: 2) }
            case .code(let text, let language):
                CodeBlockView(text: text, language: language)
            case .rule:
                Tokens.border.frame(height: 1).padding(.vertical, 4)
            case .list(let ordered, let start, let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(ordered ? "\(start + index)." : "•")
                                .font(textFont).foregroundStyle(Tokens.textTertiary).monospacedDigit()
                                .frame(width: 18, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Prose.inline(item.text)).font(textFont).foregroundStyle(Tokens.text)
                                    .lineSpacing(leading).textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                MarkdownBlocksView(blocks: item.children, small: small, nested: true)
                            }
                        }
                    }
                }
            }
        }
    }
}

/// A fenced code block (Components board): 28pt header on `bgMuted` with the language and Copy,
/// code at 12.5 mono ×1.55 on `bgSurface`, syntax colored when the language is known.
struct CodeBlockView: View {
    let text: String
    var language: String?
    @State private var copied = false

    var body: some View {
        let code = text.trimmingCharacters(in: .newlines)
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(language ?? "code").font(Fonts.micro).foregroundStyle(Tokens.textTertiary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(LinkButtonStyle(color: Tokens.textTertiary, font: Fonts.micro))
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Tokens.bgMuted)
            .overlay(alignment: .bottom) { Tokens.borderSubtle.frame(height: 1) }
            ScrollView(.horizontal, showsIndicators: false) {
                highlighted(code)
                    .font(Fonts.code)
                    .lineSpacing(Fonts.outputLeading)
                    .foregroundStyle(Tokens.text)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.bgSurface, in: RoundedRectangle(cornerRadius: Radius.md))
        .clipShape(RoundedRectangle(cornerRadius: Radius.md))
        .overlay(RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Tokens.border, lineWidth: 1))
    }

    private func highlighted(_ code: String) -> Text {
        guard let path = CodeHighlight.path(forFenceLanguage: language) else { return Text(code) }
        let lines = code.components(separatedBy: "\n")
        let colored = CodeHighlight.highlightLines(lines, path: path, style: .theme)
        guard colored.count == lines.count else { return Text(code) }
        var joined = AttributedString()
        for (index, line) in colored.enumerated() {
            if index > 0 { joined += AttributedString("\n") }
            joined += line
        }
        return Text(joined)
    }
}
