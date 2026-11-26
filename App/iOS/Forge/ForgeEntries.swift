import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// Where Issues & PRs is reached from: Home's row on iPhone, and the iPad sidebar's row with its
/// Pinned section (iPadIPReview). Shown while a paired host offers Issues & PRs.
@MainActor
enum ForgeEntry {
    static func available(_ hosts: MobileHosts) -> Bool {
        hosts.hosts.contains { $0.supports(RemoteProtocol.forgeCapability) }
    }

    /// The row's count: what needs you, in lantern.
    static func trailing(_ store: ForgeStore) -> SHListRow.Trailing {
        store.needsYou > 0 ? .reason("\(store.needsYou)") : .none
    }
}

/// Home's Issues & PRs row (iPhone): a sixth tab would put Settings under iOS's More, so the
/// destination is a row here, its count the pull requests and issues waiting on you.
struct HomeForgeSection: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        if ForgeEntry.available(hosts) {
            let store = ForgeStore.of(hosts)
            SHListCard {
                Button { navigator.open(.forge(.list)) } label: {
                    SHListRow("Issues & PRs", leading: .symbol(ForgeGlyph.pullRequest), trailing: ForgeEntry.trailing(store))
                }
                .buttonStyle(.shRow(radius: 0))
                .accessibilityValue(store.needsYou > 0 ? "\(store.needsYou) need you" : "")
            }
            .task(id: store.sessionsKey) { await store.loadSidebars() }
        }
    }
}
