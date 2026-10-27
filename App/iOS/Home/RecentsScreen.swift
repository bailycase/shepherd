import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Every thread of one of Home's groups, past Home's first few (home track): Recents (so a thread
/// in Working, Done or Pinned is listed there instead, once), or the whole of Working or Done.
struct RecentsScreen: View {
    enum Group {
        case recents, working, done

        var title: String {
            switch self {
            case .recents: "Recents"
            case .working: "Working"
            case .done: "Done"
            }
        }

        func rows(_ groups: FleetSidebarGroups) -> [FleetThreadRow] {
            switch self {
            case .recents: groups.recents
            case .working: groups.working
            case .done: groups.done
            }
        }
    }

    var group: Group = .recents
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let rows = group.rows(SidebarThreads.of(hosts).groups(feed.model))
        let selected = navigator.selectedThread
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    VStack(spacing: 0) {
                        if row.id != rows.first?.id { SHHairline() }
                        Button { navigator.open(row.route) } label: {
                            ThreadRow(row: row, selected: row.ref.agentRef == selected).equatable()
                        }
                        .buttonStyle(.shRow(radius: 0))
                        .contextMenu { if row.design == nil { ThreadRowMenu(thread: row.ref.agentRef) } }
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: SHListMetrics.cardRadius))
            .shCard(radius: SHListMetrics.cardRadius)
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .refreshable { await feed.refresh() }
        .task { await feed.watch() }
        .navigationTitle(group.title)
        .navigationBarTitleDisplayMode(.inline)
    }
}
