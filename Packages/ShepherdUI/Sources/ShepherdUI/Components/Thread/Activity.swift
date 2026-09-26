import SwiftUI

// Tool activity (NWThread, ToolRows, LiveText): one quiet line per burst of work, its calls on a
// hairline rail, and the changes card that ends a turn with edits.

/// One burst of tool work: "Explored 7 files · read 5 · search 2 · 0.9s". 26pt, the label in
/// 12.5 `textSecondary`, the meta in mono 11 `textTertiary`, a 10pt chevron; a real button
/// with a hover fill that expands the burst into its calls. A failed burst turns `failed` and
/// stays visible. A live one is the thread's live indicator (LiveText): the tool's own glyph in
/// `textSecondary`, the verb and the command shimmering (`nwShimmer(active:)`), its elapsed time
/// in mono 11 `textTertiary`, and its last output lines. Nothing spins.
public struct NWActivityLine: View {
    /// Which glyph leads the line: the tool's own, live or done.
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
    /// At the accessibility text sizes (iOS) the label wraps rather than widening the thread.
    @Environment(\.dynamicTypeSize) private var typeSize

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
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
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
                // Only a line with something behind it wears the chevron; its place stays.
                NWThreadChevron(isExpanded: isExpanded, shown: action != nil).foregroundStyle(nw.textTertiary)
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

    /// The running call (LiveText): its own glyph, still, in `textSecondary`; the verb and the
    /// command shimmer; the clock ticks beside them in tertiary.
    private func liveHeader(since: Date?) -> some View {
        let nw = Color.nw
        return HStack(spacing: NW.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(nw.textSecondary)
                .frame(width: NWThreadMetrics.activityIcon, height: NWThreadMetrics.activityIcon)
            Text(label).font(.nw(.ui, weight: .regular))
                .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: true)
                .nwShimmer(active: true)
                .layoutPriority(1)
            if !meta.isEmpty {
                Text(meta).font(.nwMono(11)).lineLimit(1).truncationMode(.tail)
                    .nwShimmer(active: true)
            }
            if let since {
                NWElapsedText(since: since, style: .long).font(.nwMono(11)).foregroundStyle(nw.textTertiary).fixedSize()
            }
        }
        .frame(minHeight: NWThreadMetrics.liveHeight)
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
/// turns to point down as it opens, under whatever motion the expansion runs with. Under Reduce
/// Motion nothing turns: the two positions cross-fade. A row with nothing to open keeps the
/// chevron's place but draws none (`shown: false`), so labels line up with rows that have one.
struct NWThreadChevron: View {
    let isExpanded: Bool
    var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !shown {
                Color.clear.frame(width: NWThreadMetrics.chevron, height: NWThreadMetrics.chevron)
            } else if reduceMotion {
                ZStack {
                    glyph.opacity(isExpanded ? 0 : 1)
                    glyph.rotationEffect(.degrees(90)).opacity(isExpanded ? 1 : 0)
                }
            } else {
                glyph.rotationEffect(.degrees(isExpanded ? 90 : 0))
            }
        }
        .accessibilityHidden(true)
    }

    private var glyph: some View {
        Image(systemName: "chevron.right")
            .font(.system(size: 8, weight: .semibold))
            .frame(width: NWThreadMetrics.chevron, height: NWThreadMetrics.chevron)
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
        NWActivityRail {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows) { row in
                    NWActivityCallRowView(row: row, labelWidth: labelWidth, onSelect: onSelect, onShowAll: onShowAll, menu: menu)
                }
            }
            .padding(.vertical, NW.Space.xxs)
        }
    }
}

/// What an expanded line holds (its calls), indented on a `lineStrong` hairline rail that runs
/// under the line's glyph.
struct NWActivityRail<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
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

/// Ends every turn that edited files (ChangesCard(turn.changes), NWThread, Main): a header with
/// a 30pt tile, "Edited 5 files" over its diff stat, Undo and Review; then the first three files
/// as plain paths (the folder dims, the name reads first, "new" on a created file) and "N more".
/// Review and the rows open the Changes pane on this turn. After Undo the card is one dashed line,
/// "Undid the agent’s edits to 5 files", with Redo (ChangesCard · after Undo).
public struct NWChangesCard: View {
    public enum Phase: Equatable, Sendable {
        case edited
        case undone
    }

    let title: String
    let added: Int
    let removed: Int
    let files: [NWChangedFile]
    let total: Int
    let phase: Phase
    let busy: Bool
    let notice: String?
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?
    let onUndo: (() -> Void)?
    let onRedo: (() -> Void)?

