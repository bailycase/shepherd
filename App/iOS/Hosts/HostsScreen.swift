import SwiftUI
import ShepherdUI

/// Settings ▸ Hosts (home track): every host with its connection and what runs there, Retry while
/// it is offline, and Add a Mac. A card opens the host's form.
struct HostsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let cards = HomeFeed.of(hosts).model.hosts
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if cards.isEmpty {
                    Text("No Macs yet. Add a Mac with the code it shows.")
                        .shText(.caption).foregroundStyle(Color.sh.textSecondary)
                        .padding(.horizontal, SH.Space.xs)
                }
                LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.hostCardMinWidth), spacing: MobileLayout.blockSpacing)],
                          alignment: .leading, spacing: MobileLayout.blockSpacing) {
                    ForEach(cards) { card in HostCardView(card: card, presentsForm: false) }
                }
                Button("Add a Mac", systemImage: "plus") { navigator.open(.settings(.host(nil))) }
                    .buttonStyle(.sh(.secondary, size: .l))
                Text("Macs pair with a code on the same local network. The connection has no TLS, so keep it on a network you trust.")
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
