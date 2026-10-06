import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

@Suite("Page and board mentions in a thread", .integrationTimeLimit)
struct PageMentionPickerFlowTests {
    @Test func pagesPickOneAttachmentAndBoardsStillDrillIntoElements() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pickingPageAndBoard() }
        }
    }

    @MainActor
    static func pickingPageAndBoard() async throws {
        AccessibilityNode.enable()
        let design = Design(id: DesignID(rawValue: "checkout"), name: "Checkout", createdAt: 1)
        let board = DesignPath("A.dc.html")!
        var index = DesignIndex(title: nil)
        index.pages = [.init(id: "flows", name: "Checkout flows")]
        index.boards[board] = .init(x: 0, y: 0, w: 1280, h: 800, title: "Funnel first", page: "flows")
        index.order = [board]
        let snapshot = DesignSnapshot(designID: design.id, revision: 23, index: index, boards: [:])
        let entries = try #require(DesignMentionCatalog.entries(design: design, snapshot: snapshot, sources: [:], system: nil))
        let catalog = DesignMentionCatalog(designs: [entries.design], pages: [design.id: entries.pages],
                                           boards: [design.id: entries.boards], elements: entries.elements)
        var thread: ComposerThread?
        let chips = DesignReferenceChips(agentID: AgentID(rawValue: "picker"), io: .init(catalog: { catalog }, attach: { reference in
            let label = reference.page != nil ? "Checkout › Page · Checkout flows" : "Checkout › Funnel first"
            _ = thread?.store.attach(reference: NativeAttachedReference(reference: reference.pinned(at: 23), label: label))
        }))
        let windowThread = ComposerThread(focused: true, designReferences: chips)
        thread = windowThread
        defer { windowThread.close() }
        try await windowThread.waitUntilReady()
        try await eventuallyOnMain("the composer to take the keyboard") { windowThread.focusedEditor?.isFieldEditor == true }
        func row(_ prefix: String) -> String? {
            windowThread.window.elements().compactMap(\.label).first { $0.hasPrefix(prefix) }
        }
        windowThread.type("Build @")
        try await eventuallyOnMain("the design to be listed") { row("Checkout, ") != nil }
        try windowThread.window.press(try #require(row("Checkout, ")))
        try await eventuallyOnMain("pages and boards to be listed") { row("Checkout flows, Page") != nil && row("Funnel first, ") != nil }
        let pageRow = try #require(row("Checkout flows, Page"))
        #expect(pageRow.contains("1 board") && pageRow.contains("attaches all boards"))
        #expect(ControlPress.undersized(windowThread.window.controls().filter { $0.label == pageRow }, minimum: .desktop).isEmpty)
        try windowThread.window.press(pageRow)
        try await eventuallyOnMain("the page to attach as one chip") { windowThread.store.attachedReferences.count == 1 }
        #expect(windowThread.store.attachedReferences[0].reference.page == "flows")
        #expect(windowThread.store.draft == "Build ")
        try await eventuallyOnMain("the mention to leave the field") { windowThread.focusedEditor?.string == "Build " }
        try await eventuallyOnMain("the page picker to close") { windowThread.window.element("Mention") == nil }

        windowThread.type("@Checkout › ")
        try await eventuallyOnMain("the board to be listed") { row("Funnel first, ") != nil }
        try windowThread.window.press(try #require(row("Funnel first, ")))
        try await eventuallyOnMain("the board's whole-board row") { row("Whole board, ") != nil }
        #expect(windowThread.store.attachedReferences.count == 1, "drilling into a board attaches nothing")
        try windowThread.window.press(try #require(row("Whole board, ")))
        try await eventuallyOnMain("the individual board to join the page") { windowThread.store.attachedReferences.count == 2 }
        #expect(windowThread.store.attachedReferences.map(\.reference.kind) == [.page, .board])
        #expect(windowThread.store.attachedReferences[1].reference.board == board && windowThread.store.attachedReferences[1].reference.page == nil)
        try ControlPress.perform("Remove", onLabelContaining: "Page · Checkout flows", under: windowThread.window.host)
        try await eventuallyOnMain("only the board to remain") { windowThread.store.attachedReferences.count == 1 }
        #expect(windowThread.store.attachedReferences[0].reference.kind == .board && windowThread.store.draft == "Build ")
    }
}
