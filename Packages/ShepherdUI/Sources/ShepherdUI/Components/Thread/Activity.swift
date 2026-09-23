import SwiftUI

// Tool activity (NWThread board, "Activity line states"): one quiet line per burst of work,
// its calls on a hairline rail, and the changes card that ends a turn with edits.

/// One burst of tool work: "Explored 7 files · read 5 · search 2 · 0.9s". 26pt, the label in
/// 12.5 `textSecondary`, the meta in mono 11 `textTertiary`, a 10pt chevron; a real button
/// with a hover fill that expands the burst into its calls. A failed burst turns `failed` and
/// stays visible. A live one shows a running spinner, the verb in `textPrimary`, the command,
/// its elapsed time in running blue, and its last output lines.
public struct NWActivityLine: View {
    /// Which glyph leads the line.
    public enum Kind: Sendable { case explore, edit, run, subagents, other }

    public enum Status: Equatable, Sendable {
        case done
        case failed
        /// Running since `since`, with its last output lines.
        case live(since: Date?, tail: [String])
    }

    let kind: Kind
    let label: String
    let meta: String
    let status: Status
    let isExpanded: Bool
    let accessibilityText: String
    let action: (() -> Void)?

    /// `action` toggles the calls; nil for a line with nothing behind it.
    public init(kind: Kind, label: String, meta: String, status: Status = .done, isExpanded: Bool = false,
                accessibilityLabel: String? = nil, action: (() -> Void)? = nil) {
        self.kind = kind
        self.label = label
        self.meta = meta
        self.status = status
        self.isExpanded = isExpanded
        self.accessibilityText = accessibilityLabel ?? [label, meta].filter { !$0.isEmpty }.joined(separator: ", ")
        self.action = action
    }

