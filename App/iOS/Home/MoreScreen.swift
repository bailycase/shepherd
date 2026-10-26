import SwiftUI
import ShepherdUI
import ShepherdRemote

/// More (MobileMore, iPadHosts boards; home track): every host as a card with its connection,
/// what runs there, Retry while it is offline, and Add host. A card opens the host's form. Under
/// the hosts, Extensions (the bundled and installed pi extensions the hosts load) opens
/// Settings ▸ Extensions, and Design systems while a host serves designs; the board's Archive
/// waits for the Mac. On iPad the
/// sidebar's More expands in place instead, to Hosts (`PadHostsScreen`) and Extensions.
struct MoreScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let cards = feed.model.hosts
        let settings = SettingsStore.of(hosts)
        let designs = MobileDesigns.of(hosts).model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                SHListHeader("Hosts") {
                    Button("Add host", systemImage: "plus") { navigator.present(.settings(.host(nil))) }
                        .buttonStyle(.sh(.ghost, size: .s, tint: Color.sh.running))
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
                    .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xs)
                    .padding(.top, SH.Space.xs)
                if !cards.isEmpty {
                    SHListCard {
                        // While a host serves designs (MobileMore: "2 · acme-web, Shepherd Design").
                        if designs.available {
                            Button { navigator.open(.designs(.systems)) } label: {
                                SHListRow("Design systems", subtitle: designs.systemsSummary, subtitleMono: false,
                                          leading: .symbol("paintpalette"))
                            }
                            .buttonStyle(.shRow(radius: 0))
                        }
                        Button { navigator.open(.settings(SettingsPage.pi.route)) } label: {
                            SHListRow(SettingsPage.pi.title, subtitle: settings.extensionsValue(chosenHost: navigator.settingsSelection.chosenHost).map { "\($0) installed" },
                                      subtitleMono: false, leading: .symbol(SettingsPage.pi.symbol))
                        }
                        .buttonStyle(.shRow(radius: 0))
                    }
                    .padding(.top, MobileLayout.sectionSpacing - MobileLayout.headerSpacing)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .background(Color.sh.bgWindow)
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
        SHHostCard(name: card.name, address: card.address, state: card.state, status: card.phase.word,
                   summary: card.summary, summaryTone: card.state == .failed ? .failed : nil,
                   detail: card.lastSeen.map { "Last seen " + HostLastSeen.text($0, now: .now) },
                   openLabel: "Edit \(card.name)", open: edit) {
            if card.canRetry {
                Button("Retry", systemImage: "arrow.clockwise") { hosts.retry(card.id) }
                    .buttonStyle(.sh(.secondary, size: .s))
                    .accessibilityLabel("Retry \(card.name)")
            }
        }
    }

    private func edit() {
        if presentsForm { navigator.present(.settings(.host(card.id))) } else { navigator.open(.settings(.host(card.id))) }
    }
}
