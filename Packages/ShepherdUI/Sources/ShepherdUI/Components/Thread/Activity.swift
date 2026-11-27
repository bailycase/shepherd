import SwiftUI

// Tool activity (ToolFeed › A · One live line): one line per stretch of work, its calls on a
// hairline rail, and the changes card that ends a turn with edits.

/// One burst of tool work: "Explored 7 files · read 5 · search 2 · 0.9s". 26pt, the label in
/// 12.5 `textSecondary`, the meta in mono 11 `textTertiary`, a 10pt chevron; a real button
/// with a hover fill that expands the burst into its calls. A failed burst turns `failed` and
/// stays visible. A live one is the thread's live indicator (ToolFeed › A · One live line): no glyph and nothing spinning, the verb and the command shimmering (`shShimmer(active:)`), its elapsed time in mono 11 `textTertiary`, and its last
/// output lines.
public struct SHActivityLine: View {
    /// Which glyph leads the line: the tool's own, live or done.
    /// `drew` and `checked` are the design agent's verbs ("Drew 4 boards", "Checked against
    /// acme-web"): the nib and the shield. `lookedAtDesign` is a thread reading a design piece it
    /// was sent ("Looked at Checkout funnel dashboard › A · Funnel first"): the nib too. `browser`
    /// is an agent using its thread's Browser ("Opened localhost:5173/checkout in Browser"): the globe. `computer` is an agent
    /// working this Mac's apps ("5 actions in Safari"): the pointer. `images` is the neutral count of the
    /// images a message or a tool result carries ("2 images", ThreadImagesSent and ThreadImagesReceived): the `photo` glyph.
    public enum Kind: Sendable { case explore, edit, run, subagents, drew, checked, lookedAtDesign, browser, computer, images, other }

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
    /// A call the model is still writing: "18 KB received" of its arguments, before its clock.
    var received: String?
    /// A finished stretch in the boards' words (GXThread): the chevron first, "Worked for 2m 12s" and, after it in `textTertiary`, what the
    /// stretch did. Nil keeps the glyph and meta of every other line.
    var worked: Worked?

    public struct Worked: Equatable, Sendable {
        public var duration: String?
        public var summary: String
        public init(duration: String?, summary: String) { self.duration = duration; self.summary = summary }
        var title: String { duration.map { "Worked for \($0)" } ?? "Worked" }
    }
    /// At the accessibility text sizes (iOS) the label wraps rather than widening the thread.
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `action` toggles the calls; nil for a line with nothing behind it.
    public init(kind: Kind, label: String, meta: String, status: Status = .done, isExpanded: Bool = false,
                accessibilityLabel: String? = nil, action: (() -> Void)? = nil, received: String? = nil, worked: Worked? = nil) {
        self.kind = kind
        self.label = label
        self.meta = meta
        self.status = status
        self.isExpanded = isExpanded
        let text = accessibilityLabel ?? [label, meta].filter { !$0.isEmpty }.joined(separator: ", ")
        self.accessibilityText = received.map { text + ", " + $0 } ?? text
        self.action = action
        self.received = received
        self.worked = worked
    }

    /// What "18 KB received" means, on hover.
    static func receivedHelp(_ received: String) -> String {
        let amount = received.replacingOccurrences(of: " received", with: "")
        return "\(amount) of this call’s arguments have arrived from the model. Nothing is written to disk until the call runs."
    }

