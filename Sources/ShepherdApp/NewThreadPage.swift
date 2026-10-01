import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The New thread page (NavNewThread; ⌘N or the first destination): "What should the agent work
/// on?", the composer with attach, the workplace chip (project · host, with the worktree option
/// in its menu), the shared model, thinking and speed chips and Send, and the Continue card for the most recent
/// running thread, and "Start a design" while the Design tool is on. Sending creates the agent
/// with the prompt and its images as its opening message and opens its thread. The mission card
/// waits on Missions, so it is not shown.
struct NewThreadPage: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome
    @FocusState private var composing: Bool
    @State private var menu: Menu?
    @State private var picker: ModelPickerState?
    @State private var dropTargeted = false
    @State private var picking = false
    @State private var dismissal = ComposerMenuDismissal()

    private enum Menu: Equatable { case place, models, settings }

    private var draft: NewThreadState { vm.newThread }

    var body: some View {
        let _ = NWRenderProbe.tick("newThread.page")
        VStack(spacing: 0) {
            DestinationPageHeader(title: "New thread", chrome: chrome)
            VStack(spacing: AppLayout.newThreadGap) {
                Text("What should the agent work on?")
                    .font(.nwSans(AppLayout.newThreadHeadingSize, .semibold))
                    .tracking(AppLayout.newThreadHeadingTracking)
                    .foregroundStyle(Color.nw.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                composer
                    .frame(maxWidth: AppLayout.newThreadComposerWidth)
                    .zIndex(1)
                if let notice = draft.notice(vm) {
                    Text(notice).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                        .frame(maxWidth: AppLayout.newThreadComposerWidth, alignment: .leading)
                        .nwTransition(.content)
                }
                ContinueCards(card: vm.continueCard, open: { vm.selectSidebarRow($0) },
                              design: vm.designToolEnabled ? { vm.openNewDesign() } : nil)
                    .frame(maxWidth: AppLayout.newThreadComposerWidth)
                    .padding(.top, AppLayout.newThreadCardsTop)
            }
            .padding(.horizontal, AppLayout.newThreadSidePadding)
            .padding(.bottom, AppLayout.newThreadBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture { if menu != nil { menu = nil } }
        }
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: draft.notice(vm))
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .onChange(of: menu) { _, open in
            let menu = $menu
            dismissal.dismiss = { menu.wrappedValue = nil }
            dismissal.watch(open != nil)
        }
        .onDisappear { dismissal.watch(false) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            draft.attach(urls: urls)
        }
    }

    // MARK: Composer

    private var composer: some View {
        NWComposer(isFocused: composing || menu != nil || dropTargeted) {
            ForEach(draft.attachments.items) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            TextField(text: Binding(get: { draft.prompt }, set: { draft.prompt = $0 }),
                      prompt: Text("Describe the task…").foregroundStyle(Color.nw.textTertiary),
                      axis: .vertical) {
                Text("What should the agent work on?")
            }
            .lineLimit(1...NWComposerMetrics.fieldMaxLines)
            .textFieldStyle(.plain)
            .font(Font.nw(.body))
            .foregroundStyle(Color.nw.textPrimary)
            .autocorrectionDisabled()
            .tint(Color.nw.lantern)
            .focused($composing)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { return .ignored }
                draft.send(vm)
                return .handled
            }
            .onKeyPress(.escape) {
                guard menu != nil else { return .ignored }
                menu = nil
                return .handled
            }
            .onPasteCommand(of: [.image, .fileURL]) { draft.attach($0) }
            .accessibilityLabel("What should the agent work on?")
        } controls: {
            controls
        }
        .nwAnimation(.list, value: draft.attachments.ids)
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            draft.attach(providers)
            return true
        }
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .overlay(alignment: .bottomLeading) { menus }
    }

    private var controls: some View {
        ComposerControlsMinimum {
            HStack(spacing: NW.Space.xxs) {
                ViewThatFits(in: .horizontal) {
                    controlChips(short: false)
                    controlChips(short: true)
                }
                .nwAnimation(.content, value: [draft.model, draft.thinking.rawValue, draft.serviceTier.rawValue])
                if draft.starting {
                    ProgressView().progressViewStyle(.nwSpinner(color: Color.nw.textTertiary))
                        .frame(width: NWComposerMetrics.actionSize, height: NWComposerMetrics.actionSize)
                        .accessibilityLabel("Starting")
                } else {
                    NWComposerActionButton(.send, enabled: draft.blocker(vm) == nil) { draft.send(vm) }
                        .help(draft.blocker(vm) ?? "Send (\(KeybindingsStore.shared.sendDisplay))")
                }
            }
            .nwAnimation(.content, value: draft.starting)
        }
    }

    private func controlChips(short: Bool) -> some View {
        let chip = NewThreadPlaces.chip(NewThreadState.hosts(vm), chosen: draft.place)
        let levels = draft.thinkingLevels(vm)
        let tiers = draft.serviceTiers(vm)
        return HStack(spacing: NW.Space.xxs) {
            Button { picking = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(.nwIcon(size: NWComposerMetrics.chipHeight))
                .disabled(draft.attachments.isFull)
                .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                .accessibilityLabel("Attach file")
            let summary = ModelSettingsSummary(model: draft.model, thinking: draft.thinkingLevel(vm).rawValue, thinkingOffered: !levels.isEmpty,
                                               speed: draft.serviceTier, speedOffered: tiers.count > 1, shortenedName: short)
            Button { toggle(.settings) } label: {
                NWModelSettingsLabel(model: summary.name, thinking: summary.thinking, fast: summary.fast)
            }
            .buttonStyle(.nwComposerChip(active: menu == .settings || menu == .models))
            .help("Model settings: \(draft.model)")
            .accessibilityLabel("Model settings: \(draft.model.isEmpty ? "default model" : draft.model)")
            .accessibilityValue(summary.value)
            Spacer(minLength: NW.Space.m)
            Button { toggle(.place) } label: { NWPlaceChipLabel(project: chip.project, host: chip.host) }
                .buttonStyle(.nwComposerChip(active: menu == .place))
                .help(draft.worktree ? "In a new worktree of \(chip.project) on \(chip.host)" : "\(chip.project) on \(chip.host)")
        }
    }

    // MARK: Menus

    /// The open menu, under the card: its top-leading corner 8pt below the card's bottom-leading
    /// one, over the cards beneath.
    private var menus: some View {
        ZStack(alignment: .topLeading) {
            switch menu {
            case .place:
                placeMenu.nwTransition(.overlay, anchor: .topLeading)
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
                let levels = draft.thinkingLevels(vm)
                let tiers = draft.serviceTiers(vm)
                NWModelSettings(models: ModelCatalog.settingsModels(catalog: draft.catalog, current: draft.model, recent: RecentModels.load().map(\.id),
                                                                    currentOffersFast: tiers.count > 1),
                                thinking: NativeThinkingLevel.levels(levels.map(\.rawValue)).map {
                                    NWThinkingOption(id: $0.id, title: $0.title, note: $0.note)
                                }, currentThinking: draft.thinkingLevel(vm).rawValue,
                                speeds: tiers.count > 1 ? tiers.map {
                                    NWSpeedOption(id: $0.rawValue, title: $0.title, detail: $0.summary, boosted: $0 != .standard)
                                } : [], currentSpeed: draft.serviceTier.rawValue,
                                chooseModel: { model in
                                    RecentModels.record(model.id, thread: nil)
                                    draft.setModel(model.id)
                                    menu = nil
                                    composing = true
                                }, chooseThinking: { id in
                                    if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) }
                                }, chooseSpeed: { id in
                                    if let tier = ServiceTier(rawValue: id) { draft.setServiceTier(tier) }
                                }, allModels: openModels, close: { menu = nil; composing = true })
                    .nwTransition(.overlay, anchor: .topLeading)
            case nil:
                EmptyView()
            }
        }
        .fixedSize()
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .nwAnimation(.overlay, value: menu)
    }

    private var placeMenu: some View {
        let hosts = NewThreadState.hosts(vm)
        let offers = draft.offersWorktree(vm)
        return NWPlaceMenu(
            sections: NewThreadPlaces.sections(hosts, chosen: draft.place),
            worktree: offers ? NWPlaceWorktree(isOn: draft.worktree, caption: NewThreadRules.worktreeCaption(base: "")) : nil,
            onChoose: { option in
                if let place = NewThreadPlaces.place(option) { draft.choose(host: place.host, space: place.space, vm: vm) }
                menu = nil
                composing = true
            },
            onAdd: { section in
                menu = nil
                if let host = NewThreadPlaces.host(of: section) { vm.remoteSpacePickerHostID = host } else { vm.addSpaceFromPanel() }
            },
            onWorktree: { draft.worktree = $0 },
            onClose: { menu = nil; composing = true }
        ) { option in
            ProjectMenu(vm: vm, place: NewThreadPlaces.place(option))
        }
    }

    private func toggle(_ next: Menu) {
        menu = menu == next ? nil : next
    }

    private func openModels() {
        guard menu != .models else { menu = nil; return }
        picker = ModelPickerState(catalog: draft.catalog, recent: RecentModels.load().map(\.id),
                                  current: draft.model.isEmpty ? nil : draft.model)
        menu = .models
        Task {
            await draft.refreshModels(vm)
            if let catalog = draft.catalog { picker?.update(catalog) }
        }
    }
}

