import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The Designs list on iPad (DuoOpenDesigns, DuoClosedDesigns), which the sidebar's Designs row
/// opens: every serving host's designs as cards in the phone's grid (SHDesignTile), most recently
/// active first, each naming its host when there are several, then the hosts' design systems.
/// Only hosts that offer `designs.v1` have designs here.
struct PadDesignsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let designs = PadDesigns.of(hosts)
        let systems = MobileDesigns.of(hosts)
        let thumbnails = PadDesignThumbnails.shared
        let now = Date()
        let tagsHosts = Set(designs.rows.map(\.ref.host)).count > 1
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesignLayout.sectionSpacing) {
                // The board's own title (DuoOpenDesigns: 28 bold), not the navigation bar's.
                Text("Designs")
                    .font(.shSans(MobileDesignLayout.titleSize, .bold))
                    .foregroundStyle(Color.sh.textPrimary)
                    .padding(.horizontal, SH.Space.xs)
                    .accessibilityAddTraits(.isHeader)
                if !designs.rows.isEmpty {
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        SHListHeader("Recent", style: .quiet)
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: SHPhoneDesignMetrics.gridColumnMinimum),
                                                     spacing: SHPhoneDesignMetrics.gridColumnSpacing, alignment: .top)],
                                  spacing: SHPhoneDesignMetrics.gridRowSpacing) {
                            ForEach(designs.rows) { row in
                                let first = designs.library(row.ref.host).listing?.designs.first { $0.id == row.ref.design }?.firstBoard
                                let drawing = row.agentID.flatMap { hosts.host(row.ref.host)?.agent($0) }?.status == .working
                                SHDesignTile(name: row.name,
                                             detail: drawing ? "Drawing · \(row.boards)"
                                                 : [row.system, row.boards, RemoteDesignPresentation.age(row.lastActive, now: now)]
                                                     .compactMap { $0 }.joined(separator: " · "),
                                             host: tagsHosts ? row.hostName : nil,
                                             action: { PadDesignHooks.open(row.ref, navigator: navigator) }) {
                                    PadDesignThumbnail(image: thumbnails.image(row.ref), version: thumbnails.versions[row.ref] ?? 0)
                                }
                                .task(id: first?.sha256) {
                                    guard let first else { return }
                                    thumbnails.update(row.ref, path: first.path, size: CGSize(width: first.width, height: first.height),
                                                      sha: first.sha256, source: designs.library(row.ref.host).source(row.ref.design))
                                }
                            }
                        }
                    }
                }
                if !systems.model.systems.isEmpty {
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        SHListHeader("Design systems", style: .quiet)
                        DesignSystemsCard(rows: systems.model.systems, swatches: systems.swatches)
                    }
                }
                if designs.rows.isEmpty {
                    // Not drawn on any board: the least that is honest.
                    Text(designs.available ? "No designs yet. Start one on the Mac." : "No host serves designs. Turn on Settings ▸ Experiments ▸ Design tool on a Mac.")
                        .font(.sh(.caption))
                        .foregroundStyle(Color.sh.textTertiary)
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter + SH.Space.xs)
            .padding(.bottom, MobileLayout.padThreadGutter)
        }
        .background(Color.sh.bgWindow)
        .navigationTitle("Designs")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(removing: .title)
        .toolbar(.hidden, for: .tabBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                Button("New design", systemImage: "plus") { DesignsHooks.create(navigator: navigator) }
                    .buttonStyle(.glassProminent)
                    .disabled(!designs.available)
            }
        }
        .refreshable { await designs.refresh(); await systems.refresh() }
        .task { await designs.refresh(); await systems.refresh() }
    }
}