    /// When the call ends, the live line cross-fades into its finished line in place and its
    /// output lines go at once: they update per output chunk, and a thread following its tail
    /// must not watch them shrink.
    public var body: some View {
        let live: (since: Date?, tail: [String])? = if case .live(let since, let tail) = status { (since, tail) } else { nil }
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            ZStack(alignment: .leading) {
                if let live {
                    liveHeader(since: live.since).shTransition(.content)
                } else {
                    finished.shTransition(.content)
                }
            }
            .shAnimation(.content, value: live == nil)
            if let tail = live?.tail, !tail.isEmpty { liveTail(tail) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var symbol: String {
        if status == .failed { return "exclamationmark.triangle" }
        return switch kind {
        case .explore: "magnifyingglass"
        case .edit: "pencil"
        case .run: "terminal"
        case .subagents: SHGlyph.gitBranch.symbolName
        case .drew, .lookedAtDesign: "pencil.tip"
        case .checked: "checkmark.shield"
        case .browser: "globe"
        case .computer: "cursorarrow"
        case .images: "photo"
        case .other: "wrench.adjustable"
        }
    }

    /// A real button only when something is behind it: a line with nothing to open is its words
    /// alone (no hover, press, or focus, and VoiceOver hears no button).
    @ViewBuilder private var finished: some View {
        Group {
            if let action {
                Button(action: action) { finishedLabel }
                    .buttonStyle(.shRow())
                    .accessibilityLabel(accessibilityText)
                    .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
                    .accessibilityHint("Shows the calls")
            } else {
                finishedLabel
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(accessibilityText)
            }
        }
        .padding(.leading, -SH.Space.xs)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The boards' finished line: a thinking row's twin, its chevron at the left, "Worked for 2m 12s" in `textSecondary` and the summary after it.
    private func workedLabel(_ worked: Worked) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.s) {
            SHThreadChevron(isExpanded: isExpanded, shown: action != nil).foregroundStyle(sh.textTertiary)
            SHActivityWords(metaMinimum: SHThreadMetrics.activityMetaMinimum * ThemeStore.shared.textScale) {
                Text(worked.title)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                    .shContentTransition(.numeric())
                Text(worked.summary)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shContentTransition(.numeric())
            }
        }
        .shAnimation(.content, value: [worked.title, worked.summary])
        .padding(.leading, SH.Space.xs)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: SHThreadMetrics.activityHeight)
    }

    @ViewBuilder private var finishedLabel: some View {
        if status == .done, let worked { workedLabel(worked) } else { plainFinishedLabel }
    }

    private var plainFinishedLabel: some View {
        let sh = Color.sh
        let failed = status == .failed
        return HStack(spacing: SH.Space.m) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(failed ? sh.failed : sh.textTertiary)
                .frame(width: SHThreadMetrics.activityIcon, height: SHThreadMetrics.activityIcon)
            SHActivityWords(metaMinimum: SHThreadMetrics.activityMetaMinimum * ThemeStore.shared.textScale) {
                Text(label)
                    .font(.sh(.ui, weight: .regular))
                    .foregroundStyle(failed ? sh.failed : sh.textSecondary)
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                    .shContentTransition(.numeric())
                if !meta.isEmpty {
                    Text(meta)
                        .font(.sh(.mono))
                        .foregroundStyle(sh.textTertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .monospacedDigit()
                        .shContentTransition(.numeric())
                }
            }
            // Only a line with something behind it wears the chevron; its place stays.
            SHThreadChevron(isExpanded: isExpanded, shown: action != nil).foregroundStyle(sh.textTertiary)
        }
        // A finished call joining the line counts up ("Explored 6 files").
        .shAnimation(.content, value: [label, meta])
        .padding(.leading, SH.Space.xs)
        .padding(.trailing, SH.Space.m)
        .frame(minHeight: SHThreadMetrics.activityHeight)
    }

