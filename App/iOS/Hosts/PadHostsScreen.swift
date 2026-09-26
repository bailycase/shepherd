import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdRemote

/// The iPad's Hosts destination (iPadHosts board), from More's Hosts row: the hosts as a list
/// beside the chosen one's detail: its connection and address, and what runs there now (each
/// row opens its thread), or, while it is offline, why and when it was last seen, with Retry.
/// The board's load, worktree, version and log cards wait for the remote protocol to carry them.
struct PadHostsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var chosen: UUID?

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        Group {
            if model.hosts.isEmpty {
                NoHostsState().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                let current = model.hosts.first { $0.id == chosen } ?? model.hosts[0]
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: NW.Space.xxs) {
                            ForEach(model.hosts) { card in
                                Button { chosen = card.id } label: {
                                    NWHostRow(name: card.name, detail: Self.detail(card, now: .now), state: card.state,
                                              selected: card.id == current.id)
                                        .equatable()
                                }
                                .buttonStyle(.plain)
                                .contextMenu { HostMenuItems(card: card) }
                            }
                            Text("Hosts connect over your LAN or VPN. The connection has no TLS.")
                                .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                                .padding(.horizontal, NW.Space.l)
                                .padding(.top, NW.Space.m)
                        }
                        .padding(NW.Space.m)
                    }
                    .refreshable {
                        hosts.retryAll()
                        await feed.refresh()
                    }
                    .frame(width: MobileLayout.hostsListWidth)
                    NWHairline(.vertical)
                    PadHostDetail(card: current, running: model.running.filter { $0.ref.host == current.id },
                                  automations: model.automationsRunning.filter { $0.host == current.id })
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .background(Color.nw.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add host", systemImage: "plus") { navigator.present(.settings(.host(nil))) }
            }
        }
    }

    /// "3 threads · 2 running", or "Offline · last seen 7:12 AM".
    static func detail(_ card: FleetHostCard, now: Date) -> String {
        switch card.phase {
        case .connected:
            let threads = nativeCount(card.threads, "thread")
            return card.running > 0 ? "\(threads) · \(card.running) running" : threads
        case .connecting:
            return "Connecting…"
        case .disconnected, .failed:
            return card.lastSeen.map { "Offline · last seen \(HostLastSeen.short($0, now: now))" } ?? "Offline"
        }
    }
}

/// The chosen host: its name, connection and address, then what runs there, or why it is offline.
private struct PadHostDetail: View {
    let card: FleetHostCard
    let running: [FleetThreadRow]
    let automations: [FleetAutomationRow]
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let nw = Color.nw
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: NW.Space.m) {
                    Text(card.name).font(.nw(.headline)).foregroundStyle(nw.textPrimary).lineLimit(1)
                    HStack(spacing: NW.Space.s) {
                        NWStatusDot(card.state, size: NWListMetrics.attentionDot)
                        Text(card.phase.word).font(.nw(.caption, weight: .medium)).foregroundStyle(card.state.textColor)
                    }
                    Text(card.address).font(.nw(.caption)).foregroundStyle(nw.textTertiary).lineLimit(1)
                    Spacer(minLength: NW.Space.m)
                    Menu {
                        HostMenuItems(card: card)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.nwIcon(bordered: true))
                    .nwTouchTarget(height: NW.Height.controlM, width: NW.Height.controlM)
                    .accessibilityLabel("Host options")
                }
                if card.phase.isConnected {
                    runningHere
                } else {
                    VStack(alignment: .leading, spacing: NW.Space.s) {
                        Text(card.summary).nwText(.ui).foregroundStyle(card.state == .failed ? nw.failed : nw.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let seen = card.lastSeen {
                            Text("Last seen " + HostLastSeen.text(seen, now: .now)).nwText(.caption).foregroundStyle(nw.textTertiary)
                        }
                        if card.canRetry {
                            Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                                .buttonStyle(.nw(.secondary))
                                .padding(.top, NW.Space.xs)
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.vertical, MobileLayout.gutter)
            .frame(maxWidth: MobileLayout.threadMaxWidth, alignment: .leading)
        }
        .accessibilityElement(children: .contain)
    }

    /// "RUNNING HERE · 3": the threads and automation runs going on this host now.
    @ViewBuilder private var runningHere: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Running here · \(running.count + automations.count)").nwSectionLabel()
                Spacer(minLength: NW.Space.m)
                Text("threads and automations").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
            }
            .padding(.horizontal, NW.Space.xs)
            if running.isEmpty && automations.isEmpty {
                Text("Nothing is running here.").nwText(.caption).foregroundStyle(nw.textTertiary)
                    .padding(.horizontal, NW.Space.xs)
            } else {
                NWListCard {
                    // The host is this page's: rows leave its name out.
                    ForEach(running) { row in
                        let time: NWOverviewRow.Time = if case .elapsed(let since)? = row.clock { .elapsed(since: Date(milliseconds: since)) } else { .none }
                        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
                            NWOverviewRow(row.title, detail: Self.local(row).now, leading: RunningGlyph.of(row), time: time)
                                .equatable()
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                    ForEach(automations) { row in
                        if let run = row.run {
                            Button { navigator.open(.thread(run.agentRef)) } label: {
                                NWOverviewRow(row.name, detail: "\(row.stateWord) · \(row.place)", detailMono: false,
                                              leading: .symbol("bolt", row.runStatus == .blocked ? .attention : .running))
                                    .equatable()
                            }
                            .buttonStyle(.nwRow(radius: 0))
                        }
                    }
                }
            }
        }
    }
}

extension PadHostDetail {
    static func local(_ row: FleetThreadRow) -> FleetThreadRow {
        var row = row
        row.hostTag = nil
        return row
    }
}

/// A host's actions: Retry while it is offline, and its form.
private struct HostMenuItems: View {
    let card: FleetHostCard
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if card.canRetry {
            Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
        }
        Button("Edit Host…", systemImage: "pencil") { navigator.present(.settings(.host(card.id))) }
    }
}
