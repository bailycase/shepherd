import SwiftUI

// The widgets (GlanceHome, GlanceiPad, GlanceLock): the sidebar in miniature. Each is its
// content only; the widget's background and corners are the system's (`containerBackground`).
// A row opens its thread through `link` when the surface gives one.

/// Small: the most urgent thread (or the one pinned to it) alone.
public struct SHGlanceSmall: View {
    let item: SHGlance.Item?
    let glance: SHGlance
    let stale: Bool
    let now: Date

    public init(_ item: SHGlance.Item?, in glance: SHGlance, stale: Bool, now: Date) {
        self.item = item
        self.glance = glance
        self.stale = stale
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            if let item {
                HStack(spacing: SH.Space.s) {
                    SHGlanceMark(item.state, stale: stale, size: SHGlanceMetrics.mark - 1)
                    Text(stale ? "Stale" : item.state.agentState.label)
                        .font(.shSans(SHGlanceMetrics.row, .medium))
                        .foregroundStyle(stale ? Color.sh.textTertiary : item.state.agentState.textColor)
                    Spacer(minLength: 0)
                    head(item)
                }
                Text(item.title)
                    .font(.shSans(SHGlanceMetrics.lead, .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .lineLimit(2)
                    .padding(.top, SH.Space.xxs)
                detail(item)
                Spacer(minLength: 0)
                footer(item)
            } else {
                SHGlanceEmpty(glance: glance, compact: true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func head(_ item: SHGlance.Item) -> some View {
        if !stale {
            switch item.state {
            case .needsYou:
                Text("\(glance.count(.needsYou))").font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.lanternText)
            case .running:
                if let since = item.since { SHGlanceElapsed(since: since) }
            case .done, .failed:
                if let since = item.since { SHGlanceAgo(since, now: now) }
            }
        }
    }

    @ViewBuilder private func detail(_ item: SHGlance.Item) -> some View {
        let body = Font.shSans(SHGlanceMetrics.row)
        if stale {
            Text(SHGlanceHeader.staleLine(glance, now: now)).font(body).foregroundStyle(Color.sh.textTertiary).lineLimit(3)
        } else {
            switch item.state {
            case .needsYou:
                if let question = item.question { Text(question).font(body).foregroundStyle(Color.sh.textSecondary).lineLimit(3) }
            case .running:
                if let command = item.command {
                    Text(command).font(.shMono(SHGlanceMetrics.mono)).foregroundStyle(Color.sh.textTertiary).lineLimit(2)
                }
                if let subagents = item.subagents, subagents.total > 0 {
                    Text(SHGlanceSubagents(subagents).line).font(.shMono(SHGlanceMetrics.micro)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
                }
            case .done, .failed:
                if let result = item.result { Text(result).font(body).foregroundStyle(Color.sh.textSecondary).lineLimit(3) }
            }
        }
    }

    private func footer(_ item: SHGlance.Item) -> some View {
        HStack(spacing: SH.Space.s) {
            if let changes = item.changes, changes.files > 0, !stale { SHGlanceDiff(changes) }
            Text([item.hostName, item.state == .needsYou ? item.since.map { SHGlanceAgo.text($0, now: now) } : nil]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.shMono(SHGlanceMetrics.micro))
                .foregroundStyle(Color.sh.textTertiary)
                .lineLimit(1)
        }
    }
}

/// Nothing running or waiting: the crook, a line, and the hosts.
struct SHGlanceEmpty: View {
    let glance: SHGlance
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(spacing: SH.Space.s) {
                SHGlanceCrook(color: Color.sh.textTertiary).frame(width: SHGlanceMetrics.mark - 1, height: SHGlanceMetrics.mark - 1)
                Text("Shepherd").font(.shSans(SHGlanceMetrics.row, .medium)).foregroundStyle(Color.sh.textSecondary)
            }
            Text("Nothing running or waiting")
                .font(.shSans(SHGlanceMetrics.lead, .semibold))
                .foregroundStyle(Color.sh.textPrimary)
                .padding(.top, SH.Space.xs)
            if !compact {
                Text("Start a thread and it shows up here.").font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textSecondary)
            }
            Spacer(minLength: 0)
            SHGlanceHostsLine(glance: glance)
        }
    }
}

/// "● build-01, This Mac online · ○ horizon offline".
struct SHGlanceHostsLine: View {
    let glance: SHGlance

    var body: some View {
        Text(glance.hostsLine)
            .font(.shMono(SHGlanceMetrics.micro))
            .foregroundStyle(Color.sh.textTertiary)
            .lineLimit(1)
    }
}

/// Medium, large and a column of extra large: Needs you, Failed, Working, and (with `done`) Done
/// today, as many rows as `rows` allows, most urgent first.
public struct SHGlanceList: View {
    let glance: SHGlance
    let rows: Int
    let done: Bool
    let header: String?
    let stale: Bool
    let now: Date
    let link: (SHGlance.Item) -> URL?

    /// `header` names the widget's scope ("All work", a host) above the groups; nil draws none.
    public init(_ glance: SHGlance, rows: Int, done: Bool = false, header: String? = nil, stale: Bool, now: Date,
                link: @escaping (SHGlance.Item) -> URL? = { _ in nil }) {
        self.glance = glance
        self.rows = rows
        self.done = done
        self.header = header
        self.stale = stale
        self.now = now
        self.link = link
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.xxs) {
            if let header, !stale {
                HStack(spacing: SH.Space.s) {
                    SHGlanceCrook(color: Color.sh.lantern).frame(width: SHGlanceMetrics.mark - 1, height: SHGlanceMetrics.mark - 1)
                    Text("Shepherd").font(.shSans(SHGlanceMetrics.title, .semibold)).foregroundStyle(Color.sh.textPrimary)
                    Spacer(minLength: 0)
                    Text(header).font(.shMono(SHGlanceMetrics.micro)).foregroundStyle(Color.sh.textTertiary)
                }
                .padding(.bottom, SH.Space.xxs)
            }
            if stale {
                HStack(spacing: SH.Space.s) {
                    SHGlanceMark(nil, stale: true, size: SHGlanceMetrics.mark - 2)
                    Text(SHGlanceHeader.staleLine(glance, now: now)).font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                }
                .padding(.bottom, SH.Space.xxs)
            }
            if groups.isEmpty {
                SHGlanceEmpty(glance: glance, compact: false)
            } else {
                ForEach(groups, id: \.title) { group in
                    HStack {
                        SHGlanceGroupHead(group.title, count: group.count, attention: group.title == "Needs you")
                        Spacer(minLength: 0)
                        if group.hidden > 0 {
                            Text("+\(group.hidden) more").font(.shMono(SHGlanceMetrics.micro)).foregroundStyle(Color.sh.textTertiary)
                        }
                    }
                    .padding(.top, SH.Space.xxs)
                    ForEach(group.items) { item in
                        if let url = link(item) {
                            Link(destination: url) { SHGlanceRow(item, now: now, stale: stale) }
                        } else {
                            SHGlanceRow(item, now: now, stale: stale)
                        }
                    }
                }
                Spacer(minLength: 0)
                if header != nil && !stale { SHGlanceHostsLine(glance: glance) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    struct Bucket {
        var title: String
        var count: Int
        var items: [SHGlance.Item]
        var hidden: Int
    }

    /// The groups with rows to show, `rows` shared out most urgent first. A group always shows
    /// its head with at least one row.
    var groups: [Bucket] {
        var all: [(String, [SHGlance.Item])] = [("Needs you", glance.needsYou), ("Failed", glance.failed), ("Working", glance.working)]
        if done { all.append(("Done today", glance.done)) }
        var left = rows
        var groups: [Bucket] = []
        for (title, items) in all where !items.isEmpty && left > 0 {
            let shown = Array(items.prefix(left))
            left -= shown.count + 1
            groups.append(Bucket(title: title, count: items.count, items: shown, hidden: items.count - shown.count))
        }
        return groups
    }
}

/// Extra large (iPad): one column per host, each its own list.
public struct SHGlanceColumns: View {
    let glance: SHGlance
    let stale: Bool
    let now: Date
    let link: (SHGlance.Item) -> URL?

    public init(_ glance: SHGlance, stale: Bool, now: Date, link: @escaping (SHGlance.Item) -> URL? = { _ in nil }) {
        self.glance = glance
        self.stale = stale
        self.now = now
        self.link = link
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                SHGlanceCrook(color: Color.sh.lantern).frame(width: SHGlanceMetrics.mark - 1, height: SHGlanceMetrics.mark - 1)
                Text("Shepherd").font(.shSans(SHGlanceMetrics.title, .semibold)).foregroundStyle(Color.sh.textPrimary)
                Text(glance.summary).font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
                Spacer(minLength: 0)
            }
            HStack(alignment: .top, spacing: SH.Space.l) {
                ForEach(glance.hosts, id: \.name) { host in
                    column(host)
                    if host != glance.hosts.last { SHHairline(.vertical) }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func column(_ host: SHGlance.Host) -> some View {
        let scoped = SHGlance(items: glance.items.filter { $0.hostName == host.name }, hosts: [host], updated: glance.updated)
        return VStack(alignment: .leading, spacing: SH.Space.xs) {
            HStack(spacing: SH.Space.s) {
                Circle().fill(host.online ? Color.sh.done : Color.sh.textTertiary).frame(width: SHGlanceMetrics.dot - 1, height: SHGlanceMetrics.dot - 1)
                Text(host.name).font(.shSans(SHGlanceMetrics.row, .semibold)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Spacer(minLength: 0)
                Text(host.online ? "online" : "offline").font(.shMono(SHGlanceMetrics.micro)).foregroundStyle(Color.sh.textTertiary)
            }
            if host.online || !scoped.items.isEmpty {
                SHGlanceList(scoped, rows: SHGlanceMetrics.columnRows, done: true, stale: stale || !host.online, now: now, link: link)
            } else {
                Text("Offline. Its threads show here when it reconnects.")
                    .font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textTertiary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }
}

// MARK: Lock Screen accessories

/// Circular: how many need you, with a full ring while any do; else how many work. The Lock
/// Screen draws accessories in one tint, so the ring, not a color, says it needs you.
public struct SHGlanceCircular: View {
    let glance: SHGlance

    public init(_ glance: SHGlance) { self.glance = glance }

    public var body: some View {
        let need = glance.count(.needsYou)
        ZStack {
            Circle().stroke(Color.sh.textPrimary, lineWidth: need > 0 ? 3 : 0)
            VStack(spacing: 0) {
                SHGlanceCrook(color: Color.sh.textPrimary).frame(width: SHGlanceMetrics.micro, height: SHGlanceMetrics.micro)
                Text("\(need > 0 ? need : glance.count(.running))")
                    .font(.shSans(SHGlanceMetrics.accessoryCount, .semibold))
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(glance.summary)
    }
}

/// Rectangular: the counts, then the most urgent thread and why.
public struct SHGlanceRectangular: View {
    let glance: SHGlance
    let stale: Bool
    let now: Date

    public init(_ glance: SHGlance, stale: Bool, now: Date) {
        self.glance = glance
        self.stale = stale
        self.now = now
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: SH.Space.xs) {
                SHGlanceCrook(color: Color.sh.textPrimary).frame(width: SHGlanceMetrics.mono, height: SHGlanceMetrics.mono)
                Text(stale ? "Last update \(SHGlanceAgo.text(glance.updated, now: now)) ago" : glance.summary)
                    .font(.shSans(SHGlanceMetrics.body, .semibold)).lineLimit(1)
            }
            if let lead = glance.lead {
                Text(lead.title).font(.shSans(SHGlanceMetrics.body, .medium)).lineLimit(1)
                Text([lead.tag, lead.hostName, lead.since.map { SHGlanceAgo.text($0, now: now) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.shSans(SHGlanceMetrics.row)).foregroundStyle(Color.sh.textSecondary).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

extension SHGlance {
    /// The inline accessory beside the date: "3 need you · 4 working".
    public var inline: String { summary }
}
