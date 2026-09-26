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

/// The question dock in a real `ThreadView` whose pi is the scripted stub: pi's select, confirm,
/// input and editor questions take the composer's place and are answered with the dock's keys,
/// which reach pi as its dialogs take them. Key events are built and handed to the dock's key
/// monitor, never posted; typing goes through the focused field's input system.
@Suite("Question dock", .mainActorExclusive)
@MainActor
struct QuestionDockIntegrationTests {
    @Test func aSelectIsPickedByItsNumberAndAnsweredWithReturn() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask-choice")
        #expect(thread.store.dialogs.first?.options?.count == 3)

        #expect(keys.handle(thread.key("↩", keyCode: 36)) == false, "nothing picked: ↩ is not the dock's yet")
        #expect(keys.handle(thread.key("4", keyCode: 21)) == false, "no fourth option")
        #expect(keys.handle(thread.key("1", keyCode: 18)))
        #expect(keys.handle(thread.key("2", keyCode: 19)), "picking again moves the pick")
        #expect(thread.responses.isEmpty, "a pick is not an answer")
        #expect(keys.handle(thread.key("↩", keyCode: 36)))

        let response = try await thread.response()
        #expect(response["value"] as? String == "Leave them alone\nDeploy from a clean checkout beside it.", "the option exactly as offered")
        try await thread.waitForTheComposer()
    }

    @Test(arguments: [(key: "1", keyCode: UInt16(18), confirmed: true), (key: "2", keyCode: UInt16(19), confirmed: false)])
    func aConfirmAnswersAsItsNumberIsPressed(key: String, keyCode: UInt16, confirmed: Bool) async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask")

        #expect(keys.handle(thread.key(key, keyCode: keyCode)))

        #expect(try await thread.response()["confirmed"] as? Bool == confirmed)
        try await thread.waitForTheComposer()
    }

    @Test func anInputTakesTheKeyboardAndAnswersWithWhatWasTyped() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask-input")
        try await eventuallyOnMain("the answer field to take the keyboard") { thread.focusedEditor != nil }

        thread.type("release/2.1")
        #expect(keys.handle(thread.key("1", keyCode: 18)) == false, "in its field, numbers type")
        #expect(keys.handle(thread.key("↩", keyCode: 36)))

        #expect(try await thread.response()["value"] as? String == "release/2.1")
        try await thread.waitForTheComposer()
    }

    @Test func anEditorStartsWithItsPrefillAndAnswersAsTyped() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask-editor")
        try await eventuallyOnMain("the editor field to take the keyboard") { thread.focusedEditor != nil }
        #expect(thread.focusedEditor?.string == "fix: typo")

        thread.type(" in the README")
        #expect(keys.handle(thread.key("↩", keyCode: 36, modifiers: .shift)) == false, "⇧↩ breaks the line")
        #expect(keys.handle(thread.key("↩", keyCode: 36)))

        #expect(try await thread.response()["value"] as? String == "fix: typo in the README")
    }

    /// Esc folds the dock to its one line, which still holds the composer's place; while hidden
    /// only Esc is the dock's, and Esc brings it back with the pick it had.
    @Test func escapeHidesTheQuestionToItsLineAndShowsItAgain() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask-choice")
        #expect(keys.handle(thread.key("1", keyCode: 18)))
        let open = try await thread.settledInset()

        #expect(keys.handle(thread.key("\u{1b}", keyCode: 53)))
        let hidden = try await thread.settledInset()
        #expect(hidden < open, "the dock folded: \(hidden) from \(open)")
        #expect(abs(hidden - (NWQuestionDockMetrics.hiddenHeight + AppLayout.composerBottom)) <= 1, "one 46pt line: \(hidden)")
        #expect(keys.handle(thread.key("2", keyCode: 19)) == false)
        #expect(keys.handle(thread.key("↩", keyCode: 36)) == false)
        #expect(thread.keyMonitor === keys && keys.watching && keys.window === thread.window.window, "hidden, it still takes Esc")

        #expect(keys.handle(thread.key("\u{1b}", keyCode: 53)))
        #expect(try await thread.settledInset() == open, "back as it was")
        #expect(thread.keyMonitor === keys && keys.watching && keys.window === thread.window.window)
        #expect(keys.handle(thread.key("↩", keyCode: 36)), "the pick survived hiding")
        #expect(try await thread.response()["value"] as? String == "Compare first (Recommended)\nDiff them against main; nothing is overwritten.")
    }

    /// The dock's keys are plain: ⌘1 still selects an agent, and a key pressed while another
    /// field has the keyboard stays there.
    @Test func chordsAndOtherFieldsKeepTheirKeys() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        let keys = try await thread.ask("ask-choice")

        #expect(keys.handle(thread.key("1", keyCode: 18, modifiers: .command)) == false)
        #expect(keys.handle(thread.key("1", keyCode: 18, modifiers: .option)) == false)
        let other = NSTextView()
        thread.window.host.addSubview(other)
        defer { other.removeFromSuperview() }
        #expect(thread.window.window.makeFirstResponder(other))
        #expect(keys.handle(thread.key("1", keyCode: 18)) == false, "the other field keeps it")
    }

    /// Stopping is how a question is refused: pi gets the cancelled answer, then the abort.
    @Test func stoppingRefusesTheQuestion() async throws {
        let thread = try await QuestionThread()
        defer { thread.close() }
        _ = try await thread.ask("select")

        await thread.store.abort()

        #expect(try await thread.response()["cancelled"] as? Bool == true)
        try await thread.waitForTheComposer()
    }
}

