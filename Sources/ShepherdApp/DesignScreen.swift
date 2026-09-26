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
            DesignCanvasPane(screen: vm.designScreen(designID))
            DesignChatPane(vm: vm, screen: vm.designScreen(designID), model: model, thread: thread)
                .frame(width: AppLayout.designChatWidth)
        }
        .onChange(of: model.isVisible, initial: true) { vm.designVisibility(designID, visible: model.isVisible) }
        .onDisappear { vm.designVisibility(designID, visible: false) }
        .onAppear { [vm] in
            // The chat's messages carry what the canvas shows as they leave.
            let screen = vm.designScreen(designID)
            vm.threadStores.store(for: thread.agentID).designContext = { [weak screen] in screen?.viewRecord }
        }
    }
}

/// The canvas: the design's boards, the tool, the zoom, the selection ringed over the boards, and
/// the comments' pins. The Comment tool's click on an element opens the editor beside it; a pin
/// opens its thread.
struct DesignCanvasPane: View {
    @Bindable var screen: DesignScreenModel

    var body: some View {
        let host = screen.host
        let zoom = screen.viewport.zoom
        NWDesignCanvas(boards: screen.boards, viewport: $screen.viewport, tool: $screen.tool,
                       selection: screen.selectionRings, hover: screen.hoverRing,
                       pins: screen.pins, openPin: { screen.openThread($0) }, popoverAnchor: screen.popoverAnchor,
                       pick: { screen.pick($0) }, point: { screen.pointer($0) },
                       resized: { screen.resized($0) }, zooming: { screen.setZooming($0) }) { board in
            if let host, let path = DesignPath(board.id) {
                DesignBoardSlot(host: host, path: path, zoom: zoom, content: board.content)
            }
        } popover: {
            DesignCommentPopover(screen: screen)
        }
    }
}

/// What opens beside a pin: the editor for a new comment (the review's comment editor), or a
/// comment's thread with its answers, Resolve and Reply….
struct DesignCommentPopover: View {
    @Bindable var screen: DesignScreenModel
    @FocusState private var editorFocused: Bool

    var body: some View {
        if let element = screen.draftElement {
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

/// The chat pane (DZCanvas): its tabs (Chat, and Comments with the open comments' count; Tweak
/// comes with its own change), then the design agent's thread, whose composer has attach and Send
/// only, or the open comments' cards. The thread stays mounted under the Comments tab.
struct DesignChatPane: View {
    var vm: ShepherdViewModel
    @Bindable var screen: DesignScreenModel
    let model: AgentLayoutModel
    let thread: AgentLayoutModel.Thread

    var body: some View {
        let open = screen.openComments.count
        let commentsShown = screen.paneTab == .comments
        VStack(spacing: 0) {
            NWDesignPaneTabs([NWDesignPaneTabs.Tab(id: DesignPaneTab.chat.rawValue, title: "Chat"),
                              NWDesignPaneTabs.Tab(id: DesignPaneTab.comments.rawValue, title: "Comments", count: open > 0 ? open : nil)],
                             selection: screen.paneTab.rawValue) { id in
                if let tab = DesignPaneTab(rawValue: id) { screen.paneTab = tab }
            }
            ZStack {
                if let pane = model.tab.layout.leaf(withID: thread.paneID) {
                    let agentID = thread.agentID
                    AgentThreadPane(
                        session: vm.sessions.session(for: pane, in: model.tab),
                        store: vm.threadStores.store(for: agentID),
                        active: model.isVisible,
                        isFocused: model.focusedPaneID == thread.paneID,
                        request: { [vm] in try await vm.server.nativeThread(agentID: agentID, request: $0) },
                        preview: PiSessionFile.previewLoader(sessionID: thread.piSessionID, cwd: pane.cwd),
                        commandKey: ThreadCommandCenter.key(local: agentID),
                        agentName: thread.agentName,
                        workingDirectory: pane.cwd,
                        designChat: true)
                        .environment(\.designCommentCards, screen.commentCards)
                        .opacity(commentsShown ? 0 : 1)
                        .allowsHitTesting(!commentsShown)
                        .accessibilityHidden(commentsShown)
                }
                if commentsShown {
                    DesignCommentsList(cards: screen.openCards) { screen.openThread($0.uuidString) }
                        .background(Color.nw.bgWindow)
                }
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical) }
        .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = thread.paneID })
    }
}

/// The Comments tab: the open comments' cards, oldest first, one lazy row each. A card opens its
/// thread on the canvas.
struct DesignCommentsList: View {
    let cards: [DesignCommentCardValue]
    let open: (UUID) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: AppLayout.designCommentsSpacing) {
                ForEach(cards) { card in
                    Button { open(card.id) } label: {
                        NWCommentCard(number: card.number, target: card.target, meta: card.meta, text: card.text)
                            .equatable()
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(AppLayout.designCommentsPadding)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// The toolbar over a design (DZCanvas): the breadcrumb to it, its design system, Present and
/// Export. Present waits for its own board and Export for its sheet, so both draw disabled.
struct DesignToolbar: View, Equatable {
    let name: String
    let system: String
    var leadingInset: CGFloat = 0
    var showSidebar: (() -> Void)?
    let designs: () -> Void

    nonisolated static func == (a: Self, b: Self) -> Bool {
        a.name == b.name && a.system == b.system && a.leadingInset == b.leadingInset && (a.showSidebar == nil) == (b.showSidebar == nil)
    }

    var body: some View {
        NWDesignHeader(name, style: .toolbar, leadingInset: leadingInset, sidebar: showSidebar,
                       sidebarShortcut: KeybindingsStore.shared.display(.toggleSidebar), designs: designs) {
            NWDesignSystemChip(system)
            Button {} label: { Image(systemName: "play.fill") }
                .buttonStyle(.nwIcon)
                .disabled(true)
                .help("Present")
                .accessibilityLabel("Present")
            Button("Export", systemImage: "square.and.arrow.up") {}
                .buttonStyle(.nw(.secondary))
                .disabled(true)
        }
    }
}
