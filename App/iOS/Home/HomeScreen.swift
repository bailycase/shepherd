import SwiftUI
import ShepherdUI

/// The iPhone Home tab's root (MobileAgents board; home track). The foundation's version lists
/// each host with its agents, opens a thread, and links New thread, Search and the destinations.
struct HomeScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let sections = FleetSection.sections(hosts)
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                if sections.isEmpty {
                    NWEmptyState(Text("Add a host"), message: "Connect to a Mac running Shepherd to see its threads.") {
                        Button("Add host") { navigator.open(.settings(.host(nil))) }.buttonStyle(.nw(.primary))
                    }
                }
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        FleetHostHeader(section: section)
                        ForEach(section.rows) { row in
                            Button { navigator.open(.thread(row.ref)) } label: {
                                FleetRowView(row: row, dimmed: !section.phase.isConnected).equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                VStack(spacing: 0) {
                    destination("Needs you", systemImage: "exclamationmark.circle", route: .needsYou)
                    destination("Automations", systemImage: "clock.arrow.circlepath", route: .automations)
                    destination("More", systemImage: "ellipsis.circle", route: .more)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Shepherd")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
                Button("New thread", systemImage: "square.and.pencil") { NewThreadHooks.open(navigator: navigator) }
            }
        }
    }

    private func destination(_ title: String, systemImage: String, route: HomeRoute) -> some View {
        Button { navigator.open(.home(route)) } label: {
            Label(title, systemImage: systemImage)
                .font(.nw(.ui))
                .foregroundStyle(Color.nw.textPrimary)
                .frame(maxWidth: .infinity, minHeight: MobileLayout.rowHeight, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
