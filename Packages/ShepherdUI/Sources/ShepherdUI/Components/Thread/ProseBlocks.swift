import SwiftUI

/// How prose reads: a reply's body, a quote inside it, or the model's thinking.
enum SHProseVoice: Equatable {
    /// Body in `textPrimary`.
    case reply
    /// Body italic in `textSecondary`.
    case quoted
    /// Italic 12.5 at 1.55 in `textSecondary` (expanded `SHThinking`); headings semibold.
    case thinking
}

/// Blocks at one level: those inside a list item, a quote or a disclosure, or a thinking block's own. Each is its own
/// `SHProseBlockView`, so a level whose last block grew draws that block alone.
///
/// The blocks are keyed by position. They belong to a block value that is never edited in place, only replaced by one that
/// grew at its end (a reply is parsed forward, and the parts of a chunk keep their ids in `SHProseChunk`), so a position is the
/// same block from one pull to the next; a nested block has no id of its own to key by.
struct SHProseBlocks<Code: SHProseCode>: View {
    let blocks: [SHProseBlock]
    /// The open fence under these blocks: the index of the block that holds it, then its path inside that block.
    var writing: [Int]? = nil
    var nested = false
    /// How deep in lists these blocks sit: each level draws its own bullet.
    var depth = 0
    var voice = SHProseVoice.reply

    var body: some View {
        ForEach(blocks.enumerated(), id: \.offset) { index, block in
            SHProseBlockView<Code>(block: block, writing: Self.writing(writing, under: index), nested: nested, depth: depth, voice: voice)
                .equatable()
        }
    }

    /// Where the open fence is inside the block at `index`, given its path among the blocks: nil when it is in another.
    static func writing(_ path: [Int]?, under index: Int) -> [Int]? {
        guard let path, path.first == index else { return nil }
        return Array(path.dropFirst())
    }
}

/// One Markdown block of agent prose, drawn by its voice at its depth. Equatable on everything it draws, so a pull that
/// leaves the block as it was does not evaluate it again.
struct SHProseBlockView<Code: SHProseCode>: View, Equatable {
    let block: SHProseBlock
    /// The open fence inside this block: `[]` when the block is the fence, else one index per level down (a quote's or a
    /// disclosure's block; a list's item, then its block); nil when none is open here.
    var writing: [Int]? = nil
    var nested = false
    var depth = 0
    var voice = SHProseVoice.reply
    @Environment(\.shProseHTML) private var pages
    @Environment(\.shProseSize) private var size
    @Environment(\.shProseHalfLeading) private var halfLeading
    @Environment(\.shProseTaskLinks) private var taskLinks
    @Environment(\.shProseFileRoot) private var fileRoot
    @Environment(\.shProseFileLinks) private var fileLinks

    nonisolated static func == (lhs: SHProseBlockView, rhs: SHProseBlockView) -> Bool {
        lhs.block == rhs.block && lhs.writing == rhs.writing && lhs.nested == rhs.nested && lhs.depth == rhs.depth && lhs.voice == rhs.voice
    }

    private var words: SHProseWords {
        SHProseWords(voice: voice, size: size, halfLeading: halfLeading, taskLinks: taskLinks, fileRoot: fileRoot, fileLinks: fileLinks)
    }

