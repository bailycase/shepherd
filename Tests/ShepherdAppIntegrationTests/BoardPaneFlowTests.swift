import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A board card's picture opens the board beside the thread (ThreadBoardPane): the pane's strip
/// gains Design, the tab shows the board and its zoom, and its Open in design acts, pressed as
/// VoiceOver presses them (`ControlPress`) in a process of its own.
@Suite("Board beside the thread", .mainActorExclusive)
@MainActor
struct BoardPaneFlowTests {
    @Test func aCardsBoardOpensInTheDesignTab() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.opening() }
        }
        expectScenarioCompleted(result)
    }

    static func opening() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let space = Fixture.space(path: app.dir.path)
        let agent = Fixture.agent("parent", in: space, piSession: SessionID())
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        let id = agent.agent.id
        vm.selectAgent(id)
        let window = OffscreenWindow(size: CGSize(width: 1500, height: 900), dark: true, RootView(vm: vm))
        defer { window.close() }
        let owner = SidePaneOwner.local(id)
        #expect(!vm.sidePaneTabs(for: owner).contains(.design), "no Design tab until a board is opened in it")

        let reference = try #require(DesignReference(designID: DesignID(rawValue: "gone"), board: DesignPath("A.dc.html"), revision: 13))
        let board = DesignReferenceChips.Board(design: "Checkout redesign", board: "A · Funnel first", meta: ["560 × 410", "revision 13"],
                                               size: CGSize(width: 560, height: 410), hasPicture: false, reference: reference)
        vm.showBoardBeside(owner, board)
        #expect(vm.isRightPaneOpen && vm.subagentInspector.tab(for: owner) == .design && vm.sidePaneTabs(for: owner).contains(.design))
        try await eventuallyOnMain("the Design tab to draw the board") {
            window.controls().contains { $0.label == "Design" } && window.controls().contains { $0.label == "Zoom in" }
        }
        // The design isn't on this Mac: Open in design says so rather than opening nothing.
        _ = try window.press("Open in design")
        #expect(vm.remoteActionError == "That design is no longer on this Mac.")
    }
}
