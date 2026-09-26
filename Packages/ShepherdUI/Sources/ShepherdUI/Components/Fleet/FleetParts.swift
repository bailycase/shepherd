import SwiftUI

// The phone and iPad boards' lists of threads and hosts (MobileAgents, MobileInbox, MobileMore,
// iPadSidebar, iPadOverview): rounded cards of rows, their section headers, host badges, and the
// Needs you card. Plain values in; interaction is the caller's.

/// The lists' own measures.
public enum NWListMetrics {
    /// A one-line row (the boards' 48pt, over the touch minimum).
    public static let rowHeight: CGFloat = 48
    /// A title over a status line: the boards' 52pt in thread and search lists (Home, Search,
    /// More). Choice lists (56), review files (58) and automations (64) have their own rows.
    public static let twoLineRowHeight: CGFloat = 52
    /// A card of rows (the boards' 12pt corners).
    public static let cardRadius: CGFloat = NW.Radius.l
    /// The leading column (dot or symbol), so titles line up whatever leads them.
    public static let leadingWidth: CGFloat = 20
    /// The status dot in a row.
    public static let dot: CGFloat = 7
    /// A Needs you card's glowing dot for a thread (MobileInbox).
    public static let attentionDot: CGFloat = 8
    /// A symbol in a row's leading column.
    public static let symbol: CGFloat = 15
    /// How far a host's address may shrink to stay on one line before it truncates.
    public static let addressMinimumScale: CGFloat = 0.6
    /// The lines a status line may wrap to at accessibility sizes, its time included.
    public static let accessibilityStatusLines = 3
    /// A row whose host is offline, or an automation switched off.
    public static let dimmedOpacity: Double = 0.55
}

/// A time beside a row's status line: counting up while something runs, or how long ago it moved.
public enum NWRowClock: Equatable, Sendable {
    case elapsed(since: Date)
    case ago(Date)
}

/// A list section's head (13/600): "Needs you  4" in lantern, "Recents" in secondary, with an
/// optional trailing count (mono, tertiary) or action.
public struct NWListHeader<Trailing: View>: View {
    let title: String
    let attention: Bool
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, attention: Bool = false, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.attention = attention
        self.trailing = trailing
    }

    public var body: some View {
        HStack(spacing: NW.Space.m) {
            Text(title)
                .font(.nw(.caption, weight: .semibold))
                .foregroundStyle(attention ? Color.nw.lanternText : Color.nw.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: NW.Space.xs)
            trailing()
        }
        .padding(.horizontal, NW.Space.xs)
    }
}

extension NWListHeader where Trailing == Text? {
    public init(_ title: String, attention: Bool = false, count: Int? = nil) {
        self.init(title, attention: attention) {
            count.map {
                Text("\($0)").font(.nw(.mono))
                    .foregroundStyle(attention ? Color.nw.lanternText : Color.nw.textTertiary)
            }
        }
    }
}

/// The host a row lives on, as a small bordered mono chip ("build-01").
public struct NWHostBadge: View {
    let name: String

    public init(_ name: String) { self.name = name }

    public var body: some View {
        Text(name)
            .font(.nw(.micro, weight: .regular))
            .foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, NW.Space.xs + NW.Space.xxs)
            .padding(.vertical, NW.Space.xxs)
            .nwBorder(Color.nw.lineStrong, radius: NW.Radius.xs)
            .fixedSize()
            .accessibilityLabel("on \(name)")
    }
}

/// One row of a list card: what leads it (a status dot or a symbol), a title over an optional
/// status line (with a live or "ago" time), one trailing accessory, and a chevron.
public struct NWListRow: View, Equatable {
    public enum Leading: Equatable, Sendable {
        case none
        /// A status dot: hollow while idle, glowing while it needs you.
        case state(AgentState)
        /// An SF Symbol, tinted by a state (lantern for attention) or secondary.
        case symbol(String, AgentState? = nil)
    }

    public enum Trailing: Equatable, Sendable {
        case none
        /// A plain value in tertiary ("System", "5").
        case value(String)
        /// Why it needs you, in lantern mono ("asked you").
        case reason(String)
        /// A problem, in failed mono ("1 host offline").
        case alert(String)
        /// The host it lives on.
        case host(String)
    }

    let title: String
    let subtitle: String?
    let subtitleMono: Bool
    let subtitleTone: AgentState?
    let clock: NWRowClock?
    let leading: Leading
    let trailing: Trailing
    let chevron: Bool
    let selected: Bool
    let dimmed: Bool
    @Environment(\.dynamicTypeSize) private var typeSize

    public init(_ title: String, subtitle: String? = nil, subtitleMono: Bool = true, subtitleTone: AgentState? = nil,
                clock: NWRowClock? = nil, leading: Leading = .none, trailing: Trailing = .none, chevron: Bool = true,
                selected: Bool = false, dimmed: Bool = false) {
        self.title = title
        self.subtitle = subtitle
        self.subtitleMono = subtitleMono
        self.subtitleTone = subtitleTone
        self.clock = clock
        self.leading = leading
        self.trailing = trailing
        self.chevron = chevron
        self.selected = selected
        self.dimmed = dimmed
    }

