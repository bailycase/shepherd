import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Design references from the canvas (RefImplementMenu, RefImplementSheet, RefImplementBoard,
/// RefSentStay, RefCopied, RefNoteBack), the chip a real send leaves in the thread, and
/// DesignRefStates' specimens. A real server and stub pi; boards drawn off screen and shown from
/// their snapshots.
extension DesignPreviewTests {
    /// The canvas boards' window.
    static let referenceWindow = CGSize(width: 1600, height: 1000)

    /// The design workspace, with the threads the sheet lists: a live one in dashboard-web (a git
    /// checkout, so a new thread starts on a worktree), and two more.
    func referenceWorkspace() async throws -> (workspace: PreviewWorkspace, checkout: Design, agent: Agent, thread: Agent) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm
        vm.designNetwork = .none
        vm.designLiveCap = 0
        vm.copyToPasteboard = { _ in }
        let repo = try makeScratchRepo()
        let web = Space(name: "dashboard-web", path: repo.path)
        let ingest = Space(name: "analytics-ingest", path: workspace.dir.path)
        let now = Date().timeIntervalSince1970 * 1000
        var (thread, threadTab) = try await workspace.agent("Checkout page polish", in: web, order: 0, live: true, cwd: repo.path)
        thread.lastActiveAt = now - 4 * 60_000
        var (backfill, backfillTab) = try await workspace.agent("Funnel events backfill", in: ingest, order: 0)
        backfill.lastActiveAt = now - 3_600_000
        var (csv, csvTab) = try await workspace.agent("Fix CSV export encoding", in: web, order: 1)
        csv.lastActiveAt = now - 30 * 3_600_000
        let designs = Space.designs()
        var (agent, tab) = try await workspace.agent("Checkout funnel dashboard", in: designs, order: 0, live: true, cwd: workspace.dir.path)
        let checkout = Design(name: "Checkout funnel dashboard", agentID: agent.id, createdAt: 1_000)
        agent.designID = checkout.id
        try await workspace.seed(ShepherdState(spaces: [web, ingest, designs], tabs: [threadTab, backfillTab, csvTab, tab],
                                               agents: [thread, backfill, csv, agent]))
        _ = try await workspace.server.createDesign(checkout)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: checkout.id, on: workspace.server, perRow: 3)
        let server = workspace.server
        try await eventuallyOnMain("the design to load") { vm.state.designs.count == 1 && vm.state == server.state }
        return (workspace, checkout, agent, thread)
    }

    /// A's first step card, where the fixture board draws it.
    func stepCard() throws -> DesignElementPick {
        let a = try #require(DesignPath("A.dc.html"))
        return DesignElementPick(board: a, id: try #require(DesignElementID(board: a.viewName, tid: 7, path: [1, 1, 0])),
                                 rect: CGRect(x: 32, y: 78, width: 396, height: 80), kind: .shape, label: "Step 1 90%",
                                 tag: "card · Step 1 90%", words: "card")
    }

    /// DesignRefStates: every chip state (another host's and an offline host's among them), the
    /// preview, the @ picker's stages, the board actions, the sheets, the toasts, the agent's line
    /// and the thread's pin.
    @Test func designReferenceStates() async throws {
        try await Preview.render("design-reference-states", size: CGSize(width: 1260, height: 2180)) {
            NWDesignReferenceSpecimens()
                .padding(NW.Space.xxl)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.nw.bgWindow)
        }
    }

    /// RefImplementMenu: an element selected on A, the board actions with Implement…, and the
    /// right-click and ••• menus beside it (drawn as the native menus list them).
    @Test func designReferenceMenu() async throws {
        let (workspace, checkout, _, _) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        let card = try stepCard()
        screen.setSelection([.init(board: card.board, element: card)])
        #expect(screen.actionsBoard == card.board, "an element's board wears the actions")
        try await Preview.render("app-window-design-ref-menu", size: Self.referenceWindow, ready: {
            if screen.snapshot != nil, screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return screen.viewport == Self.closeOnA && screen.isDrawn
        }) {
            RootView(vm: vm)
        }
        let items = screen.menuItems(designName: checkout.name, keys: vm.keybindings)
        try await Preview.render("design-ref-menus", size: CGSize(width: 720, height: 300)) {
            HStack(alignment: .top, spacing: NW.Space.xl) {
                CanvasMenuLookalike(items: items)
                CanvasMenuLookalike(items: [], menu: vm.designMenu(.local(checkout.id), context: .toolbar))
            }
            .padding(NW.Space.xl)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
        #expect(items.filter { !$0.isDivider }.map(\.title) == ["Comment", "Tweak", "Implement in a Thread…", "Copy Reference", "Duplicate"])
    }

    /// RefImplementSheet: Implement the step card into an existing thread, with a message; the
    /// footer says what goes.
    @Test func designReferenceSheet() async throws {
        let (workspace, checkout, _, thread) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        let card = try stepCard()
        screen.setSelection([.init(board: card.board, element: card)])
        screen.implementSelection(designName: checkout.name)
        let model = try #require(vm.implementSheet)
        model.message = "Build this in the checkout page. Keep our existing table component for the steps."
        model.opensThread = true
        try await Preview.render("app-window-design-ref-sheet", size: Self.referenceWindow, ready: {
            if screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return model.prepared != nil && screen.isDrawn
        }) {
            RootView(vm: vm)
        }
        #expect(model.thread == thread.id.rawValue, "the most recently active thread is picked")
        #expect(model.shownThreads.map(\.name) == ["Checkout page polish", "Funnel events backfill", "Fix CSV export encoding"])
    }

    /// RefImplementBoard: A whole, into a new thread in dashboard-web on a new worktree.
    @Test func designReferenceSheetNewThread() async throws {
        let (workspace, checkout, _, _) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        screen.select("A.dc.html")
        screen.implementSelection(designName: checkout.name)
        let model = try #require(vm.implementSheet)
        model.mode = .new
        model.opensThread = false
        try await Preview.render("app-window-design-ref-sheet-board", size: Self.referenceWindow, ready: {
            model.prepared != nil && screen.isDrawn
        }) {
            RootView(vm: vm)
        }
        #expect(model.chosenProject?.name == "dashboard-web" && model.chosenProject?.isRepo == true)
        #expect(model.branch == "agent/implement-funnel-first")
    }

    /// RefSentStay: sent with "Open the thread after sending" off: the canvas stays, and the toast
    /// offers the thread. The thread got the message with its chip.
    @Test func designReferenceSentStaying() async throws {
        let (workspace, checkout, _, thread) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        let store = vm.threadStores.store(for: thread.id)
        let server = workspace.server, id = thread.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        let card = try stepCard()
        screen.setSelection([.init(board: card.board, element: card)])
        screen.implementSelection(designName: checkout.name)
        let model = try #require(vm.implementSheet)
        try await eventuallyOnMain("the piece to be pinned") { model.prepared != nil }
        model.message = "Build this in the checkout page."
        model.opensThread = false
        vm.sendImplementSheet(model)
        try await eventuallyOnMain("the send", timeout: .seconds(60)) { vm.implementSheet == nil && vm.referenceToast != nil }
        #expect(vm.selectedAgentID == checkout.agentID, "the canvas stays")
        #expect(!vm.settings.implementOpensThread, "the choice is remembered")
        try await Preview.render("app-window-design-ref-sent", size: Self.referenceWindow, ready: {
            if screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return screen.isDrawn
        }) {
            RootView(vm: vm)
        }
        try await eventuallyOnMain("pi to read the reference's record") {
            store.snapshot?.messages.contains { $0.role == "user" && ($0.blocks.first.map { DesignReferenceFence.opens($0.text) } ?? false || $0.designReferences != nil) } == true
        }
    }

    /// RefCopied: Copy reference's toast on the canvas.
    @Test func designReferenceCopied() async throws {
        let (workspace, checkout, _, _) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        var copied: [String] = []
        vm.copyToPasteboard = { copied.append($0) }
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        let card = try stepCard()
        screen.setSelection([.init(board: card.board, element: card)])
        screen.copySelectionReference(designName: checkout.name)
        try await eventuallyOnMain("the toast") { vm.referenceToast != nil }
        #expect(copied.count == 1 && DesignReference(string: copied[0])?.element == card.id)
        try await Preview.render("app-window-design-ref-copied", size: Self.referenceWindow, ready: {
            if screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return screen.isDrawn
        }) {
            RootView(vm: vm)
        }
    }

    /// RefNoteBack: a thread's note on the step card, its blue pin and its card with Open thread
    /// and Resolve.
    @Test func designReferenceNoteBack() async throws {
        let (workspace, checkout, _, thread) = try await referenceWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.selectSidebarRow(.design(checkout.id))
        let screen = vm.designScreen(checkout.id)
        await screen.refresh()
        let card = try stepCard()
        let note = DesignThreadNote(agentID: thread.id, thread: thread.name, board: card.board, element: card.id, label: "Step 1 90%",
                                    revision: 23, text: "Implemented in #142 on `agent/checkout-funnel`. Bars use `--accent`; counts use the existing table cell.",
                                    createdAt: Date().timeIntervalSince1970 * 1000 - 12 * 60_000)
        // The design keeps it beside its project, as design_note leaves it.
        let folder = try #require(workspace.server.designs.folder(for: checkout.id))
        try JSONEncoder().encode(DesignThreadNotes(notes: [note])).write(to: folder.appendingPathComponent("thread-notes.json"))
        // A comment on the same card beside it, as RefNoteBack draws: the Comments tab counts both.
        _ = try await workspace.server.addDesignComment(checkout.id, draft: DesignCommentDraft(
            board: card.board, tid: card.id.tid, path: card.id.path, target: "Step 1",
            rect: DesignCommentRect(x: card.rect.minX, y: card.rect.minY, w: card.rect.width, h: card.rect.height),
            text: "Show the absolute counts next to the percentages."))
        await screen.refresh()
        await screen.refreshNotes()
        screen.noteRects[note.id] = card.rect
        #expect(screen.commentsTabCount == 2)
        screen.openThread(DesignScreenModel.notePinID(note.id))
        #expect(screen.openThreadNote?.id == note.id)
        #expect(screen.pins.contains { $0.style == .threadNote(thread.name) })
        try await Preview.render("app-window-design-ref-note", size: Self.referenceWindow, ready: {
            if screen.viewport != Self.closeOnA { screen.viewport = Self.closeOnA }
            return screen.isDrawn
        }) {
            RootView(vm: vm)
        }
    }
}

