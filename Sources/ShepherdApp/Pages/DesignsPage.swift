import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdSidebar

/// The Designs page in the main column (NavDesigns; Settings ▸ Experiments ▸ Design tool): its
/// model from the view model, and each design's first board read again as designs change.
struct DesignsDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()
    /// A ZIP or folder is over the page (ImportDrop).
    @State private var dropTargeted = false

    var body: some View {
        let _ = SHRenderProbe.tick("page.designs")
        let thumbnails = vm.designRendering.thumbnails
        DesignsPage(model: vm.designsPage, filter: vm.designsPageFilter, actions: DesignsPageActions(
            setFilter: { vm.designsPageFilter = $0 },
            open: { vm.openDesign($0) },
            create: { vm.openNewDesign() },
            openGit: { vm.openDesignGitOpen() },
            openSystem: { target in
                switch target {
                case .system(let namespace): vm.openDesignSystem(namespace)
                case .build(let id): vm.openSystemBuild(id)
                case .remote(let ref): vm.openRemoteDesignSystem(ref)
                case .remoteBuild(let ref): vm.openRemoteSystemBuild(ref)
                }
            },
            build: { vm.buildDesignSystem(in: $0) },
            openRemote: { vm.openRemoteDesign($0) },
            buildRemote: { vm.buildRemoteSystem(host: $0, in: $1) },
            remoteThumbnail: { host, id in vm.remoteDesignRenderings[host]?.thumbnails.image(id) },
            designMenu: { vm.performDesignMenu($0, on: $1) },
            systemMenu: { vm.performDesignSystemMenu($0, on: $1) },
            visibility: { vm.designThumbnailVisibility($0, visible: $1) }),
            thumbnail: { thumbnails.image($0) }, chrome: chrome)
            // Over the page under its header (ImportDrop).
            .overlay { if dropTargeted { SHDesignsDropTarget().padding(.top, SHToolbarMetrics.height) } }
            .onDrop(of: DesignsDropDelegate.types, delegate: DesignsDropDelegate(targeted: $dropTargeted) { vm.importDesignProject($0) })
            .task(id: vm.designThumbnailSignature) {
                await vm.loadDesignThumbnails()
                await vm.loadDesignCommentCounts()
            }
            .task(id: vm.remoteDesignsSignature) { await vm.loadRemoteDesigns() }
            .task { await vm.loadDesignSystems() }
    }
}

/// What the Designs page's controls do.
struct DesignsPageActions {
    var setFilter: (String) -> Void
    var open: (DesignID) -> Void
    var create: () -> Void
    /// Open from Git (GitDesignOpen): clone a shared design into Designs.
    var openGit: () -> Void = {}
    var openSystem: (DesignSystemTarget) -> Void = { _ in }
    /// "Build one from a repo" in a project.
    var build: (SpaceID) -> Void = { _ in }
    /// A host's design card.
    var openRemote: (RemoteDesignRef) -> Void = { _ in }
    /// A host's "Build one from a repo", in one of its spaces.
    var buildRemote: (UUID, SpaceID) -> Void = { _, _ in }
    /// A host's design's first board, as drawn here.
    var remoteThumbnail: (UUID, DesignID) -> CGImage? = { _, _ in nil }
    /// A design card's menu item (DesignCardMenu), and a system card's (SystemCardMenu).
    var designMenu: (DesignMenuAction, DesignTarget) -> Void = { _, _ in }
    var systemMenu: (DesignMenuAction, DesignSystemTarget) -> Void = { _, _ in }
    var visibility: (DesignTarget, Bool) -> Void = { _, _ in }
}

/// The Designs page (NavDesigns): the bar ("Designs", the filter pill, and a capsule of Open from
/// Git and New design), then Recent designs as cards in rows of four, and Design systems, with
/// "Build one from a repo" at the section's right, in rows of three (swatches, name, source, how
/// many designs use it). A system card opens its page.
struct DesignsPage: View {
    let model: DesignsPageModel
    let filter: String
    let actions: DesignsPageActions
    let thumbnail: (DesignID) -> CGImage?
    var chrome = PageHeaderChrome()