    /// When the call ends, the live line cross-fades into its finished line in place and its
    /// output lines go at once: they update per output chunk, and a thread following its tail
    /// must not watch them shrink.
    public var body: some View {
        let live: (since: Date?, tail: [String])? = if case .live(let since, let tail) = status { (since, tail) } else { nil }
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            ZStack(alignment: .leading) {
                if let live {
                    liveHeader(since: live.since).nwTransition(.content)
                } else {
                    finished.nwTransition(.content)
                }
            }
            .nwAnimation(.content, value: live == nil)
            if let tail = live?.tail, !tail.isEmpty { liveTail(tail) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        if status == .failed { return "exclamationmark.triangle" }
        return switch kind {
        case .explore: "magnifyingglass"
        case .edit: "pencil"
        case .run: "apple.terminal"
        case .subagents: "arrow.triangle.branch"
        case .other: "wrench.adjustable"
        }
    }

    private var finished: some View {
        let nw = Color.nw
        let failed = status == .failed
        return Button {
            action?()
        } label: {
            HStack(spacing: NW.Space.m) {
                Image(systemName: symbol)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(failed ? nw.failed : nw.textTertiary)
                    .frame(width: NWThreadMetrics.activityIcon, height: NWThreadMetrics.activityIcon)
                Text(label)
                    .font(.nw(.ui, weight: .regular))
                    .foregroundStyle(failed ? nw.failed : nw.textSecondary)
                    .lineLimit(1)
                    .fixedSize()
                    .layoutPriority(1)
                    .nwContentTransition(.numeric())
                if !meta.isEmpty {
                    Text(meta)
                        .font(.nwMono(11))
                        .foregroundStyle(nw.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .nwContentTransition(.numeric())
                }
                if action != nil {
                    NWThreadChevron(isExpanded: isExpanded).foregroundStyle(nw.textTertiary)
                }
            }
            // A finished call joining the line counts up ("Explored 6 files").
            .nwAnimation(.content, value: [label, meta])
            .padding(.leading, NW.Space.xs)
            .padding(.trailing, NW.Space.m)
            .frame(minHeight: NWThreadMetrics.activityHeight)
        }
        .buttonStyle(.nwRow())
        .disabled(action == nil)
        .padding(.leading, -NW.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityLabel(accessibilityText)
        .accessibilityValue(action == nil ? "" : isExpanded ? "Expanded" : "Collapsed")
        .accessibilityHint(action == nil ? "" : "Shows the calls")
    }

    private func liveHeader(since: Date?) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            ProgressView().progressViewStyle(.nwSpinner(size: NWThreadMetrics.activityIcon))
            Text(label).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textPrimary).lineLimit(1).fixedSize()
                .layoutPriority(1)
            if !meta.isEmpty {
                Text(meta).font(.nwMono(11)).foregroundStyle(nw.textTertiary).lineLimit(1).truncationMode(.tail)
            }
            if let since {
                NWElapsedText(since: since, style: .long).font(.nwMono(11)).foregroundStyle(nw.running).fixedSize()
            }
        }
        .frame(minHeight: NWThreadMetrics.activityHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func liveTail(_ tail: [String]) -> some View {
        let nw = Color.nw
        return VStack(alignment: .leading, spacing: NWThreadMetrics.tailLineSpacing) {
            ForEach(Array(tail.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.nwMono(11))
                    .foregroundStyle(index == tail.count - 1 ? nw.textSecondary : nw.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, NWThreadMetrics.liveTailIndent)
        .accessibilityHidden(true)
    }
}

/// The thread's 10pt disclosure chevron (activity lines, thinking): one `chevron.right` that
/// turns to point down as it opens, under whatever motion the expansion runs with.
struct NWThreadChevron: View {
    let isExpanded: Bool

    var body: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .frame(width: NWThreadMetrics.chevron, height: NWThreadMetrics.chevron)
            .rotationEffect(.degrees(isExpanded ? 90 : 0))
            .accessibilityHidden(true)
    }
}

/// One call behind an activity line.
public struct NWActivityCallRow: Identifiable, Equatable, Sendable {
    public var id: String
    /// The kind column: "read", "edit", "bash".
    public var label: String
    /// A path (truncated at the head) or a command (at the tail).
    public var detail: String
    public var isPath: Bool
    public var stat: String?
    public var failed: Bool
    /// The call's first output lines, shown while the row is expanded; `moreLines` counts the rest.
    public var output: [String]
    public var moreLines: Int
    /// The host clipped the output: the full text only opens in its own sheet.
    public var truncated: Bool
    public var isExpanded: Bool
    /// "edit, Sources/A.swift, +58 −41"
    public var accessibilityLabel: String

    public init(id: String, label: String, detail: String, isPath: Bool = false, stat: String? = nil, failed: Bool = false,
                output: [String] = [], moreLines: Int = 0, truncated: Bool = false, isExpanded: Bool = false,
                accessibilityLabel: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isPath = isPath
        self.stat = stat
        self.failed = failed
        self.output = output
        self.moreLines = moreLines
        self.truncated = truncated
        self.isExpanded = isExpanded
        self.accessibilityLabel = accessibilityLabel ?? [label, detail, stat].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An expanded line's calls (NWThread board): an indented list on a hairline rail, 22pt mono 11
/// rows of kind · path or command · stat. A row opens its file or its output (`onSelect`);
/// an expanded row shows its first lines on `bgSunken`, and "… n more lines" (or, for output
/// the host clipped, "Output truncated · open") asks for the rest.
public struct NWActivityCalls<Menu: View>: View {
    let rows: [NWActivityCallRow]
    let onSelect: (String) -> Void
    let onShowAll: (String) -> Void
    let menu: (NWActivityCallRow) -> Menu

    public init(_ rows: [NWActivityCallRow], onSelect: @escaping (String) -> Void, onShowAll: @escaping (String) -> Void,
                @ViewBuilder menu: @escaping (NWActivityCallRow) -> Menu) {
        self.rows = rows
        self.onSelect = onSelect
        self.onShowAll = onShowAll
        self.menu = menu
    }

    public var body: some View {
        // Geist Mono advances 0.6em: the column fits the longest kind, never less than 32pt.
        let longest = rows.map(\.label.count).max() ?? 0
        let labelWidth = max(NWThreadMetrics.callLabelWidth, (CGFloat(longest) * 11 * 0.6 * ThemeStore.shared.textScale).rounded(.up))
        VStack(alignment: .leading, spacing: 0) {
            ForEach(rows) { row in
                NWActivityCallRowView(row: row, labelWidth: labelWidth, onSelect: onSelect, onShowAll: onShowAll, menu: menu)
            }
        }
        .padding(.vertical, NW.Space.xxs)
        .padding(.leading, NWThreadMetrics.railPadding)
        .overlay(alignment: .leading) { NWHairline(.vertical, color: .nw.lineStrong) }
        .padding(.leading, NWThreadMetrics.railInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension NWActivityCalls where Menu == EmptyView {
    public init(_ rows: [NWActivityCallRow], onSelect: @escaping (String) -> Void, onShowAll: @escaping (String) -> Void) {
        self.init(rows, onSelect: onSelect, onShowAll: onShowAll) { _ in EmptyView() }
    }
}

private struct NWActivityCallRowView<Menu: View>: View {
    let row: NWActivityCallRow
    let labelWidth: CGFloat
    let onSelect: (String) -> Void
    let onShowAll: (String) -> Void
    let menu: (NWActivityCallRow) -> Menu

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            Button { onSelect(row.id) } label: {
                HStack(spacing: 10) {
                    Text(row.label).foregroundStyle(nw.textTertiary).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                    Text(row.detail).foregroundStyle(nw.textSecondary).lineLimit(1)
                        .truncationMode(row.isPath ? .head : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if let stat = row.stat {
                        Text(stat).foregroundStyle(row.failed ? nw.failed : nw.textTertiary).lineLimit(1).fixedSize().monospacedDigit()
                    }
                }
                .font(.nwMono(11))
                .padding(.horizontal, NW.Space.xs)
                .frame(minHeight: NWThreadMetrics.callRowHeight)
            }
            .buttonStyle(.nwRow(radius: NW.Radius.xs))
            .padding(.horizontal, -NW.Space.xs)
            .contextMenu { menu(row) }
            .help(row.detail)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.output.isEmpty ? "" : row.isExpanded ? "Expanded" : "Collapsed")
            if row.isExpanded, !row.output.isEmpty {
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    Text(row.output.joined(separator: "\n"))
                        .font(.nwMono(11))
                        .lineSpacing(NWThreadMetrics.tailLineSpacing)
                        .foregroundStyle(nw.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.moreLines > 0 {
                        Button("… \(row.moreLines) more line\(row.moreLines == 1 ? "" : "s")") { onShowAll(row.id) }
                            .buttonStyle(.nwLink(font: .nwMono(11)))
                    } else if row.truncated {
                        Button("Output truncated · open") { onShowAll(row.id) }
                            .buttonStyle(.nwLink(font: .nwMono(11)))
                    }
                }
                .padding(.vertical, NW.Space.m)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.s))
                .padding(.leading, labelWidth + 10)
                .padding(.bottom, NW.Space.xs)
                .nwTransition(.disclosure)
            }
        }
    }
}

// MARK: Changes card

/// One file in a changes card.
public struct NWChangedFile: Identifiable, Equatable, Sendable {
    public enum Status: String, Sendable { case modified = "M", added = "A", deleted = "D" }
    public var id: String { path }
    public var path: String
    /// "Sources/ShepherdApp/" in `textTertiary`, then the filename in `textPrimary`.
    public var directory: String
    public var name: String
    public var status: Status
    public var added: Int
    public var removed: Int

    public init(path: String, directory: String, name: String, status: Status, added: Int, removed: Int) {
        self.path = path
        self.directory = directory
        self.name = name
        self.status = status
        self.added = added
        self.removed = removed
    }
}

/// Ends every turn that edited files (NWThread board): a 32pt `bgSunken` header "4 files
/// changed +149 −63" with Review, then a 28pt row per file with its status letter (M lantern,
/// A done, D failed), directory and name, and diff stat. Review and the rows open the review
/// pane; without `onOpen` the rows are plain.
public struct NWChangesCard: View {
    let title: String
    let added: Int
    let removed: Int
    let files: [NWChangedFile]
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?

    public init(title: String, added: Int, removed: Int, files: [NWChangedFile],
                onReview: (() -> Void)? = nil, onOpen: ((String) -> Void)? = nil) {
        self.title = title
        self.added = added
        self.removed = removed
        self.files = files
        self.onReview = onReview
        self.onOpen = onOpen
    }

    public var body: some View {
        let nw = Color.nw
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "pencil").font(.system(size: 10, weight: .medium)).foregroundStyle(nw.textSecondary)
                    .frame(width: 12, height: 12)
                Text(title).font(.nw(.ui, weight: .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1).fixedSize()
                NWDiffStat(added: added, removed: removed, font: .nwMono(11))
                Spacer(minLength: 0)
                if let onReview {
                    Button(action: onReview) { Label("Review", systemImage: "plus.forwardslash.minus") }
                        .buttonStyle(.nw(.ghost, size: .s))
                        .accessibilityLabel("Review \(title)")
                }
            }
            .padding(.leading, NW.Space.l)
            .padding(.trailing, NW.Space.s)
            .frame(height: NWThreadMetrics.changesHeaderHeight)
            .background(nw.bgSunken)
            .accessibilityElement(children: .combine)
            ForEach(files) { file in
                NWHairline()
                row(file)
            }
        }
        .frame(maxWidth: .infinity)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func row(_ file: NWChangedFile) -> some View {
        let nw = Color.nw
        let content = HStack(spacing: 10) {
            Text(file.status.rawValue).font(.nwMono(11, .bold)).foregroundStyle(statusColor(file.status))
            Text("\(Text(file.directory).foregroundStyle(nw.textTertiary))\(Text(file.name).foregroundStyle(nw.textPrimary))")
                .font(.nwMono(12)).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            NWDiffStat(added: file.added, removed: file.removed, font: .nwMono(11))
        }
        .padding(.horizontal, NW.Space.l)
        .frame(minHeight: NWThreadMetrics.changesRowHeight)
        .contentShape(Rectangle())
        let label = "\(file.path), \(statusWord(file.status)), \(file.added) added, \(file.removed) removed"
        if let onOpen {
            Button { onOpen(file.path) } label: { content }
                .buttonStyle(.nwRow(radius: 0))
                .accessibilityLabel(label)
                .accessibilityHint("Opens the file in the review pane")
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        }
    }

    private func statusColor(_ status: NWChangedFile.Status) -> Color {
        switch status {
        case .modified: .nw.lantern
        case .added: .nw.done
        case .deleted: .nw.failed
        }
    }

    private func statusWord(_ status: NWChangedFile.Status) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        }
    }
}