    /// The running call (ToolFeed › A): no glyph and nothing spins; the verb and the
    /// command shimmer; the clock ticks beside them in tertiary.
    private func liveHeader(since: Date?) -> some View {
        let sh = Color.sh
        return HStack(spacing: SH.Space.m) {
            SHActivityWords(metaMinimum: SHThreadMetrics.activityMetaMinimum * ThemeStore.shared.textScale) {
                Text(label).font(.sh(.ui, weight: .regular))
                    .lineLimit(typeSize.isAccessibilitySize ? nil : 1)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
                if !meta.isEmpty {
                    Text(meta).font(.sh(.mono)).lineLimit(1).truncationMode(.tail)
                }
            }
            // One band over the verb and the command together: one layer per live line.
            .shShimmer(active: true)
            if received != nil || since != nil {
                HStack(spacing: 0) {
                    if let received { Text(received + (since == nil ? "" : " · ")) }
                    if let since { SHElapsedText(since: since, style: .long) }
                }
                .font(.shMono(11)).foregroundStyle(sh.textTertiary).fixedSize()
                .help(received.map(Self.receivedHelp) ?? "")
            }
        }
        .frame(minHeight: SHThreadMetrics.liveHeight)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private func liveTail(_ tail: [String]) -> some View {
        let sh = Color.sh
        return VStack(alignment: .leading, spacing: SHThreadMetrics.tailLineSpacing) {
            ForEach(Array(tail.enumerated()), id: \.offset) { index, line in
                Text(line)
                    .font(.shMono(11))
                    .foregroundStyle(index == tail.count - 1 ? sh.textSecondary : sh.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .padding(.leading, SHThreadMetrics.liveTailIndent)
        .accessibilityHidden(true)
    }
}

/// An activity line's words: the label, then the meta (when there is one) 8pt after it. The label
/// takes the room it needs and truncates only when the line has no more, so a label naming boards
/// or a page never widens the thread. The meta takes what is left, and leaves when that is not
/// room for a few characters, since a letter cut in half is only noise.
struct SHActivityWords: Layout {
    /// The least room the meta gets.
    let metaMinimum: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) -> CGSize {
        measure(proposal.width, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Void) {
        let parts = measure(bounds.width, subviews)
        subviews[0].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading,
                          proposal: ProposedViewSize(width: parts.label.width, height: nil))
        guard subviews.count > 1 else { return }
        if parts.meta > 0 {
            subviews[1].place(at: CGPoint(x: bounds.minX + parts.label.width + SH.Space.m, y: bounds.midY), anchor: .leading,
                              proposal: ProposedViewSize(width: parts.meta, height: nil))
        } else {
            subviews[1].place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: .zero)
        }
    }

    /// The label's size and the width the meta gets (0: none), for `width` (nil: as wide as they want).
    private func measure(_ width: CGFloat?, _ subviews: Subviews) -> (size: CGSize, label: CGSize, meta: CGFloat) {
        let label = subviews[0].sizeThatFits(ProposedViewSize(width: width, height: nil))
        guard subviews.count > 1 else { return (label, label, 0) }
        let metaSize = subviews[1].sizeThatFits(ProposedViewSize(width: width.map { max(0, $0 - label.width - SH.Space.m) }, height: nil))
        let room = width.map { $0 - label.width - SH.Space.m }
        // All of it when it fits; else what is left, unless that is too little to read.
        // All of it when it fits; else what is left, unless that is too little to read.
        let meta = room.map { metaSize.width <= $0 + 0.01 || $0 >= metaMinimum ? min(metaSize.width, $0) : 0 } ?? metaSize.width
        guard meta > 0 else { return (label, label, 0) }
        return (CGSize(width: label.width + SH.Space.m + meta, height: max(label.height, metaSize.height)), label, meta)
    }
}

/// The thread's 10pt disclosure chevron (activity lines, thinking): one `chevron.right` that
/// turns to point down as it opens, under whatever motion the expansion runs with. Under Reduce
/// Motion nothing turns: the two positions cross-fade. A row with nothing to open keeps the
/// chevron's place but draws none (`shown: false`), so labels line up with rows that have one.
struct SHThreadChevron: View {
    let isExpanded: Bool
    var shown = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if !shown {
                Color.clear.frame(width: SHThreadMetrics.chevron, height: SHThreadMetrics.chevron)
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
            .frame(width: SHThreadMetrics.chevron, height: SHThreadMetrics.chevron)
    }
}

/// What a "Looked at…" line opens to (SHActivityLine(.lookedAtDesign) · expanded): on the calls'
/// rail, one 18pt row per part the agent got — `pic` the picture and its size, `html` the
/// page and its weight, `css` the styles, `tok` the tokens with the file and lines they live in.
public struct SHLookedAtDetails: View {
    public struct Row: Identifiable, Equatable, Sendable {
        public var id: String { label }
        /// "pic", "html", "css", "tok".
        public var label: String
        public var detail: String
        /// "756 × 612", "6.2 KB", "web/static/tokens.css:4–16".
        public var trailing: String?

        public init(label: String, detail: String, trailing: String? = nil) {
            self.label = label
            self.detail = detail
            self.trailing = trailing
        }
    }

    let rows: [Row]

    public init(_ rows: [Row]) { self.rows = rows }

    public var body: some View {
        let sh = Color.sh
        let M = SHReferenceMetrics.self
        VStack(alignment: .leading, spacing: M.detailRowGap) {
            ForEach(rows) { row in
                HStack(spacing: M.detailColumnGap) {
                    Text(row.label).font(.shMono(M.detailSize)).foregroundStyle(sh.textTertiary)
                        .frame(width: M.detailLabelWidth, alignment: .leading)
                    Text(row.detail).font(.shMono(M.detailSize)).foregroundStyle(sh.textPrimary).lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: SH.Space.m)
                    if let trailing = row.trailing {
                        Text(trailing).font(.shSans(M.detailSize)).foregroundStyle(sh.textTertiary).lineLimit(1).fixedSize()
                    }
                }
                .frame(height: M.detailRowHeight)
                .accessibilityElement(children: .combine)
            }
        }
        .padding(.leading, M.detailRail)
        .overlay(alignment: .leading) { SHHairline(.vertical, color: sh.lineSubtle) }
        .padding(.leading, M.detailIndent)
        .padding(.top, SH.Space.xs)
    }
}

/// One call behind an activity line.
/// The lines an edit added and removed.
public struct SHCallDiff: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public init(added: Int, removed: Int) { self.added = added; self.removed = removed }
}

