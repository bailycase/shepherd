import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// Design references from the canvas (RefImplementMenu, RefImplementSheet, RefNoteBack):
/// Implement in a thread's sheet and branch, the selection's name, the right-click and ••• menus,
/// the canvas's chords, and a thread's note back.
@Suite("Design references from the canvas")
@MainActor
struct DesignReferenceCanvasTests {
    static let checkout = DesignID(rawValue: "checkout")
    static let a = DesignPath("A.dc.html")!
    static let card = DesignElementID(board: "A.dc.html", tid: 7, path: [1, 1, 0])!

    // MARK: Implement in a thread

    @Test(arguments: [
        ("card “Checkout funnel”", "agent/implement-card-checkout-funnel"),
        ("A · Funnel first", "agent/implement-funnel-first"),
        ("Café · Menü", "agent/implement-cafe-menu"),
        ("“”", "agent/implement-design"),
    ])
    func aNewThreadsBranchNamesThePiece(piece: String, branch: String) {
        #expect(ImplementBranch.name(for: piece) == branch)
    }

    @Test func theSheetSearchesItsThreadsAndSendsOnlyOnceThePieceIsPinned() throws {
        let selection = DesignReferenceSelection(designID: Self.checkout, designName: "Checkout funnel dashboard", board: Self.a,
                                                 boardTitle: "A · Funnel first", element: nil)
        let threads = [ImplementSheetModel.Thread(id: AgentID(rawValue: "t1"), name: "Checkout page polish", project: "dashboard-web", age: "4m"),
                       ImplementSheetModel.Thread(id: AgentID(rawValue: "t2"), name: "Funnel events backfill", project: "analytics-ingest", age: "1h")]
        let model = ImplementSheetModel(selection: selection, threads: threads, projects: [], project: nil, opensThread: true)
        #expect(model.thread == "t1" && model.mode == .existing && !model.canSend, "nothing goes before the piece is pinned")
        #expect(model.title == "Implement A · Funnel first" && model.crumbs == ["Checkout funnel dashboard"])
        model.query = "backfill"
        #expect(model.shownThreads.map(\.name) == ["Funnel events backfill"] && model.thread == "t2")
        model.prepared(PreparedDesignReference(reference: try #require(selection.reference).pinned(at: 23), design: "Checkout funnel dashboard",
                                               boardTitle: "A · Funnel first",
                                               outline: DesignReferenceOutline(kind: .board, styles: 42, tokens: 14, system: "acme-web")))
        #expect(model.canSend && model.version == "v23")
        model.mode = .new
        #expect(!model.canSend, "a new thread needs a project")
        #expect(ImplementSheetModel(selection: selection, threads: [], projects: [], project: nil, opensThread: false).mode == .new)
    }

    @Test func anElementIsNamedByItsNameAndWords() {
        let pick = DesignElementPick(board: Self.a, id: Self.card, rect: .zero, kind: .shape, label: "Checkout funnel",
                                     tag: "card · Checkout funnel", words: "card")
        var selection = DesignReferenceSelection(designID: Self.checkout, designName: "Checkout", board: Self.a, boardTitle: "A · Funnel first",
                                                 element: pick)
        #expect(selection.piece == "card “Checkout funnel”" && selection.crumbs == ["Checkout", "A · Funnel first", "card “Checkout funnel”"])
        selection.element = nil
        #expect(selection.piece == "A · Funnel first")
        selection.board = nil
        #expect(selection.piece == "Checkout" && selection.reference?.kind == .design)
    }

    // MARK: The canvas

    private func screen(implemented: @escaping (DesignReferenceSelection) -> Void = { _ in },
                        copied: @escaping (DesignReferenceSelection) -> Void = { _ in },
                        notes: [DesignThreadNote] = []) async throws -> DesignScreenModel {
        let index = try DesignIndex.decode(Data("""
        {"v":3,"boards":{"A.dc.html":{"x":0,"y":0,"w":1280,"h":800,"title":"A · Funnel first"}},"order":["A.dc.html"]}
        """.utf8))
        let snapshot = DesignSnapshot(designID: Self.checkout, revision: 1, index: index, boards: [Self.a: "sha"])
        let screen = DesignScreenModel(designID: Self.checkout, host: nil, snapshot: { _ in snapshot }, source: { _, _ in "" },
                                       actions: DesignCanvasActions(snapshot: { _ in snapshot }, duplicate: { _, _, _ in throw CommandFailure("canvas", "no") },
                                                                    updateIndex: { _, _, _ in throw CommandFailure("canvas", "no") },
                                                                    ask: { _, _, _ in true }, report: { _ in }))
        screen.referenceActions = DesignReferenceCanvasActions(implement: implemented, copy: copied, notes: { _ in notes },
                                                               threadExists: { _ in true })
        await screen.refresh()
        return screen
    }

