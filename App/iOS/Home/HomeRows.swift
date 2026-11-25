import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Home's rows and cards: `FleetModel`'s plain values drawn with ShepherdUI's list parts. Each
// row view compares equal on its values, so a poll that changes one thread redraws one row.

extension FleetRef {
    var agentRef: AgentRef { AgentRef(host: host, agent: agent) }
}

extension AgentRef {
    var fleetRef: FleetRef { FleetRef(host: host, agent: agent) }
}

extension FleetClock {
    var rowClock: SHRowClock {
        switch self {
        case .elapsed(let since): .elapsed(since: Date(milliseconds: since))
        case .ago(let at): .ago(Date(milliseconds: at))
        }
    }
}

extension String {
    /// "needs you" as "Needs you": the first letter alone.
    var sentenceCased: String { prefix(1).uppercased() + dropFirst() }
}

extension Date {
    init(milliseconds: Double) { self.init(timeIntervalSince1970: milliseconds / 1000) }
}

extension FleetAttention {
    /// Where Open goes: the thread.
    var route: MobileRoute { .thread(ref.agentRef) }

    var leading: SHListRow.Leading {
        switch origin {
        case .thread, .project: .state(.attention)
        case .automation: .symbol("bolt", .attention)
        }
    }

    /// What kind of thing asks, for "Where it came from".
    var kind: String {
        switch origin {
        case .thread: "A thread"
        case .automation(let name): "A run of the automation \(name)"
        case .project: "A Project's thread"
        }
    }

    /// What asks, in iPadOverview's cards: the thread, and for an automation's run that it is one.
    var overviewOrigin: String {
        switch origin {
        case .thread, .project: thread
        case .automation: "\(thread) · automation"
        }
    }

    /// The origin glyph of an automation's run; a thread has none.
    var symbol: String? {
        switch origin {
        case .thread, .project: nil
        case .automation: "bolt"
        }
    }
}

extension FleetHostCard {
    /// The connection as a status: done while connected, running while connecting.
    var state: AgentState {
        phase.isConnected ? .done : phase == .connecting ? .running : .failed
    }
}

extension FleetThreadRow {
    /// Where a row opens: a design's row its design, any other its thread.
    var route: MobileRoute {
        if let design { return .designs(.design(HostDesignRef(host: ref.host, design: design.id))) }
        return .thread(ref.agentRef)
    }
}

/// A thread in Home, Recents and the sidebar; a design's row (MobileAgents) wears the nib and
/// "design · 4 boards". Home's rows (DuoClosedHome) have no dot: the title over what a working
/// thread does as a verb ("Running python") or where any other works ("Shepherd"), the state in
/// words at the right ("Running, 2m"; "13m" for the rest, after the host's name while rows from
/// several hosts mix), and a chevron. The sidebar's rows are the title and one word (iPadSidebar).
struct ThreadRow: View, Equatable {
    let row: FleetThreadRow
    var selected = false
    /// The sidebar's rows are one line: the title alone.
    var compact = false

    private var trailing: SHListRow.Trailing {
        if compact {
            if row.failed { return .alert("failed") }
            if row.status == .done, let clock = row.clock?.rowClock { return .stamp(nil, clock) }
            return row.hostTag.map { .host($0) } ?? .none
        }
        if row.status == .working, !row.offline, row.design == nil {
            return .stamp("Running", row.clock?.rowClock, joiner: ", ")
        }
        if row.hostTag == nil, row.clock == nil { return .none }
        return .stamp(row.hostTag, row.clock?.rowClock)
    }

    var body: some View {
        SHListRow(row.title, subtitle: compact ? nil : row.inboxLine, subtitleMono: false,
                  leading: row.design != nil ? .symbol("pencil.tip") : .none, trailing: trailing,
                  chevron: !compact, selected: selected, dimmed: row.offline, compact: compact)
            // The words at the right say the state; VoiceOver hears it.
            .accessibilityValue((compact && row.failed ? "failed" : FleetModel.statusWord(row.status)) + (row.offline ? ", host offline" : ""))
    }
}

extension FleetThreadRow {
    /// Home's line under the title: what a working thread does now ("Running python",
    /// "Thinking"), else the repo it works in, else what the host says of it.
    var inboxLine: String {
        if design != nil { return detail }
        if status == .working, !offline { return doing ?? place ?? detail }
        return place ?? detail
    }
}

/// Something waiting on you, as one row (Home's preview, the sidebar).
struct AttentionRow: View, Equatable {
    let item: FleetAttention
    var selected = false
    /// The sidebar's rows show the reason chip; Home's show the question under the title.
    var compact = false

    var body: some View {
        // The sidebar names the thread; its chip says who asks ("reviewer") or why.
        SHListRow(compact ? item.thread : item.title, subtitle: compact ? nil : item.question, subtitleMono: false, subtitleLines: 2,
                  leading: .none, trailing: compact ? .reason(item.reason) : .stamp(item.hostTag, item.since.map { .ago(Date(milliseconds: $0)) }),
                  chevron: !compact, selected: selected, compact: compact)
    }
}

