import SwiftUI

// The glance surfaces' shared parts: their measures, the state marks, rows, the subagent line
// and the buttons. WidgetKit draws each surface once per update and runs no animation or
// platform view, so every mark here is a plain shape: a spinner is a still arc, the attention
// dot has no glow, and a running time counts through `Text(timerInterval:)`.

/// The glance boards' measures (GlanceWatch … GlanceControls).
public enum SHGlanceMetrics {
    /// A card's title (14/600) and lead (13.5/600).
    public static let title: CGFloat = 14
    public static let lead: CGFloat = 13.5
    /// Body lines: what it does now, the question, a result.
    public static let body: CGFloat = 13
    /// A row's title (12.5/500).
    public static let row: CGFloat = 12.5
    /// Meta (host, time, tags) in mono.
    public static let mono: CGFloat = 11.5
    /// Group heads and footers.
    public static let micro: CGFloat = 10.5
    /// A row's height in a list.
    public static let rowHeight: CGFloat = 19
    /// The leading mark of a card's header and lead.
    public static let mark: CGFloat = 15
    /// A row's state dot.
    public static let dot: CGFloat = 7
    /// A card button: a 34pt capsule (38 in the island).
    public static let button: CGFloat = 34
    public static let islandButton: CGFloat = 38
    public static let buttonText: CGFloat = 13.5
    /// The island's compact count or time, and the minimal dot.
    public static let compactText: CGFloat = 12.5
    public static let minimalDot: CGFloat = 9
    /// The circular accessory's count.
    public static let accessoryCount: CGFloat = 26
    /// Rows a Live Activity lists under its lead, and what a widget lists by size.
    public static let watchRows = 3
    public static let mediumRows = 5
    public static let largeRows = 12
    public static let columnRows = 9
}

/// A thread's state as a dot: filled in its color, never glowing (a widget runs no animation).
public struct SHGlanceDot: View {
    let state: SHGlance.State
    let size: CGFloat

    public init(_ state: SHGlance.State, size: CGFloat = SHGlanceMetrics.dot) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        Circle().fill(state.agentState.color).frame(width: size, height: size).accessibilityHidden(true)
    }
}

/// A card's leading mark: a still spinner arc while running, the crook while it needs you, the
/// state's symbol otherwise; a clock when the card is stale.
public struct SHGlanceMark: View {
    let state: SHGlance.State?
    let stale: Bool
    let size: CGFloat

    public init(_ state: SHGlance.State?, stale: Bool = false, size: CGFloat = SHGlanceMetrics.mark) {
        self.state = state
        self.stale = stale
        self.size = size
    }