public struct SHActivityCallRow: Identifiable, Equatable, Sendable {
    public var id: String
    /// The kind column: "read", "edit", "bash".
    public var label: String
    /// A path (truncated at the head) or a command (at the tail).
    public var detail: String
    public var isPath: Bool
    public var stat: String?
    /// An edit's lines added and removed, which the Mac draws in their colours in place of `stat`.
    public var diff: SHCallDiff?
    public var failed: Bool
    /// The call's first output lines, shown while the row is expanded; `moreLines` counts the rest.
    public var output: [String]
    public var moreLines: Int
    /// The host clipped the output: the full text only opens in its own sheet.
    public var truncated: Bool
    public var isExpanded: Bool
    /// The file the call read or changed, for its Open in button (OpenInD); nil for any other call.
    public var filePath: String?
    /// "edit, Sources/A.swift, +58 −41"
    public var accessibilityLabel: String

    public init(id: String, label: String, detail: String, isPath: Bool = false, stat: String? = nil, diff: SHCallDiff? = nil,
                failed: Bool = false, output: [String] = [], moreLines: Int = 0, truncated: Bool = false, isExpanded: Bool = false,
                filePath: String? = nil, accessibilityLabel: String? = nil) {
        self.id = id
        self.label = label
        self.detail = detail
        self.isPath = isPath
        self.stat = stat
        self.diff = diff
        self.failed = failed
        self.output = output
        self.moreLines = moreLines
        self.truncated = truncated
        self.isExpanded = isExpanded
        self.filePath = filePath
        self.accessibilityLabel = accessibilityLabel ?? [label, detail, stat].compactMap { $0 }.joined(separator: ", ")
    }
}

/// An expanded line's calls (SHThread board): an indented list on a hairline rail, 22pt mono 11
/// rows of kind · path or command · stat. A row opens its file or its output (`onSelect`);
/// an expanded row shows its first lines on `bgSunken`, and "… n more lines" (or, for output
/// the host clipped, "Output truncated · open") asks for the rest.
public struct SHActivityCalls<Menu: View>: View {
    let rows: [SHActivityCallRow]
    let onSelect: (String) -> Void
    let onShowAll: (String) -> Void
    let menu: (SHActivityCallRow) -> Menu

    public init(_ rows: [SHActivityCallRow], onSelect: @escaping (String) -> Void, onShowAll: @escaping (String) -> Void,
                @ViewBuilder menu: @escaping (SHActivityCallRow) -> Menu) {
        self.rows = rows
        self.onSelect = onSelect
        self.onShowAll = onShowAll
        self.menu = menu
    }

    public var body: some View {
        // Geist Mono advances 0.6em: the column fits the longest kind, never less than 32pt and
        // never more than its cap (a longer name truncates).
        let longest = min(rows.map(\.label.count).max() ?? 0, SHThreadMetrics.callLabelMaxCharacters)
        let labelWidth = max(SHThreadMetrics.callLabelWidth, (CGFloat(longest) * 11 * 0.6 * ThemeStore.shared.textScale).rounded(.up))
        SHActivityRail {
            VStack(alignment: .leading, spacing: SHThreadMetrics.callRowGap) {
                ForEach(rows) { row in
                    SHActivityCallRowView(row: row, labelWidth: labelWidth, onSelect: onSelect, onShowAll: onShowAll, menu: menu)
                }
            }
            .padding(.vertical, SH.Space.xxs)
        }
    }
}

/// What an expanded line holds (its calls), indented on a `lineStrong` hairline rail that runs
/// under the line's glyph.
struct SHActivityRail<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(.leading, SHThreadMetrics.railPadding)
            .overlay(alignment: .leading) { SHHairline(.vertical, color: SHThreadMetrics.stepsRule(Color.sh)) }
            .padding(.leading, SHThreadMetrics.railInset)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
    }
}

