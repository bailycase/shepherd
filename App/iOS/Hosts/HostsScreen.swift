import SwiftUI
import ShepherdUI

/// Settings ▸ Hosts (home track): every host with its connection and what runs there, Retry while
/// it is offline, and Add host. A card opens the host's form.
struct HostsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let cards = HomeFeed.of(hosts).model.hosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if cards.isEmpty {
                    Text("No hosts yet. Add the Macs you run Shepherd on.")
                        .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.xs)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.hostCardMinWidth), spacing: MobileLayout.blockSpacing)],
                          alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    ForEach(cards) { card in HostCardView(card: card, presentsForm: false) }
                }
                Button("Add host", systemImage: "plus") { navigator.open(.settings(.host(nil))) }
                    .buttonStyle(.sh(.secondary, size: .l))
                Text("Trusted LAN or VPN only: the connection has no TLS.")
                    .shText(.caption).foregroundStyle(Color.sh.textTertiary)
                    .padding(.horizontal, SH.Space.xs)
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
        }
        .background(Color.sh.bgWindow)
        .refreshable { hosts.retryAll() }
        .navigationTitle("Hosts")
        .navigationBarTitleDisplayMode(.inline)
    }
}
