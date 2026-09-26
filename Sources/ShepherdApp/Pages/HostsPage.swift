import SwiftUI
import ShepherdUI

/// What the Hosts page's buttons do.
struct HostsPageActions {
    var retry: (UUID) -> Void
    /// Asks before removing (the caller confirms).
    var remove: (UUID) -> Void
    var addHost: () -> Void
}

/// The Hosts page (NavHosts; More ▸ Hosts): where agents run. This Mac and each remote host as a
/// card with its connection, what runs or waits there, and Retry and Remove for a remote host;
/// Add host opens the host form. Missions and daemons are not built, so the board's daemon
/// facts, Load, worktree sizes, Open terminal and Logs are left out.
struct HostsPage: View {
    let model: HostsPageModel
    let actions: HostsPageActions
    var chrome = PageHeaderChrome()

    static let explainer = "Where agents run. Threads run on the host you pick when you start them. "
        + "Remote threads show the host’s name as a tag in Recents."

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Hosts", subtitle: model.subtitle, chrome: chrome) {
                Button("Add host", systemImage: "plus", action: actions.addHost)
                    .buttonStyle(.nw(.primary))
            }
            ScrollView {
                VStack(alignment: .leading, spacing: AppLayout.hostExplainerSpacing) {
                    Text(Self.explainer)
                        .font(.nw(.ui, weight: .regular))
                        .lineSpacing(NWTextStyle.caption.lineSpacing)
                        .foregroundStyle(Color.nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: AppLayout.hostExplainerMaxWidth, alignment: .leading)
                    Grid(horizontalSpacing: NWPageMetrics.columnGap, verticalSpacing: NWPageMetrics.columnGap) {
                        ForEach(model.rows, id: \.first?.id) { row in
                            GridRow {
                                ForEach(row) { card in
                                    HostPageCardView(card: card, actions: actions)
                                        .equatable()
                                }
                                ForEach(0..<(AppLayout.hostColumns - row.count), id: \.self) { _ in
                                    Color.clear.frame(maxWidth: .infinity).gridCellUnsizedAxes(.vertical)
                                }
                            }
                        }
                    }
                }
                .padding(.vertical, NWPageMetrics.bodyVertical)
                .padding(.horizontal, NWPageMetrics.sideInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .background(Color.nw.bgWindow)
    }
}

/// One host's card with its actions.
struct HostPageCardView: View, Equatable {
    let card: HostsPageCard
    let actions: HostsPageActions

    nonisolated static func == (a: HostPageCardView, b: HostPageCardView) -> Bool { a.card == b.card }

    var body: some View {
        if case .remote(let id) = card.id {
            NWHostPageCard(name: card.name, subtitle: card.subtitle, offlineSince: card.offlineSince, status: card.status,
                           state: card.state, facts: card.facts, note: card.note) {
                if card.canRetry {
                    Button("Retry", systemImage: "arrow.clockwise") { actions.retry(id) }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .accessibilityLabel("Retry \(card.name)")
                }
                if card.canRemove {
                    Button("Remove") { actions.remove(id) }
                        .buttonStyle(.nw(.ghost, size: .s))
                        .accessibilityLabel("Remove \(card.name)")
                }
            }
        } else {
            NWHostPageCard(name: card.name, subtitle: card.subtitle, status: card.status, state: card.state,
                           facts: card.facts, note: card.note)
        }
    }
}
