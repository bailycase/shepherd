import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Thinking level shortcuts", .integrationTimeLimit)
struct CycleThinkingShortcutIntegrationTests {
    @Test func shiftTabCyclesTheFocusedThreadAndWrapsWithoutChangingItsDraft() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.cyclingThread() }
        }
    }

    @Test func aReboundThinkingShortcutReplacesShiftTabAndResetRestoresIt() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.rebinding() }
        }
    }

    @Test func unavailableThinkingLeavesTheShortcutAlone() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors {
                for state in ["unfocused", "offOnly", "oneLevel", "nonReasoning", "unsupported", "question"] {
                    try await Self.unavailable(state)
                }
            }
        }
    }

    @Test func newThreadAndNewDesignCycleTheirOwnSupportedThinkingLevels() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.cyclingNewComposers() }
        }
    }

    @Test func theKeyboardRowStartsAndCancelsRecordingAndResetsTheThinkingShortcut() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.keyboardControls() }
        }
    }

    @MainActor
    private static func monitor(in view: NSView) -> ComposerKeyMonitor? {
        if let reader = view as? ComposerWindowReader.Reader,
           reader.monitor?.chord() == KeybindingsStore.shared.chord(for: .cycleThinkingLevel) { return reader.monitor }
        return view.subviews.lazy.compactMap { monitor(in: $0) }.first
    }

    @MainActor
    private static func key(in window: OffscreenWindow, chord: KeyChord = ShortcutAction.cycleThinkingLevel.defaultChord) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: chord.modifierFlags,
            timestamp: 0, windowNumber: window.window.windowNumber, context: nil,
            characters: chord.key == "tab" ? "\u{19}" : chord.key,
            charactersIgnoringModifiers: chord.key == "tab" ? "\u{19}" : chord.key,
            isARepeat: false, keyCode: chord.key == "tab" ? 48 : 16))
    }

    @MainActor
    private static func readyMonitor(in window: OffscreenWindow) async throws -> ComposerKeyMonitor {
        try await eventuallyOnMain("the focused composer to accept thinking cycling") {
            window.layout()
            return monitor(in: window.host)?.accepts() == true
        }
        return try #require(monitor(in: window.host))
    }

    @MainActor
    private static func cyclingThread() async throws {
        let thread = ComposerThread(messages: 2, focused: true, thinkingLevels: ["low", "medium", "high", "xhigh"])
        defer { thread.close() }
        try await thread.waitUntilReady()
        thread.store.draft = "Keep this draft and its focus."
        let monitor = try await readyMonitor(in: thread.window)
        let editor = try #require(thread.focusedEditor)
        let other = OffscreenWindow()
        defer { other.close() }
        #expect(!monitor.handle(try key(in: other)))
        #expect(!monitor.handle(try key(in: thread.window, chord: KeyChord(key: "tab"))))
        #expect(!monitor.handle(try key(in: thread.window, chord: KeyChord(key: "tab", command: true, shift: true))))
        KeybindingsStore.shared.isRecording = true
        #expect(!monitor.handle(try key(in: thread.window)), "the settings recorder takes precedence")
        KeybindingsStore.shared.isRecording = false
        for level in ["high", "xhigh", "low", "medium"] {
            _ = try await readyMonitor(in: thread.window)
            #expect(monitor.handle(try key(in: thread.window)))
            try await eventuallyOnMain("the thread to show \(level)") { thread.store.thinking == level && !thread.store.busy }
        }
        _ = try await readyMonitor(in: thread.window)
        #expect(monitor.handle(try key(in: thread.window)))
        #expect(monitor.handle(try key(in: thread.window)))
        try await eventuallyOnMain("two presses before a render to advance two levels") { thread.store.thinking == "xhigh" && !thread.store.busy }
        let levels = thread.requests.compactMap { request -> String? in
            if case .setThinking(let session, let generation, _, let level) = request {
                #expect(session == "s" && generation == "g")
                return level
            }
            return nil
        }
        #expect(levels == ["high", "xhigh", "low", "medium", "xhigh"])
        #expect(thread.store.draft == "Keep this draft and its focus.")
        #expect(thread.focusedEditor === editor)
        #expect(!thread.requests.contains { if case .send = $0 { true } else { false } })
        thread.openModelPicker()
        try await eventuallyOnMain("the model search field to release the composer shortcut") { !monitor.accepts() }
        #expect(!monitor.handle(try key(in: thread.window)))
    }

    @MainActor
    private static func rebinding() async throws {
        let thread = ComposerThread(messages: 0, focused: true, thinkingLevels: ["low", "medium", "high"])
        defer { thread.close() }
        try await thread.waitUntilReady()
        let monitor = try await readyMonitor(in: thread.window)
        let keys = KeybindingsStore.shared
        let custom = KeyChord(key: "y", command: true, option: true)
        #expect(keys.assign(custom, to: .cycleThinkingLevel) == nil)
        #expect(!monitor.handle(try key(in: thread.window)), "the old key is no longer intercepted")
        #expect(monitor.handle(try key(in: thread.window, chord: custom)))
        try await eventuallyOnMain("the rebound chord to choose High") { thread.store.thinking == "high" && !thread.store.busy }
        _ = try await readyMonitor(in: thread.window)
        #expect(keys.reset(.cycleThinkingLevel) == nil)
        #expect(!monitor.handle(try key(in: thread.window, chord: custom)))
        #expect(monitor.handle(try key(in: thread.window)))
        try await eventuallyOnMain("Shift-Tab to wrap to Low after reset") { thread.store.thinking == "low" && !thread.store.busy }
    }

    @MainActor
    private static func unavailable(_ state: String) async throws {
        let store = NativeThreadStore()
        var snapshot = ComposerThread.snapshot(messages: 0, commands: [])
        snapshot.thinkingLevels = state == "offOnly" ? ["off"] : state == "oneLevel" ? ["medium"] : ["low", "medium", "high"]
        if state == "unsupported" { snapshot.supportedActions.removeAll { $0 == "setThinking" } }
        if state == "question" { snapshot.dialogs = [NativeThreadDialog(id: "question", kind: .input, title: "A question")] }
        let models = state == "nonReasoning" ? [PiModelCatalog.Entry(id: "anthropic/claude-opus-4-5", reasoning: false)] : ModelCatalogFixture.entries
        var requests: [NativeThreadRequest] = []
        let window = OffscreenWindow(size: CGSize(width: 900, height: 600),
            ThreadView(store: store, active: true, isFocused: state != "unfocused", request: { request in
                requests.append(request)
                return .snapshot(value: snapshot)
            }, listModels: { ModelCatalog(models) }))
        defer { store.stop(); window.close() }
        try await eventuallyOnMain("the unavailable composer to load") { store.ready }
        try await eventuallyOnMain("the unavailable composer to release the shortcut") {
            window.layout()
            return state == "question" || monitor(in: window.host)?.accepts() == false
        }
        if let monitor = monitor(in: window.host) { #expect(!monitor.handle(try key(in: window))) }
        #expect(!requests.contains { if case .setThinking = $0 { true } else { false } })
        #expect(store.thinking == "medium")
    }

    @MainActor
    private static func cyclingNewComposers() async throws {
        try StubPi.installAsEngine()
        let listing = ModelListing(models: ["openai/gpt-5", "fixture/plain"], defaultModel: "openai/gpt-5",
            withoutThinking: ["fixture/plain"], thinkingLevels: ["openai/gpt-5": ["low", "medium", "high", "xhigh"]])
        let app = try AppHarness(modelCatalog: { listing })
        defer { app.stop() }
        let vm = try await app.start(with: ShepherdState(spaces: [Fixture.space(path: app.dir.path)]))
        vm.openNewThread()
        try await eventuallyOnMain("new-thread levels to load") { !vm.newThread.loadingDefaults }
        vm.newThread.setModel("openai/gpt-5")
        vm.newThread.setThinking(.xhigh)
        vm.newThread.prompt = "Keep the opening prompt."
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 700), NewThreadPage(vm: vm, chrome: PageHeaderChrome()))
        defer { window.close() }
        let newThreadMonitor = try await readyMonitor(in: window)
        #expect(newThreadMonitor.handle(try key(in: window)))
        try await eventuallyOnMain("new thread to wrap to Low") { vm.newThread.thinking == .low }
        vm.newThread.setThinking(.minimal)
        #expect(vm.newThread.thinkingLevel(vm) == .low)
        #expect(newThreadMonitor.handle(try key(in: window)))
        try await eventuallyOnMain("new thread to advance from the displayed Low, not the unsupported Minimal") { vm.newThread.thinking == .medium }
        #expect(vm.newThread.prompt == "Keep the opening prompt.")
        vm.newThread.setModel("fixture/plain")
        try await eventuallyOnMain("the non-reasoning new thread to release Shift-Tab") { !newThreadMonitor.accepts() }
        #expect(!newThreadMonitor.handle(try key(in: window)))
        #expect(vm.state.agents.isEmpty, "cycling never submits the prompt")

        vm.openNewDesign()
        try await eventuallyOnMain("new-design levels to load") { vm.newDesign.listing != nil }
        vm.newDesign.setModel("openai/gpt-5")
        vm.newDesign.setThinking(.medium)
        vm.newDesign.brief = "Keep the design brief."
        window.show(NewDesignPage(vm: vm, chrome: PageHeaderChrome()))
        let newDesignMonitor = try await readyMonitor(in: window)
        #expect(newDesignMonitor.handle(try key(in: window)))
        try await eventuallyOnMain("new design to choose High") { vm.newDesign.thinking == .high }
        vm.newDesign.setThinking(.minimal)
        #expect(newDesignMonitor.handle(try key(in: window)))
        try await eventuallyOnMain("new design to advance from the displayed Low") { vm.newDesign.thinking == .medium }
        #expect(vm.newDesign.brief == "Keep the design brief.")
        #expect(vm.state.agents.isEmpty)
    }

    @MainActor
    private static func keyboardControls() async throws {
        AccessibilityNode.enable()
        let app = try AppHarness()
        defer { app.stop() }
        let vm = try await app.start()
        let window = OffscreenWindow(size: CGSize(width: 1200, height: 2400), KeyboardSettings(vm: vm))
        defer { window.close() }
        let label = "Cycle thinking level shortcut"
        try await eventuallyOnMain("the thinking shortcut recorder") { window.element(label) != nil }
        #expect(window.element(label)?.value == "⇧⇥")
        let recorder = try window.press(label)
        #expect(recorder.frame.height >= 24 && recorder.frame.width >= 24)
        try await eventuallyOnMain("the recorder to capture") { KeybindingsStore.shared.isRecording && window.element(label)?.value == "Recording" }
        #expect(try #require(window.element(label)).frame.height >= 24)
        try window.press(label)
        try await eventuallyOnMain("recording to cancel") { !KeybindingsStore.shared.isRecording }

        let captured = try #require(KeyChord(event: key(in: window, chord: KeyChord(key: "y", command: true, option: true))))
        #expect(KeybindingsStore.shared.assign(captured, to: .cycleThinkingLevel) == nil)
        try await eventuallyOnMain("the rebound shortcut and Reset to show") { window.element(label)?.value == "⌥⌘Y" && window.element("Reset Cycle thinking level") != nil }
        try window.press(label)
        try await eventuallyOnMain("the rebound recorder to capture") { KeybindingsStore.shared.isRecording && window.element(label)?.value == "Recording" }
        try window.press(label)
        try await eventuallyOnMain("the rebound recording to cancel") { !KeybindingsStore.shared.isRecording && window.element(label)?.value == "⌥⌘Y" }
        let reset = try window.press("Reset Cycle thinking level")
        #expect(reset.frame.height >= 24 && reset.frame.width >= 24)
        try await eventuallyOnMain("Reset to restore Shift-Tab") { window.element(label)?.value == "⇧⇥" && KeybindingsStore.shared.isDefault(.cycleThinkingLevel) }
        #expect(window.element("Reset Cycle thinking level") == nil)
    }
}
