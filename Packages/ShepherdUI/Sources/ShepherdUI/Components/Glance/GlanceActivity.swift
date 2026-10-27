import SwiftUI

// The Live Activities (GlanceWatch, GlanceFollow) and their Dynamic Island (GlanceIsland). Each
// card is its content only: the Lock Screen's card, its background and corners are the system's
// (`activityBackgroundTint`), as is the island's black.

/// The Watch: every host's work in one card. Its header counts; the most urgent thread leads,
/// with its question's answers when it needs you; the rest follow as rows.
public struct SHGlanceWatchCard<Buttons: View>: View {
    let glance: SHGlance
    let stale: Bool
    let now: Date
    let buttons: (SHGlance.Item) -> Buttons

    public init(_ glance: SHGlance, stale: Bool, now: Date, @ViewBuilder buttons: @escaping (SHGlance.Item) -> Buttons) {
        self.glance = glance
        self.stale = stale
        self.now = now
        self.buttons = buttons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            SHGlanceHeader(glance, stale: stale, now: now)
            if let lead = glance.lead {
                SHGlanceLead(lead, stale: stale, now: now).padding(.top, SH.Space.xs)
                if lead.state == .needsYou, !stale {
                    buttons(lead).padding(.top, SH.Space.xs)
                }
                let rest = glance.items.dropFirst()
                let shown = rest.prefix(lead.state == .needsYou && !stale ? 1 : SHGlanceMetrics.watchRows)
                if !shown.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(shown)) { SHGlanceRow($0, now: now, stale: stale) }
                    }
                    .padding(.top, SH.Space.xs)
                }
                let more = rest.count - shown.count + glance.omittedCount
                if more > 0 {
                    Text("+\(more) more")
                        .font(.shMono(SHGlanceMetrics.micro))
                        .foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            } else {
                Text("Nothing running or waiting")
                    .font(.shSans(SHGlanceMetrics.body))
                    .foregroundStyle(Color.sh.textSecondary)
            }
        }
    }
}

/// A card's head: the most urgent state's mark and the counts, the hosts on the right; or, stale,
/// when it last heard and who it cannot reach.
public struct SHGlanceHeader: View {
    let glance: SHGlance
    let stale: Bool
    let now: Date

    public init(_ glance: SHGlance, stale: Bool, now: Date) {
        self.glance = glance
        self.stale = stale
        self.now = now
    }

    public var body: some View {
        HStack(spacing: SH.Space.m) {
            SHGlanceMark(glance.urgent, stale: stale)
            if stale {
                Self.staleLine(glance)
                    .font(.shSans(SHGlanceMetrics.body))
                    .foregroundStyle(Color.sh.textSecondary)
                    .lineLimit(1)
            } else {
                counts.lineLimit(1)
                Spacer(minLength: SH.Space.s)
                Text(glance.hosts.filter(\.online).map(\.name).joined(separator: " · "))
                    .font(.shMono(SHGlanceMetrics.mono))
                    .foregroundStyle(Color.sh.textTertiary)
                    .lineLimit(1)
            }
        }
    }

    private var counts: Text {
        let need = glance.count(.needsYou)
        var others = glance
        others.items = glance.items.filter { $0.state != .needsYou }
        others.omitted[.needsYou] = nil
        let rest = others.summary
        let font = Font.shSans(SHGlanceMetrics.title, .semibold)
        guard need > 0 else { return Text(rest).font(font).foregroundStyle(Color.sh.textPrimary) }
        let head = Text("\(need) need\(need == 1 ? "s" : "") you").font(font).foregroundStyle(Color.sh.lanternText)
        guard rest != "Nothing running" else { return head }
        return Text("\(head)\(Text(" · \(rest)").font(font).foregroundStyle(Color.sh.textPrimary))")
    }

