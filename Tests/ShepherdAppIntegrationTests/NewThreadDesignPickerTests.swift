import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The New thread page's @ picker and its chip, in a real window with the real model behind them,
/// pressed the way VoiceOver presses (`ControlPress`; each scenario in its own process): "@" opens
/// the picker, a design drills into its boards, "Whole design" puts a chip beside the prompt and
/// leaves the words, the chip's Remove takes it back, Send starts the thread (and a design alone is
/// enough to press it). Nothing is posted to the window.
@Suite("New thread design picker", .integrationTimeLimit)
struct NewThreadDesignPickerTests {
    @Test func pickingADesignPutsItsChipBesideThePromptAndSendStartsTheThread() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.pickingAndSending() }
        }
    }

    @Test func removingTheChipLeavesTheWordsAndNothingToSend() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.removingTheChip() }
        }
    }

    @Test func theDesignsAreSaidToBeLoadingThenListedOnTheNewThreadPage() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.loadingThenListed() }
        }
    }

    // MARK: Scenarios

    /// The page over a real workspace, its field holding the keyboard.
    @MainActor
    private static func page() async throws -> (NewThreadDesignTests.Workspace, OffscreenWindow, NSTextView) {
        AccessibilityNode.enable()
        let w = try await NewThreadDesignTests.workspace()
        w.vm.openNewThread()
        let draft = w.vm.newThread
        try await eventuallyOnMain("the model capabilities to load") { !draft.loadingDefaults }
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 800), dark: true, NewThreadPage(vm: w.vm, chrome: PageHeaderChrome()))
        var found: NSTextView?
        try await eventuallyOnMain("the field to take the keyboard") {
            window.layout()
            found = (window.window.firstResponder as? NSTextView).flatMap { $0.isFieldEditor ? $0 : nil }
            return found != nil
        }
        return (w, window, try #require(found))
    }

    /// Types `text` at the end of the focused field, as the input system inserts it: no key events.
    @MainActor
    private static func type(_ text: String, in editor: NSTextView) {
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// What VoiceOver's action menu offers on the composer's design chip (its Remove is an action,
    /// as the chip combines its parts into one control).
    @MainActor
    private static func chipActions(in window: OffscreenWindow) -> [String] {
        window.layout()
        return ControlPress.actions(onLabelContaining: "Design reference", under: window.host)
    }

    /// The label of the picker row whose label starts with `prefix`.
    @MainActor
    private static func row(_ prefix: String, in window: OffscreenWindow) -> String? {
        window.elements().compactMap(\.label).first { $0.hasPrefix(prefix) }
    }

    @MainActor
    static func pickingAndSending() async throws {
        let (w, window, editor) = try await Self.page()
        defer { w.app.stop(); window.close() }
        let draft = w.vm.newThread
        Self.type("tools:0 Match @", in: editor)

        try await eventuallyOnMain("the picker to list the design", timeout: .seconds(60)) { Self.row("Checkout ☕️", in: window) != nil }
        #expect(window.element("Loading designs") == nil)
        // The design drills into its boards, the way in written into the prompt.
        try window.press(try #require(Self.row("Checkout ☕️", in: window)))
        try await eventuallyOnMain("the design's rows") { Self.row("Whole design", in: window) != nil }
        #expect(draft.prompt == "tools:0 Match @Checkout ☕️ › ")
        #expect(draft.references.isEmpty, "drilling in picks nothing")

        // Whole design: the chip joins the message and the mention leaves the words.
        try window.press(try #require(Self.row("Whole design", in: window)))
        try await eventuallyOnMain("the chip to join the message", timeout: .seconds(30)) { draft.references.count == 1 }
        #expect(draft.prompt == "tools:0 Match ")
        #expect(draft.references[0].reference.designID == w.design.id && draft.references[0].reference.board == nil)
        try await eventuallyOnMain("the field to show the words") { editor.string == "tools:0 Match " }
        #expect(editor.selectedRange() == NSRange(location: (editor.string as NSString).length, length: 0),
                "the caret stays after the words, so typing goes on from there")
        try await eventuallyOnMain("the picker to close") { window.element("Mention") == nil }
        try await eventuallyOnMain("the chip, with its Remove") { Self.chipActions(in: window) == ["Remove"] }

        // Send, pressed: the thread starts with the design in its opening message.
        let send = try window.press("Send")
        #expect(send.isEnabled)
        try await eventuallyOnMain("the new agent to be selected", timeout: .seconds(60)) { w.vm.selectedAgentID != nil && !draft.starting }
        #expect(draft.references.isEmpty && draft.prompt.isEmpty)
        let id = try #require(w.vm.selectedAgentID)
        let server = w.app.server
        try await eventuallyAsync("pi to be sent the design", timeout: .seconds(60)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.designReferences?.first?.design == "Checkout ☕️" }
        }
    }

    @MainActor
    static func removingTheChip() async throws {
        let (w, window, editor) = try await Self.page()
        defer { w.app.stop(); window.close() }
        let draft = w.vm.newThread
        // A design alone is enough to press Send; taking its chip back leaves nothing to send.
        try await draft.referenceChips?.io.attach(try #require(w.vm.designReference(w.design.id)))
        try await eventuallyOnMain("the chip to be drawn") { Self.chipActions(in: window) == ["Remove"] }
        #expect(draft.blocker(w.vm) == nil)
        let send = try #require(window.controls().first { $0.label == "Send" })
        #expect(send.isEnabled, "Send is enabled with a design and no words")

        Self.type("keep these words", in: editor)
        try ControlPress.perform("Remove", onLabelContaining: "Design reference", under: window.host)
        try await eventuallyOnMain("the chip to go") { draft.references.isEmpty }
        #expect(draft.prompt == "keep these words", "the words stay")
        try await eventuallyOnMain("Send to say it needs words") { window.controls().first { $0.label == "Send" }?.isEnabled == true }
        draft.prompt = ""
        try await eventuallyOnMain("Send to be off") { window.controls().first { $0.label == "Send" }?.isEnabled == false }
        #expect(draft.blocker(w.vm) == "Describe the task first.")
    }

    @MainActor
    static func loadingThenListed() async throws {
        let (w, window, editor) = try await Self.page()
        defer { w.app.stop(); window.close() }
        Self.type("@", in: editor)
        // Before the designs are read the picker says so, at once.
        try await eventuallyOnMain("the picker to open") { window.element("Mention") != nil }
        let said = window.element("Loading designs") != nil
        try await eventuallyOnMain("the designs", timeout: .seconds(60)) { Self.row("Checkout ☕️", in: window) != nil }
        #expect(window.element("Loading designs") == nil, "and the line is gone once they are listed (it was shown: \(said))")
    }
}