    public var body: some View {
        Group {
            if stale {
                Image(systemName: "clock").font(.system(size: size - 2, weight: .medium)).foregroundStyle(Color.sh.textTertiary)
            } else {
                switch state {
                case .running:
                    Circle().trim(from: 0, to: 0.75)
                        .stroke(Color.sh.running, style: StrokeStyle(lineWidth: size / 9, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .padding(size / 7)
                case .done, .failed:
                    Image(systemName: state?.agentState.symbolName ?? "")
                        .font(.system(size: size - 3, weight: .semibold))
                        .foregroundStyle(state?.agentState.color ?? Color.sh.textTertiary)
                case .needsYou, nil:
                    SHGlanceCrook(color: state == nil ? Color.sh.textTertiary : Color.sh.lantern)
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The crook, in a color of the caller's (SHCrook is always lantern).
public struct SHGlanceCrook: View {
    let color: Color

    public init(color: Color) { self.color = color }

    public var body: some View {
        GeometryReader { geo in
            SHCrookShape().stroke(color, style: StrokeStyle(lineWidth: 2.4 * min(geo.size.width, geo.size.height) / 24,
                                                            lineCap: .round, lineJoin: .round))
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
    }
}

/// A running time counting up from `since` ("37:12"), drawn by the system so it keeps counting
/// between updates.
public struct SHGlanceElapsed: View {
    let since: Date
    let size: CGFloat

    public init(since: Date, size: CGFloat = SHGlanceMetrics.mono) {
        self.since = since
        self.size = size
    }

    public var body: some View {
        Text(timerInterval: since...Date.distantFuture, countsDown: false)
            .font(.shMono(size, .semibold))
            .monospacedDigit()
            .foregroundStyle(Color.sh.running)
            .multilineTextAlignment(.trailing)
            .lineLimit(1)
            .fixedSize()
    }
}

/// How long ago (mono, tertiary): "2m", "1h", "3d".
public struct SHGlanceAgo: View {
    let date: Date
    let now: Date

    public init(_ date: Date, now: Date) {
        self.date = date
        self.now = now
    }

    public var body: some View {
        Text(Self.text(date, now: now))
            .font(.shMono(SHGlanceMetrics.mono))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
            .fixedSize()
    }

    public static func text(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        switch seconds {
        case ..<60: return "now"
        case ..<3600: return "\(Int(seconds / 60))m"
        case ..<86_400: return "\(Int(seconds / 3600))h"
        default: return "\(Int(seconds / 86_400))d"
        }
    }
}

/// "+67 −48" (mono, in `done` and `failed`).
public struct SHGlanceDiff: View {
    let changes: SHGlance.Changes

    public init(_ changes: SHGlance.Changes) { self.changes = changes }

    public var body: some View {
        SHDiffStat(added: changes.added, removed: changes.removed, font: .shMono(SHGlanceMetrics.mono))
    }
}

/// A thread's subagents (MobileSubagents' tray head): a dot each, then "1 running · 1 waiting on
/// parent · 1 done".
public struct SHGlanceSubagents: View {
    let subagents: SHGlance.Subagents

    public init(_ subagents: SHGlance.Subagents) { self.subagents = subagents }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            SHBranchGlyph(.running, size: SHGlanceMetrics.mark - 2, color: Color.sh.textTertiary)
            HStack(spacing: SH.Space.xxs) {
                ForEach(Array(dots.enumerated()), id: \.offset) { _, state in
                    if let state {
                        Circle().fill(state.color).frame(width: SHGlanceMetrics.dot - 1, height: SHGlanceMetrics.dot - 1)
                    } else {
                        Circle().strokeBorder(Color.sh.textTertiary, lineWidth: 1).frame(width: SHGlanceMetrics.dot - 1, height: SHGlanceMetrics.dot - 1)
                    }
                }
            }
            Text(line).font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(line)
    }

    /// One dot per subagent, at most six: running, waiting (hollow), done.
    private var dots: [AgentState?] {
        Array((Array(repeating: AgentState.running, count: subagents.running) as [AgentState?]
            + Array(repeating: nil, count: subagents.waiting)
            + Array(repeating: AgentState.done, count: subagents.done)).prefix(6))
    }

    var line: String {
        var parts: [String] = []
        if subagents.running > 0 { parts.append("\(subagents.running) running") }
        if subagents.waiting > 0 { parts.append("\(subagents.waiting) waiting on parent") }
        if subagents.done > 0 { parts.append("\(subagents.done) done") }
        return parts.joined(separator: " · ")
    }
}

/// One thread in a list: its dot, its title, and on the right what matters for its state (the
/// tag it waits with, how long it has run, when it finished).
public struct SHGlanceRow: View {
    let item: SHGlance.Item
    let now: Date
    let stale: Bool

    public init(_ item: SHGlance.Item, now: Date, stale: Bool = false) {
        self.item = item
        self.now = now
        self.stale = stale
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            if stale && item.state == .running {
                Circle().strokeBorder(Color.sh.textTertiary, lineWidth: 1.5).frame(width: SHGlanceMetrics.dot, height: SHGlanceMetrics.dot)
            } else {
                SHGlanceDot(item.state)
            }
            Text(item.title)
                .font(.shSans(SHGlanceMetrics.row, .medium))
                .foregroundStyle(stale ? Color.sh.textSecondary : Color.sh.textPrimary)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            trailing
        }
        .frame(height: SHGlanceMetrics.rowHeight)
    }

    @ViewBuilder private var trailing: some View {
        switch item.state {
        case .needsYou:
            if let tag = item.tag {
                Text(tag).font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.lanternText).lineLimit(1).fixedSize()
            }
        case .failed:
            Text("failed").font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.failed).fixedSize()
        case .running:
            if stale {
                Text("unknown").font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textTertiary).fixedSize()
            } else if let since = item.since {
                // A row says how long in whole minutes; only a card's lead counts live.
                SHGlanceAgo(since, now: now)
            }
        case .done:
            if let since = item.since { SHGlanceAgo(since, now: now) }
        }
    }
}

/// A group's head in a list: "Needs you 3" in lantern, "Working 4", "Done today 2".
public struct SHGlanceGroupHead: View {
    let title: String
    let count: Int
    let attention: Bool

    public init(_ title: String, count: Int, attention: Bool = false) {
        self.title = title
        self.count = count
        self.attention = attention
    }

    public var body: some View {
        HStack(spacing: SH.Space.xs) {
            Text(title).font(.shSans(SHGlanceMetrics.micro, .semibold))
            Text("\(count)").font(.shMono(SHGlanceMetrics.micro))
        }
        .foregroundStyle(attention ? Color.sh.lanternText : Color.sh.textSecondary)
    }
}

/// A card button's face: a 34pt capsule sharing the row (38 in the island); Reply… keeps its
/// own width so the answers get the rest. The recommended
/// answer is the one primary, lantern on `textOnLantern`; Stop's word is `failed`.
public struct SHGlanceButtonLabel: View {
    let action: SHGlanceAction
    let island: Bool

    public init(_ action: SHGlanceAction, island: Bool = false) {
        self.action = action
        self.island = island
    }

    public var body: some View {
        let sh = Color.sh
        let height = island ? SHGlanceMetrics.islandButton : SHGlanceMetrics.button
        let fits = action == .reply
        Text(action.title)
            .font(.shSans(SHGlanceMetrics.buttonText, .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .fixedSize(horizontal: fits, vertical: false)
            .foregroundStyle(action.isPrimary ? sh.textOnLantern : action == .stop ? sh.failed : island ? sh.islandText : sh.textPrimary)
            .padding(.horizontal, SH.Space.l)
            .frame(maxWidth: fits ? nil : .infinity)
            .frame(height: height)
            .background(action.isPrimary ? sh.lantern : island ? sh.islandFill : sh.bgSelected, in: Capsule())
    }
}

/// A card's buttons, 8pt apart, each made by the surface (`make`: an App Intent's button, a link).
public struct SHGlanceButtons<Button: View>: View {
    let actions: [SHGlanceAction]
    let make: (SHGlanceAction) -> Button

    public init(_ actions: [SHGlanceAction], @ViewBuilder make: @escaping (SHGlanceAction) -> Button) {
        self.actions = actions
        self.make = make
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            // A widget archives its views: a ForEach's ids must be Encodable.
            ForEach(actions, id: \.self) { action in make(action) }
        }
    }
}
