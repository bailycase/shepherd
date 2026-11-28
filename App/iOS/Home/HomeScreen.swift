import SwiftUI
import ShepherdUI
import ShepherdRemote

/// The iPhone Home tab's root, and the iPhone Duo's closed display: the Mac's sidebar as a list screen with the large title
/// (MobileAgents, DuoClosedHome), no card. Hosts that are not connected come first with Retry, then `SidebarContent`: the
/// destinations (New thread, Designs, Automations, Issues & PRs, the Review queue), Needs you, Working, Done, Pinned, and Recents with
/// the spaces, and the footer's Fleet line and Settings under the list. Designs, Projects and Automations are tabs beside it
/// (`PhoneShell`). A row's long press is the Mac's row menu (`ThreadRowMenu`).
struct HomeScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let model = feed.model
        ScrollView {
            if model.hosts.isEmpty {
                NoHostsState().padding(.horizontal, MobileLayout.gutter)
            } else {
                VStack(spacing: 0) {
                    HostNotices(cards: model.offlineHosts)
                        .padding(.horizontal, MobileLayout.gutter)
                        .padding(.bottom, model.offlineHosts.isEmpty ? 0 : SH.Space.m)
                    SidebarContent(phone: true)
                }
            }
        }
        .background(Color.sh.bgWindow)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            SidebarFooterBar().background(Color.sh.bgWindow)
        }
        .refreshable {
            hosts.retryAll()
            await feed.refresh()
        }
        .task { await feed.watch() }
        .navigationTitle("Shepherd")
        // Search and More in one capsule, New thread beside it as the screen's one prominent action and the last to overflow; on the Duo's
        // closed display both join the system column above the tabs (DuoClosedHome, platform-iphone-duo.md).
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button { SearchHooks.open(navigator: navigator) } label: { DuoStripLabel("Search", systemImage: "magnifyingglass") }
                StopAllWorkingMenu()
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { NewThreadHooks.open(navigator: navigator) } label: { DuoStripLabel("New thread", systemImage: "square.and.pencil") }
                    .buttonStyle(.glassProminent)
                    .tint(Color.sh.primary)
                    .disabled(model.hosts.isEmpty)
            }
            .visibilityPriority(.high)
        }
    }
}

/// No hosts yet: the one thing to do is add one.
struct NoHostsState: View {
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        SHEmptyState(Text("Add a Mac"), message: "Pair with a Mac running Shepherd to see its threads.") {
            Button("Add a Mac") { navigator.present(.settings(.host(nil))) }.buttonStyle(.sh(.primary))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, MobileLayout.sectionSpacing)
    }
}
