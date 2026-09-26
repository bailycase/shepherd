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
    var rowClock: NWRowClock {
        switch self {
        case .elapsed(let since): .elapsed(since: Date(milliseconds: since))
        case .ago(let at): .ago(Date(milliseconds: at))
        }
    }
}

extension Date {
    init(milliseconds: Double) { self.init(timeIntervalSince1970: milliseconds / 1000) }
}

extension FleetAttention {
    /// Where Open goes: the asking subagent's run, or the thread.
    var route: MobileRoute {
        runID.map { SubagentHooks.run(thread: ref.agentRef, runID: $0) } ?? .thread(ref.agentRef)
    }

    var leading: NWListRow.Leading {
        switch origin {
        case .thread: .state(.attention)
        case .automation: .symbol("bolt", .attention)
        case .subagent: .symbol("arrow.triangle.branch", .attention)
        }
    }

    /// What kind of thing asks, for "Where it came from".
    var kind: String {
        switch origin {
        case .thread: "A thread"
        case .automation(let name): "A run of the automation \(name)"
        case .subagent(let name): "Its subagent \(name)"
        }
    }

    /// The card's origin glyph; a thread's is the glowing dot (nil).
    var symbol: String? {
        switch origin {
        case .thread: nil
        case .automation: "bolt"
        case .subagent: "arrow.triangle.branch"
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

/// A thread in Recents, the overview and the sidebar; a design's row (MobileAgents) wears the nib
/// and "design · 4 boards".
struct ThreadRow: View, Equatable {
    let row: FleetThreadRow
    var selected = false
    /// The sidebar's rows are one line: the title, and the host it lives on.
    var compact = false
    /// The overview's narrow columns leave the chevron out for the title's sake.
    var chevron = true

    var body: some View {
        // The sidebar says a failed last turn (iPadThreadError): a failed dot and "failed".
        let failed = compact && row.failed
        NWListRow(row.title, subtitle: compact ? nil : row.detail, clock: compact ? nil : row.clock?.rowClock,
                  leading: row.design != nil ? .symbol("pencil.tip") : .state(failed ? .failed : AgentState(row.status)),
                  trailing: failed ? .meta("failed") : row.hostTag.map { .host($0) } ?? .none,
                  chevron: chevron && !compact, selected: selected, dimmed: row.offline, compact: compact)
            // The sidebar's one-line rows say their state only by the dot.
            .accessibilityValue(compact ? (failed ? "failed" : FleetModel.statusWord(row.status)) + (row.offline ? ", host offline" : "") : "")
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
        NWListRow(compact ? item.thread : item.title, subtitle: compact ? nil : item.question, subtitleTone: .attention, leading: item.leading,
                  trailing: compact ? .reason(item.reason) : item.hostTag.map { .host($0) } ?? .none,
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

    var body: some View {
        NWAttentionCard(symbol: item.symbol, origin: item.originLabel, title: item.title, question: item.question,
                        message: answers ? item.message : nil, since: item.since.map(Date.init(milliseconds:)), host: item.hostTag,
                        selected: selected, style: answers ? .card : .item) {
            if answers {
                AttentionReplies(item: item, busy: busy)
                Button("Open") { navigator.open(item.route) }
                    .buttonStyle(.nw(item.reply == .open ? .secondary : .ghost))
                    .accessibilityLabel("Open \(item.thread)")
            }
            if let failure {
                Text(failure).nwText(.caption).foregroundStyle(Color.nw.failed)
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
    var size: NWButtonStyle.Size = .m
    var pickLast = false
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let feed = HomeFeed.of(hosts)
        switch item.reply {
        case .choose(let options):
            let ordered = Array(options.enumerated())
            ForEach(pickLast ? ordered.reversed() : ordered, id: \.offset) { index, option in
                Button(option) { Task { await feed.choose(item, option) } }
                    .buttonStyle(.nw(index == 0 ? .primary : .secondary, size: size))
                    .disabled(busy)
            }
        case .confirm:
            if pickLast { no(feed) }
            Button("Yes") { Task { await feed.answer(item, .confirm(value: true)) } }
                .buttonStyle(.nw(.primary, size: size)).disabled(busy)
            if !pickLast { no(feed) }
        case .open:
            EmptyView()
        }
    }

    private func no(_ feed: HomeFeed) -> some View {
        Button("No") { Task { await feed.answer(item, .confirm(value: false)) } }
            .buttonStyle(.nw(.secondary, size: size)).disabled(busy)
    }
}

/// A host that is not connected, on Home: its name, why, and Retry.
struct HostNotice: View, Equatable {
    let card: FleetHostCard
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dynamicTypeSize) private var typeSize

    static func == (a: HostNotice, b: HostNotice) -> Bool { a.card == b.card }

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: NW.Space.l) {
            Group {
                if card.phase == .connecting {
                    ProgressView().progressViewStyle(.nwSpinner)
                } else {
                    NWStatusDot(card.state, size: NWListMetrics.dot)
                }
            }
            .frame(width: NWListMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(card.name).font(.nw(.ui, weight: .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(2)
                Text(card.summary).font(.nw(.caption)).foregroundStyle(card.state.textColor).lineLimit(3)
                // At accessibility sizes Retry drops under the name rather than squeezing it.
                if typeSize.isAccessibilitySize { retry.padding(.top, NW.Space.xs) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { retry }
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: NWListMetrics.twoLineRowHeight)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var retry: some View {
        if card.canRetry {
            Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                .buttonStyle(.nw(.secondary, size: .s))
                .accessibilityLabel("Retry \(card.name)")
        }
    }
}