    /// `total` counts every file the turn changed (the card lists the first three); without it,
    /// `files` are all of them. `onUndo` and `onRedo` are left out where they can't apply (not the
    /// last turn, an older host); `busy` holds them while one runs; `notice` says why one refused.
    public init(title: String, added: Int, removed: Int, files: [NWChangedFile], total: Int? = nil, phase: Phase = .edited,
                busy: Bool = false, notice: String? = nil, onReview: (() -> Void)? = nil, onOpen: ((String) -> Void)? = nil,
                onUndo: (() -> Void)? = nil, onRedo: (() -> Void)? = nil) {
        self.title = title
        self.added = added
        self.removed = removed
        self.files = files
        self.total = max(total ?? files.count, files.count)
        self.phase = phase
        self.busy = busy
        self.notice = notice
        self.onReview = onReview
        self.onOpen = onOpen
        self.onUndo = onUndo
        self.onRedo = onRedo
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.s) {
            switch phase {
            case .edited: edited
            case .undone: undone
            }
            if let notice {
                Text(notice)
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .nwTransition(.content)
            }
        }
        .nwAnimation(.content, value: phase)
        .nwAnimation(.content, value: notice)
    }

    private var edited: some View {
        let nw = Color.nw
        let shown = Array(files.prefix(NWThreadMetrics.changesShownFiles))
        let more = total - shown.count
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "plus.forwardslash.minus")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .frame(width: NWThreadMetrics.changesTile, height: NWThreadMetrics.changesTile)
                    .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                    .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.nwSans(13, .semibold)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    NWDiffStat(added: added, removed: removed, font: .nwMono(11))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if let onUndo {
                    Button(action: onUndo) {
                        HStack(spacing: 5) {
                            Text("Undo")
                            Image(systemName: "arrow.uturn.backward").font(.system(size: 10, weight: .medium))
                        }
                    }
                    .buttonStyle(.nw(.ghost, size: .s))
                    .disabled(busy)
                    .help("Put back this turn’s edits in the worktree")
                    .accessibilityLabel("Undo the agent’s edits to \(total) file\(total == 1 ? "" : "s")")
                }
                if let onReview {
                    Button("Review", action: onReview)
                        .buttonStyle(.nw(.secondary, size: .s))
                        .accessibilityLabel("Review \(title)")
                }
            }
            .padding(.vertical, 10)
            .padding(.leading, NW.Space.l)
            .padding(.trailing, 10)
            ForEach(shown) { file in
                NWHairline()
                row(file)
            }
            if more > 0 {
                NWHairline()
                moreRow(more)
            }
        }
        .frame(maxWidth: .infinity)
        .background(nw.bgWindow, in: RoundedRectangle(cornerRadius: NWThreadMetrics.changesRadius))
        .clipShape(RoundedRectangle(cornerRadius: NWThreadMetrics.changesRadius))
        .nwBorder(nw.lineSubtle, radius: NWThreadMetrics.changesRadius)
        .accessibilityElement(children: .contain)
    }

    private var undone: some View {
        let nw = Color.nw
        return HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium)).foregroundStyle(nw.textSecondary)
                .accessibilityHidden(true)
            Text(title).font(.nw(.ui, weight: .regular)).foregroundStyle(nw.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRedo {
                Button("Redo", action: onRedo)
                    .buttonStyle(.nw(.ghost, size: .s))
                    .disabled(busy)
                    .help("Put the agent’s edits back")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, NW.Space.l)
        .overlay {
            RoundedRectangle(cornerRadius: NWThreadMetrics.changesRadius)
                .strokeBorder(nw.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private func row(_ file: NWChangedFile) -> some View {
        let nw = Color.nw
        let content = HStack(spacing: NW.Space.m) {
            Text("\(Text(file.directory).foregroundStyle(nw.textTertiary))\(Text(file.name).foregroundStyle(nw.textPrimary))")
                .font(.nw(.ui, weight: .regular)).lineLimit(1).truncationMode(.head)
                .frame(maxWidth: .infinity, alignment: .leading)
            if file.status != .modified {
                Text(file.status == .added ? "new" : "deleted").font(.nwSans(11)).foregroundStyle(nw.textTertiary)
            }
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
                .accessibilityHint("Opens the file in the Changes pane")
        } else {
            content.accessibilityElement(children: .ignore).accessibilityLabel(label)
        }
    }

    @ViewBuilder private func moreRow(_ count: Int) -> some View {
        let label = Text("\(count) more").font(.nwSans(12)).foregroundStyle(Color.nw.textSecondary)
            .padding(.horizontal, NW.Space.l)
            .frame(maxWidth: .infinity, minHeight: NWThreadMetrics.changesRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        if let onReview {
            Button(action: onReview) { label }
                .buttonStyle(.nwRow(radius: 0))
                .accessibilityLabel("\(count) more files")
                .accessibilityHint("Opens the Changes pane")
        } else {
            label
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