    var body: some View {
        VStack(spacing: 0) {
            SHDesignsBar("Designs", leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                         sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar)) {
                SHDesignsFilterField("Filter designs", text: Binding(get: { filter }, set: actions.setFilter))
                SHToolbarCapsule {
                    Button("Open from Git", action: actions.openGit)
                        .buttonStyle(.shBar)
                    SHBarDivider()
                    Button("New design", systemImage: "plus", action: actions.create)
                        .buttonStyle(.shBar)
                }
            }
            ScrollView(.vertical) {
                // One lazy stack, one view per element: a section's label, a row of cards. Only
                // the rows on screen are built.
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Self.items(model)) { item in
                        VStack(alignment: .leading, spacing: 0) {
                            switch item {
                            case .label(let title, let first), .hostLabel(_, let title, let first):
                                SHDesignsSection(title)
                                    .padding(.top, first ? SHDesignsHomeMetrics.sectionTop : SHDesignsHomeMetrics.sectionGap)
                                    .padding(.bottom, SHDesignsHomeMetrics.sectionBottom)
                            case .systemsLabel(let host, let projects, let first):
                                DesignSystemsLabel(projects: projects, build: { space in
                                    if let host { actions.buildRemote(host, space) } else { actions.build(space) }
                                })
                                    .equatable()
                                    .padding(.top, first ? SHDesignsHomeMetrics.sectionTop : SHDesignsHomeMetrics.sectionGap)
                                    .padding(.bottom, SHDesignsHomeMetrics.sectionBottom)
                            case .cards(let row, let first):
                                DesignCardRow(slots: row, open: actions.open, thumbnail: thumbnail,
                                              menu: { actions.designMenu($0, .local($1)) },
                                              visibility: { actions.visibility(.local($0), $1) })
                                    .equatable()
                                    .padding(.top, first ? 0 : SHDesignsHomeMetrics.gap)
                            case .hostSystems(let row, let first):
                                DesignSystemCardRow(systems: row, open: actions.openSystem, menu: actions.systemMenu)
                                    .equatable()
                                    .padding(.top, first ? 0 : SHDesignsHomeMetrics.gap)
                            case .hostCards(let host, let row, let first):
                                DesignCardRow(slots: row.map(DesignsPageModel.Slot.design),
                                              open: { actions.openRemote(RemoteDesignRef(hostID: host, designID: $0)) },
                                              thumbnail: { actions.remoteThumbnail(host, $0) },
                                              menu: { actions.designMenu($0, .remote(RemoteDesignRef(hostID: host, designID: $1))) },
                                              visibility: { actions.visibility(.remote(RemoteDesignRef(hostID: host, designID: $0)), $1) })
                                    .equatable()
                                    .padding(.top, first ? 0 : SHDesignsHomeMetrics.gap)
                            case .systems(let row, let first):
                                DesignSystemCardRow(systems: row, open: actions.openSystem, menu: actions.systemMenu)
                                    .equatable()
                                    .padding(.top, first ? 0 : SHDesignsHomeMetrics.gap)
                            }
                        }
                    }
                }
                .padding(.top, SHDesignsHomeMetrics.top)
                .padding(.bottom, SHDesignsHomeMetrics.bottom)
                .padding(.horizontal, SHDesignsHomeMetrics.inset)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.hidden)
        }
        .background(Color.sh.bgWindow)
    }

    /// The page's elements, in order.
    enum Item: Identifiable {
        case label(String, first: Bool)
        /// A row of cards, and whether it is the section's first.
        case cards([DesignsPageModel.Slot], first: Bool)
        /// A host's name over its designs.
        case hostLabel(UUID, String, first: Bool)
        /// A row of a host's cards.
        case hostCards(UUID, [DesignsPageModel.Card], first: Bool)
        /// "Design systems" with "Build one from a repo" at its right: this Mac's (`host` nil), or a
        /// host's, where the host builds for other devices (`projects` is then its spaces).
        case systemsLabel(host: UUID?, projects: [DesignsPageModel.Project]?, first: Bool)
        /// A row of a host's design systems (and builds still reading).
        case hostSystems([DesignsPageModel.System], first: Bool)
        /// A row of system cards.
        case systems([DesignsPageModel.System], first: Bool)

        var id: String {
            switch self {
            case .label(let title, _): "label.\(title)"
            case .hostLabel(let host, _, _): "label.host.\(host.uuidString)"
            case .cards(let row, _): "row.\(row.first?.id ?? "")"
            case .hostCards(let host, let row, _): "host.\(host.uuidString).\(row.first?.id.rawValue ?? "")"
            case .systemsLabel(let host, _, _): "label.systems.\(host?.uuidString ?? "")"
            case .hostSystems(let row, _): "host.systems.\(row.first.map { "\($0.id)" } ?? "")"
            case .systems(let row, _): "systems.\(row.first.map { "\($0.id)" } ?? "")"
            }
        }
    }

    static func items(_ model: DesignsPageModel) -> [Item] {
        var items: [Item] = []
        if !model.cards.isEmpty || model.importing != nil {
            items.append(.label("Recent designs", first: true))
            items += model.rows.enumerated().map { Item.cards($1, first: $0 == 0) }
        }
        // Each host's designs under its name (not drawn: NavDesigns shows This Mac's alone).
        for host in model.hosts {
            items.append(.hostLabel(host.id, host.name, first: items.isEmpty))
            items += host.rows.enumerated().map { .hostCards(host.id, $1, first: $0 == 0) }
            if !host.systems.isEmpty || host.projects != nil {
                items.append(.systemsLabel(host: host.id, projects: host.projects, first: false))
                items += host.systemRows.enumerated().map { .hostSystems($1, first: $0 == 0) }
            }
        }
        items.append(.systemsLabel(host: nil, projects: model.projects, first: items.isEmpty))
        items += model.systemRows.enumerated().map { .systems($1, first: $0 == 0) }
        return items
    }
}

