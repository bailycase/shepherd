import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Jump to a board (JumpInContext) against a real server, a live stub design agent and real
/// board views: the command palette's chord opens the card over a design and the palette
/// anywhere else, the toolbar's field opens it too, and a row pressed through accessibility
/// shows its board picked and in view, or opens another design.
@Suite("Design jump flow", .mainActorExclusive)
@MainActor
struct DesignJumpFlowTests {
    private struct Opened {
        let app: AppHarness
        let vm: ShepherdViewModel
        let window: OffscreenWindow
        let design: Design
        let other: Design
        let thread: AgentFixture

        /// The design's toolbar over an empty column, with the card's overlay over both, as
        /// RootView arranges them: what the presses reach, beside the canvas's own window.
        @MainActor func chrome() -> OffscreenWindow {
            OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true,
                            VStack(spacing: 0) { WorkspaceHeaderView(vm: vm); Spacer() }.overlay { DesignJumpOverlay(vm: vm) })
        }
    }

    /// The checkout design on screen in a window, beside a plain thread and a second design.
    private static func open() async throws -> Opened {
        AccessibilityNode.enable()
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        var drawer = try await app.liveAgent("Checkout", in: space, order: 0)
        let thread = try await app.liveAgent("thread", in: space, order: 1)
        let design = Design(name: "Checkout", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [drawer, thread]))
        vm.designNetwork = .none
        _ = try await app.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: app.server, perRow: 3)
        let other = Design(name: "Onboarding", createdAt: 500)
        _ = try await app.server.createDesign(other)
        try await DesignFixtures.draw([DesignFixtures.checkout[3]], in: other.id, on: app.server)
        vm.selectAgent(drawer.agent.id)
        let window = OffscreenWindow(size: CGSize(width: 1400, height: 900), dark: true, WorkspaceView(vm: vm))
        let screen = vm.designScreen(design.id)
        try await eventuallyOnMain("the canvas to draw", timeout: .seconds(60)) {
            window.layout()
            return screen.isDrawn && !screen.visibleBoards.isEmpty && vm.state.designs.count == 2
        }
        return Opened(app: app, vm: vm, window: window, design: design, other: other, thread: thread)
    }

    @Test func thePalettesChordJumpsOverADesignAndOpensThePaletteElsewhere() async throws {
        let opened = try await Self.open()
        defer { opened.app.stop(); opened.window.close() }
        let vm = opened.vm
        vm.toggleCommandPaletteOrJump()
        #expect(vm.designJump?.design == opened.design.id)
        #expect(!vm.showCommandPalette, "over a design the chord never shows the palette")
        vm.toggleCommandPaletteOrJump()
        #expect(vm.designJump == nil, "pressed again it closes the card")

        vm.selectAgent(opened.thread.agent.id)
        vm.toggleCommandPaletteOrJump()
        #expect(vm.showCommandPalette && vm.designJump == nil, "on a thread it is the palette")
        vm.toggleCommandPaletteOrJump()
        #expect(!vm.showCommandPalette)
    }

    /// The toolbar's field opens the card; a board's row, pressed, picks that board and brings it
    /// into view, and it heads Recent next time with "this board" on it. A click on the canvas
    /// opens nothing.
    @Test func theFieldOpensTheCardAndARowShowsItsBoard() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.fieldAndRow() }
        }
    }

    private static func fieldAndRow() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let vm = opened.vm
        let screen = vm.designScreen(opened.design.id)
        screen.select("A.dc.html")
        let chrome = opened.chrome()
        defer { chrome.close() }
        try await eventuallyOnMain("the toolbar's field") { chrome.controls().contains { $0.label == "Jump to a board" } }
        let field = try chrome.press("Jump to a board")
        #expect(ControlPress.undersized([field], minimum: .desktop).isEmpty, "the field's hit area is \(String(describing: field.frame))")
        let model = try #require(vm.designJump)
        #expect(model.rows.allSatisfy { $0.section == .otherBoards }, "a click on the canvas picks a board, it doesn't open one")
        #expect(model.rows.first { $0.tag == "this board" }?.title == "A · Funnel first")

        try await eventuallyOnMain("the card's rows") { chrome.controls().contains { $0.label == "A · phone, 390 × 844" } }
        let row = try chrome.press("A · phone, 390 × 844")
        #expect(ControlPress.undersized([row], minimum: .desktop).isEmpty)
        #expect(vm.designJump == nil, "a jump closes the card")
        let phone = try #require(DesignPath("A-phone.dc.html"))
        try await eventuallyOnMain("the phone board picked and in view") {
            opened.window.layout()
            return screen.focusBoard == phone && screen.visibleBoards.contains(phone)
        }

        vm.openDesignJump(opened.design.id)
        let again = try #require(vm.designJump)
        #expect(again.rows.first?.title == "A · phone" && again.rows.first?.section == .recent, "a jump heads Recent")
        #expect(again.rows.first?.tag == "this board")
        #expect(again.highlight == 1, "the highlight skips the board on screen")
    }

    /// All designs lists the other design; its row opens it.
    @Test func allDesignsOpensAnotherDesign() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.allDesigns() }
        }
    }

    private static func allDesigns() async throws {
        let opened = try await open()
        defer { opened.app.stop(); opened.window.close() }
        let vm = opened.vm
        let chrome = opened.chrome()
        defer { chrome.close() }
        vm.openDesignJump(opened.design.id)
        try await eventuallyOnMain("the scope pills") { chrome.controls().contains { $0.label == "All designs" } }
        let pill = try chrome.press("All designs", in: "Scope")
        #expect(ControlPress.undersized([pill], minimum: .desktop).isEmpty, "the pill's hit area is \(String(describing: pill.frame))")
        let model = try #require(vm.designJump)
        #expect(model.scope == .allDesigns)
        #expect(Set(model.rows.map(\.title)) == ["Checkout", "Onboarding"])
        model.query = "onb"
        #expect(model.rows.map(\.title) == ["Onboarding"])
        vm.runDesignJump(try #require(model.highlighted))
        try await eventuallyOnMain("the other design to open") { vm.shownDesign?.id == opened.other.id }
    }
}
