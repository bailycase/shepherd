import SwiftUI
import ShepherdUI
import ShepherdRemote

/// More (MobileMore, iPadHosts boards; home track): every host as a card with its connection,
/// what runs there, Retry while it is offline, and Add host. A card opens the host's form. Under
/// the hosts, Extensions (the bundled and installed pi extensions the hosts load) opens
/// Settings ▸ Extensions; the board's Design systems and Archive wait for the Mac.
struct MoreScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let cards = feed.model.hosts
        let settings = SettingsStore.of(hosts)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                NWListHeader("Hosts") {
                    Button("Add host", systemImage: "plus") { navigator.present(.settings(.host(nil))) }
                        .buttonStyle(.nw(.ghost, size: .s, tint: Color.nw.running))
                }
                if cards.isEmpty {
                    NoHostsState()
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.hostCardMinWidth), spacing: MobileLayout.blockSpacing)],
                              alignment: .leading, spacing: MobileLayout.blockSpacing) {
                        ForEach(cards) { card in HostCardView(card: card) }
                    }
                }
                Text("Hosts connect over your LAN or VPN. The connection has no TLS.")
                    .nwText(.caption).foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, NW.Space.xs)
                    .padding(.top, NW.Space.xs)
                if !cards.isEmpty {
                    NWListCard {
                        Button { navigator.open(.settings(SettingsPage.pi.route)) } label: {
                            NWListRow(SettingsPage.pi.title, subtitle: settings.extensionsValue.map { "\($0) installed" },
                                      subtitleMono: false, leading: .symbol(SettingsPage.pi.symbol))
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                    .padding(.top, MobileLayout.sectionSpacing - MobileLayout.headerSpacing)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .background(Color.nw.bgWindow)
        .refreshable {
            hosts.retryAll()
            await settings.refresh()
        }
        .task { await settings.watch() }
        .navigationTitle("More")
    }
}

/// A host's card: Retry while it is offline; a tap opens its form. From Home the form is presented; in
/// Settings it is pushed.
struct HostCardView: View {
    let card: FleetHostCard
    var presentsForm = true
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NWHostCard(name: card.name, address: card.address, state: card.state, status: card.phase.word,
                   summary: card.summary, summaryTone: card.state == .failed ? .failed : nil,
                   detail: card.lastSeen.map { "Last seen " + HostLastSeen.text($0, now: .now) },
                   openLabel: "Edit \(card.name)", open: edit) {
            if card.canRetry {
                Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .accessibilityLabel("Retry \(card.name)")
            }
        }
    }

    private func edit() {
        if presentsForm { navigator.present(.settings(.host(card.id))) } else { navigator.open(.settings(.host(card.id))) }
    }
}
