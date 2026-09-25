import SwiftUI
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// The New thread page (NavNewThread; ⌘N or the first destination): "What should the agent work
/// on?", the composer with the workplace chip (project · host, with the worktree option in its
/// menu), the model and thinking chips and Send, and the Continue card for the most recent
/// running thread. Sending creates the agent with the prompt as its opening message and opens
/// its thread. The mission and design cards wait on Missions and Designs, so they are not shown.
struct NewThreadPage: View {
    var vm: ShepherdViewModel
    let chrome: PageHeaderChrome
    @FocusState private var composing: Bool
    @State private var menu: Menu?
    @State private var picker: ModelPickerState?

    private enum Menu: Equatable { case place, models, thinking }

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
                if let error = draft.error {
                    Text(error).font(.nw(.caption)).foregroundStyle(Color.nw.failed)
                        .frame(maxWidth: AppLayout.newThreadComposerWidth, alignment: .leading)
                        .nwTransition(.content)
                }
                ContinueCards(card: vm.continueCard, open: { vm.selectSidebarRow($0) })
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
        .nwAnimation(.content, value: draft.error)
        .onChange(of: draft.focusRequest, initial: true) { composing = true }
    }

    // MARK: Composer

    private var composer: some View {
        NWComposer(isFocused: composing || menu != nil) {
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
            .focused($composing)
            .onKeyPress(.return, phases: .down) { press in
                if press.modifiers.contains(.shift) { draft.prompt += "\n"; return .handled }
                draft.send(vm)
                return .handled
            }
            .onKeyPress(.escape) {
                guard menu != nil else { return .ignored }
                menu = nil
                return .handled
            }
            .accessibilityLabel("What should the agent work on?")
        } controls: {
            controls
        }
        .overlay(alignment: .bottomLeading) { menus }
    }

    private var controls: some View {
        let hosts = NewThreadState.hosts(vm)
        let chip = NewThreadPlaces.chip(hosts, chosen: draft.place)
        let levels = draft.thinkingLevels(vm)
        let blocker = draft.blocker(vm)
        return HStack(spacing: NW.Space.xxs) {
            Button { toggle(.place) } label: { NWPlaceChipLabel(project: chip.project, host: chip.host) }
                .buttonStyle(.nwComposerChip(active: menu == .place))
                .help(draft.worktree ? "In a new worktree of \(chip.project) on \(chip.host)" : "\(chip.project) on \(chip.host)")
            Button { openModels() } label: {
                HStack(spacing: NW.Space.s) {
                    Text(NewThreadRules.shortModel(draft.model)).font(Font.nw(.code)).lineLimit(1).truncationMode(.middle)
                    NWChipChevron()
                }
            }
            .buttonStyle(.nwComposerChip(active: menu == .models))
            .help(draft.model.isEmpty ? "Model: the default" : "Model: \(draft.model)")
            .accessibilityLabel("Model \(NewThreadRules.shortModel(draft.model))")
            if !levels.isEmpty {
                Button { toggle(.thinking) } label: {
                    HStack(spacing: NW.Space.s) {
                        Image(systemName: "lightbulb").font(.system(size: AppLayout.chipSymbol, weight: .medium))
                            .foregroundStyle(Color.nw.textSecondary)
                        Text("Thinking")
                        Text(draft.thinking.clamped(to: levels).title).foregroundStyle(Color.nw.textPrimary).fontWeight(.medium)
                        NWChipChevron()
                    }
                }
                .buttonStyle(.nwComposerChip(active: menu == .thinking))
                .accessibilityLabel("Thinking level: \(draft.thinking.clamped(to: levels).title)")
            }
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
        .nwAnimation(.content, value: draft.starting)
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
            case .thinking:
                let levels = draft.thinkingLevels(vm)
                NWThinkingMenu(options: NativeThinkingLevel.levels(levels.map(\.rawValue)).map {
                    NWThinkingOption(id: $0.id, title: $0.title, note: $0.note)
                }, current: draft.thinking.clamped(to: levels).rawValue) { option in
                    menu = nil
                    composing = true
                    if let level = ThinkingLevel(rawValue: option.id) { draft.setThinking(level) }
                } onClose: { menu = nil; composing = true }
                .nwTransition(.overlay, anchor: .topLeading)
            case nil:
                EmptyView()
            }
        }
        .fixedSize()
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
    /// The most recent running thread (automation runs and offline hosts' threads aside), for the
    /// New thread page.
    var continueCard: ContinueCard? {
        for row in sidebarLists.recents where row.leading == .dot(.running) && !row.offline {
            switch row.id {
            case .local(let id):
                return ContinueCard(id: row.id, title: row.title, since: statusSince[id])
            case .remote(let ref):
                let since = remoteAgent(ref)?.lastActiveAt.map { Date(timeIntervalSince1970: $0 / 1000) }
                return ContinueCard(id: row.id, title: row.title, since: since)
            }
        }
        return nil
    }
}

/// The suggestion cards under the composer: only Continue is built (Missions and Designs are
/// not), so the row holds one card at a third of its width, or nothing.
private struct ContinueCards: View, Equatable {
    let card: ContinueCard?
    let open: (SidebarRowID) -> Void

    static func == (a: ContinueCards, b: ContinueCards) -> Bool { a.card == b.card }

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
                Spacer(minLength: 0)
            }
        }
        .frame(height: SuggestionCard.height)
        .nwAnimation(.content, value: card?.id)
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