extension SHActivityCalls where Menu == EmptyView {
    public init(_ rows: [SHActivityCallRow], onSelect: @escaping (String) -> Void, onShowAll: @escaping (String) -> Void) {
        self.init(rows, onSelect: onSelect, onShowAll: onShowAll) { _ in EmptyView() }
    }
}

private struct SHActivityCallRowView<Menu: View>: View {
    let row: SHActivityCallRow
    let labelWidth: CGFloat
    let onSelect: (String) -> Void
    let onShowAll: (String) -> Void
    let menu: (SHActivityCallRow) -> Menu
    @State private var hovering = false
    @State private var statWidth: CGFloat = 0
    @State private var openInWidth: CGFloat = 0

    #if os(macOS)
    /// An edit's lines in the diff colours, else its stat in `textTertiary` (`failed` when it did).
    @ViewBuilder private func statView(_ sh: SHPalette) -> some View {
        if let diff = row.diff, !row.failed {
            SHDiffStat(added: diff.added, removed: diff.removed, font: .sh(.ui, weight: .regular), hidesZero: true).fixedSize()
        } else if let stat = row.stat {
            Text(stat).font(.sh(.ui, weight: .regular)).foregroundStyle(row.failed ? sh.failed : sh.textTertiary).lineLimit(1).fixedSize()
        }
    }
    #endif

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Button { onSelect(row.id) } label: {
                #if os(macOS)
                // The board's `.tl` (GXExpanded): the verb in words, the path or command in mono, then what came of it.
                HStack(spacing: SH.Space.s) {
                    // A tool's own name can be long: a verb keeps its words; a name past the cap truncates there, and reads before the detail.
                    let longName = row.label.count > SHThreadMetrics.callLabelMaxCharacters
                    Text(row.label).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary).lineLimit(1)
                        .fixedSize(horizontal: !longName, vertical: false)
                        .frame(maxWidth: longName ? SHThreadMetrics.callVerbMaxWidth * ThemeStore.shared.textScale : nil, alignment: .leading)
                        .layoutPriority(1)
                    Text(row.detail).font(.sh(.mono)).foregroundStyle(sh.textSecondary).lineLimit(1)
                        .truncationMode(row.isPath ? .head : .tail)
                        .padding(.trailing, openInWidth > 0 ? openInWidth + SH.Space.m : 0)
                    statView(sh)
                        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statWidth = $0 }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SH.Space.xs)
                .frame(minHeight: SHThreadMetrics.callRowHeight)
                .padding(.vertical, SHThreadMetrics.callRowPress)
                #else
                HStack(spacing: 10) {
                    Text(row.label).foregroundStyle(sh.textTertiary).lineLimit(1).frame(width: labelWidth, alignment: .leading)
                    Text(row.detail).foregroundStyle(sh.textSecondary).lineLimit(1)
                        .truncationMode(row.isPath ? .head : .tail)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.trailing, openInWidth > 0 ? openInWidth + SH.Space.m : 0)
                    if let stat = row.stat {
                        Text(stat).foregroundStyle(row.failed ? sh.failed : sh.textTertiary).lineLimit(1).fixedSize().monospacedDigit()
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statWidth = $0 }
                    }
                }
                .font(.shMono(11))
                .padding(.horizontal, SH.Space.xs)
                .frame(minHeight: SHThreadMetrics.callRowHeight)
                #endif
            }
            .buttonStyle(.shRow(radius: SH.Radius.xs))
            .shOpenIn(row.filePath, hovering: hovering, trailing: SH.Space.xs + (row.stat == nil ? 0 : statWidth + 10), width: $openInWidth)
            // After the overlay: the button covers the pointer, and hover tracked beneath it would end, hide it, and loop.
            .onHover { hovering = row.filePath != nil && $0 }
            .padding(.horizontal, -SH.Space.xs)
            .padding(.vertical, -SHThreadMetrics.callRowPress)
            .contextMenu { menu(row) }
            .help(row.detail)
            .accessibilityLabel(row.accessibilityLabel)
            .accessibilityValue(row.output.isEmpty ? "" : row.isExpanded ? "Expanded" : "Collapsed")
            if row.isExpanded, !row.output.isEmpty {
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    Text(row.output.joined(separator: "\n"))
                        .font(.shMono(11))
                        .lineSpacing(SHThreadMetrics.tailLineSpacing)
                        .foregroundStyle(sh.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    if row.moreLines > 0 {
                        Button { onShowAll(row.id) } label: {
                            Text("… \(row.moreLines) more line\(row.moreLines == 1 ? "" : "s")")
                                .frame(minHeight: SHThreadMetrics.callRowHeight, alignment: .leading)
                                .padding(.vertical, SHThreadMetrics.callRowPress)
                        }
                        .buttonStyle(.shLink(font: .shMono(11)))
                        // Pressed over the call rows' 24pt, drawn and laid out at the board's 20.
                        .padding(.vertical, -SHThreadMetrics.callRowPress)
                    } else if row.truncated {
                        Button { onShowAll(row.id) } label: {
                            Text("Output truncated · open")
                                .frame(minHeight: SHThreadMetrics.callRowHeight, alignment: .leading)
                                .padding(.vertical, SHThreadMetrics.callRowPress)
                        }
                        .buttonStyle(.shLink(font: .shMono(11)))
                        // Pressed over the call rows' 24pt, drawn and laid out at the board's 20.
                        .padding(.vertical, -SHThreadMetrics.callRowPress)
                    }
                }
                .padding(.vertical, SH.Space.m)
                .padding(.horizontal, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.s))
                .padding(.leading, labelWidth + 10)
                .padding(.bottom, SH.Space.xs)
                .shTransition(.disclosure)
            }
        }
    }
}

