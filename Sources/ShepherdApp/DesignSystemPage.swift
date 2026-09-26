import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// A design system's page (DZSystem): the header with its sync state and chip, the section list,
// and the system's colors, type, spacing and radii, components (live specimens drawn by the
// board renderer) and the designs drawn in it. A system built from a repository shows it as its
// build's layout, beside the build agent's chat (decision 12: Chat only); any other system shows
// it as the Design systems page.

/// The Design systems page in the main column: a system without an agent of its own (Night
/// Watch, or one a canvas's agent wrote), with no chat beside it.
struct DesignSystemDestination: View {
    var vm: ShepherdViewModel
    var chrome = PageHeaderChrome()

    var body: some View {
        let _ = NWRenderProbe.tick("page.designSystem")
        let namespace = vm.designSystemShown
        let model = namespace.map { vm.designSystemPage(.system($0)) } ?? DesignSystemPageModel()
        VStack(spacing: 0) {
            DesignSystemHeader(model: model, toolbar: false, leadingInset: chrome.leadingInset, showSidebar: chrome.showSidebar,
                               designs: { vm.openDestination(.designs) })
                .equatable()
            DesignSystemContent(model: model, specimens: vm.designRendering.specimens,
                                resync: { vm.resyncDesignSystem($0) }, openDesign: { vm.openDesign($0) })
                .equatable()
        }
        .background(Color.nw.bgWindow)
        .task { await vm.loadDesignSystems() }
        .task(id: "\(namespace ?? "")/\(model.revision)") {
            if let namespace { await vm.loadDesignSpecimens(namespace) }
        }
    }
}

/// A system build's layout (DZSystem): the system its agent is building beside the agent's
/// chat, a 420pt pane with the Chat tab alone. Mounted and hidden like every agent's layout.
struct DesignSystemLayoutView: View {
    var vm: ShepherdViewModel
    let model: AgentLayoutModel
    let designID: DesignID
    let thread: AgentLayoutModel.Thread

    var body: some View {
        let _ = NWRenderProbe.tick("layout.designSystem")
        HStack(spacing: 0) {
            DesignSystemBuildPane(vm: vm, designID: designID)
            DesignSystemChatPane(vm: vm, model: model, thread: thread)
                .frame(width: AppLayout.designChatWidth)
        }
    }
}

/// The system a build's agent is building, derived in its own view so a change elsewhere in the
/// workspace reruns only this.
private struct DesignSystemBuildPane: View {
    var vm: ShepherdViewModel
    let designID: DesignID

    var body: some View {
        let model = vm.designSystemPage(.build(designID))
        DesignSystemContent(model: model, specimens: vm.designRendering.specimens,
                            resync: { vm.resyncDesignSystem($0) }, openDesign: { vm.openDesign($0) })
            .equatable()
            .task { if !vm.designSystems.loaded { await vm.loadDesignSystems() } }
            .task(id: "\(model.namespace ?? "")/\(model.revision)") {
                if let namespace = model.namespace { await vm.loadDesignSpecimens(namespace) }
            }
    }
}

/// The build's chat: the Chat tab over the agent's thread, whose composer has attach and Send
/// only.
struct DesignSystemChatPane: View {
    var vm: ShepherdViewModel
    let model: AgentLayoutModel
    let thread: AgentLayoutModel.Thread

    var body: some View {
        VStack(spacing: 0) {
            NWDesignPaneTabs([NWDesignPaneTabs.Tab(id: "chat", title: "Chat")], selection: "chat")
            if let pane = model.tab.layout.leaf(withID: thread.paneID) {
                let agentID = thread.agentID
                AgentThreadPane(
                    session: vm.sessions.session(for: pane, in: model.tab),
                    store: vm.threadStores.store(for: agentID),
                    active: model.isVisible,
                    isFocused: model.focusedPaneID == thread.paneID,
                    request: { [vm] in try await vm.server.nativeThread(agentID: agentID, request: $0) },
                    preview: PiSessionFile.previewLoader(sessionID: thread.piSessionID, cwd: pane.cwd, sessionsRoot: vm.server.pi.sessionsRoot),
                    commandKey: ThreadCommandCenter.key(local: agentID),
                    agentName: thread.agentName,
                    workingDirectory: pane.cwd,
                    restartPi: { [vm] in vm.retryAgentStart(agentID, newConversation: $0) },
                    designChat: true)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical) }
        .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = thread.paneID })
    }
}