    var body: some View {
        let _ = SHRenderProbe.tick("prose.block")
        let sh = Color.sh
        let tone = voice == .reply ? sh.textPrimary : sh.textSecondary
        switch block {
        case .heading(_, let text):
            words.heading(text).foregroundStyle(tone).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, nested || voice == .thinking ? 0 : SH.Space.xs)
                .accessibilityAddTraits(.isHeader)
        case .paragraph(let text):
            words.paragraph(text).foregroundStyle(tone).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                // CSS puts half of a line's leading above and below it; `.lineSpacing` only adds it between lines, so a paragraph
                // of n lines is n line heights tall here only with it (the ProjectLead boards' `line-height: 1.6`).
                .padding(.vertical, halfLeading && voice == .reply ? SHProseWords.halfLeadingPad : 0)
        case .quote(let inner):
            VStack(alignment: .leading, spacing: SH.Space.m) {
                SHProseBlocks<Code>(blocks: inner, writing: writing, nested: true, depth: depth, voice: voice == .thinking ? .thinking : .quoted)
            }
            .padding(.leading, SH.Space.l)
            .overlay(alignment: .leading) { sh.lineStrong.frame(width: SHThreadMetrics.ruleWidth) }
        case .code(let text, let language):
            let open = writing?.isEmpty == true
            if SHMermaidBlock.renders(language: language, writing: open) {
                SHMermaidBlock(text)
            } else if SHHTMLBlock<EmptyView>.renders(language: language, pages: pages) {
                SHHTMLBlock(source: text, writing: open) { Code(code: text, language: "html", writing: open).equatable() }
            } else {
                Code(code: text, language: language, writing: open).equatable()
            }
        case .rule:
            SHHairline().padding(.vertical, SH.Space.xs)
        case .list(let ordered, let start, let items):
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                ForEach(items.enumerated(), id: \.offset) { index, item in
                    SHProseListItemView<Code>(item: item, ordered: ordered, number: start + index,
                                              writing: SHProseBlocks<Code>.writing(writing, under: index), depth: depth, voice: voice)
                        .equatable()
                }
            }
        case .table(let table):
            SHProseTableView(table: table).equatable()
        case .image(let image):
            SHProseImageView(image: image)
        case .details(let summary, let inner):
            SHProseDetails<Code>(summary: summary, blocks: inner, writing: writing, depth: depth, voice: voice)
        case .footnotes(let notes):
            SHProseFootnotes(notes: notes)
        }
    }
}

/// One item of a list: its marker, its text, and the blocks under it. Equatable, so the items of a list that grew at its end
/// are not drawn again.
struct SHProseListItemView<Code: SHProseCode>: View, Equatable {
    let item: SHProseListItem
    let ordered: Bool
    /// The item's number in an ordered list.
    let number: Int
    /// The open fence under this item: the index of the block that holds it, then its path inside that block.
    var writing: [Int]? = nil
    /// How deep in lists the list sits; the item's own blocks sit one deeper.
    var depth = 0
    var voice = SHProseVoice.reply
    @Environment(\.shProseSize) private var size
    @Environment(\.shProseHalfLeading) private var halfLeading
    @Environment(\.shProseTaskLinks) private var taskLinks
    @Environment(\.shProseFileRoot) private var fileRoot
    @Environment(\.shProseFileLinks) private var fileLinks

    nonisolated static func == (lhs: SHProseListItemView, rhs: SHProseListItemView) -> Bool {
        lhs.item == rhs.item && lhs.ordered == rhs.ordered && lhs.number == rhs.number && lhs.writing == rhs.writing
            && lhs.depth == rhs.depth && lhs.voice == rhs.voice
    }

    private var words: SHProseWords {
        SHProseWords(voice: voice, size: size, halfLeading: halfLeading, taskLinks: taskLinks, fileRoot: fileRoot, fileLinks: fileLinks)
    }

