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
                PadListDetail(listWidth: MobileLayout.hostsListWidth) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: SH.Space.xxs) {
                            ForEach(model.hosts) { card in
                                Button { chosen = card.id } label: {
                                    SHHostRow(name: card.name, detail: Self.detail(card, now: .now), state: card.state,
                                              selected: card.id == current.id)
                                        .equatable()
                                }
                                .buttonStyle(.plain)
                                .contextMenu { HostMenuItems(card: card) }
                            }
                            Text("Hosts connect over your LAN or VPN. The connection has no TLS.")
                                .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                                .padding(.horizontal, SH.Space.l)
                                .padding(.top, SH.Space.m)
                        }
                        .padding(SH.Space.m)
                    }
                    .refreshable {
                        hosts.retryAll()
                        await feed.refresh()
                    }
                } detail: {
                    PadHostDetail(card: current, running: model.running.filter { $0.ref.host == current.id },
                                  automations: model.automationsRunning.filter { $0.host == current.id })
                } single: {
                    // Too narrow for both (iPhone Duo): the phone's host cards, each opening its form.
                    ScrollView {
                        VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                            ForEach(model.hosts) { card in HostCardView(card: card) }
                        }
                        .padding(MobileLayout.gutter)
                    }
                    .refreshable {
                        hosts.retryAll()
                        await feed.refresh()
                    }
                }
            }
        }
        .background(Color.sh.bgWindow)
        .task { await feed.watch() }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar {
            // iPadHosts: "Hosts" leads the bar, over the list.
            ToolbarItem(placement: .topBarLeading) {
                Text("Hosts").font(.sh(.headline)).foregroundStyle(Color.sh.textPrimary)
                    .fixedSize()
                    .accessibilityAddTraits(.isHeader)
            }
            .sharedBackgroundVisibility(.hidden)
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
        let sh = Color.sh
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: SH.Space.m) {
                    Text(card.name).font(.sh(.headline)).foregroundStyle(sh.textPrimary).lineLimit(1)
                    HStack(spacing: SH.Space.s) {
                        SHStatusDot(card.state, size: SHListMetrics.attentionDot)
                        Text(card.phase.word).font(.sh(.caption, weight: .medium)).foregroundStyle(card.state.textColor)
                    }
                    Text(card.address).font(.sh(.caption)).foregroundStyle(sh.textTertiary).lineLimit(1)
                    Spacer(minLength: SH.Space.m)
                    Menu {
                        HostMenuItems(card: card)
                    } label: {
                        Image(systemName: "ellipsis")
                    }
                    .buttonStyle(.shIcon(bordered: true))
                    .shTouchTarget(height: SH.Height.controlM, width: SH.Height.controlM)
                    .accessibilityLabel("Host options")
                }
                if card.phase.isConnected {
                    runningHere
                } else {
                    VStack(alignment: .leading, spacing: SH.Space.s) {
                        Text(card.summary).shText(.ui).foregroundStyle(card.state == .failed ? sh.failed : sh.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if let seen = card.lastSeen {
                            Text("Last seen " + HostLastSeen.text(seen, now: .now)).shText(.caption).foregroundStyle(sh.textTertiary)
                        }
                        if card.canRetry {
                            Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                                .buttonStyle(.sh(.secondary))
                                .padding(.top, SH.Space.xs)
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
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                Text("Running here · \(running.count + automations.count)").shSectionLabel()
                Spacer(minLength: SH.Space.m)
                Text("threads and automations").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
            }
            .padding(.horizontal, SH.Space.xs)
            if running.isEmpty && automations.isEmpty {
                Text("Nothing is running here.").shText(.caption).foregroundStyle(sh.textTertiary)
                    .padding(.horizontal, SH.Space.xs)
            } else {
                SHListCard {
                    // The host is this page's: rows leave its name out.
                    ForEach(running) { row in
                        let time: SHOverviewRow.Time = if case .elapsed(let since)? = row.clock { .elapsed(since: Date(milliseconds: since)) } else { .none }
                        Button { navigator.open(.thread(row.ref.agentRef)) } label: {
                            SHOverviewRow(row.title, detail: Self.local(row).now, leading: RunningGlyph.of(row), time: time)
                                .equatable()
                        }
                        .buttonStyle(.shRow(radius: 0))
                    }
                    ForEach(automations) { row in
                        if let run = row.run {
                            Button { navigator.open(.thread(run.agentRef)) } label: {
                                SHOverviewRow(row.name, detail: "\(row.stateWord) · \(row.place)", detailMono: false,
                                              leading: .symbol("bolt", row.runStatus == .blocked ? .attention : .running))
                                    .equatable()
                            }
                            .buttonStyle(.shRow(radius: 0))
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