/// A native menu's items as the boards draw them, for a capture (a real menu is its own window).
private struct CanvasMenuLookalike: View {
    let items: [NWCanvasMenuItem]
    var menu: DesignMenu? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let menu {
                ForEach(Array(menu.sections.enumerated()), id: \.offset) { index, section in
                    if index > 0 { NWHairline().padding(.vertical, NW.Space.xs) }
                    ForEach(section) { item in row(item.title, symbol: item.symbol, chord: nil, destructive: item.destructive) }
                }
            } else {
                ForEach(items) { item in
                    if item.isDivider {
                        NWHairline().padding(.vertical, NW.Space.xs)
                    } else {
                        row(item.title, symbol: item.symbol ?? "circle", chord: chord(item), destructive: item.destructive)
                    }
                }
            }
        }
        .padding(NW.Space.s)
        .frame(width: 300, alignment: .leading)
        .nwPopover(radius: NW.Radius.l)
    }

    private func chord(_ item: NWCanvasMenuItem) -> String? {
        guard let key = item.key else { return nil }
        return (item.shift ? "⇧" : "") + (item.command ? "⌘" : "") + (key == "\r" ? "↩" : key.uppercased())
    }

    private func row(_ title: String, symbol: String, chord: String?, destructive: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.nwSans(13)).foregroundStyle(destructive ? Color.nw.failed : Color.nw.textSecondary).frame(width: 13)
            Text(title).font(.nwSans(12.5)).foregroundStyle(destructive ? Color.nw.failed : Color.nw.textPrimary)
            Spacer(minLength: NW.Space.m)
            if let chord { Text(chord).font(.nwMono(11)).foregroundStyle(Color.nw.textTertiary) }
        }
        .frame(minHeight: NW.Height.controlM)
        .padding(.horizontal, NW.Space.m)
    }
}
