import SwiftUI
import ShepherdCore
import ShepherdUI

/// The Designs page in the main column (NavDesigns; Settings ▸ Experiments ▸ Design tool): its
/// model from the view model, and each design's first board read again as designs change.
struct DesignsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        let _ = NWRenderProbe.tick("page.designs")
        let thumbnails = vm.designRendering.thumbnails
        DesignsPage(model: vm.designsPage, filter: vm.designsPageFilter, actions: DesignsPageActions(
            setFilter: { vm.designsPageFilter = $0 },
            open: { vm.openDesign($0) },
            create: { vm.openNewDesign() }), thumbnail: { thumbnails.image($0) }, chrome: chrome)
            .task(id: vm.designThumbnailSignature) { await vm.loadDesignThumbnails() }
    }
}

/// What the Designs page's controls do.
struct DesignsPageActions {
    var setFilter: (String) -> Void
    var open: (DesignID) -> Void
    var create: () -> Void
}

/// The Designs page (NavDesigns): the header ("Designs", "Filter designs", New design), then the
/// recent designs as cards in rows of four and the design systems they are drawn in. P1 reads a
/// design's system as its project, so a system card is its name and how many designs use it:
/// the swatches, the source line and "Build one from a repo" come with design systems.
struct DesignsPage: View {
    let model: DesignsPageModel
    let filter: String
    let actions: DesignsPageActions
    let thumbnail: (DesignID) -> CGImage?
    var chrome = PageHeaderChrome()

    var body: some View {
        VStack(spacing: 0) {
            DestinationPageHeader(title: "Designs", chrome: chrome) {
                NWPageFilterField("Filter designs", text: Binding(get: { filter }, set: actions.setFilter))
                Button("New design", systemImage: "plus", action: actions.create)
                    .buttonStyle(.nw(.primary))
            }
            ScrollView(.vertical) {
                // One lazy stack, one view per element: a section's label, a row of cards, the
                // systems' grid. Only the rows on screen are built.
                LazyVStack(alignment: .leading, spacing: NWPageMetrics.columnGap) {
                    ForEach(Self.items(model)) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            switch item {
                            case .label(let title, let first):
                                Text(title)
                                    .font(.nw(.caption, weight: .medium))
                                    .foregroundStyle(Color.nw.textTertiary)
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.top, first ? 0 : AppLayout.designsSectionSpacing - NWPageMetrics.columnGap)
                                    .padding(.bottom, NW.Space.l - NWPageMetrics.columnGap)
                            case .cards(let row):
                                DesignCardRow(cards: row, open: actions.open, thumbnail: thumbnail)
                                    .equatable()
                            case .systems(let systems):
                                systemsGrid(systems)
                            }
                        }
                    }
                }
                .padding(.vertical, NWPageMetrics.bodyVertical)
                .padding(.horizontal, NWPageMetrics.sideInset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.nw.bgWindow)
    }

    /// The page's elements, in order.
    enum Item: Identifiable {
        case label(String, first: Bool)
        case cards([DesignsPageModel.Card])
        case systems([DesignsPageModel.System])

        var id: String {
            switch self {
            case .label(let title, _): "label.\(title)"
            case .cards(let row): "row.\(row.first?.id.rawValue ?? "")"
            case .systems: "systems"
            }
        }
    }

    static func items(_ model: DesignsPageModel) -> [Item] {
        var items: [Item] = []
        if !model.cards.isEmpty {
            items.append(.label("Recent designs", first: true))
            items += model.rows.map(Item.cards)
        }
        if !model.systems.isEmpty {
            items.append(.label("Design systems", first: items.isEmpty))
            items.append(.systems(model.systems))
        }
        return items
    }

    private func systemsGrid(_ systems: [DesignsPageModel.System]) -> some View {
        Grid(horizontalSpacing: NWPageMetrics.columnGap, verticalSpacing: NWPageMetrics.columnGap) {
            ForEach(Array(stride(from: 0, to: systems.count, by: AppLayout.designSystemColumns)), id: \.self) { start in
                GridRow {
                    let row = systems[start..<min(start + AppLayout.designSystemColumns, systems.count)]
                    ForEach(row) { system in
                        NWDesignSystemCard(name: system.name, count: system.count)
                            .frame(maxWidth: .infinity)
                    }
                    ForEach(0..<(AppLayout.designSystemColumns - row.count), id: \.self) { _ in
                        Color.clear.frame(maxWidth: .infinity).gridCellUnsizedAxes(.vertical)
                    }
                }
            }
        }
    }
}

/// A row of up to four design cards, redrawn only when one of its cards changes.
struct DesignCardRow: View, Equatable {
    let cards: [DesignsPageModel.Card]
    let open: (DesignID) -> Void
    let thumbnail: (DesignID) -> CGImage?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.cards == b.cards }

    var body: some View {
        HStack(alignment: .top, spacing: NWPageMetrics.columnGap) {
            ForEach(cards) { card in
                DesignCardView(card: card, open: open, image: thumbnail(card.id))
                    .equatable()
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<(DesignsPageModel.columns - cards.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}

/// One design's card.
struct DesignCardView: View, Equatable {
    let card: DesignsPageModel.Card
    let open: (DesignID) -> Void
    let image: CGImage?

    nonisolated static func == (a: Self, b: Self) -> Bool { a.card == b.card }

    var body: some View {
        NWDesignCard(name: card.name, system: card.system, detail: card.detail, edited: card.edited, board: card.board,
                     selected: card.selected, action: { open(card.id) }) {
            DesignThumbnailSlot(image: image)
        }
    }
}
