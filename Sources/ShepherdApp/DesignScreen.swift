import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

/// A design's screen (DZCanvas): the canvas beside the 420pt chat pane holding its agent's
/// thread. It is the design agent's layout, mounted and hidden like every agent's, so switching
/// to and from a design is a visibility flip; hidden, its canvas gives up its live views and its
/// thread stops polling. The header over it is `DesignToolbar`.
struct DesignLayoutView: View {
    var vm: ShepherdViewModel
    let model: AgentLayoutModel
    let designID: DesignID
    let thread: AgentLayoutModel.Thread

    var body: some View {
        let _ = NWRenderProbe.tick("layout.design")
        HStack(spacing: 0) {
            DesignCanvasPane(screen: vm.designScreen(designID), vm: vm, designName: vm.design(designID)?.name ?? "")
            DesignChatPane(vm: vm, screen: vm.designScreen(designID), model: model, thread: thread)
                .frame(width: AppLayout.designChatWidth)
        }
        .onChange(of: model.isVisible, initial: true) { vm.designVisibility(designID, visible: model.isVisible) }
        // The toolbar's chip draws the design's system from the catalog.
        .task { if !vm.designSystems.loaded { await vm.loadDesignSystems() } }
        .onDisappear { vm.designVisibility(designID, visible: false) }
        .onAppear { [vm] in
            // The chat's messages carry what the canvas shows as they leave.
            let screen = vm.designScreen(designID)
            vm.threadStores.store(for: thread.agentID).designContext = { [weak screen] in screen?.viewRecord }
        }
    }
}

/// The canvas: the design's boards and notes, the tool, the zoom, the selection ringed over the
/// boards, and the comments' pins. The Comment tool's click on an element opens the editor beside
/// it; a pin opens its thread. The board actions float over the board picked whole.
/// A presented board (Present, Play) covers it all.
struct DesignCanvasPane: View {
    @Bindable var screen: DesignScreenModel
    /// This Mac's view model, for the references' toast; nil for another host's design.
    var vm: ShepherdViewModel? = nil
    var designName = ""

    var body: some View {
        let host = screen.host
        let zoom = screen.viewport.zoom
        let referencing = screen.referenceActions != nil
        NWDesignCanvas(boards: screen.boards, viewport: $screen.viewport, tool: $screen.tool,
                       selection: screen.selectionRings, hover: screen.hoverRing,
                       pins: screen.pins, openPin: { screen.openThread($0) }, popoverAnchor: screen.popoverAnchor,
                       notes: screen.notes, actions: actions,
                       move: { screen.move($0) },
                       contextMenu: referencing ? { [designName] pick in
                           await screen.contextMenu(for: pick, designName: designName, keys: KeybindingsStore.shared)
                       } : nil,
                       pick: { screen.pick($0) }, point: { screen.pointer($0) },
                       resized: { screen.resized($0) }, zooming: { screen.setZooming($0) }) { board in
            if let host, let path = DesignPath(board.id) {
                DesignBoardSlot(host: host, path: path, zoom: zoom, content: board.content)
            }
        } popover: {
            DesignCommentPopover(screen: screen)
        }
        .overlay {
            if let vm { DesignReferenceToastLayer(vm: vm, designID: screen.designID) }
        }
        .background {
            if referencing {
                DesignCanvasKeys(active: screen.isActive && screen.presented == nil,
                                 chatHasDraft: { [vm, designID = screen.designID] in
                                     guard let vm, let agent = vm.design(designID)?.agentID else { return false }
                                     return vm.threadStores.existing(for: agent)?.hasDraft == true
                                 },
                                 implement: { screen.implementSelection(designName: designName) },
                                 copy: { screen.copySelectionReference(designName: designName) })
            }
        }
        .overlay {
            if let host, let path = screen.presented, let board = screen.snapshot?.index.boards[path] {
                let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                NWBoardPresentation(title: title?.isEmpty == false ? title! : path.stem,
                                    boardSize: CGSize(width: board.w, height: board.h), close: { screen.present(nil) }) { zoom in
                    DesignPresentedSlot(host: host, path: path, zoom: zoom, content: host.tokens[path] ?? 0)
                }
            }
        }
    }

    /// The board actions over the selection's board: Comment takes the Comment tool (the next
    /// element picked takes the comment), Tweak opens its tab, Variations and Duplicate act on
    /// the board, Implement… hands the selection to a thread (RefImplementMenu), and ••• plays an
    /// interactive one.
    private var actions: NWCanvasActions? {
        guard let path = screen.actionsBoard else { return nil }
        let screen = screen
        let designName = designName
        return NWCanvasActions(board: path.rawValue, actions: NWBoardActions.Actions(
            comment: { screen.tool = .comment },
            tweak: { screen.paneTab = .tweak },
            variations: { screen.askForVariations(of: path) },
            duplicate: { screen.duplicate(path) },
            play: screen.isInteractive(path) ? { screen.present(path) } : nil,
            implement: screen.referenceActions == nil ? nil : { screen.implementSelection(designName: designName) }))
    }
}

