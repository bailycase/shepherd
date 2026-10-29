import AppKit
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// The live Mission failure: ⌘↩ in a station's embedded thread while the same agent's ordinary thread stays mounted
/// but hidden (the layout deck flips visibility, never remounts). Both composers share the agent's store. The press
/// must reach the visible composer's own send once; the hidden one must never take it.
@Suite("Composer keys with a hidden thread on the same store", .mainActorExclusive)
@MainActor
struct MissionComposerKeyTests {
    @Observable @MainActor final class Deck { var plainVisible = true }

    struct Host: View {
        let store: NativeThreadStore
        let deck: Deck
        let request: NativeThreadStore.Request
        let missionRequest: NativeThreadStore.Request
        let missionSend: ProjectComposerSend
        let plainInput: ThreadInput, missionInput: ThreadInput
        var body: some View {
            ZStack {
                // The ordinary thread: kept mounted when hidden, as AgentLayoutDeck does.
                ThreadView(store: store, active: deck.plainVisible, isFocused: deck.plainVisible, request: request,
                           listModels: { .empty }, retainedInput: plainInput)
                    .opacity(deck.plainVisible ? 1 : 0).allowsHitTesting(deck.plainVisible)
                if !deck.plainVisible {
                    // The station's embedded thread, its send owned by the mission.
                    ThreadView(store: store, active: true, isFocused: false, request: missionRequest, listModels: { .empty }, retainedInput: missionInput)
                        .environment(\.projectComposerSend, missionSend)
                }
            }
        }
    }

    final class Counts { var plain = 0, mission: [String] = [] }

    static func keyDown(_ window: OffscreenWindow, command: Bool) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: command ? .command : [], timestamp: 0,
                         windowNumber: window.window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    /// Every composer field in the window, in view order (the hidden thread's first). AppKit views, not
    /// accessibility: a hidden thread's field is out of the accessibility tree but still in the window.
    static func fields(_ window: OffscreenWindow) -> [ComposerTextField.Field] {
        func walk(_ view: NSView) -> [ComposerTextField.Field] {
            (view as? ComposerTextField.Field).map { [$0] } ?? view.subviews.flatMap(walk)
        }
        return walk(window.host)
    }

    static func editor(_ window: OffscreenWindow, nth index: Int) throws -> NSTextView & NSTextInputClient {
        let all = fields(window)
        let field = try #require(all.dropFirst(index).first, "composer field \(index) of \(all.count)")
        try #require(window.window.makeFirstResponder(field))
        return try #require(field.currentEditor() as? (NSTextView & NSTextInputClient))
    }

    enum Press: String, CaseIterable { case commandReturn, sendButton }

    @Test(arguments: [true, false], Press.allCases)
    func theEmbeddedThreadSendsThroughItsOwnComposerOnce(plainWasFocused: Bool, press: Press) async throws {
        AccessibilityNode.enable()
        let store = NativeThreadStore()
        let counts = Counts()
        let deck = Deck()
        deck.plainVisible = plainWasFocused
        // As the host serves it: the ordinary request gets no actions for a mission thread; the mission's
        // source adds "send" while its turn can be steered (MissionController.thread(for:)).
        var plainSnapshot = ComposerThread.snapshot(messages: 0, commands: [])
        plainSnapshot.supportedActions = ["images"]
        var missionSnapshot = plainSnapshot
        missionSnapshot.supportedActions.append("send")
        let window = OffscreenWindow(size: CGSize(width: 900, height: 700))
        defer { store.stop(); window.close() }
        let request: NativeThreadStore.Request = { request in
            if case .send = request { counts.plain += 1; return .failure(code: "mission_control", message: "This thread belongs to a Mission.") }
            return .snapshot(value: plainSnapshot)
        }
        let missionRequest: NativeThreadStore.Request = { request in
            if case .send = request { counts.plain += 1; return .failure(code: "mission_control", message: "This thread belongs to a Mission.") }
            return .snapshot(value: missionSnapshot)
        }
        let missionSend = ProjectComposerSend(placeholder: "Steer", carriesImages: false, send: { text, _ in counts.mission.append(text); return true })
        window.show(Host(store: store, deck: deck, request: request, missionRequest: missionRequest, missionSend: missionSend, plainInput: ThreadInput(), missionInput: ThreadInput()))
        try await eventuallyOnMain("thread ready") { window.layout(); return store.ready }
        if plainWasFocused {
            // The ordinary thread had the keyboard, then the deck hid it.
            _ = try Self.editor(window, nth: 0)
            window.layout()
            deck.plainVisible = false
        }
        try await eventuallyOnMain("embedded composer shown") {
            window.layout(); return Self.fields(window).count == 2
        }
        // Typed into the visible (embedded) composer, the last one in view order.
        let field = try Self.editor(window, nth: 1)
        field.insertText("steer this", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventuallyOnMain("draft typed") { store.draft == "steer this" }
        window.layout()
        // Dispatched through the app to the offscreen window only: the composers' window monitors see it as a real press.
        // Proof the press travels the app's real route: a local key monitor (as every composer installs) sees it.
        var routed = 0
        let probe = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in routed += 1; return event }
        defer { probe.map(NSEvent.removeMonitor) }
        switch press {
        case .commandReturn: NSApp.sendEvent(Self.keyDown(window, command: true))
        // The visible composer's own Send (the hidden thread's is out of the accessibility tree).
        case .sendButton:
            try await eventuallyOnMain("the visible Send is enabled") { window.layout(); return window.controls().contains { $0.label == "Send" && $0.isEnabled } }
            try window.press("Send")
        }
        // A swallowed press does nothing at all, so this wait may expire; the expectations below say which composer acted.
        try? await eventuallyOnMain("the press is handled", timeout: .seconds(5)) { !counts.mission.isEmpty || counts.plain > 0 }
        print("composer-key-route monitorsSaw=\(routed) mission=\(counts.mission) plain=\(counts.plain)")
        #expect(counts.mission == ["steer this"], "the embedded composer's own send ran once")
        #expect(counts.plain == 0, "the hidden ordinary composer never took the press")
    }
}