// MARK: Changes card

/// One file in a changes card.
public struct SHChangedFile: Identifiable, Equatable, Sendable {
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

/// A changes card's last row once it lists `shown` of the `listed` files it has (the host sends a
/// turn's first 20) out of `total`: "Show 10 more" lists the next batch in place, so a turn of a
/// hundred files never floods the thread; past the listed files, "N more in Review" opens the pane.
public enum SHChangesMore: Equatable, Sendable {
    case show(Int)
    case review(Int)
    case none

    public init(shown: Int, listed: Int, total: Int) {
        if shown < listed {
            self = .show(min(SHThreadMetrics.changesMoreFiles, listed - shown))
        } else if total > shown {
            self = .review(total - shown)
        } else {
            self = .none
        }
    }

    public var text: String? {
        switch self {
        case .show(let count): "Show \(count) more"
        case .review(let count): "\(count) more in Review"
        case .none: nil
        }
    }
}

/// Ends every turn that edited files (ChangesCard(turn.changes), SHThread, Main): a header with
/// a 30pt tile, "Edited 5 files" over its diff stat, Undo and Review; then the first three files
/// as plain paths (the folder dims, the name reads first, "new" on a created file) and "Show N
/// more", which lists the next files (`SHChangesMore`). Review and the rows open the Changes pane on this turn. After Undo the card is one dashed line,
/// "Undid the agent’s edits to 5 files", with Redo (ChangesCard · after Undo).
public struct SHChangesCard: View {
    public enum Phase: Equatable, Sendable {
        case edited
        case undone
    }

    let title: String
    let added: Int
    let removed: Int
    let files: [SHChangedFile]
    let total: Int
    let phase: Phase
    let busy: Bool
    let notice: String?
    let onReview: (() -> Void)?
    let onOpen: ((String) -> Void)?
    let onUndo: (() -> Void)?
    let onRedo: (() -> Void)?
    @State private var shownCount = SHThreadMetrics.changesShownFiles

    /// `total` counts every file the turn changed (the card lists the first three); without it,
    /// `files` are all of them. `onUndo` and `onRedo` are left out where they can't apply (not the
    /// last turn, an older host); `busy` holds them while one runs; `notice` says why one refused.
    public init(title: String, added: Int, removed: Int, files: [SHChangedFile], total: Int? = nil, phase: Phase = .edited,
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
        VStack(alignment: .leading, spacing: SH.Space.s) {
            switch phase {
            case .edited: edited
            case .undone: undone
            }
            if let notice {
                Text(notice)
                    .font(.sh(.caption))
                    .foregroundStyle(Color.sh.failed)
                    .fixedSize(horizontal: false, vertical: true)
                    .shTransition(.content)
            }
        }
        .shAnimation(.content, value: phase)
        .shAnimation(.content, value: notice)
    }