    var body: some View {
        let sh = Color.sh
        let tone = voice == .reply ? sh.textPrimary : sh.textSecondary
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // The marker ends 6pt before the item, as a list's outside marker does.
            marker
                .frame(width: SHThreadMetrics.listIndent - SH.Space.s, alignment: .trailing)
                .padding(.trailing, SH.Space.s)
            VStack(alignment: .leading, spacing: SH.Space.xs) {
                if !item.text.characters.isEmpty || item.children.isEmpty {
                    words.paragraph(item.text).foregroundStyle(tone).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                SHProseBlocks<Code>(blocks: item.children, writing: writing, nested: true, depth: depth + 1, voice: voice)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityValue(item.task.map { $0 == .done ? "Done" : "Not done" } ?? "")
    }

    /// "1.", a bullet for this depth (•, ◦, ▪), or a task's box.
    @ViewBuilder private var marker: some View {
        let sh = Color.sh
        if let task = item.task {
            Image(systemName: task == .done ? "checkmark.square.fill" : "square")
                .font(words.font)
                .foregroundStyle(task == .done ? sh.textSecondary : sh.textTertiary)
                .accessibilityHidden(true)
        } else {
            Text(ordered ? "\(number)." : SHProseWords.bullet(depth: depth))
                .font(words.font).foregroundStyle(voice == .thinking ? sh.textSecondary : sh.textPrimary).monospacedDigit()
                .fixedSize()
                .accessibilityHidden(!ordered)
        }
    }
}

/// A paragraph's, heading's or list item's words in one voice, with the environment of the view that draws them.
@MainActor struct SHProseWords {
    let voice: SHProseVoice
    let size: SHProseSize
    let halfLeading: Bool
    let taskLinks: SHProseTaskLinks?
    let fileRoot: URL?
    let fileLinks: SHProseFileLinks?

    /// CSS's half-leading for the boards' `line-height: 1.6` at the body size (`SHLeadMetrics.proseLineHeight`).
    @MainActor static var halfLeadingPad: CGFloat { SHLineSpacing.halfLeading(size: SHTextStyle.body.size, lineHeight: SHLeadMetrics.proseLineHeight) }

    var font: Font { voice == .thinking ? SHThinking.font : .sh(.body, size: size) }

    /// A paragraph's or a list item's text in this voice.
    @ViewBuilder func paragraph(_ text: AttributedString) -> some View {
        switch voice {
        case .reply, .quoted:
            if voice == .reply, halfLeading, SHPlainParagraph.isPlain(text) {
                SHPlainParagraph(text: String(text.characters), size: size, lineSpacing: SHTextStyle.body.lineSpacing(size))
            } else if voice == .reply, let taskLinks, SHProseTaskLinks.hasReference(text) {
                SHTaskChipText.text(text, links: taskLinks, size: size).shText(.body, size: size)
                    .textRenderer(SHTaskChipRenderer(halfLeading: Self.halfLeadingPad))
                    .modifier(SHTaskChipPressTargets(halfLeading: Self.halfLeadingPad))
            } else {
                // Outside a Project conversation a task reference is only words: nothing opens it, the system included.
                let shown = SHProseTaskLinks.hasReference(text) ? SHProseTaskLinks.inert(text) : text
                SHProseFileLinks.prose(shown, root: fileRoot, actions: fileLinks).shText(.body, size: size).italic(voice == .quoted)
                    .modifier(SHFileLinkTargets(actions: SHProseFileLinks.targets(shown, root: fileRoot, actions: fileLinks)))
            }
        case .thinking: Text(text).font(SHThinking.font).italic().lineSpacing(SHThinking.lineSpacing)
        }
    }

    @ViewBuilder func heading(_ text: AttributedString) -> some View {
        switch voice {
        case .reply, .quoted:
            SHProseFileLinks.prose(text, root: fileRoot, actions: fileLinks).font(.sh(.headline, size: size)).lineSpacing(SHTextStyle.headline.lineSpacing(size))
                .modifier(SHFileLinkTargets(actions: SHProseFileLinks.targets(text, root: fileRoot, actions: fileLinks)))
        case .thinking: Text(text).font(SHThinking.headingFont).italic().lineSpacing(SHThinking.lineSpacing)
        }
    }

    /// Bullets alternate by depth, as nested lists read in print.
    static func bullet(depth: Int) -> String {
        // The square asks for its text form: iOS would draw it as a large emoji square.
        ["•", "◦", "▪\u{FE0E}"][depth % 3]
    }
}