/// What opens beside a pin: the editor for a new comment (the review's comment editor), or a
/// comment's thread with its answers, Resolve and Reply….
struct DesignCommentPopover: View {
    @Bindable var screen: DesignScreenModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        if let note = screen.openThreadNote {
            // A thread's note (ThreadNoteCard): never a comment, never the design agent's.
            let actions = screen.referenceActions
            NWThreadNoteCard(thread: note.thread, age: nwCommentAge(since: note.createdAt), text: note.text,
                             from: DesignReferencePresentation.version(note.revision).map { "from \($0)" },
                             openThread: actions.flatMap { actions in
                                 actions.threadExists(note.agentID) ? {
                                     screen.closeComment()
                                     actions.openThread?(note.agentID)
                                 } : nil
                             },
                             resolve: { screen.resolveNote(note.id) })
        } else if let element = screen.draftElement {
            NWCommentEditor(text: $screen.draftText, isFocused: $editorFocused, placeholder: "Comment for the design agent",
                            context: "on \(nativeBoardName(element.board.rawValue))\(element.words.map { " · \($0)" } ?? "")",
                            onSave: { screen.submitComment() }, onCancel: { screen.closeComment() })
                .disabled(screen.sendingComment)
        } else if let comment = screen.openThread {
            let now = Date()
            NWCommentThread(
                author: "You", age: nwCommentAge(since: comment.createdAt, now: now),
                note: comment.detached ? "element changed" : nil, text: comment.text,
                entries: comment.replies.map { reply in
                    NWCommentEntry(id: reply.id.uuidString, author: reply.author == .agent ? "Design agent" : "You",
                                   age: nwCommentAge(since: reply.createdAt, now: now), text: reply.text)
                },
                reply: $screen.replyText,
                onResolve: { screen.resolve(comment.id) },
                onReply: { screen.sendReply() },
                onClose: { screen.closeComment() })
        }
    }
}

/// The chat pane (DZCanvas, DZTweak): its tabs, Chat (the design agent's thread, with the
/// standard composer at its compact size), Comments (the open comments' cards, counted with the threads' notes) and Tweak (the
/// selection's controls). The thread stays mounted under the other tabs, hidden, so switching tabs
/// never rebuilds it.
struct DesignChatPane: View {
    var vm: ShepherdViewModel
    @Bindable var screen: DesignScreenModel
    let model: AgentLayoutModel
    let thread: AgentLayoutModel.Thread

    /// Chat, Comments with its count, and Tweak where the canvas can write.
    static func tabs(open: Int, tweak: Bool) -> [NWDesignPaneTabs.Tab] {
        var tabs = [NWDesignPaneTabs.Tab(id: DesignPaneTab.chat.rawValue, title: "Chat"),
                    NWDesignPaneTabs.Tab(id: DesignPaneTab.comments.rawValue, title: "Comments", count: open > 0 ? open : nil)]
        if tweak { tabs.append(NWDesignPaneTabs.Tab(id: DesignPaneTab.tweak.rawValue, title: "Tweak")) }
        return tabs
    }

