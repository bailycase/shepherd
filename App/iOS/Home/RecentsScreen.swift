import SwiftUI
import ShepherdUI
import ShepherdRemote

/// Every recent thread across hosts, past Home's first few (home track).
struct RecentsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let feed = HomeFeed.of(hosts)
        let rows = feed.model.recents
        let selected = navigator.selectedThread
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(rows) { row in
                    VStack(spacing: 0) {
                        if row.id != rows.first?.id { NWHairline() }
                        Button { navigator.open(row.route) } label: {
                            ThreadRow(row: row, selected: row.ref.agentRef == selected).equatable()
                        }
                        .buttonStyle(.nwRow(radius: 0))
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: NWListMetrics.cardRadius))
            .nwCard(radius: NWListMetrics.cardRadius)
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .refreshable { await feed.refresh() }
        .task { await feed.watch() }
        .navigationTitle("Recents")
        .navigationBarTitleDisplayMode(.inline)
    }
}
