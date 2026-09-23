import SwiftUI
import AppKit
import ShepherdUI
import ShepherdRemote

/// Agent prose: block Markdown on the spec's ramp, capped at the 680pt measure.
struct Prose: View {
    let text: String
    var small = false

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.blockSpacing) {
            MarkdownBlocksView(blocks: nativeMarkdownBlocks(text), small: small)
        }
        .frame(maxWidth: AppLayout.proseMaxWidth, alignment: .leading)
    }

    /// Inline Markdown: code runs take the code face on `bgHover`. A per-run border cannot be
    /// expressed inside `Text`, so the fill alone marks the span.
    @MainActor
    static func inline(_ text: String) -> AttributedString {
        guard var attributed = try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else {
            return AttributedString(text)
        }
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].font = Font.nwMono(13)
            attributed[run.range].backgroundColor = Color.nw.bgHover
        }
        for run in attributed.runs where run.link != nil {
            attributed[run.range].foregroundColor = Color.nw.running
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

    private var textFont: Font { small || nested ? Font.nw(.body) : Font.nw(.body) }
    private var leading: CGFloat { small || nested ? NWTextStyle.body.lineSpacing : NWTextStyle.body.lineSpacing }

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
            switch block {
            case .heading(let level, let text):
                Text(Prose.inline(text)).font(level <= 2 ? Font.nwSans(small ? 15 : 17, .semibold) : Font.nw(.title))
                    .foregroundStyle(Color.nw.textPrimary).lineSpacing(3).textSelection(.enabled)
                    .padding(.top, nested ? 0 : 6)
            case .paragraph(let text):
                Text(Prose.inline(text)).font(textFont).foregroundStyle(Color.nw.textPrimary)
                    .lineSpacing(leading).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            case .quote(let text):
                Text(Prose.inline(text)).font(textFont).lineSpacing(leading).italic()
                    .foregroundStyle(Color.nw.textSecondary).textSelection(.enabled)
                    .padding(.leading, 12)
                    .overlay(alignment: .leading) { Color.nw.lineSubtle.frame(width: 2) }
            case .code(let text, let language):
                CodeBlockView(text: text, language: language)
            case .rule:
                NWHairline().padding(.vertical, 4)
            case .list(let ordered, let start, let items):
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                        HStack(alignment: .firstTextBaseline, spacing: 0) {
                            Text(ordered ? "\(start + index)." : "•")
                                .font(textFont).foregroundStyle(Color.nw.textSecondary).monospacedDigit()
                                .frame(width: 18, alignment: .leading)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(Prose.inline(item.text)).font(textFont).foregroundStyle(Color.nw.textPrimary)
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
                Text(language ?? "code").font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary)
                Spacer()
                Button(copied ? "Copied" : "Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(code, forType: .string)
                    copied = true
                    Task { try? await Task.sleep(for: .seconds(1.5)); copied = false }
                }
                .buttonStyle(NWLinkButtonStyle(color: Color.nw.textSecondary, font: Font.nw(.micro)))
                .accessibilityLabel("Copy code")
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(Color.nw.bgSunken)
            .overlay(alignment: .bottom) { NWHairline() }
            ScrollView(.horizontal) {
                highlighted(code)
                    .font(Font.nw(.mono))
                    .lineSpacing(NWTextStyle.code.lineSpacing)
                    .foregroundStyle(Color.nw.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize()
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
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
