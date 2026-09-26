import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// Designs on iPhone (MobileDesigns), pushed from Home's Designs row: Search and New design in
/// the navigation bar, the large title, Recent as a two-column grid of tiles (each its first board
/// drawn on the phone), and Design systems as a list card.
struct DesignsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let designs = MobileDesigns.of(hosts)
        let model = designs.model
        ScrollView {
            VStack(alignment: .leading, spacing: MobileDesignLayout.sectionSpacing) {
                if !model.available {
                    NWEmptyState(Text("No designs here"), message: RemoteHostClient.designsRefusal, showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                } else if model.tiles.isEmpty && model.systems.isEmpty {
                    NWEmptyState(Text("No designs yet"), message: "Start one with New design; its boards show here.", showsMark: false)
                        .frame(maxWidth: .infinity)
                        .padding(.top, NW.Space.xxxl)
                }
                if !model.tiles.isEmpty {
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        NWListHeader("Recent", count: nil)
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: NWPhoneDesignMetrics.gridColumnSpacing,
                                                                     alignment: .top), count: 2),
                                  spacing: NWPhoneDesignMetrics.gridRowSpacing) {
                            ForEach(model.tiles) { tile in
                                DesignTileView(tile: tile, source: designs.source(tile.ref)) {
                                    DesignsHooks.open(tile.ref, navigator: navigator)
                                }
                                .equatable()
                            }
                        }
                    }
                }
                if !model.systems.isEmpty {
                    VStack(alignment: .leading, spacing: MobileLayout.headerSpacing) {
                        NWListHeader("Design systems", count: nil)
                        DesignSystemsCard(rows: model.systems, swatches: designs.swatches)
                    }
                }
            }
            .padding(.horizontal, MobileDesignLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.nw.bgWindow)
        .refreshable { await designs.refresh() }
        .task { await designs.refresh() }
        .navigationTitle("Designs")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Search", systemImage: "magnifyingglass") { SearchHooks.open(navigator: navigator) }
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            // New design is the lantern circle (MobileDesigns).
            ToolbarItem(placement: .topBarTrailing) {
                Button("New design", systemImage: "plus") { DesignsHooks.create(navigator: navigator) }
                    .buttonStyle(.glassProminent)
                    .tint(Color.nw.lantern)
                    .disabled(designs.serving.isEmpty)
            }
        }
    }
}

/// A design's tile: its first board drawn on the phone at the tile's width (a phone board at its
/// height, centered), its name, and its line.
struct DesignTileView: View, Equatable {
    let tile: RemoteDesignTile
    let source: RemoteDesignSource?
    let open: () -> Void

    static func == (a: DesignTileView, b: DesignTileView) -> Bool { a.tile == b.tile && (a.source == nil) == (b.source == nil) }

    var body: some View {
        NWDesignTile(name: tile.name, detail: tile.detail, host: tile.hostTag, action: open) {
            GeometryReader { proxy in
                if let first = tile.firstBoard {
                    let size = CGSize(width: first.width, height: first.height)
                    let scale = RemoteDesignPresentation.tileScale(size, in: proxy.size)
                    let phone = size.height > size.width
                    DesignBoardImage(ref: tile.ref, source: source, path: first.path, sha256: first.sha256, size: size,
                                     shown: CGSize(width: size.width * scale, height: size.height * scale),
                                     alignment: phone ? .top : .topLeading)
                }
            }
        }
    }
}

/// The hosts' design systems as a list card, each opening its page.
struct DesignSystemsCard: View {
    let rows: [RemoteDesignSystemRow]
    let swatches: [String: [String]]
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        NWListCard {
            ForEach(rows) { row in
                Button { navigator.open(.designs(.system(host: row.host, namespace: row.namespace))) } label: {
                    NWDesignSystemRow(name: row.name, source: [row.source, row.hostTag].compactMap { $0 }.joined(separator: " · "),
                                      colors: (swatches[row.id] ?? []).map { Color(light: $0, dark: $0) })
                }
                .buttonStyle(.nwRow(radius: 0))
            }
        }
    }
}
