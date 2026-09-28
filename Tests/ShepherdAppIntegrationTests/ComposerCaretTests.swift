import AppKit
import Foundation
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The composer's field with its selection bound (⌫ at the start of the words takes the last
/// chip back): a draft replaced from outside the field (a mention chosen, a command picked)
/// still leaves the caret at its end, as it did before the selection was bound.
@Suite("Composer caret", .mainActorExclusive)
@MainActor
struct ComposerCaretTests {
    /// Exercise the native command, not synthetic keyboard events delivered to the user's app.
    @Test(arguments: [0, 5])
    func aNativeNewlineReplacesTheSelectionAndKeepsTheDraftUnsent(selectionLength: Int) async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        let store = vm.threadStores.store(for: agents[0].agent.id)
        store.draft = "beforeafter"
        var found: NSTextView?
        try await eventuallyOnMain("the composer field to mount") {
            ListPerf.settle(window)
            found = window.window.firstResponder as? NSTextView
            return found?.string == "beforeafter"
        }
        let editor = try #require(found)
        let sent = store.sentCount
        editor.setSelectedRange(NSRange(location: 6, length: selectionLength))

        editor.insertNewlineIgnoringFieldEditor(nil)

        let expected = selectionLength == 0 ? "before\nafter" : "before\n"
        try await eventuallyOnMain("native insertion to update the draft") {
            ListPerf.settle(window)
            return store.draft == expected
        }
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        #expect(store.sentCount == sent)
    }

    @Test func aDraftReplacedFromOutsideTheFieldLeavesTheCaretAtItsEnd() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        vm.focusedPaneID = agents[0].piPane.id
        var found: NSTextView?
        try await eventuallyOnMain("the composer to take the keyboard") {
            ListPerf.settle(window)
            found = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
            return found != nil
        }
        let editor = try #require(found)
        let store = vm.threadStores.store(for: agents[0].agent.id)

        editor.insertText("Match the funnel in @fun", replacementRange: NSRange(location: NSNotFound, length: 0))
        ListPerf.settle(window)
        #expect(store.draft == "Match the funnel in @fun")
        #expect(editor.selectedRange() == NSRange(location: 24, length: 0))

        let chosen = "Match the funnel in @Checkout funnel dashboard › A · Funnel first › "
        store.draft = chosen
        try await eventuallyOnMain("the field to show the chosen words") {
            ListPerf.settle(window)
            return editor.string == chosen
        }
        #expect(editor.selectedRange() == NSRange(location: (chosen as NSString).length, length: 0))

        // The caret moved to the start, then the draft shortened under it: still a caret the field can hold.
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        ListPerf.settle(window)
        store.draft = "Match"
        try await eventuallyOnMain("the field to show the shorter draft") {
            ListPerf.settle(window)
            return editor.string == "Match"
        }
        #expect(NSMaxRange(editor.selectedRange()) <= 5)
    }
}
