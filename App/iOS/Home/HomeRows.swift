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

    /// The card's origin glyph; a thread's is the glowing dot (nil).
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
        SHListRow(row.title, subtitle: compact ? nil : row.detail, clock: compact ? nil : row.clock?.rowClock,
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
        SHListRow(compact ? item.thread : item.title, subtitle: compact ? nil : item.question, subtitleTone: .attention, leading: item.leading,
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
    @Environment(MobileProjects.self) private var projects

    var body: some View {
        // On iPhone an automation's card is titled by its question over the asker's context
        // (MobileInbox); the iPad's cards keep the name and "Thread" or "Automation" (iPadOverview).
        let pad = navigator.layout == .pad
        let asked = !pad && answers && item.symbol != nil && item.message != nil
        SHAttentionCard(symbol: item.symbol, origin: pad ? item.shortOriginLabel : item.originLabel, title: asked ? item.question : item.title,
                        question: asked ? (item.message ?? item.question) : item.question,
                        message: answers && !asked ? item.message : nil, since: item.since.map(Date.init(milliseconds:)), host: item.hostTag,
                        selected: selected, style: answers ? .card : .item) {
            if answers {
                AttentionReplies(item: item, busy: busy)
                Button("Open") { navigator.open(projects.route(item)) }
                    .buttonStyle(.sh(item.reply == .open ? .secondary : .ghost))
                    .accessibilityLabel("Open \(item.thread)")
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
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let feed = HomeFeed.of(hosts)
        switch item.reply {
        case .choose(let options):
            let ordered = Array(options.enumerated())
            ForEach(pickLast ? ordered.reversed() : ordered, id: \.offset) { index, option in
                Button(option) { Task { await feed.choose(item, option) } }
                    .buttonStyle(.sh(index == 0 ? .primary : .secondary, size: size))
                    .disabled(busy)
            }
        case .confirm:
            if pickLast { no(feed) }
            Button("Yes") { Task { await feed.answer(item, .confirm(value: true)) } }
                .buttonStyle(.sh(.primary, size: size)).disabled(busy)
            if !pickLast { no(feed) }
        case .open:
            EmptyView()
        }
    }

    private func no(_ feed: HomeFeed) -> some View {
        Button("No") { Task { await feed.answer(item, .confirm(value: false)) } }
            .buttonStyle(.sh(.secondary, size: size)).disabled(busy)
    }
}

/// A host that is not connected, on Home: its name, why, and Retry.
struct HostNotice: View, Equatable {
    let card: FleetHostCard
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dynamicTypeSize) private var typeSize

    static func == (a: HostNotice, b: HostNotice) -> Bool { a.card == b.card }

    var body: some View {
        HStack(alignment: typeSize.isAccessibilitySize ? .top : .center, spacing: SH.Space.l) {
            Group {
                if card.phase == .connecting {
                    ProgressView().progressViewStyle(.shSpinner)
                } else {
                    SHStatusDot(card.state, size: SHListMetrics.dot)
                }
            }
            .frame(width: SHListMetrics.leadingWidth)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(card.name).font(.sh(.ui, weight: .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(2)
                Text(card.summary).font(.sh(.caption)).foregroundStyle(card.state.textColor).lineLimit(3)
                // At accessibility sizes Retry drops under the name rather than squeezing it.
                if typeSize.isAccessibilitySize { retry.padding(.top, SH.Space.xs) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !typeSize.isAccessibilitySize { retry }
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHListMetrics.twoLineRowHeight)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder private var retry: some View {
        if card.canRetry {
            Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                .buttonStyle(.sh(.secondary, size: .s))
                .accessibilityLabel("Retry \(card.name)")
        }
    }
}
