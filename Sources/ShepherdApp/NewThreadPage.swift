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
    /// The @ picker: where it is and what it lists, derived once per change of the prompt (as the
    /// thread composer's is).
    @State private var mentions = MentionPickerState()
    /// Where the field's caret is, for ⌫ at the start of the words (not observed).
    @State private var caret = ComposerCaret()

    private enum Menu: Equatable { case place, models, settings }

    /// `settingsOpen` starts with the model-settings popover open, for the preview renders.
    init(vm: ShepherdViewModel, chrome: PageHeaderChrome, settingsOpen: Bool = false) {
        self.vm = vm
        self.chrome = chrome
        _menu = State(initialValue: settingsOpen ? .settings : nil)
    }

    private var draft: NewThreadState { vm.newThread }

    /// This Mac's designs, for the @ picker and the chips; nil with the Design tool off.
    private var references: DesignReferenceChips? { vm.designToolEnabled ? draft.referenceChips : nil }

    /// The @ picker is up: a mention is being typed. It says "Loading designs…" until the designs
    /// are read, and for a project on another host a note that none can go there.
    private var mentionShown: Bool { mentions.isOpen && references != nil }

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
            .onTapGesture {
                if menu != nil { menu = nil }
                dismissMention()
            }
        }
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: draft.notice(vm))
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .onChange(of: menu != nil || mentionShown, initial: true) { _, open in
            let (menu, mentions, state) = ($menu, $mentions, vm.newThread)
            dismissal.dismiss = {
                if menu.wrappedValue != nil {
                    menu.wrappedValue = nil
                } else {
                    mentions.wrappedValue.dismissed = state.prompt
                    mentions.wrappedValue.close()
                }
            }
            dismissal.watch(open)
        }
        // A pasted reference becomes a chip; a mention opens the @ picker.
        .onChange(of: draft.prompt, initial: true) { old, new in promptChanged(from: old, to: new) }
        .onChange(of: references?.catalog) { _, _ in updateMentions() }
        .onChange(of: references?.catalogStage) { _, _ in updateMentions() }
        .onChange(of: references?.picturesVersion) { _, _ in if mentions.isOpen { updateMentions() } }
        .onChange(of: draft.place) { _, _ in updateMentions() }
        .onChange(of: mentionShown) { _, shown in if shown { menu = nil } }
        .onDisappear { dismissal.watch(false) }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.image], allowsMultipleSelection: true) { result in
            guard case .success(let urls) = result else { return }
            draft.attach(urls: urls)
        }
    }

    // MARK: Composer

    private var composer: some View {
        NWComposer(isFocused: composing || menu != nil || mentionShown || dropTargeted) {
            // Design pieces sit first, above the words (DesignReferenceChip(ref)).
            ForEach(draft.references) { attached in
                ComposerReferenceChip(attached: attached, references: references) { draft.detach(reference: attached.id) }
                    .nwTransition(.list, edge: .leading)
            }
            ForEach(draft.attachments.items) { attachment in
                NWAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .nwTransition(.list, edge: .leading)
            }
        } field: {
            TextField(text: Binding(get: { draft.prompt }, set: { draft.prompt = $0 }), selection: caretBinding,
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
            .modifier(CycleThinkingShortcut(focused: composing && !draft.starting && !draft.loadingDefaults,
                                          current: draft.thinkingLevel(vm).rawValue, levels: draft.thinkingLevels(vm).map(\.rawValue),
                                          choose: { id in if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) } }))
            .onKeyPress(.return, phases: .down) { press in
                if let result = NWReturnKey.lineBreak(for: press) { return result }
                // ↩ over the @ picker chooses its row, and never starts the thread.
                if mentionShown {
                    if let row = mentions.highlightedRow { chooseMention(row) }
                    return .handled
                }
                draft.send(vm)
                return .handled
            }
            .onKeyPress(.tab) {
                guard mentionShown else { return .ignored }
                if let row = mentions.highlightedRow { chooseMention(row) }
                return .handled
            }
            .onKeyPress(.upArrow) {
                guard mentionShown else { return .ignored }
                mentions.move(-1)
                return .handled
            }
            .onKeyPress(.downArrow) {
                guard mentionShown else { return .ignored }
                mentions.move(1)
                return .handled
            }
            // → drills into a design or a board; ← and ⌫ with nothing typed after the breadcrumb go back a level.
            .onKeyPress(.rightArrow) {
                guard mentionShown, let row = mentions.highlightedRow, row.trailing == .drill else { return .ignored }
                chooseMention(row)
                return .handled
            }
            .onKeyPress(.leftArrow) {
                guard mentionShown, mentions.filterIsEmpty, mentions.scope != .designs else { return .ignored }
                mentionBack()
                return .handled
            }
            .onKeyPress(.delete) {
                if mentionShown, mentions.filterIsEmpty, mentions.scope != .designs {
                    mentionBack()
                    return .handled
                }
                // ⌫ with the caret at the start of the words takes the last chip back.
                guard let last = draft.references.last,
                      ComposerCaret.takesBackChip(draft: draft.prompt, selection: caret.selection(in: draft.prompt)) else { return .ignored }
                draft.detach(reference: last.id)
                return .handled
            }
            .onKeyPress(.escape) {
                if mentionShown {
                    dismissMention()
                    return .handled
                }
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
        .nwAnimation(.list, value: draft.references.map(\.id))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            draft.attach(providers)
            return true
        }
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .overlay(alignment: .bottomLeading) { menus }
        .overlay(alignment: .bottomLeading) { mentionMenu }
    }

    /// The field's selection, kept in `caret` without redrawing the page. A selection the prompt has
    /// outgrown (the prompt replaced from outside the field) reads as none.
    private var caretBinding: Binding<TextSelection?> {
        Binding(get: { [caret, draft] in caret.selection(in: draft.prompt) }, set: { [caret] in caret.selection = $0 })
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

    // MARK: Design references

    /// The @ picker, under the card as the page's other menus are: designs, then a design's boards
    /// and a board's elements, or what it says before it has rows.
    private var mentionMenu: some View {
        ZStack(alignment: .topLeading) {
            if mentionShown, menu == nil {
                let content = mentions.content
                NWMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: mentions.highlighted,
                                maxHeight: NWComposerMetrics.modelPickerMaxHeight, choose: { chooseMention($0) }, drill: { chooseMention($0) },
                                back: { mentionBack() }, hover: { mentions.highlighted = $0 }, startDesign: references?.io.startDesign,
                                retry: { references?.startCatalogRead() },
                                appear: { id in
                                    if let item = mentions.content.items[id] { references?.rowAppeared(item) }
                                })
                    .nwTransition(.overlay, anchor: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .nwAnimation(.overlay, value: mentionShown && menu == nil)
    }

    /// Esc, a click away, or the Design tool going: the picker closes for the prompt as typed.
    private func dismissMention() {
        guard mentions.isOpen else { return }
        mentions.dismissed = draft.prompt
        mentions.close()
    }

    /// The prompt changed: a reference it gained by a paste becomes a chip (the text around it
    /// stays), and the picker follows the mention it ends in.
    private func promptChanged(from old: String, to new: String) {
        guard references != nil else {
            if mentions.isOpen { mentions.close() }
            return
        }
        if let pasted = ComposerReferencePaste.extract(new, previous: old) {
            draft.prompt = pasted.draft
            for reference in pasted.references { attach(reference) }
            return
        }
        updateMentions()
    }

    /// Derives what the picker lists for the prompt as it is; opening it reads this Mac's designs.
    private func updateMentions() {
        guard let references else { return }
        let wasOpen = mentions.isOpen, scope = mentions.scope
        let unavailable = draft.referencesUnavailable
        // Opening reads the designs afresh: the picker says it is loading from this call on.
        if unavailable == nil, mentions.opens(for: draft.prompt) { references.startCatalogRead() }
        mentions.update(draft: draft.prompt, catalog: references.catalog, stage: references.catalogStage, unavailable: unavailable) {
            references.rowPicture($0)
        }
        guard unavailable == nil else { return }
        if mentions.isOpen, !wasOpen {
            draft.referenceError = nil
            references.io.wantPictures(mentions.scope)
        } else if mentions.isOpen, mentions.scope != scope {
            references.io.wantPictures(mentions.scope)
        }
    }

    /// A row chosen: a design or board drills in; anything else joins the message as a chip, its
    /// mention taken out of the words.
    private func chooseMention(_ row: NWMentionRow) {
        switch mentions.choose(row) {
        case .drill(let text):
            draft.prompt = text
        case .pick(let reference, let text):
            draft.prompt = text
            attach(reference)
        case nil:
            break
        }
        composing = true
    }

    private func mentionBack() {
        if let text = mentions.back() { draft.prompt = text }
        composing = true
    }

    /// Pins `reference` and puts its chip in the composer; why it can't, under the card.
    private func attach(_ reference: DesignReference) {
        guard let references else { return }
        let draft = draft
        Task {
            do {
                try await references.io.attach(reference)
            } catch {
                draft.referenceError = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
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