    public nonisolated static func == (a: NWListRow, b: NWListRow) -> Bool {
        a.title == b.title && a.subtitle == b.subtitle && a.subtitleMono == b.subtitleMono && a.subtitleTone == b.subtitleTone
            && a.clock == b.clock && a.leading == b.leading && a.trailing == b.trailing && a.chevron == b.chevron
            && a.selected == b.selected && a.dimmed == b.dimmed
    }

    public var body: some View {
        let nw = Color.nw
        HStack(spacing: NW.Space.l) {
            leadingView
                .frame(width: NWListMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                // At accessibility sizes a line may wrap once rather than lose most of its words.
                Text(title)
                    .font(.nw(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(nw.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                if subtitle != nil || clock != nil {
                    statusLine
                        .font(subtitleMono ? .nw(.mono) : .nw(.caption))
                        .foregroundStyle(subtitleTone?.textColor ?? nw.textTertiary)
                        .lineLimit(typeSize.isAccessibilitySize ? NWListMetrics.accessibilityStatusLines : 1)
                }
                // At accessibility sizes the accessory goes under the title, which keeps its width.
                if typeSize.isAccessibilitySize { trailingView }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { trailingView }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.nw(.caption, weight: .semibold))
                    .foregroundStyle(nw.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(maxWidth: .infinity,
               minHeight: subtitle != nil || clock != nil ? NWListMetrics.twoLineRowHeight : NWListMetrics.rowHeight,
               alignment: .leading)
        .background(selected ? nw.bgSelected : .clear)
        .opacity(dimmed ? NWListMetrics.dimmedOpacity : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var statusLine: some View {
        switch clock {
        case .none:
            Text(subtitle ?? "")
        case .elapsed(let since)?:
            TimelineView(NWElapsedSchedule(start: since, style: .long)) { context in
                timed(NWDuration.text(context.date.timeIntervalSince(since), .long))
            }
        case .ago(let at)?:
            TimelineView(NWElapsedSchedule(start: at)) { context in
                timed(NWDuration.text(context.date.timeIntervalSince(at)) + " ago")
            }
        }
    }

    /// The status with its time: a long command truncates, the time stays whole. At
    /// accessibility sizes the two wrap as one text, which a whole time beside would squeeze.
    @ViewBuilder private func timed(_ time: String) -> some View {
        if typeSize.isAccessibilitySize {
            Text(subtitle.map { "\($0) · \(time)" } ?? time)
        } else {
            HStack(spacing: 0) {
                if let subtitle { Text(subtitle) }
                Text(subtitle == nil ? time : " · " + time).fixedSize()
            }
        }
    }

    @ViewBuilder private var leadingView: some View {
        switch leading {
        case .none:
            EmptyView()
        case .state(let state):
            if state == .idle || state == .queued {
                Circle().strokeBorder(Color.nw.textTertiary, lineWidth: 1)
                    .frame(width: NWListMetrics.dot - 1, height: NWListMetrics.dot - 1)
                    .accessibilityHidden(true)
            } else {
                NWStatusDot(state, size: NWListMetrics.dot)
            }
        case .symbol(let name, let tone):
            // A glyph that needs you is lanternText; only a status dot glows in lantern.
            Image(systemName: name)
                .font(.nw(.ui, weight: .medium))
                .foregroundStyle(tone == .attention ? Color.nw.lanternText : tone?.color ?? Color.nw.textSecondary)
                .accessibilityHidden(true)
        }
    }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .value(let text):
            Text(text).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
        case .reason(let text):
            Text(text).font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.lanternText).lineLimit(1).fixedSize()
        case .alert(let text):
            Text(text).font(.nw(.micro, weight: .regular)).foregroundStyle(Color.nw.failed).lineLimit(1).fixedSize()
        case .host(let name):
            NWHostBadge(name)
        }
    }
}

/// A card of rows with a 1px rule between them (the boards' 12pt list cards).
public struct NWListCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { NWHairline() }
                    subview
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
        .nwCard(radius: NWListMetrics.cardRadius)
    }
}

/// A Needs you card (MobileInbox, iPadOverview): where it comes from and when, the thread, the
/// question, and the answers that fit in place. Its origin is a glyph in `lanternText` (a branch
/// for a subagent, a bolt for an automation run), or, for a thread (`symbol` nil), the glowing
/// 8pt lantern dot.
public struct NWAttentionCard<Actions: View>: View {
    let symbol: String?
    let origin: String
    let title: String
    let question: String
    let message: String?
    let since: Date?
    let host: String?
    let selected: Bool
    @ViewBuilder let actions: () -> Actions

    public init(symbol: String?, origin: String, title: String, question: String, message: String? = nil, since: Date? = nil,
                host: String? = nil, selected: Bool = false, @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.origin = origin
        self.title = title
        self.question = question
        self.message = message
        self.since = since
        self.host = host
        self.selected = selected
        self.actions = actions
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            // The kind, host and time share a line when they fit; otherwise the host and time drop under.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: NW.Space.s) {
                    originLine
                    Spacer(minLength: NW.Space.xs)
                    stamp
                }
                VStack(alignment: .leading, spacing: NW.Space.xs) {
                    originLine
                    stamp
                }
            }
            Text(title)
                .font(.nw(.ui, weight: .semibold))
                .foregroundStyle(nw.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(question).nwText(.caption).foregroundStyle(nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).nwText(.caption).foregroundStyle(nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            NWWrapStack(spacing: NW.Space.m, lineSpacing: NW.Space.xs) { actions() }
                .padding(.top, NW.Space.xxs)
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: NWListMetrics.cardRadius, fill: selected ? nw.bgSelected : nil, line: selected ? nw.lineStrong : nil)
        .accessibilityElement(children: .contain)
    }

    private var originLine: some View {
        HStack(spacing: NW.Space.s) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.nw(.caption, weight: .semibold))
                        .foregroundStyle(Color.nw.lanternText)
                } else {
                    NWStatusDot(.attention, size: NWListMetrics.attentionDot)
                }
            }
            .accessibilityHidden(true)
            Text(origin).font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).lineLimit(2)
        }
    }

    private var stamp: some View {
        HStack(spacing: NW.Space.s) {
            if let host { NWHostBadge(host) }
            if let since {
                TimelineView(NWElapsedSchedule(start: since)) { context in
                    Text(NWDuration.text(context.date.timeIntervalSince(since)))
                        .font(.nw(.caption)).foregroundStyle(Color.nw.textTertiary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// A host's card (MobileMore, iPadHosts): the name, its address, the connection, what runs there,
/// and actions (Retry) while it is offline.
public struct NWHostCard<Actions: View>: View {
    let name: String
    let address: String
    let state: AgentState
    let status: String
    let summary: String
    let summaryTone: AgentState?
    let openLabel: String?
    let open: (() -> Void)?
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `state` colors the connection: done while connected, running while connecting, failed
    /// while offline. With `open`, the card opens on a tap and shows a chevron (a button labeled
    /// `openLabel` for VoiceOver).
    public init(name: String, address: String, state: AgentState, status: String, summary: String,
                summaryTone: AgentState? = nil, openLabel: String? = nil, open: (() -> Void)? = nil,
                @ViewBuilder actions: @escaping () -> Actions) {
        self.name = name
        self.address = address
        self.state = state
        self.status = status
        self.summary = summary
        self.summaryTone = summaryTone
        self.openLabel = openLabel
        self.open = open
        self.actions = actions
    }

    public var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                Image(systemName: "desktopcomputer")
                    .font(.nw(.caption, weight: .medium))
                    .foregroundStyle(nw.textSecondary)
                    .accessibilityHidden(true)
                // Name, address and status share a line when they fit; at large text each takes its own.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: NW.Space.xxs) { nameText; addressText; statusView }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) { nameText; addressText }
                        VStack(alignment: .leading, spacing: NW.Space.xxs) { nameText; addressText }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusView
                }
                if let open {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                            .font(.nw(.caption, weight: .semibold))
                            .foregroundStyle(nw.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .nwTouchTarget(height: NW.Height.controlS, width: NW.Height.controlS)
                    .accessibilityLabel(openLabel ?? name)
                }
            }
            Text(summary)
                .nwText(.caption)
                .foregroundStyle(summaryTone?.textColor ?? nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            NWWrapStack(spacing: NW.Space.m, lineSpacing: NW.Space.xs) { actions() }
        }
        .padding(NW.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: NWListMetrics.cardRadius)
        .contentShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
        .onTapGesture { open?() }
        .accessibilityElement(children: .contain)
    }

    private var statusView: some View {
        HStack(spacing: NW.Space.xs) {
            NWStatusDot(state, size: NWListMetrics.dot - 1)
            Text(status).font(.nw(.caption, weight: .medium)).foregroundStyle(state.textColor)
        }
        .fixedSize()
    }

    private var nameText: some View {
        Text(name).font(.nw(.ui, weight: .semibold)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
    }

    private var addressText: some View {
        // One line at any size: an address broken mid-number reads as two.
        Text(address).font(.nw(.mono)).foregroundStyle(Color.nw.textTertiary)
            .lineLimit(1).minimumScaleFactor(NWListMetrics.addressMinimumScale).truncationMode(.middle)
    }
}

/// Lays its children out in rows, wrapping to a new row when the next one does not fit (a card's
/// buttons at large text). Empty when it has no children.
public struct NWWrapStack: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    public init(spacing: CGFloat = NW.Space.m, lineSpacing: CGFloat = NW.Space.m) {
        self.spacing = spacing
        self.lineSpacing = lineSpacing
    }

    public func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + CGFloat(max(0, rows.count - 1)) * lineSpacing
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    public func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
                subviews[index].place(at: CGPoint(x: x, y: y + (row.height - size.height) / 2), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + lineSpacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var row = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: width, height: nil))
            let needed = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            if !row.indices.isEmpty, needed > width {
                rows.append(row)
                row = Row()
            }
            row.width = row.indices.isEmpty ? size.width : row.width + spacing + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
        }
        if !row.indices.isEmpty { rows.append(row) }
        return rows
    }
}