    /// "Last update 6 minutes ago · This Mac unreachable". The age counts on its own: a stale
    /// card is not redrawn, so a computed "6m" would freeze at the moment it went stale.
    public static func staleLine(_ glance: SHGlance) -> Text {
        let ago = staleAge(glance)
        guard let unreachable = glance.unreachable else { return Text("Last update \(ago)") }
        return Text("Last update \(ago) · \(unreachable) unreachable")
    }

    /// "6 minutes ago", counting on its own. A counting text never wraps, so a narrow surface
    /// puts it on a line of its own.
    public static func staleAge(_ glance: SHGlance) -> Text {
        Text(.currentDate, format: .reference(to: glance.updated, allowedFields: [.minute, .hour, .day], maxFieldCount: 1))
    }
}

/// The lead thread: its mark, title and time, then what it does or asks.
struct SHGlanceLead: View {
    let item: SHGlance.Item
    let stale: Bool
    let now: Date

    init(_ item: SHGlance.Item, stale: Bool, now: Date) {
        self.item = item
        self.stale = stale
        self.now = now
    }

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            HStack(spacing: SH.Space.m) {
                SHGlanceMark(item.state, stale: stale && item.state == .running, dotForQuestion: true)
                Text(item.title)
                    .font(.shSans(SHGlanceMetrics.lead, .semibold))
                    .foregroundStyle(stale ? Color.sh.textSecondary : Color.sh.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SHGlanceLeadTime(item: item, stale: stale, now: now)
            }
            if let line = SHGlanceLead.line(item, stale: stale) {
                line.lineLimit(2).padding(.leading, SHGlanceMetrics.mark + SH.Space.m)
            }
        }
    }

    /// What it asks, runs, or ended with.
    static func line(_ item: SHGlance.Item, stale: Bool) -> Text? {
        let body = Font.shSans(SHGlanceMetrics.body)
        switch item.state {
        case .needsYou:
            return item.question.map { Text($0).font(body).foregroundStyle(Color.sh.textSecondary) }
        case .running:
            let verb = Text(stale ? "Was running" : "Running").font(body).foregroundStyle(stale ? Color.sh.textTertiary : Color.sh.textPrimary)
            guard let command = item.command else {
                return item.subagents.map { _ in verb } ?? (stale ? Text("Status unknown").font(body).foregroundStyle(Color.sh.textTertiary) : nil)
            }
            return Text("\(verb)  \(Text(command).font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textTertiary))")
        case .done, .failed:
            return item.result.map { Text($0).font(body).foregroundStyle(Color.sh.textSecondary) }
        }
    }
}

/// The lead's time: counting while it runs, "host · 2m" while it waits, how long ago it ended.
struct SHGlanceLeadTime: View {
    let item: SHGlance.Item
    let stale: Bool
    let now: Date

