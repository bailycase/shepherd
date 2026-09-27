import SwiftUI
import ShepherdCore
import ShepherdUI

/// The Designs page in the main column (NavDesigns; Settings ▸ Experiments ▸ Design tool): its
/// model from the view model, and each design's first board read again as designs change.
struct DesignsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    /// A ZIP or folder is over the page (ImportDrop).
    @State private var dropTargeted = false

    var body: some View {
        let _ = NWRenderProbe.tick("page.designs")
        let thumbnails = vm.designRendering.thumbnails
        DesignsPage(model: vm.designsPage, filter: vm.designsPageFilter, actions: DesignsPageActions(
            setFilter: { vm.designsPageFilter = $0 },
            open: { vm.openDesign($0) },
            create: { vm.openNewDesign() },
            openSystem: { target in
                switch target {
                case .system(let namespace): vm.openDesignSystem(namespace)
                case .build(let id): vm.openSystemBuild(id)
                }
            },
            build: { vm.buildDesignSystem(in: $0) },
            openRemote: { vm.openRemoteDesign($0) },
            remoteThumbnail: { host, id in vm.remoteDesignRenderings[host]?.thumbnails.image(id) },
            designMenu: { vm.performDesignMenu($0, on: $1) },
            systemMenu: { vm.performDesignSystemMenu($0, on: $1) }),
            thumbnail: { thumbnails.image($0) }, chrome: chrome)
            .overlay { if dropTargeted { NWDesignsDropTarget() } }
            .onDrop(of: DesignsDropDelegate.types, delegate: DesignsDropDelegate(targeted: $dropTargeted) { vm.importDesignProject($0) })
            .task(id: vm.designThumbnailSignature) { await vm.loadDesignThumbnails() }
            .task(id: vm.remoteDesignsSignature) { await vm.loadRemoteDesigns() }
            .task { await vm.loadDesignSystems() }
    }
}

/// What the Designs page's controls do.
struct DesignsPageActions {
    var setFilter: (String) -> Void
    var open: (DesignID) -> Void
    var create: () -> Void
    var openSystem: (DesignSystemTarget) -> Void = { _ in }
    /// "Build one from a repo" in a project.
    var build: (SpaceID) -> Void = { _ in }
    /// A host's design card.
    var openRemote: (RemoteDesignRef) -> Void = { _ in }
    /// A host's design's first board, as drawn here.
    var remoteThumbnail: (UUID, DesignID) -> CGImage? = { _, _ in nil }
    /// A design card's menu item (DesignCardMenu), and a system card's (SystemCardMenu).
    var designMenu: (DesignMenuAction, DesignTarget) -> Void = { _, _ in }
    var systemMenu: (DesignMenuAction, DesignSystemTarget) -> Void = { _, _ in }
}

/// The Designs page (NavDesigns): the header ("Designs", "Filter designs", New design), then the
/// recent designs as cards in rows of four, and the design systems in rows of three (swatches,
/// name, source, how many designs use it) ending in "Build one from a repo". A system card opens
/// its page.
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
                            case .label(let title, let first), .hostLabel(_, let title, let first):
                                Text(title)
                                    .font(.nw(.caption, weight: .medium))
                                    .foregroundStyle(Color.nw.textTertiary)
                                    .accessibilityAddTraits(.isHeader)
                                    .padding(.top, first ? 0 : AppLayout.designsSectionSpacing - NWPageMetrics.columnGap)
                                    .padding(.bottom, NW.Space.l - NWPageMetrics.columnGap)
                            case .cards(let row):
                                DesignCardRow(slots: row, open: actions.open, thumbnail: thumbnail,
                                              menu: { actions.designMenu($0, .local($1)) })
                                    .equatable()
                            case .hostCards(let host, let row):
                                DesignCardRow(slots: row.map(DesignsPageModel.Slot.design),
                                              open: { actions.openRemote(RemoteDesignRef(hostID: host, designID: $0)) },
                                              thumbnail: { actions.remoteThumbnail(host, $0) },
                                              menu: { actions.designMenu($0, .remote(RemoteDesignRef(hostID: host, designID: $1))) })
                                    .equatable()
                            case .systems(let row, let tile, let first):
                                DesignSystemCardRow(systems: row, tile: tile, projects: model.projects,
                                                    open: actions.openSystem, build: actions.build, menu: actions.systemMenu)
                                    .equatable()
                                    .padding(.top, first ? 0 : NWPageMetrics.columnGap)
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
        case cards([DesignsPageModel.Slot])
        /// A host's name over its designs.
        case hostLabel(UUID, String, first: Bool)
        /// A row of a host's cards.
        case hostCards(UUID, [DesignsPageModel.Card])
        /// A row of system cards, whether the build tile ends it, and whether it is the first.
        case systems([DesignsPageModel.System], tile: Bool, first: Bool)

        var id: String {
            switch self {
            case .label(let title, _): "label.\(title)"
            case .hostLabel(let host, _, _): "label.host.\(host.uuidString)"
            case .cards(let row): "row.\(row.first?.id ?? "")"
            case .hostCards(let host, let row): "host.\(host.uuidString).\(row.first?.id.rawValue ?? "")"
            case .systems(let row, let tile, _): "systems.\(row.first.map { "\($0.id)" } ?? (tile ? "tile" : ""))"
            }
        }
    }

    static func items(_ model: DesignsPageModel) -> [Item] {
        var items: [Item] = []
        if !model.cards.isEmpty || model.importing != nil {
            items.append(.label("Recent designs", first: true))
            items += model.rows.map(Item.cards)
        }
        // Each host's designs under its name (not drawn: NavDesigns shows This Mac's alone).
        for host in model.hosts {
            items.append(.hostLabel(host.id, host.name, first: items.isEmpty))
            items += host.rows.map { .hostCards(host.id, $0) }
        }
        items.append(.label("Design systems", first: items.isEmpty))
        items += model.systemRows.enumerated().map { index, row in .systems(row.systems, tile: row.tile, first: index == 0) }
        return items
    }
}