/// A project row's context menu in the workplace menu: what the sidebar's space rows offered.
private struct ProjectMenu: View {
    var vm: ShepherdViewModel
    let place: NewThreadPlace?

    var body: some View {
        if let place, place.host == nil, let space = vm.state.spaces.first(where: { $0.id == place.space }) {
            Button("Rename…") { vm.spaceRenameTarget = space.id }
            if vm.spaceIsRepo(space) {
                Button("New Worktree…") { vm.worktreeSheetTarget = space.id }
                Button("Import Existing Worktree…") { vm.importExistingWorktreeFromPanel(in: space.id) }
            }
            Divider()
            Button("Remove Space…", role: .destructive) { vm.spaceDeleteTarget = space.id }
        } else if let place, let host = place.host {
            Button("New Agent with Options…") { vm.showNewAgentSheetForRemote(hostID: host, spaceID: place.space) }
        }
    }
}

// MARK: Continue

/// The Continue card's facts: the most recent running thread.
struct ContinueCard: Equatable {
    let id: SidebarRowID
    let title: String
    /// When it started running; nil when unknown.
    let since: Date?
}

extension ShepherdViewModel {
    /// The most recent running thread (automation runs and offline hosts' threads aside, pinned or
    /// not), for the New thread page.
    var continueCard: ContinueCard? {
        for row in sidebarLists.activity where row.leading == .dot(.running) && !row.offline {
            switch row.id {
            case .local(let id):
                return ContinueCard(id: row.id, title: row.title, since: statusSince[id])
            case .remote(let ref):
                let since = remoteAgent(ref)?.lastActiveAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                return ContinueCard(id: row.id, title: row.title, since: since)
            case .design:
                // A design's row wears the nib, never a running dot.
                continue
            }
        }
        return nil
    }
}

