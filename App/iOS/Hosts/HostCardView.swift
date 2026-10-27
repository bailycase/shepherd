import SwiftUI
import ShepherdUI
import ShepherdRemote

/// A host's card (Settings ▸ Hosts, the iPad's Hosts): Retry while it is offline; a tap opens its
/// form, pushed in Settings and presented elsewhere.
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