/// A row of up to three design system cards, the last row ending in "Build one from a repo",
/// redrawn only when one of its cards changes.
struct DesignSystemCardRow: View, Equatable {
    let systems: [DesignsPageModel.System]
    let tile: Bool
    let projects: [DesignsPageModel.Project]
    let open: (DesignSystemTarget) -> Void
    let build: (SpaceID) -> Void
    var menu: (DesignMenuAction, DesignSystemTarget) -> Void = { _, _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.systems == b.systems && a.tile == b.tile && (!a.tile || a.projects == b.projects)
    }

    var body: some View {
        HStack(alignment: .top, spacing: NWPageMetrics.columnGap) {
            ForEach(systems) { system in
                let colors = system.swatches.map { Color(light: $0.light, dark: $0.dark) }
                Group {
                    if let items = system.menu {
                        NWDesignSystemCard(name: system.name, source: system.source, count: system.count, colors: colors, tag: system.tag,
                                           action: { open(system.id) }) {
                            DesignMenuItems(menu: items) { menu($0, system.id) }
                        }
                    } else {
                        NWDesignSystemCard(name: system.name, source: system.source, count: system.count, colors: colors, tag: system.tag,
                                           dashed: system.dashed)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            if tile {
                buildTile
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<max(0, DesignsPageModel.systemColumns - systems.count - (tile ? 1 : 0)), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    /// "Build one from a repo": the one project at once, a menu of them with more, and nothing
    /// to read without one.
    @ViewBuilder private var buildTile: some View {
        if projects.count == 1, let project = projects.first {
            Button { build(project.id) } label: { NWDesignSystemBuildTile() }
                .buttonStyle(.plain)
                .help("Build a design system from \(project.name)")
        } else if projects.isEmpty {
            NWDesignSystemBuildTile(enabled: false)
                .help("Add a project to build a design system from it")
        } else {
            Menu {
                ForEach(projects) { project in
                    Button(project.name) { build(project.id) }
                }
            } label: { NWDesignSystemBuildTile() }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .help("Build a design system from a project")
        }
    }
}

/// A row of up to four design cards (an import's first), redrawn only when one of its cards
/// changes.
struct DesignCardRow: View, Equatable {
    let slots: [DesignsPageModel.Slot]
    let open: (DesignID) -> Void
    let thumbnail: (DesignID) -> CGImage?
    var menu: (DesignMenuAction, DesignID) -> Void = { _, _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.slots == b.slots }

    var body: some View {
        HStack(alignment: .top, spacing: NWPageMetrics.columnGap) {
            ForEach(slots) { slot in
                Group {
                    switch slot {
                    case .design(let card):
                        DesignCardView(card: card, open: open, image: thumbnail(card.id), menu: menu)
                            .equatable()
                    case .importing(let importing):
                        NWImportingCard(title: importing.shownTitle, done: importing.done, total: importing.total, system: importing.system)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(0..<(DesignsPageModel.columns - slots.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}

/// One design's card, with its menu (a right-click, or ••• on hover).
struct DesignCardView: View, Equatable {
    let card: DesignsPageModel.Card
    let open: (DesignID) -> Void
    let image: CGImage?
    var menu: (DesignMenuAction, DesignID) -> Void = { _, _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.card == b.card }

    var body: some View {
        NWDesignCard(name: card.name, system: card.system, detail: card.detail, edited: card.edited, board: card.board,
                     selected: card.selected, action: { open(card.id) }) {
            DesignThumbnailSlot(image: image)
        } menu: {
            DesignMenuItems(menu: card.menu) { menu($0, card.id) }
        }
    }
}