/// The suggestion cards under the composer, each a third of the row: Continue, and "Start a
/// design" last while the Design tool is on (Missions is not built).
private struct ContinueCards: View, Equatable {
    let card: ContinueCard?
    let open: (SidebarRowID) -> Void
    /// New design; nil while the Design tool is off.
    let design: (() -> Void)?

    static func == (a: ContinueCards, b: ContinueCards) -> Bool { a.card == b.card && (a.design == nil) == (b.design == nil) }

    var body: some View {
        GeometryReader { proxy in
            let width = (proxy.size.width - AppLayout.newThreadCardsGap * (AppLayout.newThreadCardsPerRow - 1))
                / AppLayout.newThreadCardsPerRow
            HStack(spacing: AppLayout.newThreadCardsGap) {
                if let card {
                    SuggestionCard(card: card) { open(card.id) }
                        .frame(width: max(0, width))
                        .nwTransition(.content)
                }
                if let design {
                    DesignSuggestionCard(action: design)
                        .frame(width: max(0, width))
                        .nwTransition(.content)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: SuggestionCard.height)
        .nwAnimation(.content, value: card?.id)
    }
}

/// "Start a design" (NavNewThread): "Need a mockup first?" beside a 12pt nib, "Start a design",
/// and "HTML boards on a canvas".
private struct DesignSuggestionCard: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppLayout.newThreadCardSpacing) {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "pencil.tip").font(.nwSans(12))
                        .foregroundStyle(Color.nw.textSecondary)
                    Text("Need a mockup first?").font(.nwSans(11.5)).foregroundStyle(Color.nw.textTertiary)
                }
                Text("Start a design").font(.nwSans(13, .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(1)
                Text("HTML boards on a canvas").font(.nwSans(11)).foregroundStyle(Color.nw.textTertiary).lineLimit(1)
            }
            .padding(.vertical, NW.Space.l)
            .padding(.horizontal, AppLayout.newThreadCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel("Start a design, HTML boards on a canvas")
    }
}

/// One suggestion card (NavNewThread): a kicker with its glyph, a title, and a detail; radius 8,
/// a `lineSubtle` border, hover `bgHover`.
private struct SuggestionCard: View {
    static let height = AppLayout.newThreadCardHeight

    let card: ContinueCard
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: AppLayout.newThreadCardSpacing) {
                HStack(spacing: NW.Space.m) {
                    Image(systemName: "bubble.left").font(.system(size: AppLayout.chipSymbol, weight: .regular)).foregroundStyle(Color.nw.textSecondary)
                    Text("Continue").font(.nwSans(11.5)).foregroundStyle(Color.nw.textTertiary)
                }
                Text(card.title).font(.nwSans(13, .medium)).foregroundStyle(Color.nw.textPrimary).lineLimit(1).truncationMode(.tail)
                Group {
                    if let since = card.since {
                        TimelineView(NWElapsedSchedule(start: since)) { context in
                            Text("running · \(NWDuration.text(context.date.timeIntervalSince(since)))")
                        }
                    } else {
                        Text("running")
                    }
                }
                .font(.nwSans(11))
                .foregroundStyle(Color.nw.textTertiary)
            }
            .padding(.vertical, NW.Space.l)
            .padding(.horizontal, AppLayout.newThreadCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.nw.bgHover : .clear, in: RoundedRectangle(cornerRadius: NW.Radius.m))
            .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: NW.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityLabel("Continue \(card.title), running")
    }
}