/// A system's header (DZSystem): "Design systems / acme-web" with its sync state, and its chip.
/// A page's header on the Design systems page; the toolbar over a build.
struct DesignSystemHeader: View, Equatable {
    let model: DesignSystemPageModel
    let toolbar: Bool
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
    let designs: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.model.title == b.model.title && a.model.status == b.model.status && a.model.namespace == b.model.namespace
            && a.model.chip == b.model.chip && a.toolbar == b.toolbar && a.leadingInset == b.leadingInset
            && (a.showSidebar == nil) == (b.showSidebar == nil)
    }

    var body: some View {
        NWDesignHeader(model.title, style: toolbar ? .toolbar : .page, section: "Design systems", status: model.status,
                       leadingInset: leadingInset, sidebar: showSidebar,
                       sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar), designs: designs) {
            if let namespace = model.namespace {
                NWDesignSystemChip(namespace, colors: model.chip.map { Color(light: $0.light, dark: $0.dark) })
            }
        }
    }
}

// MARK: Content

/// The section list and the system's sections (DZSystem): one lazy stack, one view per element
/// (a heading, a section's label, a row of swatches or specimens, a type style, a step, a
/// design), so only what is on screen is built. A section in the list scrolls to its label.
struct DesignSystemContent: View, Equatable {
    let model: DesignSystemPageModel
    let specimens: DesignSpecimens
    let resync: (String) -> Void
    let openDesign: (DesignID) -> Void
    @State private var section = DesignSystemPageModel.Section.colors.rawValue

    nonisolated static func == (a: Self, b: Self) -> Bool { a.model == b.model }

    var body: some View {
        let _ = NWRenderProbe.tick("design.systemContent")
        ScrollViewReader { proxy in
            HStack(spacing: 0) {
                if !model.sections.isEmpty {
                    NWSectionRail(model.sections, selection: section) { id in
                        section = id
                        proxy.scrollTo(id, anchor: .top)
                    }
                }
                ScrollView(.vertical) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Self.items(model)) { item in
                            VStack(alignment: .leading, spacing: 0) { row(item) }
                                .id(item.id)
                        }
                    }
                    .padding(.vertical, AppLayout.designSystemPaddingVertical)
                    .padding(.horizontal, AppLayout.designSystemPaddingHorizontal)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollIndicators(.hidden)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.nw.bgWindow)
    }

    /// The page's elements, in order.
    enum Item: Identifiable {
        case heading
        case label(DesignSystemPageModel.Section)
        case colors([DesignSystemPageModel.Swatch], first: Bool)
        case type(DesignSystemPageModel.TypeRow)
        case step(DesignSystemPageModel.Step)
        case components([DesignSystemPageModel.Component], first: Bool)
        case board(DesignSystemPageModel.BoardsRow)

        var id: String {
            switch self {
            case .heading: "heading"
            case .label(let section): section.rawValue
            case .colors(let row, _): "colors.\(row.first?.id ?? "")"
            case .type(let style): "type.\(style.id)"
            case .step(let step): "step.\(step.id)"
            case .components(let row, _): "components.\(row.first?.id ?? 0)"
            case .board(let row): "board.\(row.id.rawValue)"
            }
        }
    }

    static func items(_ model: DesignSystemPageModel) -> [Item] {
        var items: [Item] = [.heading]
        guard !model.sections.isEmpty else { return items }
        items.append(.label(.colors))
        items += stride(from: 0, to: model.colors.count, by: AppLayout.designSystemColorColumns).map { start in
            .colors(Array(model.colors[start..<min(start + AppLayout.designSystemColorColumns, model.colors.count)]), first: start == 0)
        }
        items.append(.label(.type))
        items += model.type.map(Item.type)
        items.append(.label(.steps))
        items += model.steps.map(Item.step)
        items.append(.label(.components))
        items += stride(from: 0, to: model.components.count, by: AppLayout.designSystemComponentColumns).map { start in
            .components(Array(model.components[start..<min(start + AppLayout.designSystemComponentColumns, model.components.count)]),
                        first: start == 0)
        }
        items.append(.label(.boards))
        items += model.boards.map(Item.board)
        return items
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        switch item {
        case .heading:
            heading
        case .label(let section):
            Text(section.title)
                .nwSectionLabel()
                .accessibilityAddTraits(.isHeader)
                .padding(.top, AppLayout.designSystemSectionSpacing)
                .padding(.bottom, NW.Space.s)
        case .colors(let row, let first):
            DesignSystemSwatchRow(swatches: row)
                .equatable()
                .padding(.top, first ? 0 : AppLayout.designSystemColorGap)
        case .type(let style):
            NWTypeSpecimen(style.name, spec: style.spec) {
                Text(style.sample).font(Self.font(style))
            }
        case .step(let step):
            NWTypeSpecimen(step.name, spec: step.detail) { EmptyView() }
        case .components(let row, let first):
            DesignSystemSpecimenRow(namespace: model.namespace ?? "", components: row, background: model.background,
                                    specimens: specimens)
                .padding(.top, first ? 0 : AppLayout.designSystemComponentGap)
        case .board(let design):
            Button { openDesign(design.id) } label: {
                HStack(spacing: NW.Space.xl) {
                    Text(design.name)
                        .font(.nw(.body))
                        .foregroundStyle(Color.nw.textPrimary)
                        .lineLimit(1)
                    Spacer(minLength: NW.Space.xl)
                    Text(design.detail)
                        .font(.nwMono(NWDesignMetrics.typeSpecSize))
                        .foregroundStyle(Color.nw.textTertiary)
                }
                .padding(.vertical, NW.Space.m)
                .overlay(alignment: .top) { NWHairline() }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open \(design.name)")
        }
    }

    private var heading: some View {
        HStack(alignment: .bottom, spacing: NW.Space.xl) {
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text(model.title)
                    .font(.nwMono(AppLayout.designSystemNameSize, .semibold))
                    .foregroundStyle(Color.nw.textPrimary)
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
                Self.sourceLine(model.source)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: NW.Space.xl)
            if let namespace = model.namespace, !model.builtIn {
                Button("Re-sync", systemImage: "arrow.clockwise") { resync(namespace) }
                    .buttonStyle(.nw(.secondary))
                    .disabled(!model.canResync || model.syncing)
                    .help(model.canResync ? "Read \(namespace)'s stylesheets again from its project"
                          : "Nothing to read again: it names no stylesheets, or its project is gone")
            }
        }
    }

    /// The source line, its paths and names in mono.
    static func sourceLine(_ segments: [DesignSystemPageModel.Segment]) -> Text {
        segments.reduce(Text(verbatim: "")) { line, segment in
            let run = Text(verbatim: segment.text)
                .font(segment.mono ? .nwMono(AppLayout.designSystemSourceSize) : .nwSans(AppLayout.designSystemSourceSize))
            return Text("\(line)\(run)")
        }
    }

    /// A type style's specimen font: the system's face at its size and weight, else the
    /// system's default face.
    static func font(_ style: DesignSystemPageModel.TypeRow) -> Font {
        let size = CGFloat(min(max(style.size, 1), AppLayout.designSystemSpecimenMaxSize))
        let base: Font = style.family.map { Font.custom($0, size: size) } ?? Font.system(size: size)
        return base.weight(weight(style.weight))
    }

    static func weight(_ value: Int?) -> Font.Weight {
        switch value ?? 400 {
        case ..<150: .ultraLight
        case ..<250: .thin
        case ..<350: .light
        case ..<450: .regular
        case ..<550: .medium
        case ..<650: .semibold
        case ..<750: .bold
        case ..<850: .heavy
        default: .black
        }
    }
}