/// "Design systems" and, at its right, "Build one from a repo": the one project at once, a menu of
/// them with more, and nothing to read without one. A host that doesn't build for other devices
/// (`projects` nil) draws none.
struct DesignSystemsLabel: View, Equatable {
    let projects: [DesignsPageModel.Project]?
    let build: (SpaceID) -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool { a.projects == b.projects }

    var body: some View {
        SHDesignsSection("Design systems") { link }
    }

    @ViewBuilder private var link: some View {
        if let projects {
            if projects.count == 1, let project = projects.first {
                Button { build(project.id) } label: { SHDesignsSectionLink("Build one from a repo") }
                    .buttonStyle(.plain)
                    .help("Build a design system from \(project.name)")
            } else if projects.isEmpty {
                SHDesignsSectionLink("Build one from a repo", enabled: false)
                    .help("Add a space to build a design system from it")
            } else {
                Menu {
                    ForEach(projects) { project in
                        Button(project.name) { build(project.id) }
                    }
                } label: { SHDesignsSectionLink("Build one from a repo") }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .help("Build a design system from a space")
            }
        }
    }
}

/// A row of up to three design system cards, redrawn only when one of its cards changes.
struct DesignSystemCardRow: View, Equatable {
    let systems: [DesignsPageModel.System]
    let open: (DesignSystemTarget) -> Void
    var menu: (DesignMenuAction, DesignSystemTarget) -> Void = { _, _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.systems == b.systems }

    var body: some View {
        HStack(alignment: .top, spacing: SHDesignsHomeMetrics.gap) {
            ForEach(systems) { system in
                let colors = system.swatches.map { Color(light: $0.light, dark: $0.dark) }
                Group {
                    if let items = system.menu {
                        SHDesignSystemCard(name: system.name, source: system.source, count: system.count, colors: colors,
                                           action: { open(system.id) }) {
                            DesignMenuItems(menu: items) { menu($0, system.id) }
                        }
                    } else {
                        SHDesignSystemCard(name: system.name, source: system.source, count: system.count, colors: colors,
                                           dashed: system.dashed)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(0..<max(0, DesignsPageModel.systemColumns - systems.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
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
    var visibility: (DesignID, Bool) -> Void = { _, _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool { a.slots == b.slots }

    var body: some View {
        HStack(alignment: .top, spacing: SHDesignsHomeMetrics.gap) {
            ForEach(slots) { slot in
                Group {
                    switch slot {
                    case .design(let card):
                        DesignCardView(card: card, open: open, image: thumbnail(card.id), menu: menu)
                            .equatable()
                            .onAppear { visibility(card.id, true) }
                            .onDisappear { visibility(card.id, false) }
                    case .importing(let importing):
                        SHImportingCard(title: importing.shownTitle, done: importing.done, total: importing.total, system: importing.system)
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
        SHDesignCard(name: card.name, system: card.system, detail: card.detail, edited: card.edited, board: card.board,
                     selected: card.selected, action: { open(card.id) }) {
            DesignThumbnailSlot(image: image)
        } menu: {
            DesignMenuItems(menu: card.menu) { menu($0, card.id) }
        }
    }
}
