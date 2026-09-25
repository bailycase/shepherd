import SwiftUI
import ShepherdUI

/// The iPad sidebar (iPadSidebar board; home track). The foundation's version: New thread and
/// Search, each host with its agents, and Settings at the foot.
struct PadSidebar: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let sections = FleetSection.sections(hosts)
        let selected = navigator.selectedThread
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.blockSpacing) {
                Button { NewThreadHooks.open(navigator: navigator) } label: {
                    Label("New thread", systemImage: "square.and.pencil")
                        .font(.nw(.ui))
                        .foregroundStyle(Color.nw.textPrimary)
                        .frame(maxWidth: .infinity, minHeight: NW.Height.touch, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: NW.Space.xs) {
                        FleetHostHeader(section: section)
                        ForEach(section.rows) { row in
                            Button { navigator.open(.thread(row.ref)) } label: {
                                FleetRowView(row: row, selected: row.ref == selected, dimmed: !section.phase.isConnected).equatable()
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
        }
        .background(Color.nw.bgBase)
        .navigationTitle("Shepherd")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            }
            ToolbarItem(placement: .bottomBar) {
                Button("Settings", systemImage: "gearshape") { navigator.open(.settings(.root)) }
            }
        }
    }
}
