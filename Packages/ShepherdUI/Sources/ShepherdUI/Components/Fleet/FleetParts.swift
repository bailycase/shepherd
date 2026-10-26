import SwiftUI

// The phone and iPad boards' lists of threads and hosts (MobileAgents, MobileInbox, MobileMore,
// iPadSidebar, iPadOverview): rounded cards of rows, their section headers, host badges, and the
// Needs you card. Plain values in; interaction is the caller's.

/// The lists' own measures.
public enum SHListMetrics {
    /// A one-line row (the boards' 48pt, over the touch minimum).
    public static let rowHeight: CGFloat = 48
    /// A one-line row in the iPad sidebar (iPadThread: 44pt, the touch minimum).
    public static let compactRowHeight: CGFloat = SH.Height.touch
    /// The iPad sidebar's New thread badge: its glyph in a `bgSelected` circle.
    public static let badge: CGFloat = 20
    /// A title over a status line: the boards' 52pt in thread and search lists (Home, Search,
    /// More). Choice lists (56), review files (58) and automations (64) have their own rows.
    public static let twoLineRowHeight: CGFloat = 52
    /// A card of rows (the boards' 12pt corners).
    public static let cardRadius: CGFloat = SH.Radius.l
    /// The leading column (dot or symbol), so titles line up whatever leads them.
    public static let leadingWidth: CGFloat = 20
    /// The status dot in a row.
    public static let dot: CGFloat = 7
    /// A Needs you card's glowing dot for a thread (MobileInbox).
    public static let attentionDot: CGFloat = 8
    /// A list head's title: the phone boards' 13pt, between the ramp's caption and ui.
    public static let headSize: CGFloat = 13
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
public enum SHRowClock: Equatable, Sendable {
    case elapsed(since: Date)
    case ago(Date)
}

/// A list section's head (13/600): "Needs you  4" in lantern, "Recents" in secondary, with an
/// optional trailing count (mono, tertiary) or action.
public struct SHListHeader<Trailing: View>: View {
    /// A list's head (the phone boards': 13/600 in `textSecondary`), or the iPad sidebar's
    /// quieter one (iPadThread: 13/500, a plain head in `textTertiary`).
    public enum Style: Sendable {
        case list, sidebar
    }

    let title: String
    let attention: Bool
    let style: Style
    @ViewBuilder let trailing: () -> Trailing

    public init(_ title: String, attention: Bool = false, style: Style = .list, @ViewBuilder trailing: @escaping () -> Trailing) {
        self.title = title
        self.attention = attention
        self.style = style
        self.trailing = trailing
    }

    public var body: some View {
        let sidebar = style == .sidebar
        HStack(spacing: SH.Space.m) {
            Text(title)
                .font(.shSans(SHListMetrics.headSize, sidebar ? .medium : .semibold))
                .foregroundStyle(attention ? Color.sh.lanternText : sidebar ? Color.sh.textTertiary : Color.sh.textSecondary)
                .accessibilityAddTraits(.isHeader)
            Spacer(minLength: SH.Space.xs)
            trailing()
        }
        .padding(.horizontal, SH.Space.xs)
    }
}

extension SHListHeader where Trailing == Text? {
    public init(_ title: String, attention: Bool = false, count: Int? = nil, style: Style = .list) {
        self.init(title, attention: attention, style: style) {
            count.map {
                Text("\($0)").font(.sh(.mono))
                    .foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textTertiary)
            }
        }
    }
}

/// The host a row lives on, as a small bordered mono chip ("build-01").
public struct SHHostBadge: View {
    let name: String

    public init(_ name: String) { self.name = name }

    public var body: some View {
        Text(name)
            .font(.sh(.micro, weight: .regular))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.xs + SH.Space.xxs)
            .padding(.vertical, SH.Space.xxs)
            .shBorder(Color.sh.lineStrong, radius: SH.Radius.xs)
            .fixedSize()
            .accessibilityLabel("on \(name)")
    }
}