    var body: some View {
        let open = screen.commentsTabCount
        let tab = screen.paneTab == .tweak && screen.tweak == nil ? .chat : screen.paneTab
        let chat = tab == .chat
        VStack(spacing: 0) {
            NWDesignPaneTabs(Self.tabs(open: open, tweak: screen.tweak != nil), selection: tab.rawValue) { id in
                screen.paneTab = DesignPaneTab(rawValue: id) ?? .chat
            }
            ZStack {
                if let pane = model.tab.layout.leaf(withID: thread.paneID) {
                    let agentID = thread.agentID
                    AgentThreadPane(
                        session: vm.sessions.session(for: pane, in: model.tab),
                        store: vm.threadStores.store(for: agentID),
                        input: vm.threadStores.input(for: agentID),
                        active: model.isVisible,
                        isFocused: chat && model.focusedPaneID == thread.paneID,
                        request: { [vm] in try await vm.server.nativeThread(agentID: agentID, request: $0) },
                        preview: PiSessionFile.previewLoader(sessionID: thread.piSessionID, cwd: pane.cwd, sessionsRoot: vm.server.pi.sessionsRoot),
                        commandKey: ThreadCommandCenter.key(local: agentID),
                        agentName: thread.agentName,
                        workingDirectory: pane.cwd,
                        restartPi: { [vm] in vm.retryAgentStart(agentID, newConversation: $0) },
                        designChat: true)
                    .environment(\.designCommentCards, screen.commentCards)
                    .nwComposerSize(.compact)
                    .opacity(chat ? 1 : 0)
                    .allowsHitTesting(chat)
                    .accessibilityHidden(!chat)
                }
                if tab == .comments {
                    DesignCommentsList(cards: screen.openCards, resolve: { screen.resolve($0) }, open: { screen.revealComment($0) })
                        .background(Color.nw.bgWindow)
                }
                if let tweak = screen.tweak, tab == .tweak {
                    DesignTweakPane(model: tweak, target: screen.tweakTarget, piece: screen.pieceNote) { [vm] in
                        // "Ask the agent instead…": the chat, its composer taking the keyboard; the
                        // message it sends carries the selection as data.
                        screen.paneTab = .chat
                        vm.focusedPaneID = thread.paneID
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical) }
        .simultaneousGesture(TapGesture().onEnded { [vm] in if screen.paneTab == .chat { vm.focusedPaneID = thread.paneID } })
    }
}

/// The Comments tab: the open comments' cards, oldest first, one lazy row each. A card reveals
/// its board and opens its thread; its hover action resolves it without leaving the list.
struct DesignCommentsList: View {
    let cards: [DesignCommentCardValue]
    var resolve: ((UUID) -> Void)? = nil
    var hovering: UUID? = nil
    let open: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppLayout.designCommentsSpacing) {
                ForEach(cards) { card in
                    NWCommentCard(number: card.number, target: card.target, meta: card.meta, text: card.text,
                                  onOpen: { open(card.id) }, onResolve: resolve.map { action in { action(card.id) } },
                                  hovering: hovering == card.id)
                        .equatable()
                }
            }
            .padding(AppLayout.designCommentsPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The toolbar over a design (DZCanvas): the breadcrumb to it, its pages (a canvas with more than
/// one), its design system (the chip opens the system's page), Present and Export. Present shows the selected board focused (decision
/// 11: until Present mode is drawn); Export opens its sheet (DZExport).
struct DesignToolbar: View, Equatable {
    let name: String
    /// The design's system; nil while it is drawn in none (no chip: a design has no project).
    let system: String?
    /// The system's colors on its chip.
    var swatches: [DesignSystemPresentation.Swatch] = []
    /// Opens the system's page; nil while the system isn't one this host keeps.
    var openSystem: (() -> Void)?
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
    let designs: () -> Void
    /// The design's canvas: its pages and Present.
    var screen: DesignScreenModel?
    /// Opens the Export sheet; nil while the canvas hasn't read the design yet.
    var export: (() -> Void)?
    /// ••• (DesignToolbarMenu): Rename…, Duplicate, Export…, Show design system, Delete design….
    var menu: DesignMenu?
    var perform: (DesignMenuAction) -> Void = { _ in }

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.system == b.system && a.swatches == b.swatches && (a.openSystem == nil) == (b.openSystem == nil)
            && a.leadingInset == b.leadingInset && (a.showSidebar == nil) == (b.showSidebar == nil)
            && a.screen.map(ObjectIdentifier.init) == b.screen.map(ObjectIdentifier.init) && (a.export == nil) == (b.export == nil)
            && a.menu == b.menu
    }

    var body: some View {
        NWDesignHeader(name, style: .toolbar, leadingInset: leadingInset, sidebar: showSidebar,
                       sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar), designs: designs) {
            if let screen, screen.pages.count > 1 {
                NWPopupMenu(screen.pageName ?? "Pages") {
                    ForEach(screen.pages, id: \.id) { page in
                        Button {
                            screen.showPage(page.id)
                        } label: {
                            if page.id == screen.page { Label(page.name, systemImage: "checkmark") } else { Text(page.name) }
                        }
                    }
                }
                .accessibilityLabel("Page")
            }
            if let system {
                NWDesignSystemChip(system, colors: swatches.map { Color(light: $0.light, dark: $0.dark) }, action: openSystem)
            }
            Button { screen?.togglePresent() } label: { Image(systemName: "play.fill") }
                .buttonStyle(.nwIcon(isOn: screen?.presented != nil))
                .disabled(screen?.canPresent != true)
                .help("Present")
                .accessibilityLabel("Present")
            Button("Export", systemImage: "square.and.arrow.up") { export?() }
                .buttonStyle(.nw(.secondary))
                .disabled(export == nil)
            if let menu {
                NWDesignToolbarMore(label: "More for \(name)") { DesignMenuItems(menu: menu, perform: perform) }
            }
        }
    }
}
