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
    @State private var composing = false
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

    private enum Menu: Equatable { case place, base, models, settings }

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
        let _ = SHRenderProbe.tick("newThread.page")
        VStack(spacing: 0) {
            DestinationPageHeader(title: "New thread", chrome: chrome)
            VStack(spacing: AppLayout.newThreadGap) {
                Text("What should the agent work on?")
                    .font(.shSans(AppLayout.newThreadHeadingSize, .semibold))
                    .tracking(AppLayout.newThreadHeadingTracking)
                    .foregroundStyle(Color.sh.textPrimary)
                    .multilineTextAlignment(.center)
                    .accessibilityAddTraits(.isHeader)
                composer
                    .frame(maxWidth: AppLayout.newThreadComposerWidth)
                    .zIndex(1)
                if let notice = draft.notice(vm) {
                    Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                        .frame(maxWidth: AppLayout.newThreadComposerWidth, alignment: .leading)
                        .shTransition(.content)
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
        .background(Color.sh.bgWindow)
        .shAnimation(.content, value: draft.notice(vm))
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
        SHComposer(isFocused: composing || menu != nil || mentionShown || dropTargeted) {
            // Design pieces sit first, above the words (DesignReferenceChip(ref)).
            ForEach(draft.references) { attached in
                ComposerReferenceChip(attached: attached, references: references) { draft.detach(reference: attached.id) }
                    .shTransition(.list, edge: .leading)
            }
            ForEach(draft.attachments.items) { attachment in
                SHAttachmentChip(attachment.name, thumbnail: attachment.thumbnail) {
                    draft.attachments.remove(attachment.id)
                }
                .shTransition(.list, edge: .leading)
            }
        } field: {
            ComposerTextField(text: Binding(get: { draft.prompt }, set: { draft.prompt = $0 }),
                              selection: caretBinding, placeholder: "Describe the task…",
                              label: "What should the agent work on?", focus: $composing, attach: draft.attach)
            .onComposerKey(.return) { press in
                if let result = press.lineBreak() { return result }
                // ↩ over the @ picker chooses its row, and never starts the thread.
                if mentionShown {
                    if let row = mentions.highlightedRow { chooseMention(row) }
                    return .handled
                }
                draft.send(vm)
                return .handled
            }
            .onComposerKey(.tab) {
                guard mentionShown else { return .ignored }
                if let row = mentions.highlightedRow { chooseMention(row) }
                return .handled
            }
            .onComposerKey(.upArrow) {
                guard mentionShown else { return .ignored }
                mentions.move(-1)
                return .handled
            }
            .onComposerKey(.downArrow) {
                guard mentionShown else { return .ignored }
                mentions.move(1)
                return .handled
            }
            // → drills into a design or a board; ← and ⌫ with nothing typed after the breadcrumb go back a level.
            .onComposerKey(.rightArrow) {
                guard mentionShown, let row = mentions.highlightedRow, row.trailing == .drill else { return .ignored }
                chooseMention(row)
                return .handled
            }
            .onComposerKey(.leftArrow) {
                guard mentionShown, mentions.filterIsEmpty, mentions.scope != .designs else { return .ignored }
                mentionBack()
                return .handled
            }
            .onComposerKey(.delete) {
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
            .onComposerKey(.escape) {
                if mentionShown {
                    dismissMention()
                    return .handled
                }
                guard menu != nil else { return .ignored }
                menu = nil
                return .handled
            }
            .modifier(CycleThinkingShortcut(focused: composing && !draft.starting && !draft.loadingDefaults,
                                          current: draft.thinkingLevel(vm).rawValue, levels: draft.thinkingLevels(vm).map(\.rawValue),
                                          choose: { id in if let level = ThinkingLevel(rawValue: id) { draft.setThinking(level) } }))
            .accessibilityLabel("What should the agent work on?")
        } controls: {
            controls
        }
        .shAnimation(.list, value: draft.attachments.ids)
        .shAnimation(.list, value: draft.references.map(\.id))
        .onDrop(of: [.image, .fileURL], isTargeted: $dropTargeted) { providers in
            draft.attach(providers)
            return true
        }
        .background { if mentionShown { ComposerMenuRegion(dismissal: dismissal) } }
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
            HStack(spacing: SH.Space.xxs) {
                ViewThatFits(in: .horizontal) {
                    controlChips(short: false)
                    controlChips(short: true)
                }
                .shAnimation(.content, value: [draft.model, draft.thinking.rawValue, draft.serviceTier.rawValue])
                if draft.starting {
                    ProgressView().progressViewStyle(.shSpinner(color: Color.sh.textTertiary))
                        .frame(width: SHComposerMetrics.actionSize, height: SHComposerMetrics.actionSize)
                        .accessibilityLabel("Starting")
                } else {
                    SHComposerActionButton(.send, enabled: draft.blocker(vm) == nil) { draft.send(vm) }
                        .help(draft.blocker(vm) ?? "Send (\(KeybindingsStore.shared.sendDisplay))")
                }
            }
            .shAnimation(.content, value: draft.starting)
        }
    }

    private func controlChips(short: Bool) -> some View {
        let chip = NewThreadPlaces.chip(NewThreadState.hosts(vm), chosen: draft.place)
        let levels = draft.thinkingLevels(vm)
        let tiers = draft.serviceTiers(vm)
        return HStack(spacing: SH.Space.xxs) {
            Button { picking = true } label: { Image(systemName: "paperclip") }
                .buttonStyle(.shIcon(size: SHComposerMetrics.chipHeight))
                .disabled(draft.attachments.isFull)
                .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                .accessibilityLabel("Attach file")
            let summary = ModelSettingsSummary(model: draft.model, thinking: draft.thinkingLevel(vm).rawValue, thinkingOffered: !levels.isEmpty,
                                               speed: draft.serviceTier, speedOffered: tiers.count > 1, shortenedName: short)
            Button { toggle(.settings) } label: {
                SHModelSettingsLabel(model: summary.name, thinking: summary.thinking, fast: summary.fast)
            }
            .buttonStyle(.shComposerChip(active: menu == .settings || menu == .models))
            .background { ComposerMenuRegion(dismissal: dismissal) }
            .help("Model settings: \(draft.model)")
            .accessibilityLabel("Model settings: \(draft.model.isEmpty ? "default model" : draft.model)")
            .accessibilityValue(summary.value)
            Spacer(minLength: SH.Space.m)
            Button { toggle(.place) } label: { SHPlaceChipLabel(project: chip.project, host: chip.host) }
                .buttonStyle(.shComposerChip(active: menu == .place || menu == .base))
                .background { ComposerMenuRegion(dismissal: dismissal) }
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
                placeMenu.shTransition(.overlay, anchor: .topLeading)
            case .base:
                if let space = draft.place.flatMap({ place in vm.state.spaces.first { $0.id == place.space } }) {
                    WorktreeBasePicker(vm: vm, repo: space.path, selected: draft.worktreeBase) { base in
                        draft.worktreeBase = base
                        menu = nil
                        composing = true
                    } close: { menu = .place }
                    .shTransition(.overlay, anchor: .topLeading)
                }
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
                let levels = draft.thinkingLevels(vm)
                let tiers = draft.serviceTiers(vm)
                SHModelSettings(models: ModelCatalog.settingsModels(catalog: draft.catalog, current: draft.model, recent: RecentModels.load().map(\.id),
                                                                    currentOffersFast: tiers.count > 1),
                                thinking: NativeThinkingLevel.levels(levels.map(\.rawValue)).map {
                                    SHThinkingOption(id: $0.id, title: $0.title, note: $0.note)
                                }, currentThinking: draft.thinkingLevel(vm).rawValue,
                                speeds: tiers.count > 1 ? tiers.map {
                                    SHSpeedOption(id: $0.rawValue, title: $0.title, detail: $0.summary, boosted: $0 != .standard)
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

    private var placeMenu: some View {
        let hosts = NewThreadState.hosts(vm)
        let offers = draft.offersWorktree(vm)
        return SHPlaceMenu(
            sections: NewThreadPlaces.sections(hosts, chosen: draft.place),
            worktree: offers ? SHPlaceWorktree(isOn: draft.worktree, caption: NewThreadRules.worktreeCaption(base: draft.worktreeBase ?? ""),
                                               base: draft.place?.host == nil ? draft.worktreeBase ?? "Default" : nil) : nil,
            maxHeight: SHComposerMetrics.modelPickerMaxHeight,
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
            onChooseBase: { menu = .base },
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
                SHMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: mentions.highlighted,
                                maxHeight: SHComposerMetrics.modelPickerMaxHeight, choose: { chooseMention($0) }, drill: { chooseMention($0) },
                                back: { mentionBack() }, hover: { mentions.highlighted = $0 }, startDesign: references?.io.startDesign,
                                retry: { references?.startCatalogRead() },
                                appear: { id in
                                    if let item = mentions.content.items[id] { references?.rowAppeared(item) }
                                })
                    .shTransition(.overlay, anchor: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .shAnimation(.overlay, value: mentionShown && menu == nil)
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
    private func chooseMention(_ row: SHMentionRow) {
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
        } else if let place, let host = place.host, let space = place.space {
            Button("New Agent with Options…") { vm.showNewAgentSheetForRemote(hostID: host, spaceID: space) }
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
                        .shTransition(.content)
                }
                if let design {
                    DesignSuggestionCard(action: design)
                        .frame(width: max(0, width))
                        .shTransition(.content)
                }
                Spacer(minLength: 0)
            }
        }
        .frame(height: SuggestionCard.height)
        .shAnimation(.content, value: card?.id)
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
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "pencil.tip").font(.shSans(12))
                        .foregroundStyle(Color.sh.textSecondary)
                    Text("Need a mockup first?").font(.shSans(11.5)).foregroundStyle(Color.sh.textTertiary)
                }
                Text("Start a design").font(.shSans(13, .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1)
                Text("HTML boards on a canvas").font(.shSans(11)).foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
            .padding(.vertical, SH.Space.l)
            .padding(.horizontal, AppLayout.newThreadCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
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
                HStack(spacing: SH.Space.m) {
                    Image(systemName: "bubble.left").font(.system(size: AppLayout.chipSymbol, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                    Text("Continue").font(.shSans(11.5)).foregroundStyle(Color.sh.textTertiary)
                }
                Text(card.title).font(.shSans(13, .medium)).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                Group {
                    if let since = card.since {
                        TimelineView(SHElapsedSchedule(start: since)) { context in
                            Text("running · \(SHDuration.text(context.date.timeIntervalSince(since)))")
                        }
                    } else {
                        Text("running")
                    }
                }
                .font(.shSans(11))
                .foregroundStyle(Color.sh.textTertiary)
            }
            .padding(.vertical, SH.Space.l)
            .padding(.horizontal, AppLayout.newThreadCardPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(hovering ? Color.sh.bgHover : .clear, in: RoundedRectangle(cornerRadius: SH.Radius.m))
            .shBorder(Color.sh.lineSubtle, radius: SH.Radius.m)
            .contentShape(RoundedRectangle(cornerRadius: SH.Radius.m))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityLabel("Continue \(card.title), running")
    }
}