/// A Needs you card with the answers that fit in place, and Open.
struct AttentionCard: View {
    let item: FleetAttention
    let busy: Bool
    let failure: String?
    var selected = false
    /// A card chosen in the iPad inbox answers in its detail, not here.
    var answers = true
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        // The phone's card (MobileInbox) is the thread, where it came from ("A thread on Studio"), the
        // question and its message; the iPad overview's (iPadOverview) is what asks, the question's
        // title and its text, and its list's items (iPadInbox) the thread, the question, where from.
        let pad = navigator.layout == .pad
        let overview = pad && answers
        let origin = item.hostName.isEmpty ? item.originLabel : item.symbol == nil ? "\(item.originLabel) on \(item.hostName)" : "\(item.originLabel) · \(item.hostName)"
        SHAttentionCard(symbol: item.symbol, origin: overview ? item.overviewOrigin : origin, title: overview ? item.question : item.title,
                        question: overview ? (item.message ?? "") : item.question, message: overview ? nil : answers ? item.message : nil,
                        since: item.since.map(Date.init(milliseconds:)), host: nil,
                        selected: selected, style: !answers ? .item : overview ? .overview : .card,
                        link: answers && !overview ? ("Open thread", { navigator.open(projects.route(item)) }) : nil) {
            if answers {
                AttentionReplies(item: item, busy: busy, size: overview ? .l : .m, ink: overview)
                if overview {
                    Button("Open thread") { navigator.open(projects.route(item)) }
                        .buttonStyle(.sh(.ghost, size: .l))
                        .accessibilityLabel("Open \(item.thread)")
                }
            }
            if let failure {
                Text(failure).shText(.caption).foregroundStyle(Color.sh.failed)
            }
        }
    }
}

/// The answers a question takes in place: its options, or Yes and No. The asker's pick (the
/// first) is primary: it leads a card's answers, and in a trailing foot (`pickLast`, the iPad
/// inbox's) it comes last, nearest the edge.
struct AttentionReplies: View {
    let item: FleetAttention
    let busy: Bool
    var size: SHButtonStyle.Size = .m
    var pickLast = false
    /// The asker's pick in ink, the rest as plain text (iPadOverview); the phone's answers are all pills (MobileInbox).
    var ink = false
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let feed = HomeFeed.of(hosts)
        switch item.reply {
        case .choose(let options):
            let ordered = Array(options.enumerated())
            ForEach(pickLast ? ordered.reversed() : ordered, id: \.offset) { index, option in
                Button(option) { Task { await feed.choose(item, option) } }
                    .buttonStyle(.sh(index == 0 ? (ink || pickLast ? .primary : .secondary) : (ink ? .ghost : .secondary), size: size))
                    .disabled(busy)
            }
        case .confirm:
            if pickLast { no(feed) }
            Button("Yes") { Task { await feed.answer(item, .confirm(value: true)) } }
                .buttonStyle(.sh(ink || pickLast ? .primary : .secondary, size: size)).disabled(busy)
            if !pickLast { no(feed) }
        case .open:
            EmptyView()
        }
    }

    private func no(_ feed: HomeFeed) -> some View {
        Button("No") { Task { await feed.answer(item, .confirm(value: false)) } }
            .buttonStyle(.sh(ink ? .ghost : .secondary, size: size)).disabled(busy)
    }
}

/// The hosts that are not connected, one `HostNotice` each in a card: Home's first section, and the iPad overview's top.
struct HostNotices: View {
    let cards: [FleetHostCard]

    var body: some View {
        if !cards.isEmpty {
            SHListCard {
                ForEach(cards) { card in HostNotice(card: card).equatable() }
            }
        }
    }
}

/// A host that is not connected, on Home: its name, why, and Retry.
struct HostNotice: View, Equatable {
    let card: FleetHostCard
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.dynamicTypeSize) private var typeSize

    static func == (a: HostNotice, b: HostNotice) -> Bool { a.card == b.card }

    var body: some View {
        // DuoClosedHome: the name and why in words, Retry as plain text at the top right.
        HStack(alignment: .top, spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(card.name).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                Text(card.summary).font(.sh(.caption)).shShimmer(active: card.phase == .connecting)
                    .foregroundStyle(Color.sh.textSecondary).lineLimit(3)
                // At accessibility sizes Retry drops under the name rather than squeezing it.
                if typeSize.isAccessibilitySize { retry.padding(.top, SH.Space.xs) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { retry }
        }
        .padding(.horizontal, SHListMetrics.rowInset)
        .padding(.vertical, SHListMetrics.rowPadding)
        .frame(minHeight: SHListMetrics.twoLineRowHeight)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var retry: some View {
        if card.needsPairing {
            // The Mac no longer accepts the old shared token: only a new pairing gets back in.
            Button("Add a Mac") { navigator.present(.settings(.host(nil))) }
                .buttonStyle(.plain).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityLabel("Add \(card.name) again with a code")
        } else if card.canRetry {
            Button("Retry") { hosts.retry(card.id) }
                .buttonStyle(.plain).font(.sh(.ui)).foregroundStyle(Color.sh.textPrimary)
                .accessibilityLabel("Retry \(card.name)")
        }
    }
}
