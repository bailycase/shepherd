import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The New design page (DZStart; Designs' New design, New thread's "Start a design"): "What do
/// you want to design?", the brief in a 720pt composer at the regular size (attach, the model and
/// thinking settings, and Send; no context ring before there is a conversation), and the design
/// system the boards are drawn in. Sending makes the design, starts its agent with the brief on
/// the model and level chosen, and opens its canvas.
///
/// The one card is the design system the boards are drawn in: the one picked from its menu, else
/// the most recently changed system built here, else Shepherd Design. It names the project a system
/// was read from as information; a design belongs to no project. Capture a page and From a
/// screenshot attach an image of a web page or a file to the brief.
struct NewDesignPage: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome
    @State private var composing = false
    @State private var dropTargeted = false
    @State private var picking = false
    @State private var pickingZip = false
    @State private var capturingPage = false
    @State private var pageAddress = ""
    @State private var menu: ChipMenu?
    @State private var picker: ModelPickerState?
    @State private var dismissal = ComposerMenuDismissal()

    private enum ChipMenu: Equatable { case models, settings }

    private var draft: NewDesignState { vm.newDesign }

    var body: some View {
        let _ = SHRenderProbe.tick("newDesign.page")
        VStack(spacing: 0) {
            SHDesignHeader("New design", style: .page, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                           sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar),
                           designs: { vm.openDestination(.designs) })
            VStack(spacing: AppLayout.newDesignGap) {
                VStack(spacing: AppLayout.newDesignSubtitleSpacing) {
                    Text("What do you want to design?")
                        .font(.shSans(AppLayout.newThreadHeadingSize, .semibold))
                        .tracking(AppLayout.newThreadHeadingTracking)
                        .foregroundStyle(Color.sh.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Describe the page or flow. The design agent draws it as HTML boards in your design system, "
                         + "and you refine it on the canvas.")
                        .font(.sh(.body))
                        .foregroundStyle(Color.sh.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppLayout.newDesignSubtitleWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: SH.Space.m) {
                    composer
                        .zIndex(1)
                    if let notice = draft.notice {
                        Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                            .shTransition(.content)
                    }
                }
                .frame(maxWidth: AppLayout.newDesignComposerWidth)
                .zIndex(1)
                startingPoints
                    .frame(maxWidth: AppLayout.newDesignComposerWidth)
            }
            .padding(.horizontal, AppLayout.newThreadSidePadding)
            .padding(.bottom, AppLayout.newDesignBottomExtra)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if menu != nil { menu = nil } }
        }
        .background(Color.sh.bgWindow)
        .shAnimation(.content, value: draft.notice)
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .onChange(of: menu != nil, initial: true) { _, open in
            let menu = $menu
            dismissal.dismiss = { menu.wrappedValue = nil }
            dismissal.watch(open)
        }
        .onDisappear { dismissal.watch(false) }
        .task { await vm.loadDesignSystems() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image, .pdf], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            draft.attach(urls: urls)
        }
        // A host imports a ZIP (a folder would need zipping here first).
        .fileImporter(isPresented: $pickingZip, allowedContentTypes: [.zip]) { result in
            guard case .success(let url) = result else { return }
            draft.importOnHost(url, vm: vm)
        }
    }

    // MARK: Composer

    /// The composer's card, drawn focused: the standard composer's row at its regular size.
    private var composer: some View {
        let blocker = draft.blocker(vm)
        return SHComposer(isFocused: true) {
            ForEach(draft.attachments.items) { attachment in
                SHAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .shTransition(.list, edge: .leading)
            }
        } field: {
            ComposerTextField(text: Binding(get: { draft.brief }, set: { draft.brief = $0 }),
                              placeholder: "A checkout funnel dashboard for the product team…",
                              label: "What do you want to design?", focus: $composing, attach: draft.attach)
            .onComposerKey(.return) { press in
                if let result = press.lineBreak() { return result }
                draft.send(vm)
                return .handled
            }
            .onComposerKey(.escape) {
                guard menu != nil else { return .ignored }
                menu = nil
                return .handled
            }
            .modifier(CycleThinkingShortcut(focused: composing && !draft.starting,
                                          current: draft.thinking.clamped(to: draft.thinkingLevels()).rawValue,
                                          levels: draft.thinkingLevels().map(\.rawValue),
                                          choose: { id in if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) } }))
            .frame(minHeight: AppLayout.newDesignFieldMinHeight, alignment: .topLeading)
            .accessibilityLabel("What do you want to design?")
        } controls: {
            Button { picking = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
                .disabled(draft.attachments.isFull)
                .help("Attach a screenshot or file")
                .accessibilityLabel("Attach a screenshot or file")
            if draft.host == nil {
            Button { menu = menu == .settings ? nil : .settings } label: {
                SHModelSettingsLabel(model: NewThreadRules.shortModel(draft.model),
                                     thinking: draft.thinkingLevels().isEmpty ? nil : draft.thinking.clamped(to: draft.thinkingLevels()).title)
            }
            .buttonStyle(.shComposerChip(active: menu == .settings || menu == .models))
            .background { ComposerMenuRegion(dismissal: dismissal) }
            .help(draft.model.isEmpty ? "Model settings: the default" : "Model settings: \(draft.model)")
            }
            Spacer(minLength: SH.Space.m)
            if draft.starting {
                ProgressView().progressViewStyle(.shSpinner(color: Color.sh.textTertiary))
                    .frame(width: SHComposerMetrics.actionSize, height: SHComposerMetrics.actionSize)
                    .accessibilityLabel("Starting")
            } else {
                SHComposerActionButton(.send, enabled: blocker == nil) { draft.send(vm) }
                    .help(blocker ?? "Send (\(KeybindingsStore.shared.sendDisplay))")
            }
        }
        .shAnimation(.list, value: draft.attachments.ids)
        .shAnimation(.content, value: draft.starting)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            draft.attach(providers)
            return true
        }
        .overlay(alignment: .bottomLeading) { menus }
    }

    // MARK: Menus

    /// The open menu, under the card as on New thread: its top-leading corner 8pt below the
    /// card's bottom-leading one, over the cards beneath.
    private var menus: some View {
        ZStack(alignment: .topLeading) {
            switch menu {
            case .models:
                if let picker {
                    ModelPicker(state: picker, maxHeight: SHComposerMetrics.modelPickerMaxHeight) { id in
                        menu = nil
                        composing = true
                        RecentModels.record(id, thread: nil)
                        draft.setModel(id)
                    } close: { menu = nil; composing = true }
                    .shTransition(.overlay, anchor: .topLeading)
                }
            case .settings:
                let levels = draft.thinkingLevels()
                SHModelSettings(models: ModelCatalog.settingsModels(catalog: draft.catalog, current: draft.model, recent: RecentModels.load().map(\.id)),
                                searchModels: draft.catalog?.settingsSearchModels ?? [],
                                thinking: NativeThinkingLevel.levels(levels.map(\.rawValue)).map {
                                    SHThinkingOption(id: $0.id, title: $0.title, note: $0.note)
                                }, currentThinking: draft.thinking.clamped(to: levels).rawValue, speeds: [], currentSpeed: "standard",
                                chooseModel: { model in
                                    RecentModels.record(model.id, thread: nil)
                                    draft.setModel(model.id)
                                    menu = nil
                                    composing = true
                                }, chooseThinking: { id in
                                    if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) }
                                }, chooseSpeed: { _ in }, allModels: openModels, close: { menu = nil; composing = true })
                    .shTransition(.overlay, anchor: .topLeading)
            case nil:
                EmptyView()
            }
        }
        .fixedSize()
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .shAnimation(.overlay, value: menu)
    }

    private func openModels() {
        guard menu != .models else { menu = nil; return }
        picker = ModelPickerState(catalog: draft.catalog, recent: RecentModels.load().map(\.id),
                                  current: draft.model.isEmpty ? nil : draft.model)
        menu = .models
    }

    // MARK: Starting points

    /// "DESIGN SYSTEM & STARTING POINT", three to a row: the design system the design is drawn
    /// in, chosen; Capture a page and From a screenshot (DZStartPlanned), which attach an image of
    /// the page or file to the brief; then Import a project (ImportNewDesign) and where it is made.
    /// The system's menu picks another system; the import opens the picker for a Claude Design ZIP
    /// or folder.
    private var startingPoints: some View {
        let gap = AppLayout.newDesignCardsGap
        return VStack(alignment: .leading, spacing: AppLayout.newDesignCardsLabelGap) {
            Text("Design system & starting point").shSectionLabel()
                .accessibilityAddTraits(.isHeader)
            Grid(horizontalSpacing: gap, verticalSpacing: gap) {
                GridRow {
                    systemCard
                    captureCard
                    screenshotCard
                }
                GridRow {
                    Button {
                        if draft.host == nil { vm.chooseDesignProject() } else { pickingZip = true }
                    } label: {
                        SHDesignStartCard(symbol: "square.and.arrow.down", title: "Import a project", line: "from Claude Design",
                                          note: draft.host == nil ? "a ZIP or folder you exported" : "a ZIP you exported, sent to the host",
                                          chosen: false)
                    }
                    .disabled(draft.host.flatMap(vm.newDesignHost).map { !$0.supportsDesignCapability(RemoteProtocol.designImportCapability) } ?? false)
                    .buttonStyle(.plain)
                    .help("Import a Claude Design project as a new design (\(KeybindingsStore.shared.display(.importDesign)))")
                    if !vm.newDesignHosts.isEmpty {
                        hostCard
                    } else {
                        Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                    }
                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                }
            }
            // The cards' own height: a menu's label would otherwise ask for more.
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Images go only to a design made on This Mac, so the image starting points wait for it.
    private var imagesHelp: String? {
        draft.host == nil ? nil : "Images go only to a design made on This Mac for now."
    }

    /// Capture a page: an address, then the page drawn off screen and attached to the brief.
    private var captureCard: some View {
        Button { capturingPage = true } label: {
            SHDesignStartCard(symbol: "link", title: "Capture a page", line: "paste a URL to start from",
                              note: draft.capturing.map { "capturing \($0)…" } ?? "staging or production", chosen: false)
        }
        .buttonStyle(.plain)
        .disabled(draft.host != nil || draft.capturing != nil)
        .help(imagesHelp ?? "Start from a web page: Shepherd captures it and adds it to the brief")
        .popover(isPresented: $capturingPage, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text("Capture a page").font(.sh(.body, weight: .semibold)).foregroundStyle(Color.sh.textPrimary)
                TextField("Address", text: $pageAddress, prompt: Text("https://staging.acme.dev"))
                    .textFieldStyle(.sh(mono: true))
                    .onSubmit(capturePage)
                    .accessibilityLabel("Page address")
                HStack {
                    Spacer()
                    Button("Cancel") { capturingPage = false }
                        .buttonStyle(.sh(.ghost, size: .s))
                    Button("Capture", action: capturePage)
                        .buttonStyle(.sh(.primary, size: .s))
                        .disabled(PageCapture.address(pageAddress) == nil)
                }
            }
            .padding(SH.Space.l)
            .frame(width: AppLayout.newDesignCapturePopoverWidth)
            .background(Color.sh.bgRaised)
        }
    }

    private func capturePage() {
        guard PageCapture.address(pageAddress) != nil else { return }
        capturingPage = false
        draft.capture(pageAddress)
        pageAddress = ""
        composing = true
    }

    /// From a screenshot: an image or a PDF picked, attached to the brief (a drop on the
    /// composer does the same).
    private var screenshotCard: some View {
        Button { picking = true } label: {
            SHDesignStartCard(symbol: "photo", title: "From a screenshot", line: "drop an image or a file",
                              note: "PNG, PDF, Figma export", chosen: false)
        }
        .buttonStyle(.plain)
        .disabled(draft.host != nil || draft.attachments.isFull)
        .help(imagesHelp ?? "Start from an image or a PDF")
        .onDrop(of: [.image, .fileURL], isTargeted: nil) { providers in
            draft.attach(providers)
            return true
        }
    }

    /// Where the design is made: This Mac, or a connected host that serves designs (its own
    /// systems, model and level; the brief alone goes).
    private var hostCard: some View {
        let host = draft.host.flatMap(vm.newDesignHost)
        let card = SHDesignStartCard(symbol: host == nil ? "laptopcomputer" : "server.rack", title: host?.config.name ?? "This Mac",
                                     line: "made on", note: host == nil ? "or on a connected host" : "drawn in its systems, on its model",
                                     chosen: host != nil)
        return Menu {
            Section("Make it on") {
                Button("This Mac") { draft.choose(host: nil) }
                ForEach(vm.newDesignHosts, id: \.id) { connection in
                    Button(connection.config.name) {
                        draft.choose(host: connection.id)
                        if connection.designs.listing == nil { Task { await connection.designs.refresh() } }
                    }
                }
            }
        } label: { card }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .frame(maxWidth: .infinity)
            .help("Make it on This Mac or on a connected host")
    }

    @ViewBuilder private var systemCard: some View {
        let systems = draft.systems(vm)
        let words = NewDesignState.card(system: draft.chosenSystem(in: systems), spaces: vm.state.spaces)
        let card = SHDesignStartCard(symbol: "pencil.tip", title: words.title, line: words.line, note: words.note, chosen: true)
        if systems.count > 1 {
            Menu {
                Section("Design systems") {
                    ForEach(systems, id: \.namespace) { option in
                        Button(option.info.title) { draft.choose(system: option.namespace) }
                    }
                }
            } label: { card }
                .menuStyle(.button)
                .buttonStyle(.plain)
                .menuIndicator(.hidden)
                .frame(maxWidth: .infinity)
                .help("Draw it in another design system")
        } else {
            card
        }
    }
}
