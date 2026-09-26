import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import TerminalSurfaceKit

/// Real Ghostty surfaces side by side in one off-screen window. Pane focus is applied through
/// AppKit's first responder (SwiftUI focus cannot reach permanently mounted panes), so these
/// check the window's first responder directly. The window is never key: making a view first
/// responder in it never takes the user's focus.
@Suite("Terminal first responder", .serialized, .mainActorExclusive)
@MainActor
struct TerminalFirstResponderTests {
    @MainActor private struct Panes {
        let left = TerminalSurfaceModel()
        let right = TerminalSurfaceModel()
        let window = OffscreenWindow(size: CGSize(width: 800, height: 400))

        func show(leftFocused: Bool, rightFocused: Bool) {
            window.show(HStack(spacing: 0) {
                TerminalSurfaceView(model: left, isFocused: leftFocused)
                TerminalSurfaceView(model: right, isFocused: rightFocused)
            })
        }

        func surface(of model: TerminalSurfaceModel) -> NSView? {
            TerminalFirstResponder.view(ownedBy: model.viewState, in: window.window)
        }

        var firstResponder: NSResponder? { window.window.firstResponder }
    }

    @Test func eachMountedPaneIsFoundByItsOwnerNotItsPositionInTheTree() async throws {
        let panes = Panes()
        defer { panes.window.close() }

        panes.show(leftFocused: false, rightFocused: false)

        try await eventuallyOnMain("both surfaces to mount") { panes.surface(of: panes.left) != nil && panes.surface(of: panes.right) != nil }
        let left = try #require(panes.surface(of: panes.left)), right = try #require(panes.surface(of: panes.right))
        #expect(left !== right)
        #expect(TerminalFirstResponder.surfaceViews(in: panes.window.window.contentView).count == 2)
        #expect(TerminalFirstResponder.isSurfaceView(left), "libghostty's surface class is still \(TerminalFirstResponder.surfaceClassName)")
        #expect(TerminalSurfaceModel.model(for: left) === panes.left && TerminalSurfaceModel.model(for: right) === panes.right)
    }

    @Test func theFocusedPaneTakesTheKeyboardAndFocusFollowsTheFlag() async throws {
        let panes = Panes()
        defer { panes.window.close() }

        panes.show(leftFocused: true, rightFocused: false)
        try await eventuallyOnMain("the left surface to take the keyboard") {
            panes.firstResponder != nil && panes.firstResponder === panes.surface(of: panes.left)
        }

        panes.show(leftFocused: false, rightFocused: true)
        try await eventuallyOnMain("focus to move to the right surface") {
            panes.firstResponder != nil && panes.firstResponder === panes.surface(of: panes.right)
        }
    }

    /// Add to message reads the selection: Select All in a live surface reports what it holds,
    /// with where it starts and a line's height; a click that selects nothing reports nil.
    @Test func aSelectionIsReportedWithItsTextAndPlace() async throws {
        let panes = Panes()
        defer { panes.window.close() }
        var reported: [TerminalSurfaceModel.Selection?] = []
        panes.left.onSelectionChange = { reported.append($0) }
        panes.show(leftFocused: true, rightFocused: false)
        try await eventuallyOnMain("the left surface to mount") { panes.surface(of: panes.left) != nil }
        panes.left.feed(Data("FAIL payments/ledger 0.214s\r\n".utf8))
        let surface = try #require(panes.surface(of: panes.left))
        try await eventuallyOnMain("Select All to report the output") {
            surface.perform(#selector(NSResponder.selectAll(_:)), with: nil)
            return reported.last??.text.contains("FAIL payments/ledger") == true
        }
        let selection = try #require(reported.last ?? nil)
        #expect(selection.lineHeight > 0 && selection.origin.x >= 0 && selection.origin.y >= 0)
    }

    @Test func plainAndShiftSpaceReachTheTerminal() async throws {
        let panes = Panes()
        defer { panes.window.close() }
        var input = Data()
        panes.left.onInput = { input.append($0) }
        panes.show(leftFocused: true, rightFocused: false)
        try await eventuallyOnMain("the left surface to take the keyboard") {
            panes.firstResponder != nil && panes.firstResponder === panes.surface(of: panes.left)
        }
        let surface = try #require(panes.surface(of: panes.left))
        for modifiers: NSEvent.ModifierFlags in [[], .shift] {
            input.removeAll()
            let event = try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 1,
                windowNumber: panes.window.window.windowNumber, context: nil,
                characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49))
            let handled = surface.performKeyEquivalent(with: event)
            if modifiers.isEmpty {
                #expect(handled, "plain Space must not fall through to SwiftUI control activation")
                let other = try #require(panes.surface(of: panes.right))
                #expect(!other.performKeyEquivalent(with: event), "an unfocused terminal leaves Space alone")
            }
            if !handled { surface.keyDown(with: event) }
            try await eventuallyOnMain("space to reach the terminal with modifiers \(modifiers)") {
                input == Data(" ".utf8)
            }
        }
    }

    @Test func releasingFocusOnlyGivesUpThePanesOwnSurface() async throws {
        let panes = Panes()
        defer { panes.window.close() }
        panes.show(leftFocused: true, rightFocused: false)
        try await eventuallyOnMain("the left surface to take the keyboard") {
            panes.firstResponder != nil && panes.firstResponder === panes.surface(of: panes.left)
        }

        panes.right.releaseKeyboardFocus()
        #expect(panes.firstResponder === panes.surface(of: panes.left), "another pane's release leaves the keyboard alone")

        panes.left.releaseKeyboardFocus()
        #expect(panes.firstResponder !== panes.surface(of: panes.left))
    }
}
