import SwiftUI

/// One line of a file in the viewer: its number, its colored text, and whether this change added it.
public struct SHFileViewerLine: Identifiable, Equatable, Sendable {
    public let number: Int
    public let text: AttributedString
    public let added: Bool

    public var id: Int { number }

    public init(number: Int, text: AttributedString, added: Bool) {
        self.number = number
        self.text = text
        self.added = added
    }
}

/// A file an agent edited, open over the thread (OutsideFileE): a sheet on `sheetScrim` with ‹ "2 of 2" ›, the file's
/// folder (tertiary) and name, its diff stat, a File | Diff switch, Open in editor and close, then the file or its diff, and
/// a footer naming where the shown text comes from beside the keys that work. A click on the scrim closes it. A control the
/// caller does not supply is not drawn.
public struct SHFileViewer: View {
    public enum Mode: Hashable, Sendable { case file, diff }

    public enum Content {
        case loading
        /// Something to say in place of the text: the file can't be read, git has nothing for it.
        case message(String)
        case file([SHFileViewerLine])
        case diff([SHChangesRow], reveal: (String, SHDiffReveal) -> Void)
    }

    let directory: String
    let name: String
    let stat: (added: Int, removed: Int)?
    let position: String?
    @Binding var mode: Mode
    let content: Content
    let source: String
    let previous: (() -> Void)?
    let next: (() -> Void)?
    let openInEditor: (() -> Void)?
    let close: () -> Void

    /// `directory` is the folder as the person reads it ("~/Developer/toolkit/"); `source` says where the text comes from
    /// ("Commit a41c9e2 · Add retro skill"); `position` is "2 of 2", nil for one file.
    public init(directory: String, name: String, stat: (added: Int, removed: Int)? = nil, position: String? = nil,
                mode: Binding<Mode>, content: Content, source: String, previous: (() -> Void)? = nil, next: (() -> Void)? = nil,
                openInEditor: (() -> Void)? = nil, close: @escaping () -> Void) {
        self.directory = directory
        self.name = name
        self.stat = stat
        self.position = position
        _mode = mode
        self.content = content
        self.source = source
        self.previous = previous
        self.next = next
        self.openInEditor = openInEditor
        self.close = close
    }

    public var body: some View {
        let M = SHFileViewerMetrics.self
        GeometryReader { window in
            ZStack {
                // A real button, so a click and VoiceOver's press both close it.
                Button(action: close) { Color.sh.sheetScrim.contentShape(Rectangle()) }
                    .buttonStyle(.plain)
                    .focusable(false)
                    .accessibilityLabel("Close viewer")
                VStack(spacing: 0) {
                    header
                    SHHairline()
                    body(content)
                    SHHairline()
                    footer
                }
                .frame(width: min(M.maxWidth, max(1, window.size.width - 2 * M.margin)),
                       height: max(1, window.size.height - 2 * M.margin))
                .background(Color.sh.bgWindow)
                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.l))
                .shPopover(radius: SH.Radius.l)
            }
            .frame(width: window.size.width, height: window.size.height)
        }
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isModal)
        .accessibilityLabel("File viewer, \(name)")
    }

    private var header: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            if let position {
                HStack(spacing: SH.Space.xxs) {
                    icon("chevron.left", "Previous file", previous)
                    Text(position).font(.sh(.caption)).foregroundStyle(sh.textSecondary).monospacedDigit().fixedSize()
                    icon("chevron.right", "Next file", next)
                }
            }
            (Text(directory).foregroundStyle(sh.textTertiary) + Text(name).foregroundStyle(sh.textPrimary))
                .font(.sh(.mono))
                .lineLimit(1)
                .truncationMode(.head)
                .accessibilityLabel(directory + name)
            if let stat { SHDiffStat(added: stat.added, removed: stat.removed, font: .sh(.mono)).fixedSize() }
            Spacer(minLength: SH.Space.m)
            SHSegmentedPicker("Show", selection: $mode, options: [(.file, "File"), (.diff, "Diff")])
                .fixedSize()
            if let openInEditor { icon("arrow.up.forward.square", "Open in editor", openInEditor) }
            icon("xmark", "Close", close)
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: SHFileViewerMetrics.header)
        .background(sh.bgRaised)
    }

    private var footer: some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.l) {
            Text(source).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: SH.Space.m)
            hint(["D"], mode == .file ? "diff" : "file")
            if position != nil { hint(["←", "→"], "other files") }
            hint(["esc"], "close")
        }
        .padding(.horizontal, SH.Space.l)
        .frame(height: SHFileViewerMetrics.footer)
        .background(sh.bgRaised)
    }

    private func hint(_ keys: [String], _ label: String) -> some View {
        HStack(spacing: SH.Space.xs) {
            SHKeycap(keys: keys)
            Text(label).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary)
        }
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func icon(_ symbol: String, _ label: String, _ action: (() -> Void)?) -> some View {
        Button { action?() } label: {
            Image(systemName: symbol).font(.system(size: SHFileViewerMetrics.glyph, weight: .medium))
        }
        .buttonStyle(.sh(.ghost, size: .m))
        .disabled(action == nil)
        .accessibilityLabel(label)
        .shHelp(label)
    }

    @ViewBuilder private func body(_ content: Content) -> some View {
        let sh = Color.sh
        switch content {
        case .loading:
            SHBusyLabel("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case .message(let text):
            Text(text)
                .font(.sh(.ui))
                .foregroundStyle(sh.textSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: SHFileViewerMetrics.messageWidth)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .file(let lines):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(lines) { SHFileViewerLineRow(line: $0) }
                }
                .padding(.vertical, SH.Space.m)
            }
            .textSelection(.enabled)
        case .diff(let rows, let reveal):
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    SHDiffView(rows, onReveal: reveal)
                }
                .padding(.vertical, SH.Space.xs)
            }
            .environment(\.diffWrapsLines, true)
        }
    }
}

/// A file line: a 3pt `done` bar and `doneTint` when the change added it, the number in `textTertiary`, then the code,
/// wrapped.
struct SHFileViewerLineRow: View, Equatable {
    let line: SHFileViewerLine

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text(verbatim: String(line.number))
                .font(.sh(.code))
                .foregroundStyle(sh.textTertiary)
                .monospacedDigit()
                .frame(width: SHFileViewerMetrics.numberWidth, alignment: .trailing)
                .padding(.trailing, SH.Space.l)
                .accessibilityHidden(true)
            // A blank line keeps a line's height and baseline.
            Text(line.text.characters.isEmpty ? AttributedString(" ") : line.text)
                .shText(.code)
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.trailing, SH.Space.l)
        .frame(minHeight: SHDiffMetrics.lineHeight)
        .background(line.added ? sh.doneTint : .clear)
        .overlay(alignment: .leading) {
            if line.added { Rectangle().fill(sh.done).frame(width: SHDiffMetrics.barWidth) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(line.added ? "Line \(line.number), added" : "Line \(line.number)")
    }
}

public enum SHFileViewerMetrics {
    /// The thread left showing round the sheet.
    public static let margin: CGFloat = 56
    /// The widest the sheet grows.
    public static let maxWidth: CGFloat = 1040
    public static let header: CGFloat = 48
    public static let footer: CGFloat = 32
    /// The line-number column, right-aligned.
    public static let numberWidth: CGFloat = 52
    public static let glyph: CGFloat = 13
    /// A message in place of the text wraps at this width.
    public static let messageWidth: CGFloat = 360
}