    /// The boards' `.ed`: a raised card on the `lift` shadow, "Edited 7 files" and its stat with Undo
    /// and Review as words, then a row per file (its name, its folder dimmed after it, its stat and a
    /// bar of its size against the largest), and "Show N more".
    private var edited: some View {
        let sh = Color.sh
        let shown = Array(files.prefix(shownCount))
        let more = SHChangesMore(shown: shown.count, listed: files.count, total: total)
        let largest = max(1, files.map { $0.added + $0.removed }.max() ?? 1)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 10) {
                    Text(title).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    SHDiffStat(added: added, removed: removed, font: .sh(.caption))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if let onUndo {
                    Button("Undo", action: onUndo)
                        .buttonStyle(SHCardLinkStyle(dim: true))
                        .disabled(busy)
                        .help("Put back this turn’s edits in the worktree")
                        .accessibilityLabel("Undo the agent’s edits to \(total) file\(total == 1 ? "" : "s")")
                }
                if let onReview {
                    Button("Review", action: onReview)
                        .buttonStyle(SHCardLinkStyle(dim: false))
                        .accessibilityLabel("Review \(title)")
                }
            }
            .padding(EdgeInsets(top: SH.Space.l, leading: SHThreadMetrics.changesInset, bottom: SH.Space.s, trailing: SHThreadMetrics.changesInset))
            ForEach(shown) { file in
                SHChangedFileRow(file: file, largest: largest, label: label(file), onOpen: onOpen)
            }
            if more != .none { moreRow(more) }
        }
        .padding(.bottom, SH.Space.s)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: SHThreadMetrics.changesRadius))
        .shLift(RoundedRectangle(cornerRadius: SHThreadMetrics.changesRadius))
        .shBorder(sh.lineSubtle, radius: SHThreadMetrics.changesRadius)
        .accessibilityElement(children: .contain)
    }

    /// The Mac's (GXExpanded): the same raised card as the edited one, "Undid the agent’s edits to 7 files" in
    /// `textSecondary` and Redo as a word at its end; the iPhone and iPad keep the dashed line.
    @ViewBuilder private var undone: some View {
        #if os(macOS)
        let sh = Color.sh
        HStack(spacing: SH.Space.m + SH.Space.xxs) {
            Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRedo {
                Button("Redo", action: onRedo)
                    .buttonStyle(SHCardLinkStyle(dim: false))
                    .disabled(busy)
                    .help("Put the agent’s edits back")
            }
        }
        .padding(EdgeInsets(top: SH.Space.l, leading: SHThreadMetrics.changesInset, bottom: SHThreadMetrics.undoneBottom,
                            trailing: SHThreadMetrics.changesInset))
        .frame(maxWidth: .infinity)
        .shLift(RoundedRectangle(cornerRadius: SHThreadMetrics.changesRadius))
        .shBorder(sh.lineSubtle, radius: SHThreadMetrics.changesRadius)
        .accessibilityElement(children: .contain)
        #else
        dashedUndone
        #endif
    }

    private var dashedUndone: some View {
        let sh = Color.sh
        return HStack(spacing: 10) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 11, weight: .medium)).foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            Text(title).font(.sh(.ui, weight: .regular)).foregroundStyle(sh.textSecondary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let onRedo {
                Button("Redo", action: onRedo)
                    .buttonStyle(.sh(.ghost, size: .s))
                    .disabled(busy)
                    .help("Put the agent’s edits back")
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, SH.Space.l)
        .overlay {
            RoundedRectangle(cornerRadius: SHThreadMetrics.changesRadius)
                .strokeBorder(sh.lineStrong, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
        .accessibilityElement(children: .contain)
    }

    private func label(_ file: SHChangedFile) -> String {
        "\(file.path), \(statusWord(file.status)), \(file.added) added, \(file.removed) removed"
    }

    @ViewBuilder private func moreRow(_ more: SHChangesMore) -> some View {
        let text = if case .review(let count) = more, onReview == nil { "\(count) more" } else { more.text ?? "" }
        let label = HStack(spacing: SH.Space.s) {
            if case .show = more {
                Image(systemName: "chevron.down").font(.system(size: SHThreadMetrics.chevron, weight: .semibold)).accessibilityHidden(true)
            }
            Text(text)
        }
            .font(.sh(.caption)).foregroundStyle(Color.sh.textSecondary)
            .padding(.horizontal, SHThreadMetrics.changesInset)
            .frame(maxWidth: .infinity, minHeight: SHThreadMetrics.changesRowHeight, alignment: .leading)
            .contentShape(Rectangle())
        switch more {
        case .show(let count):
            Button { shownCount += count } label: { label }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityLabel("Show \(count) more files")
        case .review(let count):
            if let onReview {
                Button(action: onReview) { label }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityLabel("\(count) more files")
                    .accessibilityHint("Opens the Changes pane")
            } else {
                label
            }
        case .none:
            EmptyView()
        }
    }

    private func statusWord(_ status: SHChangedFile.Status) -> String {
        switch status {
        case .modified: "modified"
        case .added: "added"
        case .deleted: "deleted"
        }
    }
}

/// A changes card's file row (the boards' `.edf`): the name, its folder dimmed after it, "new" or "deleted", the stat, and a
/// 56pt-wide bar of its size against the card's largest, green for what it added; while the pointer is over it, Open in
/// <app> before the stat (OpenInD). A click opens the file in Shepherd.
private struct SHChangedFileRow: View {
    let file: SHChangedFile
    /// The card's largest file, in lines added and removed: its bar is the full width.
    let largest: Int
    let label: String
    let onOpen: ((String) -> Void)?
    @State private var hovering = false
    @State private var statWidth: CGFloat = 0
    @State private var openInWidth: CGFloat = 0

    var body: some View {
        let sh = Color.sh
        let content = HStack(spacing: SHThreadMetrics.changesColumnGap) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Text(file.name).font(.sh(.ui)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text(file.directory.hasSuffix("/") ? String(file.directory.dropLast()) : file.directory)
                    .font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1).truncationMode(.head)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.trailing, openInWidth > 0 ? openInWidth + SH.Space.m : 0)
            HStack(spacing: SHThreadMetrics.changesColumnGap) {
                HStack(spacing: SH.Space.s) {
                    if file.status != .modified {
                        Text(file.status == .added ? "new" : "deleted").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                    }
                    SHDiffStat(added: file.added, removed: file.removed, font: .sh(.caption), hidesZero: true)
                }
                bar
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { statWidth = $0 }
        }
        .padding(.horizontal, SHThreadMetrics.changesInset)
        .frame(minHeight: SHThreadMetrics.changesRowHeight)
        .contentShape(Rectangle())
        Group {
            if let onOpen {
                Button { onOpen(file.path) } label: { content }
                    .buttonStyle(.shRow(radius: 0))
                    .accessibilityLabel(label)
                    .accessibilityHint("Opens the file and what changed in it")
            } else {
                content.accessibilityElement(children: .ignore).accessibilityLabel(label)
            }
        }
        // A deleted file has nothing to open.
        .shOpenIn(file.status == .deleted ? nil : file.path, hovering: hovering, trailing: SHThreadMetrics.changesInset + statWidth + SH.Space.m,
                  width: $openInWidth)
        // After the overlay: the button covers the pointer, and hover tracked beneath it would end, hide it, and loop.
        .onHover { hovering = $0 }
    }

    /// The boards' `.bar`: right-aligned in its 56pt column, as wide as the file's share of the largest.
    private var bar: some View {
        let lines = max(1, file.added + file.removed)
        let width = max(SHThreadMetrics.changesBarHeight, SHThreadMetrics.changesBarWidth * CGFloat(lines) / CGFloat(max(largest, lines)))
        let green = width * CGFloat(file.added) / CGFloat(lines)
        return HStack(spacing: 0) {
            Color.sh.done.frame(width: green)
            Color.sh.failed
        }
        .frame(width: width, height: SHThreadMetrics.changesBarHeight)
        .clipShape(Capsule())
        .frame(width: SHThreadMetrics.changesBarWidth, alignment: .trailing)
        .accessibilityHidden(true)
    }
}

/// The changes card's Undo and Review: words, not buttons (the boards' `.lk`): Review in ink at medium, Undo dimmed.
struct SHCardLinkStyle: ButtonStyle {
    let dim: Bool

    func makeBody(configuration: Configuration) -> some View {
        SHCardLink(configuration: configuration, dim: dim)
    }
}

private struct SHCardLink: View {
    let configuration: ButtonStyleConfiguration
    let dim: Bool
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.sh(.ui, weight: dim ? .regular : .medium))
            .foregroundStyle(dim && !hovering ? Color.sh.textSecondary : Color.sh.textPrimary)
            .padding(.horizontal, SH.Space.xs)
            .frame(minHeight: SH.Height.controlS)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
            .shEnabledOpacity(enabled)
            .onHover { hovering = $0 }
            .shFocusRing(radius: SH.Radius.xs)
    }
}