/// One row of a list card: what leads it (a status dot or a symbol), a title over an optional
/// status line (with a live or "ago" time), one trailing accessory, and a chevron.
public struct SHListRow: View, Equatable {
    public enum Leading: Equatable, Sendable {
        case none
        /// A status dot: hollow while idle, glowing while it needs you.
        case state(AgentState)
        /// An SF Symbol, tinted by a state (lantern for attention) or secondary.
        case symbol(String, AgentState? = nil)
        /// A symbol in a 20pt `bgSelected` circle (the iPad sidebar's New thread).
        case badge(String)
        /// A state's 14pt glyph (`SHStateGlyph`: the spinner while running; iPadOverview).
        case glyph(AgentState)
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
        /// A quiet word in mono (the iPad sidebar's "failed", "done").
        case meta(String)
    }

    let title: String
    let subtitle: String?
    let subtitleMono: Bool
    let subtitleTone: AgentState?
    let clock: SHRowClock?
    let leading: Leading
    let trailing: Trailing
    let chevron: Bool
    let selected: Bool
    let dimmed: Bool
    let compact: Bool
    let indent: CGFloat
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `compact` rows are 44pt, the iPad sidebar's; others 48 (52 with a status line). `indent`
    /// moves the content in while the row (and its selection) keeps the full width (the iPad
    /// sidebar's More sub-rows).
    public init(_ title: String, subtitle: String? = nil, subtitleMono: Bool = true, subtitleTone: AgentState? = nil,
                clock: SHRowClock? = nil, leading: Leading = .none, trailing: Trailing = .none, chevron: Bool = true,
                selected: Bool = false, dimmed: Bool = false, compact: Bool = false, indent: CGFloat = 0) {
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
        self.compact = compact
        self.indent = indent
    }

