import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdSessions

/// The New thread page (NavNewThread; ⌘N or the first destination): "What should the agent work
/// on?", the composer with attach, the workplace chip (project · host, with the worktree option
/// in its menu), the shared model, thinking and speed chips and Send, and the Continue card for the most recent
/// running thread, and "Start a design" while the Design tool is on. Sending creates the agent
/// with the prompt and its images as its opening message and opens its thread.
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
    /// The slash menu's highlighted row, the prompt Esc closed it for, and its matches, as the
    /// thread composer keeps them.
    @State private var commandIndex = 0
    @State private var dismissedQuery: String?
    @State private var slash = SlashMatchCache()

    private enum Menu: Equatable { case place, base, models, settings, branch, whereRuns }
    /// The Branch picker's New branch…: the name being typed, while its prompt is up.
    @State private var namingBranch = false
    @State private var newBranchName = ""
    /// What a click outside closes: a chip's menu, the slash menu, or the @ picker.
    private enum OpenMenu: Equatable { case none, chip, slash, mention }

    /// `settingsOpen`, `placeOpen` and `whereOpen` start with the model settings, the place menu or Where it runs open, for the
    /// preview renders.
    init(vm: ShepherdViewModel, chrome: PageHeaderChrome, settingsOpen: Bool = false, placeOpen: Bool = false, whereOpen: Bool = false) {
        self.vm = vm
        self.chrome = chrome
        _menu = State(initialValue: settingsOpen ? .settings : placeOpen ? .place : whereOpen ? .whereRuns : nil)
    }

    private var draft: NewThreadState { vm.newThread }

    /// This Mac's designs, for the @ picker and the chips; nil with the Design tool off.
    private var references: DesignReferenceChips? { vm.designToolEnabled ? draft.referenceChips : nil }

    /// The @ picker is up: a mention is being typed. It says "Loading designs…" until the designs
    /// are read, and for a project on another host a note that none can go there.
    private var mentionShown: Bool { mentions.isOpen && references != nil && commandQuery == nil }

    /// The commands the slash menu offers before the thread exists (`NewThreadState.slashCommands`).
    private var commands: [NativeCommand] {
        NewThreadState.slashCommands(catalog: vm.slashCommands.catalog, hidden: vm.slashCommands.hidden,
                                     skills: vm.settings.skillsInSlashMenu, goals: vm.settings.goalsEnabled, place: draft.place)
    }

    /// The skills "$" lists: Settings ▸ Skills keeps them out of "/" only, as in the thread composer.
    private var skills: [NativeCommand] {
        NewThreadState.slashCommands(catalog: vm.slashCommands.catalog, hidden: vm.slashCommands.hidden,
                                     skills: true, goals: false, place: draft.place).filter { $0.source == "skill" }
    }

    /// The "/" (commands) or "$" (skills) being typed at the end of the prompt, unless Esc closed its menu.
    private var commandToken: ComposerCommandToken? {
        draft.prompt == dismissedQuery ? nil : ComposerCommandToken.token(in: draft.prompt)
    }

    /// What the open menu lists: the commands for "/", the skills for "$".
    private var menuCommands: [NativeCommand] { commandToken?.sigil == "$" ? skills : commands }

    /// The query the menu matches, as in the thread composer: skills are named "skill:<name>", so
    /// "$" matches past that, and mid-prompt a token matching nothing is prose ("see /tmp").
    private var commandQuery: String? {
        guard let token = commandToken, !menuCommands.isEmpty, !token.isSkill(in: skills) else { return nil }
        let query = (token.sigil == "$" ? "skill:" + token.text : token.text).lowercased()
        guard token.startsDraft || !SlashMatchCache.matches(query: query, in: menuCommands).isEmpty else { return nil }
        return query
    }

    private var commandMatches: [NativeCommand] { commandQuery == nil ? [] : slash.matches }

    private var openMenu: OpenMenu {
        menu != nil ? .chip : commandQuery != nil ? .slash : mentionShown ? .mention : .none
    }

    var body: some View {
        let _ = SHRenderProbe.tick("newThread.page")
        let query = commandQuery
        let _ = slash.update(query: query, commands: menuCommands)
        VStack(spacing: 0) {
            DestinationPageHeader(title: "New thread", chrome: chrome, rule: false)
            // The boards' `.hero`: the composer and the suggestions under it, centred a little above the middle.
            VStack(spacing: AppLayout.newThreadGap) {
                VStack(spacing: SH.Space.l) {
                    composer
                        .zIndex(1)
                    if draft.place?.host == nil, let apps = vm.quickApps(in: draft.place?.space) {
                        NewThreadApps(apps: apps, run: { vm.runQuickApp($0) }, stop: { vm.stopApp($0) }, restart: { vm.restartApp($0) },
                                      edit: { vm.openAppsSettings() })
                    }
                }
                .frame(maxWidth: AppLayout.newThreadComposerWidth)
                .zIndex(1)
                if let note = draft.fleetPicker(vm).note, draft.notice(vm) == nil {
                    // "Runs on Mac mini in a new worktree from origin/main. It shows here as sent by you."
                    Text(note).font(.sh(.caption, weight: .regular)).foregroundStyle(Color.sh.textTertiary)
                        .frame(maxWidth: AppLayout.newThreadComposerWidth, alignment: .leading)
                        .shTransition(.content)
                }
                if let notice = draft.notice(vm) {
                    Text(notice).font(.sh(.caption)).foregroundStyle(Color.sh.failed)
                        .frame(maxWidth: AppLayout.newThreadComposerWidth, alignment: .leading)
                        .shTransition(.content)
                }
                ContinueCards(card: vm.continueCard, open: { vm.selectSidebarRow($0) },
                              design: vm.designToolEnabled ? { vm.openNewDesign() } : nil)
                    .frame(maxWidth: AppLayout.newThreadComposerWidth)
                    .padding(.top, AppLayout.newThreadCardsTop - AppLayout.newThreadGap)
            }
            .padding(.horizontal, AppLayout.newThreadSidePadding)
            .padding(.bottom, AppLayout.newThreadBottomPadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
            .onTapGesture {
                if menu != nil { menu = nil }
                if commandQuery != nil { dismissedQuery = draft.prompt }
                dismissMention()
            }
        }
        .background(Color.sh.bgWindow)
        .shAnimation(.content, value: draft.notice(vm))
        .alert("New branch", isPresented: $namingBranch) {
            TextField("Branch name", text: $newBranchName)
            Button("Cancel", role: .cancel) {}
            Button("Use") {
                let name = newBranchName.trimmingCharacters(in: .whitespacesAndNewlines)
                if !name.isEmpty { draft.worktreeBranch = .named(name) }
                menu = .place
            }
        } message: {
            Text("The new worktree starts this branch from the base.")
        }
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
        .onChange(of: openMenu, initial: true) { _, open in
            let (menu, mentions, dismissedQuery, state) = ($menu, $mentions, $dismissedQuery, vm.newThread)
            dismissal.dismiss = {
                switch open {
                case .slash: dismissedQuery.wrappedValue = state.prompt
                case .mention:
                    mentions.wrappedValue.dismissed = state.prompt
                    mentions.wrappedValue.close()
                default: menu.wrappedValue = nil
                }
            }
            dismissal.watch(open != .none)
        }
        .onChange(of: query) { _, query in
            commandIndex = 0
            // One menu at a time: typing a command takes over from a chip's menu.
            if query != nil { menu = nil }
        }
        // A pasted reference becomes a chip; a mention opens the @ picker.
        .onChange(of: draft.prompt, initial: true) { old, new in promptChanged(from: old, to: new) }
        .onChange(of: references?.catalog) { _, _ in updateMentions() }
        .onChange(of: references?.catalogStage) { _, _ in updateMentions() }
        .onChange(of: references?.picturesVersion) { _, _ in if mentions.isOpen { updateMentions() } }
        .onChange(of: draft.place) { _, _ in updateMentions() }
        .onChange(of: mentionShown) { _, shown in if shown { menu = nil } }
        .onDisappear {
            dismissal.watch(false)
            draft.referenceChips?.releasePictureDemand()
        }
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
        } leading: {
            leadingControls
        } field: {
            ComposerTextField(text: Binding(get: { draft.prompt }, set: { draft.prompt = $0 }),
                              caret: caret, placeholder: "What should the agent work on?",
                              label: "What should the agent work on?", focus: $composing, attach: draft.attach,
                              size: AppLayout.newThreadFieldSize)
            .onComposerKey(.return) { press in
                if let result = press.lineBreak() { return result }
                // ↩ over the slash menu runs its row: the thread starts with it.
                if commandQuery != nil {
                    let matches = commandMatches
                    if matches.indices.contains(commandIndex) { choose(matches[commandIndex]) }
                    return .handled
                }
                // ↩ over the @ picker chooses its row, and never starts the thread.
                if mentionShown {
                    if let row = mentions.highlightedRow { chooseMention(row) }
                    return .handled
                }
                draft.send(vm)
                return .handled
            }
            .onComposerKey(.tab) {
                if commandQuery != nil {
                    let matches = commandMatches
                    guard matches.indices.contains(commandIndex) else { return .ignored }
                    complete(matches[commandIndex])
                    return .handled
                }
                guard mentionShown else { return .ignored }
                if let row = mentions.highlightedRow { chooseMention(row) }
                return .handled
            }
            .onComposerKey(.upArrow) {
                if commandQuery != nil {
                    commandIndex = max(0, commandIndex - 1)
                    return .handled
                }
                guard mentionShown else { return .ignored }
                mentions.move(-1)
                return .handled
            }
            .onComposerKey(.downArrow) {
                if commandQuery != nil {
                    commandIndex = min(max(0, commandMatches.count - 1), commandIndex + 1)
                    return .handled
                }
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
                if commandQuery != nil {
                    dismissedQuery = draft.prompt
                    return .handled
                }
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
        .background { if mentionShown || commandQuery != nil { ComposerMenuRegion(dismissal: dismissal) } }
        // Where it runs hangs under its own chip, toward the card's trailing edge (FleetNewThread); the others at its leading one.
        .overlay(alignment: menu == .whereRuns ? .bottomTrailing : .bottomLeading) {
            menus.padding(.trailing, menu == .whereRuns ? AppLayout.fleetPlaceTrailingInset : 0)
        }
        .overlay(alignment: .bottomLeading) { mentionMenu }
    }

    /// The boards' line: the attach plus, then where it runs ("shepherd on This Mac") and, with another Mac paired, which Mac.
    private var leadingControls: some View {
        let chip = NewThreadPlaces.chip(NewThreadState.hosts(vm), chosen: draft.place)
        let fleet = draft.fleetPicker(vm)
        let withMac = !fleet.options.isEmpty
        return HStack(spacing: SH.Space.xxs) {
            Button { picking = true } label: { Image(systemName: "plus").font(.system(size: SHComposerMetrics.sendGlyph + 2)) }
                .buttonStyle(.shIcon(size: SHComposerMetrics.actionSize, round: true))
                .disabled(draft.attachments.isFull)
                .help("Attach images (drop or paste also works), up to \(NativeImage.maxPerSend)")
                .accessibilityLabel("Attach file")
            // Fleet on and another Mac paired: the Mac is its own chip, after the project (FleetNewThread).
            Button { toggle(.place) } label: { SHPlaceChipLabel(project: chip.project, host: withMac ? nil : chip.host) }
                .buttonStyle(.shComposerChip(active: menu == .place || menu == .base || menu == .branch))
                .background { ComposerMenuRegion(dismissal: dismissal) }
                .help(withMac ? chip.project : draft.worktree ? "In a new worktree of \(chip.project) on \(chip.host)" : "\(chip.project) on \(chip.host)")
            if withMac {
                Button { toggle(.whereRuns) } label: { SHFleetPlaceChipLabel(fleet.chip) }
                    .buttonStyle(.shComposerChip(active: menu == .whereRuns))
                    .background { ComposerMenuRegion(dismissal: dismissal) }
                    .help("Where it runs: \(fleet.chip)")
            }
        }
        .layoutPriority(1)
    }

    private var controls: some View {
        ComposerControlsMinimum {
            HStack(spacing: SH.Space.xxs) {
                Spacer(minLength: SH.Space.m)
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
        let levels = draft.thinkingLevels(vm)
        let tiers = draft.serviceTiers(vm)
        let summary = ModelSettingsSummary(model: draft.model, thinking: draft.thinkingLevel(vm).rawValue, thinkingOffered: !levels.isEmpty,
                                           speed: draft.serviceTier, speedOffered: tiers.count > 1, shortenedName: short,
                                           qualified: draft.catalog?.isAmbiguous(draft.model) ?? false)
        return Button { toggle(.settings) } label: {
            SHModelSettingsLabel(model: summary.name, thinking: summary.thinking, fast: summary.fast)
        }
        .buttonStyle(.shComposerChip(active: menu == .settings || menu == .models))
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .help("Model settings: \(draft.model)")
        .accessibilityLabel("Model settings: \(draft.model.isEmpty ? "default model" : draft.model)")
        .accessibilityValue(summary.value)
    }

    // MARK: Menus

    /// The open menu, under the card: its top-leading corner 8pt below the card's bottom-leading
    /// one, over the cards beneath.
    private var menus: some View {
        ZStack(alignment: .topLeading) {
            switch menu {
            case .place:
                placeMenu.shTransition(.overlay, anchor: .topLeading)
            case .whereRuns:
                whereMenu.shTransition(.overlay, anchor: .topLeading)
            case .base:
                if let space = draft.place.flatMap({ place in vm.state.spaces.first { $0.id == place.space } }) {
                    WorktreeBasePicker(vm: vm, space: space.id, repo: space.path, selected: draft.worktreeBase ?? space.worktreeBase) { base in
                        draft.worktreeBase = base
                        menu = nil
                        composing = true
                    } close: { menu = .place } defaultChanged: { base in
                        if base != nil { draft.worktree = true }
                    }
                    .shTransition(.overlay, anchor: .topLeading)
                }
            case .branch:
                if let space = draft.place.flatMap({ place in vm.state.spaces.first { $0.id == place.space } }) {
                    let base = draft.worktreeBase ?? draft.projectBase(vm)
                    BranchPickerMenu(first: "New branch from \(base.map(BranchCardGitReader.baseName) ?? "base")",
                                     selected: { if case .existing(let name)? = draft.worktreeBranch { name } else { nil } }(),
                                     load: { try await vm.branchPickerList(cwd: space.path, space: space.id) },
                                     choose: { name in
                                         draft.worktreeBranch = name.map(NewThreadBranch.existing)
                                         menu = .place
                                     },
                                     newBranch: { newBranchName = ""; namingBranch = true },
                                     fetch: {
                                         let path = space.path
                                         try await Task.detached { try BranchGit.fetchAll(cwd: path) }.value
                                     },
                                     close: { menu = .place })
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
                                searchModels: draft.catalog?.settingsSearchModels ?? [],
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
        let base = draft.worktreeBase ?? draft.projectBase(vm)
        // Branch and Base are this Mac's; a host resolves its own.
        let local = draft.place?.host == nil
        return SHPlaceMenu(
            sections: NewThreadPlaces.sections(hosts, chosen: draft.place),
            worktree: offers ? SHPlaceWorktree(isOn: draft.worktree, caption: NewThreadRules.worktreeCaption(base: base ?? ""),
                                               branch: local ? draft.worktreeBranch?.title ?? "new from \(base.map(BranchCardGitReader.baseName) ?? "default")" : nil,
                                               base: local ? base ?? "Default" : nil) : nil,
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
            onChooseBranch: { menu = .branch },
            onChooseBase: { menu = .base },
            onClose: { menu = nil; composing = true }
        ) { option in
            ProjectMenu(vm: vm, place: NewThreadPlaces.place(option))
        }
    }

    private static func row(_ option: FleetPlaceOption) -> SHFleetPlaceRow {
        let tone: SHFleetPlaceRow.Tone = switch option.tone {
        case .good: .good
        case .warn: .warn
        case .bad: .bad
        default: .quiet
        }
        return SHFleetPlaceRow(id: option.id, title: option.name, detail: option.detail, room: option.room, roomWord: option.roomWord,
                               tone: tone, isCurrent: option.chosen, isEnabled: option.selectable)
    }

    /// FleetNewThread's popover: Auto and every Mac ranked by room.
    private var whereMenu: some View {
        let picker = draft.fleetPicker(vm)
        return SHFleetPlaceMenu(
            rows: picker.options.map(Self.row), footnote: picker.footnote,
            onChoose: { row in
                draft.wherePick = picker.options.first { $0.id == row.id }?.pick
                menu = nil
                composing = true
            },
            onClose: { menu = nil; composing = true })
    }

    private func toggle(_ next: Menu) {
        // A chip's menu takes over from the slash menu, which stays closed for the prompt as typed.
        if commandQuery != nil { dismissedQuery = draft.prompt }
        menu = menu == next ? nil : next
    }

    /// A slash row chosen: "/name" becomes the prompt and starts the thread when it can, as the
    /// thread composer sends it.
    /// A row picked: a skill becomes an inline chip and the person keeps typing; a command starts
    /// the thread, unless words came before it, which become its arguments for the person to send.
    private func choose(_ command: NativeCommand) {
        if attachSkill(command) { return }
        let token = commandToken
        draft.prompt = token?.draft(running: command.name, then: "") ?? "/\(command.name)"
        dismissedQuery = nil
        composing = true
        guard token?.before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true else { return }
        if draft.blocker(vm) == nil { draft.send(vm) }
    }

    private func complete(_ command: NativeCommand) {
        if attachSkill(command) { return }
        draft.prompt = commandToken?.draft(running: command.name, then: " ") ?? "/\(command.name) "
        dismissedQuery = nil
    }

    /// A skill takes the place of its "$de" or "/skill:de" as an inline chip, as in the thread composer.
    private func attachSkill(_ command: NativeCommand) -> Bool {
        guard command.source == "skill", let token = commandToken else { return false }
        draft.prompt = ComposerSkillToken.draft(picking: command.name, for: token)
        dismissedQuery = nil
        composing = true
        return true
    }

    // MARK: Design references

    /// The slash menu or the @ picker, under the card as the page's other menus are: the commands
    /// for "/…", or designs, then a design's boards and a board's elements, or what it says before
    /// it has rows.
    private var mentionMenu: some View {
        ZStack(alignment: .topLeading) {
            if let query = commandQuery, menu == nil {
                let slash = slash
                SHSlashMenu(commands: slash.rows, total: menuCommands.count, query: query,
                            title: commandToken?.sigil == "$" ? "Skills" : "Commands", selection: $commandIndex,
                            maxHeight: SHComposerMetrics.modelPickerMaxHeight) { command in
                    if let match = slash.matches.first(where: { $0.name == command.name }) { choose(match) }
                }
                .shTransition(.overlay, anchor: .topLeading)
            } else if mentionShown, menu == nil, let references {
                let content = mentions.content
                SHMentionPicker(sections: content.sections, crumbs: content.crumbs, empty: content.empty, highlighted: mentions.highlighted,
                                maxHeight: SHComposerMetrics.modelPickerMaxHeight, choose: { chooseMention($0) }, drill: { chooseMention($0) },
                                back: { mentionBack() }, hover: { mentions.highlighted = $0 }, startDesign: references.io.startDesign,
                                retry: { references.startCatalogRead() },
                                appear: { id in
                                    if let item = mentions.content.items[id] { references.rowAppeared(item, rowID: id) }
                                }, disappear: { references.rowDisappeared($0) })
                    .onDisappear { references.releasePictureDemand() }
                    .shTransition(.overlay, anchor: .topLeading)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .background { ComposerMenuRegion(dismissal: dismissal) }
        .alignmentGuide(.bottom) { $0[.top] - AppLayout.menuGap }
        .shAnimation(.overlay, value: menu == nil ? openMenu : .none)
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
        case .link(let text):
            draft.prompt = text
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
            Button("Remove Space…", role: .destructive) { vm.requestSpaceDelete(space.id) }
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
            case .design, .remoteDesign, .dispatch:
                // A design's row wears the nib, never a running dot.
                continue
            }
        }
        return nil
    }
}

/// The suggestions under the composer (the boards' `.sugg`), one row each: Continue the most recent running thread, and
/// "Start a design" while the Design tool is on.
private struct ContinueCards: View, Equatable {
    let card: ContinueCard?
    let open: (SidebarRowID) -> Void
    /// New design; nil while the Design tool is off.
    let design: (() -> Void)?

    static func == (a: ContinueCards, b: ContinueCards) -> Bool { a.card == b.card && (a.design == nil) == (b.design == nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let card {
                SuggestionRow(symbol: "bubble.left", kicker: "Continue", title: card.title, since: card.since,
                              detail: "running", label: "Continue \(card.title), running") { open(card.id) }
                    .shTransition(.content)
            }
            if let design {
                SuggestionRow(symbol: "pencil.tip", kicker: nil, title: "Start a design", since: nil,
                              detail: "HTML boards on a canvas", label: "Start a design, HTML boards on a canvas", action: design)
                    .shTransition(.content)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .shAnimation(.content, value: card?.id)
    }
}

/// One suggestion (the boards' `.sg`): a 34pt row of its glyph, a kicker in `textSecondary`, the title in medium ink and a
/// detail in `textTertiary` ("running for 42 min"), hover `bgHover`.
private struct SuggestionRow: View {
    let symbol: String
    let kicker: String?
    let title: String
    /// When the thread started running: the detail counts it ("running for 42 min").
    let since: Date?
    let detail: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: SH.Space.m + 2) {
                Image(systemName: symbol).font(.system(size: AppLayout.chipSymbol + 2)).foregroundStyle(Color.sh.textSecondary)
                    .frame(width: SH.Space.xl)
                if let kicker { Text(kicker).foregroundStyle(Color.sh.textSecondary) }
                Text(title).fontWeight(.medium).foregroundStyle(Color.sh.textPrimary).lineLimit(1).truncationMode(.tail)
                Group {
                    if let since {
                        TimelineView(SHElapsedSchedule(start: since)) { context in
                            Text("\(detail) for \(Self.duration(context.date.timeIntervalSince(since)))")
                        }
                    } else {
                        Text(detail)
                    }
                }
                .foregroundStyle(Color.sh.textTertiary).lineLimit(1)
            }
            .font(.sh(.ui))
            .padding(.horizontal, SH.Space.l)
            .frame(height: AppLayout.newThreadSuggestionHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.shRow(radius: SH.Radius.s))
        .fixedSize(horizontal: true, vertical: false)
        .accessibilityLabel(label)
    }
    /// "42 min", "3 hr": the boards' words, on the same steps as the short clock.
    static func duration(_ seconds: TimeInterval) -> String {
        let whole = Int(max(0, seconds))
        if whole < 60 { return "\(whole) sec" }
        if whole < 3600 { return "\(whole / 60) min" }
        if whole < 86_400 { return "\(whole / 3600) hr" }
        return "\(whole / 86_400) d"
    }
}

extension NewThreadState {
    /// The slash menu's commands before the thread exists: every command a pi on this Mac has
    /// listed since launch (`SessionServer.slashCommandCatalog`), less what a thread's menu leaves
    /// out (Settings ▸ Pi ▸ Slash commands, skills while Settings ▸ Skills keeps them out, /goal
    /// without Goals). None for another host, whose commands this Mac never sees, or before a place.
    /// ponytail: the union of this Mac's threads, not the chosen project's own registry; and empty
    /// until some pi has listed its commands since launch.
    nonisolated static func slashCommands(catalog: [NativeCommand], hidden: Set<String>, skills: Bool, goals: Bool,
                              place: NewThreadPlace?) -> [NativeCommand] {
        guard let place, place.host == nil else { return [] }
        return catalog.filter { command in
            !hidden.contains(command.name) && (skills || command.source != "skill") && (goals || command.name != "goal")
        }
    }
}

/// "Run in payments" and the space's quick actions under New thread's composer (AppsNewThread
/// board): each runs in the background in the space's folder; a running one stops, and one that
/// exited restarts.
private struct NewThreadApps: View {
    let apps: QuickApps
    let run: (AppKey) -> Void
    let stop: (AppKey) -> Void
    let restart: (AppKey) -> Void
    let edit: () -> Void

    var body: some View {
        HStack(spacing: SH.Space.s) {
            Text("Run in \(apps.space)").font(.sh(.ui, weight: .regular)).foregroundStyle(Color.sh.textSecondary)
                .padding(.trailing, SH.Space.xxs)
            ForEach(apps.items) { item in
                let (verb, glyph): (String, String) = switch item.status {
                case .starting?, .running?: ("Stop", "stop.fill")
                case .exited?: ("Restart", "arrow.clockwise")
                default: ("Run", "play.fill")
                }
                Button {
                    switch verb {
                    case "Stop": stop(item.key)
                    case "Restart": restart(item.key)
                    default: run(item.key)
                    }
                } label: {
                    Label(item.app.name, systemImage: glyph).labelStyle(AppRunLabelStyle())
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .help("\(verb) \(item.app.name)")
                .accessibilityLabel("\(verb) \(item.app.name)")
            }
            Button("Edit apps…", action: edit).buttonStyle(.shLink(color: Color.sh.textTertiary))
                .padding(.leading, SH.Space.s)
            Spacer(minLength: 0)
        }
    }
}
