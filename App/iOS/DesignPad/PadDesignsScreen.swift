import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The Designs list on iPad, which the sidebar's Designs row opens: every serving host's designs
/// as the Mac's Designs page draws them (NWDesignCard, NavDesigns), most recently active first,
/// each card naming its host when there are several. No iPad board draws this page; it is the
/// least that reaches a design. Only hosts that offer `designs.v1` have designs here.
struct PadDesignsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let designs = PadDesigns.of(hosts)
        let thumbnails = PadDesignThumbnails.shared
        let now = Date()
        let tagsHosts = Set(designs.rows.map(\.ref.host)).count > 1
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: MobileLayout.padDesignCardMinWidth), spacing: NWDesignMetrics.cardGridSpacing)],
                      alignment: .leading, spacing: NWDesignMetrics.cardGridSpacing) {
                ForEach(designs.rows) { row in
                    let first = designs.library(row.ref.host).listing?.designs.first { $0.id == row.ref.design }?.firstBoard
                    NWDesignCard(name: row.name, system: row.system,
                                 detail: tagsHosts ? "\(row.boards) · \(row.hostName)" : row.boards,
                                 edited: "edited \(SuggestionsPresentation.when(row.lastActive / 1000, now: now))",
                                 board: NWDesignCardBoard(size: first.map { CGSize(width: $0.width, height: $0.height) }),
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
            .padding(MobileLayout.padThreadGutter)
            if designs.rows.isEmpty {
                // Not drawn on any board: the least that is honest.
                Text(designs.available ? "No designs yet. Start one on the Mac." : "No host serves designs. Turn on Settings ▸ Experiments ▸ Design tool on a Mac.")
                    .font(.nw(.caption))
                    .foregroundStyle(Color.nw.textTertiary)
                    .padding(.horizontal, MobileLayout.padThreadGutter)
            }
        }
        .background(Color.nw.bgWindow)
        .navigationTitle("Designs")
        .toolbar(.hidden, for: .tabBar)
        .refreshable { await designs.refresh() }
        .task { await designs.refresh() }
    }
}
