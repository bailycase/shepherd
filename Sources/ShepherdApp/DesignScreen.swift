import SwiftUI
import ShepherdCore
import ShepherdProtocol
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
            DesignChatPane(vm: vm, model: model, thread: thread)
                .frame(width: AppLayout.designChatWidth)
        }
        .onChange(of: model.isVisible, initial: true) { vm.designVisibility(designID, visible: model.isVisible) }
        .onDisappear { vm.designVisibility(designID, visible: false) }
    }
}

/// The canvas: the design's boards, the tool, and the zoom. Comments come later, so the Comment
/// tool draws disabled.
struct DesignCanvasPane: View {
    @Bindable var screen: DesignScreenModel

    var body: some View {
        let host = screen.host
        let zoom = screen.viewport.zoom
        NWDesignCanvas(boards: screen.boards, viewport: $screen.viewport, tool: $screen.tool, disabledTools: [.comment],
                       select: { screen.select($0) }, resized: { screen.resized($0) }, zooming: { screen.setZooming($0) }) { board in
            if let host, let path = DesignPath(board.id) {
                DesignBoardSlot(host: host, path: path, zoom: zoom, content: board.content)
            }
        }
    }
}

/// The chat pane (DZCanvas): its tabs (Chat alone until Tweak and Comments are built), then the
/// design agent's thread, whose composer has attach and Send only.
struct DesignChatPane: View {
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
                    preview: PiSessionFile.previewLoader(sessionID: thread.piSessionID, cwd: pane.cwd),
                    commandKey: ThreadCommandCenter.key(local: agentID),
                    agentName: thread.agentName,
                    workingDirectory: pane.cwd,
                    designChat: true)
            }
        }
        .frame(maxHeight: .infinity)
        .background(Color.nw.bgWindow)
        .overlay(alignment: .leading) { NWHairline(.vertical) }
        .simultaneousGesture(TapGesture().onEnded { [vm] in vm.focusedPaneID = thread.paneID })
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