/// A row of token swatches, redrawn only when one of them changes.
struct DesignSystemSwatchRow: View, Equatable {
    let swatches: [DesignSystemPageModel.Swatch]

    var body: some View {
        HStack(alignment: .top, spacing: AppLayout.designSystemColorGap) {
            ForEach(swatches) { swatch in
                NWTokenSwatch(swatch.name, detail: swatch.detail,
                              color: swatch.hex.map { Color(light: $0, dark: $0) } ?? .clear)
                    .frame(maxWidth: .infinity)
            }
            ForEach(0..<(AppLayout.designSystemColorColumns - swatches.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}

/// A row of component specimens: each drawn in the system by the board renderer, on the
/// system's background, once its image lands.
struct DesignSystemSpecimenRow: View {
    let namespace: String
    let components: [DesignSystemPageModel.Component]
    let background: String?
    let specimens: DesignSpecimens

    var body: some View {
        let _ = specimens.version
        let fill = background.map { Color(light: $0, dark: $0) } ?? Color.nw.bgSunken
        HStack(alignment: .top, spacing: AppLayout.designSystemComponentGap) {
            ForEach(components) { component in
                NWComponentSpecimen(component.name, template: component.template, background: fill) {
                    if let image = specimens.image(namespace, component.id) {
                        Image(decorative: image, scale: 1)
                            .resizable()
                            .interpolation(.high)
                            .aspectRatio(contentMode: .fit)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            ForEach(0..<(AppLayout.designSystemComponentColumns - components.count), id: \.self) { _ in
                Color.clear.frame(maxWidth: .infinity, maxHeight: 0)
            }
        }
    }
}