    @Test func theRightClickMenuHandsTheSelectionToAThread() async throws {
        var implemented: [DesignReferenceSelection] = []
        let screen = try await screen(implemented: { implemented.append($0) })
        let keys = KeybindingsStore(store: ScratchDefaults())
        let items = await screen.contextMenu(for: NWCanvasPick(board: Self.a.rawValue, point: nil, extending: false), designName: "Checkout", keys: keys)
        #expect(screen.picks.map(\.board) == [Self.a], "a right-click picks what it landed on")
        #expect(items.filter { !$0.isDivider }.map(\.title) == ["Comment", "Implement in a Thread…", "Copy Reference", "Duplicate"])
        let implement = try #require(items.first { $0.id == "implement" })
        #expect(implement.key == "\r" && implement.command && !implement.shift)
        let copy = try #require(items.first { $0.id == "copy" })
        #expect(copy.key == "c" && copy.command && copy.shift)
        implement.action()
        #expect(implemented.map(\.board) == [Self.a])

        let empty = await screen.contextMenu(for: NWCanvasPick(board: nil, point: nil, extending: false), designName: "Checkout", keys: keys)
        #expect(empty.map(\.title) == ["Implement Checkout…", "Copy Reference"], "the empty canvas offers the whole design")
    }

    @Test func theDesignsMenuNamesTheSelectionInItsToolbarOnly() {
        let toolbar = DesignMenu.design(.toolbar, hasSystem: true, reference: "card “Checkout funnel”")
        #expect(toolbar.sections.count == 3 && toolbar.sections[1].map(\.title) == ["Implement card “Checkout funnel”…", "Copy Reference"])
        #expect(toolbar.sections[1].map(\.action) == [.implement, .copyReference])
        #expect(DesignMenu.design(.card, hasSystem: true, reference: "x").items.allSatisfy { $0.action != .implement })
        #expect(DesignMenu.design(.toolbar, hasSystem: false, remote: "build-01", reference: "x").items.allSatisfy { $0.action != .implement },
                "another host's design waits for remote references")
    }

    @Test func aThreadsNoteIsItsOwnPinAndOpensItsCard() async throws {
        let note = DesignThreadNote(agentID: AgentID(rawValue: "t1"), thread: "Checkout page polish", board: Self.a, element: nil,
                                    revision: 23, text: "Implemented in #142.", createdAt: 1_000)
        let screen = try await screen(notes: [note])
        let pin = try #require(screen.pins.first)
        #expect(pin.style == .threadNote("Checkout page polish") && pin.rect == CGRect(x: 0, y: 0, width: 1280, height: 800),
                "a board's note sits on the board's corner")
        screen.openThread(pin.id)
        #expect(screen.openThreadNote == note && screen.popoverAnchor?.id == pin.id)
        screen.closeComment()
        #expect(screen.openThreadNote == nil)
        screen.applyNotes([])
        #expect(screen.pins.isEmpty)
    }

    @Test func textInputKeepsTheCanvasChordsForItself() {
        #expect(DesignCanvasKeys.Watcher.textHasKeyboard(NSTextView()))
        #expect(!DesignCanvasKeys.Watcher.textHasKeyboard(NSView()))
        #expect(!DesignCanvasKeys.Watcher.textHasKeyboard(nil))
    }

    /// Clicking the canvas leaves the chat's composer the keyboard, so an empty one lets ⌘↩ and
    /// ⇧⌘C through; words in it, or a draft the chat holds, keep them.
    @Test(arguments: [
        ("", false, false),
        ("Make the bars thinner", false, true),
        ("", true, true),
    ])
    func anEmptyFieldLetsTheCanvasChordsThrough(_ text: String, _ draft: Bool, _ keeps: Bool) {
        let field = NSTextView()
        field.string = text
        #expect(DesignCanvasKeys.Watcher.textHoldsKeyboard(field, chatHasDraft: { draft }) == keeps)
        #expect(!DesignCanvasKeys.Watcher.textHoldsKeyboard(NSView(), chatHasDraft: { true }))
    }
}