/// A `ThreadView` on a live stub pi, focused, in an off-screen window.
@MainActor
final class QuestionThread {
    let app: AppHarness
    let store: NativeThreadStore
    let window: OffscreenWindow
    let log: URL
    static let size = CGSize(width: 900, height: 700)

    init() async throws {
        app = try AppHarness()
        log = app.dir.appendingPathComponent("pi.log")
        let space = Fixture.space(path: app.dir.path)
        let agent = try await app.liveAgent(in: space, log: log)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [agent]))
        store = vm.threadStores.store(for: agent.agent.id)
        let server = app.server, id = agent.agent.id
        window = OffscreenWindow(size: Self.size, dark: true,
                                 ThreadView(store: store, active: true, isFocused: true,
                                            request: { try await server.nativeThread(agentID: id, request: $0) }, commandKey: "question"))
        let store = store
        try await eventuallyOnMain("the thread to connect") { store.ready }
    }

    /// Sends `prompt` and waits for pi's question to take the composer's place: the dock's key
    /// monitor, watching.
    func ask(_ prompt: String) async throws -> QuestionKeyMonitor {
        await store.send(text: prompt)
        let store = store
        try await eventuallyAsync("pi's question to reach the thread") {
            await store.refresh()
            return !store.dialogs.isEmpty
        }
        var found: QuestionKeyMonitor?
        try await eventuallyOnMain("the question dock to take the keyboard") {
            window.layout()
            found = keyMonitor
            return found?.watching == true && found?.window != nil
        }
        return try #require(found)
    }

    /// The dock's key monitor.
    var keyMonitor: QuestionKeyMonitor? {
        func find(_ view: NSView) -> QuestionKeyReader.Reader? {
            if let reader = view as? QuestionKeyReader.Reader { return reader }
            return view.subviews.lazy.compactMap(find).first
        }
        return find(window.host)?.monitor
    }

    /// A key press in this window, built but never posted.
    func key(_ characters: String, keyCode: UInt16, modifiers: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0, windowNumber: window.window.windowNumber,
                         context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode)!
    }

    var focusedEditor: NSTextView? { window.window.firstResponder as? NSTextView }

    /// Types at the end of the focused field, as the input system inserts it.
    func type(_ text: String) {
        guard let editor = focusedEditor else { return }
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// What pi was answered with, in order.
    var responses: [[String: Any]] {
        guard let data = try? Data(contentsOf: log) else { return [] }
        return data.split(separator: UInt8(ascii: "\n"))
            .compactMap { try? JSONSerialization.jsonObject(with: Data($0)) as? [String: Any] }
            .filter { $0["type"] as? String == "extension_ui_response" }
    }

    /// pi's one answer, once it has read it.
    func response() async throws -> [String: Any] {
        try await eventuallyOnMain("pi to read the answer") { !self.responses.isEmpty }
        #expect(responses.count == 1)
        return responses[0]
    }

    /// The question is gone and the composer's field is back.
    func waitForTheComposer() async throws {
        let store = store
        try await eventuallyAsync("the question to leave the thread") {
            await store.refresh()
            return store.dialogs.isEmpty
        }
        try await eventuallyOnMain("the dock to go") { self.window.layout(); return self.keyMonitor == nil }
    }

    /// The thread's bottom inset (the composer's height), once it holds still.
    func settledInset() async throws -> CGFloat {
        var last = CGFloat.nan, still = 0
        try await eventuallyOnMain("the composer to settle", poll: .milliseconds(20)) {
            window.layout()
            let inset = ListPerf.scrollView(in: window)?.contentInsets.bottom ?? .nan
            still = inset == last ? still + 1 : 0
            last = inset
            return still >= 5
        }
        return last
    }

    func close() {
        store.stop()
        window.close()
        app.stop()
    }
}