    var body: some View {
        if item.state == .running, !stale, let since = item.since {
            SHGlanceElapsed(since: since, size: SHGlanceMetrics.lead)
        } else {
            Text([item.hostName, item.since.map { SHGlanceAgo.text($0, now: now) }].compactMap { $0 }.joined(separator: " · "))
                .font(.shMono(SHGlanceMetrics.mono))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

/// Follow: one thread the person chose to follow, in full.
public struct SHGlanceFollowCard<Buttons: View>: View {
    let item: SHGlance.Item
    let glance: SHGlance
    let stale: Bool
    let now: Date
    let buttons: (SHGlance.Item) -> Buttons

    public init(_ item: SHGlance.Item, in glance: SHGlance, stale: Bool, now: Date,
                @ViewBuilder buttons: @escaping (SHGlance.Item) -> Buttons) {
        self.item = item
        self.glance = glance
        self.stale = stale
        self.now = now
        self.buttons = buttons
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(spacing: SH.Space.m) {
                SHGlanceMark(item.state, stale: stale, dotForQuestion: true)
                Text(item.title)
                    .font(.shSans(SHGlanceMetrics.title, .semibold))
                    .foregroundStyle(stale ? Color.sh.textSecondary : Color.sh.textPrimary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                trailing
            }
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                if stale {
                    SHGlanceHeader.staleLine(glance).font(.shSans(SHGlanceMetrics.body)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                }
                if let line = SHGlanceLead.line(item, stale: stale) { line.lineLimit(2) }
                if !stale, item.state == .running {
                    if let subagents = item.subagents, subagents.total > 0 { SHGlanceSubagents(subagents) }
                    if let goal = item.goal {
                        Text("Goal  \(Text(goal).foregroundStyle(Color.sh.textTertiary))")
                            .font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                    }
                }
                if !stale { meta }
            }
            .padding(.leading, SHGlanceMetrics.mark + SH.Space.m)
            buttons(item).padding(.top, SH.Space.xs)
        }
    }

    @ViewBuilder private var trailing: some View {
        let mono = Font.shMono(SHGlanceMetrics.mono)
        if stale {
            Text("as of \(glance.updated.formatted(date: .omitted, time: .shortened))").font(mono).foregroundStyle(Color.sh.textTertiary).fixedSize()
        } else {
            switch item.state {
            case .running:
                HStack(spacing: SH.Space.s) {
                    Text(item.hostName).font(mono).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                    if let since = item.since { SHGlanceElapsed(since: since, size: SHGlanceMetrics.lead) }
                }.fixedSize()
            case .needsYou:
                Text("waiting \(item.since.map { SHGlanceAgo.text($0, now: now) } ?? "")").font(mono).foregroundStyle(Color.sh.lanternText).fixedSize()
            case .done:
                Text("Done · \(item.since.map { SHGlanceAgo.text($0, now: now) } ?? "")").font(mono).foregroundStyle(Color.sh.done).fixedSize()
            case .failed:
                Text("Failed · \(item.since.map { SHGlanceAgo.text($0, now: now) } ?? "")").font(mono).foregroundStyle(Color.sh.failed).fixedSize()
            }
        }
    }

    /// Its changes, what waits in its queue, and where it runs.
    private var meta: some View {
        HStack(spacing: SH.Space.s) {
            if let changes = item.changes, changes.files > 0 {
                if item.state == .done || item.state == .failed {
                    Text("Edited \(changes.files) file\(changes.files == 1 ? "" : "s")").font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textSecondary)
                }
                SHGlanceDiff(changes)
            }
            Text(metaLine).font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
        }
    }

    private var metaLine: String {
        var parts: [String] = []
        if item.queued > 0 { parts.append("\(item.queued) queued") }
        if item.state != .running { parts.append(item.hostName) }
        let line = parts.joined(separator: " · ")
        return item.changes.map { $0.files > 0 } == true && !line.isEmpty ? "· \(line)" : line
    }
}

// MARK: Dynamic Island

/// The island's leading mark: the most urgent state's (the followed thread's), tinted for the
/// island's black.
public struct SHGlanceIslandMark: View {
    let state: SHGlance.State?
    let stale: Bool

    public init(_ state: SHGlance.State?, stale: Bool) {
        self.state = state
        self.stale = stale
    }

    public var body: some View {
        SHGlanceMark(state, stale: stale).environment(\.colorScheme, .dark)
    }
}

/// The compact island's trailing side: how many need you (lantern), how many work, or the
/// followed thread's time.
public struct SHGlanceIslandTrailing: View {
    let glance: SHGlance
    let follow: SHGlance.Item?
    let expanded: Bool
    let stale: Bool
    let now: Date

    /// `expanded`: the expanded island's corner, where the state's word is already on the left,
    /// so a thread that waits or ended says where and when instead.
    public init(_ glance: SHGlance, follow: SHGlance.Item? = nil, expanded: Bool = false, stale: Bool, now: Date) {
        self.glance = glance
        self.follow = follow
        self.expanded = expanded
        self.stale = stale
        self.now = now
    }

    public var body: some View {
        let font = Font.shMono(SHGlanceMetrics.compactText, .semibold)
        Group {
            if stale {
                SHGlanceElapsed(since: glance.updated, size: SHGlanceMetrics.compactText, color: Color.sh.islandSecondary)
            } else if let follow, expanded, follow.state != .running {
                Text([follow.hostName, follow.since.map { SHGlanceAgo.text($0, now: now) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.islandSecondary)
            } else if let follow {
                switch follow.state {
                case .running: follow.since.map { SHGlanceElapsed(since: $0, size: SHGlanceMetrics.compactText) }
                case .done: Text("Done").font(font).foregroundStyle(Color.sh.done)
                case .failed: Text("Failed").font(font).foregroundStyle(Color.sh.failed)
                case .needsYou: Text("Needs you").font(font).foregroundStyle(Color.sh.lantern)
                }
            } else if glance.count(.needsYou) > 0 {
                HStack(spacing: SH.Space.xs) {
                    Circle().fill(Color.sh.lantern).frame(width: SHGlanceMetrics.dot - 1, height: SHGlanceMetrics.dot - 1)
                    Text("\(glance.count(.needsYou))").font(font).foregroundStyle(Color.sh.lantern)
                }
            } else {
                Text("\(glance.count(.running))").font(font).foregroundStyle(Color.sh.running)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The minimal island (two activities at once): one dot in the most urgent state's color.
public struct SHGlanceIslandMinimal: View {
    let state: SHGlance.State?
    let stale: Bool

    public init(_ state: SHGlance.State?, stale: Bool) {
        self.state = state
        self.stale = stale
    }

    public var body: some View {
        Circle()
            .fill(stale || state == nil ? Color.sh.islandSecondary : state?.agentState.color ?? Color.sh.islandSecondary)
            .frame(width: SHGlanceMetrics.minimalDot, height: SHGlanceMetrics.minimalDot)
            .environment(\.colorScheme, .dark)
    }
}

/// The expanded island's head: the mark and the state's word on the left.
public struct SHGlanceIslandLeading: View {
    let item: SHGlance.Item?
    let stale: Bool

    public init(_ item: SHGlance.Item?, stale: Bool) {
        self.item = item
        self.stale = stale
    }

    public var body: some View {
        HStack(spacing: SH.Space.s) {
            SHGlanceMark(item?.state, stale: stale)
            Text(stale ? "Stale" : item?.state.agentState.label ?? "Shepherd")
                .font(.shSans(SHGlanceMetrics.body, .medium))
                .foregroundStyle(stale ? Color.sh.islandSecondary : item?.state.agentState.color ?? Color.sh.islandSecondary)
        }
        .environment(\.colorScheme, .dark)
    }
}

/// The expanded island's body: the thread, what it does or asks, and its buttons.
public struct SHGlanceIslandBody<Buttons: View>: View {
    let item: SHGlance.Item
    let glance: SHGlance
    let stale: Bool
    let now: Date
    let buttons: (SHGlance.Item) -> Buttons

    public init(_ item: SHGlance.Item, in glance: SHGlance, stale: Bool, now: Date,
                @ViewBuilder buttons: @escaping (SHGlance.Item) -> Buttons) {
        self.item = item
        self.glance = glance
        self.stale = stale
        self.now = now
        self.buttons = buttons
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            Text(item.title).font(.shSans(SHGlanceMetrics.title + 1, .semibold)).foregroundStyle(sh.islandText).lineLimit(1)
            Group {
                if stale {
                    SHGlanceHeader.staleLine(glance)
                } else {
                    switch item.state {
                    case .needsYou: Text(item.question ?? "Waiting on you")
                    case .running: Text(item.command ?? item.subagents.map { SHGlanceSubagents($0).line } ?? "Running")
                    case .done, .failed: Text(item.result ?? item.state.agentState.label)
                    }
                }
            }
            .font(.shSans(SHGlanceMetrics.body))
            .foregroundStyle(sh.islandSecondary)
            .lineLimit(2)
            if !stale {
                buttons(item).padding(.top, SH.Space.xs)
            }
        }
        .environment(\.colorScheme, .dark)
    }
}