    public nonisolated static func == (a: SHListRow, b: SHListRow) -> Bool {
        a.title == b.title && a.subtitle == b.subtitle && a.subtitleMono == b.subtitleMono && a.subtitleTone == b.subtitleTone
            && a.clock == b.clock && a.leading == b.leading && a.trailing == b.trailing && a.chevron == b.chevron
            && a.selected == b.selected && a.dimmed == b.dimmed && a.compact == b.compact && a.indent == b.indent
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            leadingView
                .frame(width: SHListMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                // At accessibility sizes a line may wrap once rather than lose most of its words.
                Text(title)
                    .font(.sh(.ui, weight: selected ? .semibold : .medium))
                    .foregroundStyle(sh.textPrimary)
                    .lineLimit(typeSize.isAccessibilitySize ? 2 : 1)
                if subtitle != nil || clock != nil {
                    statusLine
                        .font(subtitleMono ? .sh(.mono) : .sh(.caption))
                        .foregroundStyle(subtitleTone?.textColor ?? sh.textTertiary)
                        .lineLimit(typeSize.isAccessibilitySize ? SHListMetrics.accessibilityStatusLines : 1)
                }
                // At accessibility sizes the accessory goes under the title, which keeps its width.
                if typeSize.isAccessibilitySize { trailingView }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { trailingView }
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.sh(.caption, weight: .semibold))
                    .foregroundStyle(sh.textTertiary)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, SH.Space.l + indent)
        .padding(.trailing, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity,
               minHeight: subtitle != nil || clock != nil ? SHListMetrics.twoLineRowHeight
                   : compact ? SHListMetrics.compactRowHeight : SHListMetrics.rowHeight,
               alignment: .leading)
        .background(selected ? sh.bgSelected : .clear)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder private var statusLine: some View {
        switch clock {
        case .none:
            Text(subtitle ?? "")
        case .elapsed(let since)?:
            TimelineView(SHElapsedSchedule(start: since, style: .long)) { context in
                timed(SHDuration.text(context.date.timeIntervalSince(since), .long))
            }
        case .ago(let at)?:
            TimelineView(SHElapsedSchedule(start: at)) { context in
                timed(SHDuration.text(context.date.timeIntervalSince(at)) + " ago")
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

    private var leadingView: some View { SHListLeading(leading: leading) }

    @ViewBuilder private var trailingView: some View {
        switch trailing {
        case .none:
            EmptyView()
        case .value(let text):
            Text(text).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        case .reason(let text):
            Text(text).font(.sh(.micro, weight: .regular)).foregroundStyle(Color.sh.lanternText).lineLimit(1).fixedSize()
        case .alert(let text):
            Text(text).font(.sh(.micro, weight: .regular)).foregroundStyle(Color.sh.failed).lineLimit(1).fixedSize()
        case .host(let name):
            SHHostBadge(name)
        case .meta(let text):
            Text(text).font(.sh(.micro, weight: .regular)).foregroundStyle(Color.sh.textTertiary).lineLimit(1).fixedSize()
        }
    }
}

/// A list row's leading column: a status dot, a symbol, or the New thread badge.
struct SHListLeading: View {
    let leading: SHListRow.Leading

    var body: some View {
        switch leading {
        case .none:
            EmptyView()
        case .state(let state):
            if state == .idle || state == .queued {
                Circle().strokeBorder(Color.sh.textTertiary, lineWidth: 1)
                    .frame(width: SHListMetrics.dot - 1, height: SHListMetrics.dot - 1)
                    .accessibilityHidden(true)
            } else {
                SHStatusDot(state, size: SHListMetrics.dot)
            }
        case .symbol(let name, let tone):
            // A glyph that needs you is lanternText; only a status dot glows in lantern.
            Image(systemName: name)
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(tone == .attention ? Color.sh.lanternText : tone?.color ?? Color.sh.textSecondary)
                .accessibilityHidden(true)
        case .glyph(let state):
            SHStateGlyph(state)
        case .badge(let name):
            Image(systemName: name)
                .font(.sh(.micro, weight: .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .frame(width: SHListMetrics.badge, height: SHListMetrics.badge)
                .background(Color.sh.bgSelected, in: Circle())
                .accessibilityHidden(true)
        }
    }
}

/// A card's caption band (iPadOverview: "THREADS · 3", "TODAY"): the section label on `bgSunken`,
/// 8×12 inside, over the card's rows.
public struct SHCaptionBand: View {
    let text: String

    public init(_ text: String) { self.text = text }

    public var body: some View {
        Text(text)
            .shSectionLabel()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
            .background(Color.sh.bgSunken)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A row of the iPad overview's Running now and Finished cards (iPadOverview): the state in a
/// 16pt column, the title (14/500, `.ui`) with its time trailing in mono, and a line under it: what
/// it does now in mono, or how it ended.
public struct SHOverviewRow: View, Equatable {
    public enum Time: Equatable, Sendable {
        case none
        /// A fixed stamp ("11:02", "Mon").
        case text(String)
        /// Counting up from a moment ("4:12", "37m").
        case elapsed(since: Date)
    }

    let title: String
    let detail: String
    let detailMono: Bool
    let leading: SHListRow.Leading
    let time: Time
    let dimmed: Bool

    public init(_ title: String, detail: String, detailMono: Bool = true, leading: SHListRow.Leading, time: Time = .none,
                dimmed: Bool = false) {
        self.title = title
        self.detail = detail
        self.detailMono = detailMono
        self.leading = leading
        self.time = time
        self.dimmed = dimmed
    }

    public var body: some View {
        let sh = Color.sh
        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
            SHListLeading(leading: leading)
                .frame(width: SHOverviewMetrics.leadingWidth)
                .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + SHOverviewMetrics.leadingBaselineOffset }
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(title).font(.sh(.ui, weight: .medium)).foregroundStyle(sh.textPrimary).lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    timeView.font(.sh(.micro, weight: .regular)).foregroundStyle(sh.textTertiary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
                Text(detail).font(detailMono ? .sh(.mono) : .sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
            }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SHListMetrics.twoLineRowHeight, alignment: .leading)
        .opacity(dimmed ? SHListMetrics.dimmedOpacity : 1)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var timeView: some View {
        switch time {
        case .none: EmptyView()
        case .text(let text): Text(text)
        case .elapsed(let since):
            TimelineView(SHElapsedSchedule(start: since)) { context in
                Text(SHDuration.text(context.date.timeIntervalSince(since)))
            }
        }
    }
}

/// The overview rows' measures (iPadOverview).
public enum SHOverviewMetrics {
    /// The state column.
    public static let leadingWidth: CGFloat = 16
    /// Lifts a dot or glyph from the title's baseline to its middle.
    public static let leadingBaselineOffset: CGFloat = SH.Space.xs
}

/// A card of rows with a 1px rule between them (the boards' 12pt list cards).
public struct SHListCard<Content: View>: View {
    @ViewBuilder let content: () -> Content

    public init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    public var body: some View {
        VStack(spacing: 0) {
            Group(subviews: content()) { subviews in
                ForEach(subviews) { subview in
                    if subview.id != subviews.first?.id { SHHairline() }
                    subview
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
        .shCard(radius: SHListMetrics.cardRadius)
    }
}

/// A Needs you card (MobileInbox, iPadOverview): where it comes from and when, the thread, the
/// question, and the answers that fit in place. Its origin is a glyph in `lanternText` (a branch
/// for a subagent, a bolt for an automation run), or, for a thread (`symbol` nil), the glowing
/// 8pt lantern dot.
public struct SHAttentionCard<Actions: View>: View {
    /// A card (MobileInbox, iPadOverview), or a flat item of the iPad inbox's list (iPadInbox:
    /// no line, `bgSelected` while chosen).
    public enum Style: Sendable {
        case card, item
    }

    let symbol: String?
    let origin: String
    let title: String
    let question: String
    let message: String?
    let since: Date?
    let host: String?
    let selected: Bool
    let style: Style
    @ViewBuilder let actions: () -> Actions

    public init(symbol: String?, origin: String, title: String, question: String, message: String? = nil, since: Date? = nil,
                host: String? = nil, selected: Bool = false, style: Style = .card, @ViewBuilder actions: @escaping () -> Actions) {
        self.symbol = symbol
        self.origin = origin
        self.title = title
        self.question = question
        self.message = message
        self.since = since
        self.host = host
        self.selected = selected
        self.style = style
        self.actions = actions
    }

    public var body: some View {
        let sh = Color.sh
        let card = VStack(alignment: .leading, spacing: SH.Space.s) {
            // The kind, host and time share a line when they fit; otherwise the host and time drop under.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: SH.Space.s) {
                    originLine
                    Spacer(minLength: SH.Space.xs)
                    stamp
                }
                VStack(alignment: .leading, spacing: SH.Space.xs) {
                    originLine
                    stamp
                }
            }
            Text(title)
                .font(.sh(.ui, weight: .semibold))
                .foregroundStyle(sh.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(question).shText(.caption).foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message {
                    Text(message).shText(.caption).foregroundStyle(sh.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            if style == .card {
                SHWrapStack(spacing: SH.Space.m, lineSpacing: SH.Space.xs) { actions() }
                    .padding(.top, SH.Space.xxs)
            }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        Group {
            switch style {
            case .card:
                card.shCard(radius: SHListMetrics.cardRadius, fill: selected ? sh.bgSelected : nil, line: selected ? sh.lineStrong : nil)
            case .item:
                card.background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var originLine: some View {
        HStack(spacing: SH.Space.s) {
            Group {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.sh(.caption, weight: .semibold))
                        .foregroundStyle(Color.sh.lanternText)
                } else {
                    SHStatusDot(.attention, size: SHListMetrics.attentionDot)
                }
            }
            .accessibilityHidden(true)
            Text(origin).font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
        }
    }

    private var stamp: some View {
        HStack(spacing: SH.Space.s) {
            if let host { SHHostBadge(host) }
            if let since {
                TimelineView(SHElapsedSchedule(start: since)) { context in
                    Text(SHDuration.text(context.date.timeIntervalSince(since)))
                        .font(.sh(.caption)).foregroundStyle(Color.sh.textTertiary).monospacedDigit()
                        .lineLimit(1).fixedSize()
                }
            }
        }
    }
}

/// A host in the iPad Hosts list (iPadHosts): a 16pt `textSecondary` glyph, the name in mono
/// semibold over what it carries (12 `textTertiary`), and an 8pt status dot trailing; at least
/// 64pt, the chosen one on `bgSelected`.
public struct SHHostRow: View, Equatable {
    let name: String
    let detail: String
    let state: AgentState
    let selected: Bool

    public init(name: String, detail: String, state: AgentState, selected: Bool = false) {
        self.name = name
        self.detail = detail
        self.state = state
        self.selected = selected
    }

    public var body: some View {
        let sh = Color.sh
        HStack(spacing: SH.Space.l) {
            Image(systemName: "desktopcomputer")
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textSecondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(name).font(.sh(.code, weight: .semibold)).foregroundStyle(sh.textPrimary).lineLimit(1)
                Text(detail).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            SHStatusDot(state, size: SHListMetrics.attentionDot)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(maxWidth: .infinity, minHeight: SHHostRow.minHeight, alignment: .leading)
        .background(selected ? sh.bgSelected : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// The board's 64pt rows.
    public static let minHeight: CGFloat = 64
}

/// A host's card (MobileMore, iPadHosts): the name, its address, the connection, what runs there,
/// and actions (Retry) while it is offline.
public struct SHHostCard<Actions: View>: View {
    let name: String
    let address: String
    let state: AgentState
    let status: String
    let summary: String
    let summaryTone: AgentState?
    let detail: String?
    let openLabel: String?
    let open: (() -> Void)?
    @ViewBuilder let actions: () -> Actions
    @Environment(\.dynamicTypeSize) private var typeSize

    /// `state` colors the connection: done while connected, running while connecting, failed
    /// while offline. `detail` is a line under the summary ("Last seen today 07:12"). With `open`,
    /// the card opens on a tap and shows a chevron (a button labeled `openLabel` for VoiceOver).
    public init(name: String, address: String, state: AgentState, status: String, summary: String,
                summaryTone: AgentState? = nil, detail: String? = nil, openLabel: String? = nil, open: (() -> Void)? = nil,
                @ViewBuilder actions: @escaping () -> Actions) {
        self.name = name
        self.address = address
        self.state = state
        self.status = status
        self.summary = summary
        self.summaryTone = summaryTone
        self.detail = detail
        self.openLabel = openLabel
        self.open = open
        self.actions = actions
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                Image(systemName: "desktopcomputer")
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(sh.textSecondary)
                    .accessibilityHidden(true)
                // Name, address and status share a line when they fit; at large text each takes its own.
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: SH.Space.xxs) { nameText; addressText; statusView }
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) { nameText; addressText }
                        VStack(alignment: .leading, spacing: SH.Space.xxs) { nameText; addressText }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    statusView
                }
                if let open {
                    Button(action: open) {
                        Image(systemName: "chevron.right")
                            .font(.sh(.caption, weight: .semibold))
                            .foregroundStyle(sh.textTertiary)
                    }
                    .buttonStyle(.plain)
                    .shTouchTarget(height: SH.Height.controlS, width: SH.Height.controlS)
                    .accessibilityLabel(openLabel ?? name)
                }
            }
            Text(summary)
                .shText(.caption)
                .foregroundStyle(summaryTone?.textColor ?? sh.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if let detail {
                Text(detail).shText(.caption).foregroundStyle(sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            SHWrapStack(spacing: SH.Space.m, lineSpacing: SH.Space.xs) { actions() }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHListMetrics.cardRadius)
        .contentShape(RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
        .onTapGesture { open?() }
        .accessibilityElement(children: .contain)
    }

    private var statusView: some View {
        HStack(spacing: SH.Space.xs) {
            SHStatusDot(state, size: SHListMetrics.dot - 1)
            Text(status).font(.sh(.caption, weight: .medium)).foregroundStyle(state.textColor)
        }
        .fixedSize()
    }

    private var nameText: some View {
        Text(name).font(.sh(.ui, weight: .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
    }

    private var addressText: some View {
        // One line at any size: an address broken mid-number reads as two.
        Text(address).font(.sh(.mono)).foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1).minimumScaleFactor(SHListMetrics.addressMinimumScale).truncationMode(.middle)
    }
}

/// Lays its children out in rows, wrapping to a new row when the next one does not fit (a card's
/// buttons at large text). Empty when it has no children.
public struct SHWrapStack: Layout {
    let spacing: CGFloat
    let lineSpacing: CGFloat

    public init(spacing: CGFloat = SH.Space.m, lineSpacing: CGFloat = SH.Space.m) {
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
