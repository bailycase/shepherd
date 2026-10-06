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
/// the most recently changed system built here, else Night Watch. It names the project a system
/// was read from as information; a design belongs to no project. The Capture a page and From a
/// screenshot starting points come later.
struct NewDesignPage: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome
    @FocusState private var composing: Bool
    @State private var dropTargeted = false
    @State private var picking = false
    @State private var menu: ChipMenu?
    @State private var picker: ModelPickerState?

    private enum ChipMenu: Equatable { case models, settings }

    private var draft: NewDesignState { vm.newDesign }

    var body: some View {
        let _ = NWRenderProbe.tick("newDesign.page")
        VStack(spacing: 0) {
            NWDesignHeader("New design", style: .page, leadingInset: chrome.leadingInset, sidebar: chrome.showSidebar,
                           sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar),
                           designs: { vm.openDestination(.designs) })
            VStack(spacing: AppLayout.newDesignGap) {
                VStack(spacing: AppLayout.newDesignSubtitleSpacing) {
                    Text("What do you want to design?")
                        .font(.nwSans(AppLayout.newThreadHeadingSize, .semibold))
                        .tracking(AppLayout.newThreadHeadingTracking)
                        .foregroundStyle(Color.nw.textPrimary)
                        .multilineTextAlignment(.center)
                        .accessibilityAddTraits(.isHeader)
                    Text("Describe the page or flow. The design agent draws it as HTML boards in your design system, "
                         + "and you refine it on the canvas.")
                        .font(.nw(.body))
                        .foregroundStyle(Color.nw.textSecondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: AppLayout.newDesignSubtitleWidth)
                        .fixedSize(horizontal: false, vertical: true)
                }
                VStack(alignment: .leading, spacing: NW.Space.m) {
                    composer
                        .zIndex(1)
                    if let notice = draft.notice {
                        Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                            .nwTransition(.content)
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
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: draft.notice)
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .task { await vm.loadDesignSystems() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            draft.attach(urls: urls)
        }
    }

    // MARK: Composer

    /// The composer's card, drawn focused: the standard composer's row at its regular size.
    private var composer: some View {
        let blocker = draft.blocker(vm)
        return NWComposer(isFocused: true) {
            ForEach(draft.attachments.items) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            TextField(text: Binding(get: { draft.brief }, set: { draft.brief = $0 }),
                      prompt: Text("A checkout funnel dashboard for the product team…").foregroundStyle(Color.nw.textTertiary),
                      axis: .vertical) {
                Text("What do you want to design?")
            }
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .foregroundStyle(Color.nw.textPrimary)
            .tint(Color.nw.lantern)
            .focused($composing)
            .modifier(CycleThinkingShortcut(focused: composing && !draft.starting,
                                          current: draft.thinking.clamped(to: draft.thinkingLevels()).rawValue,
                                          levels: draft.thinkingLevels().map(\.rawValue),
                                          choose: { id in if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) } }))
            .frame(minHeight: AppLayout.newDesignFieldMinHeight, alignment: .topLeading)
            .onKeyPress(.return, phases: .down) { press in
                if let result = NWReturnKey.lineBreak(for: press) { return result }
                draft.send(vm)
                return .handled
            }
            .onKeyPress(.escape) {
                guard menu != nil else { return .ignored }
                menu = nil
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { draft.attach($0) }
            .accessibilityLabel("What do you want to design?")
        } controls: {
            Button { picking = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                .disabled(draft.attachments.isFull)
                .help("Attach a screenshot or file")
                .accessibilityLabel("Attach a screenshot or file")
            Button { menu = menu == .settings ? nil : .settings } label: {
                NWModelSettingsLabel(model: NewThreadRules.shortModel(draft.model),
                                     thinking: draft.thinkingLevels().isEmpty ? nil : draft.thinking.clamped(to: draft.thinkingLevels()).title)
            }
            .buttonStyle(.nwComposerChip(active: menu == .settings || menu == .models))
            .help(draft.model.isEmpty ? "Model settings: the default" : "Model settings: \(draft.model)")
            Spacer(minLength: NW.Space.m)
            if draft.starting {
                ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                    .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
                    .accessibilityLabel("Starting")
            } else {
                NWComposerActionButton(.send, enabled: blocker == nil) { draft.send(vm) }
                    .help(blocker ?? "Send (\(KeybindingsStore.shared.sendDisplay))")
            }
        }
        .nwAnimation(.list, value: draft.attachments.ids)
        .nwAnimation(.content, value: draft.starting)
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
                    ModelPicker(state: picker, maxHeight: NWComposerMetrics.modelPickerMaxHeight) { id in
                        menu = nil
                        composing = true
                        RecentModels.record(id, thread: nil)
                        draft.setModel(id)
                    } close: { menu = nil; composing = true }
                    .nwTransition(.overlay, anchor: .topLeading)
                }
            case .settings:
                let levels = draft.thinkingLevels()
                NWModelSettings(models: ModelCatalog.settingsModels(catalog: draft.catalog, current: draft.model, recent: RecentModels.load().map(\.id)),
                                thinking: NativeThinkingLevel.levels(levels.map(\.rawValue)).map {
                                    NWThinkingOption(id: $0.id, title: $0.title, note: $0.note)
                                }, currentThinking: draft.thinking.clamped(to: levels).rawValue, speeds: [], currentSpeed: "standard",
                                chooseModel: { model in
                                    RecentModels.record(model.id, thread: nil)
                                    draft.setModel(model.id)
                                    menu = nil
                                    composing = true
                                }, chooseThinking: { id in
                                    if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) }
                                }, chooseSpeed: { _ in }, allModels: openModels, close: { menu = nil; composing = true })
                    .nwTransition(.overlay, anchor: .topLeading)
            case nil:
                EmptyView()
            }
        }
        .fixedSize()
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .nwAnimation(.overlay, value: menu)
    }

    private func openModels() {
        guard menu != .models else { menu = nil; return }
        picker = ModelPickerState(catalog: draft.catalog, recent: RecentModels.load().map(\.id),
                                  current: draft.model.isEmpty ? nil : draft.model)
        menu = .models
    }

    // MARK: Starting points

    /// "DESIGN SYSTEM & STARTING POINT": the design system the design is drawn in, chosen, and
    /// Import a project (ImportNewDesign), each at a third of the row. The system's menu picks
    /// another system; the import opens the picker for a Claude Design ZIP or folder.
    private var startingPoints: some View {
        VStack(alignment: .leading, spacing: AppLayout.newDesignCardsLabelGap) {
            Text("Design system & starting point").nwSectionLabel()
                .accessibilityAddTraits(.isHeader)
            GeometryReader { proxy in
                let width = (proxy.size.width - AppLayout.newDesignCardsGap * (AppLayout.newDesignCardsPerRow - 1))
                    / AppLayout.newDesignCardsPerRow
                HStack(spacing: AppLayout.newDesignCardsGap) {
                    systemCard
                        .frame(width: max(0, width))
                    Button { vm.chooseDesignProject() } label: {
                        NWDesignStartCard(symbol: "square.and.arrow.down", title: "Import a project", line: "from Claude Design",
                                          note: "a ZIP or folder you exported", chosen: false)
                    }
                    .buttonStyle(.plain)
                    .frame(width: max(0, width))
                    .help("Import a Claude Design project as a new design (\(KeybindingsStore.shared.display(.importDesign)))")
                    Spacer(minLength: 0)
                }
            }
            .frame(height: AppLayout.newDesignCardHeight)
        }
    }

    @ViewBuilder private var systemCard: some View {
        let systems = vm.designSystems.summaries
        let words = NewDesignState.card(system: draft.chosenSystem(in: systems), spaces: vm.state.spaces)
        let card = NWDesignStartCard(symbol: "pencil.tip", title: words.title, line: words.line, note: words.note, chosen: true)
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
                .help("Draw it in another design system")
        } else {
            card
        }
    }
}
