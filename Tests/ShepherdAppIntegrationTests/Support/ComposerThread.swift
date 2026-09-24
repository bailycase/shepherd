import AppKit
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
@testable import ShepherdApp

/// A real `ThreadView` with a long thread, a full model catalog, and pi's command list, in an
/// off-screen window, for the composer's menus. Menus open the ways the app opens them: ⇧⌘M's
/// command, a draft starting with "/". Nothing here clicks or presses a key.
@MainActor
final class ComposerThread {
    nonisolated static let key = "composer"

    let store = NativeThreadStore()
    let commands = ThreadCommandCenter()
    let window: OffscreenWindow
    let size: CGSize
    private(set) var snapshot: NativeThreadSnapshot
    /// The thread's own scroll view, found before any menu (which may bring its own) opens.
    private(set) var threadScroll: NSScrollView?
    private var hosted: () -> AnyView = { AnyView(EmptyView()) }

    init(messages: Int = 40, size: CGSize = CGSize(width: 900, height: 600), models: [PiModelCatalog.Entry] = ModelCatalogFixture.entries,
         commands: [NativeCommand] = ModelCatalogFixture.commands, dialogs: [NativeThreadDialog] = [], dark: Bool = false,
         animated: Bool = true) {
        self.size = size
        snapshot = Self.snapshot(messages: messages, commands: commands, dialogs: dialogs)
        window = OffscreenWindow(size: size, dark: dark)
        let request: NativeThreadStore.Request = { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "harness released") }
            switch value {
            case .send(_, _, let operation, _, _, _): return .accepted(operationID: operation)
            default: return .snapshot(value: self.snapshot)
            }
        }
        hosted = { [store, commands = self.commands] in
            AnyView(ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: Self.key, listModels: { models })
                .environment(\.threadCommands, commands)
                // Without motion, a change's first frame is all of its work.
                .transaction { if !animated { $0.disablesAnimations = true } })
        }
        window.show(hosted())
    }

    /// A new `ThreadView` on the same store, as the workspace remounts a remote agent's thread:
    /// its first frame has the store's snapshot and draft.
    func remount() {
        window.show(hosted().id(UUID()))
        threadScroll = scrollViews().first
    }

    static func snapshot(messages count: Int, commands: [NativeCommand], dialogs: [NativeThreadDialog] = [],
                         model: String = "anthropic/claude-opus-4-5", revision: UInt64 = 1) -> NativeThreadSnapshot {
        let messages = (0..<count).map { index -> NativeThreadMessage in
            let user = index % 2 == 0
            let text = user ? "Question \(index): what changed in the composer, and why does the picker lag?"
                : Array(repeating: "Answer paragraph \(index) with enough words to wrap a line or two in the column, the way a real reply reads.",
                        count: 3).joined(separator: "\n\n")
            return NativeThreadMessage(entryID: "m\(index)", role: user ? "user" : "assistant",
                                       blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
        }
        return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: false, model: model, thinking: "medium",
                                    supportedActions: ["send", "abort", "answer", "setModel", "setThinking"], dialogsSupported: true,
                                    dialogs: dialogs, messages: messages, provisional: [], clipped: false, commands: commands)
    }

    /// Loaded, laid out, and drawing the same picture twice in a row.
    func waitUntilReady() async throws {
        try await eventuallyOnMain("the thread to load") { store.ready }
        try await settle()
        threadScroll = scrollViews().first
    }

    /// Waits until the whole window draws the same picture for a few polls.
    func settle() async throws {
        let all = CGRect(origin: .zero, size: size)
        var last = FrameTimer.capture(window, all), still = 0
        try await eventuallyOnMain("the window to come to rest", timeout: .seconds(10), poll: .milliseconds(20)) {
            window.layout()
            let now = FrameTimer.capture(window, all)
            still = now == last ? still + 1 : 0
            last = now
            return still >= 5
        }
    }

    // MARK: Opening menus

    func openModelPicker() { commands.send(.modelPicker, to: Self.key) }

    func openSlashMenu() { store.draft = "/" }

    // MARK: Reading the window

    /// Every scroll view in the window, outermost first (the thread's, then any a menu brings).
    func scrollViews() -> [NSScrollView] {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(window.host)
        return found
    }

    /// The scroll view inside the open menu.
    var menuScroll: NSScrollView? { scrollViews().first { $0 !== threadScroll } }

    /// The thread's bottom inset: the composer's measured height.
    var composerInset: CGFloat {
        window.layout()
        return threadScroll?.contentInsets.bottom ?? .nan
    }

    /// How far the thread is scrolled.
    var threadOffset: CGFloat {
        window.layout()
        return threadScroll?.contentView.bounds.origin.y ?? .nan
    }

    /// The top of the composer card, from the window's top.
    var cardTop: CGFloat { size.height - composerInset }

    /// The column's leading edge: where the card, and the menus above it, start.
    var columnLeading: CGFloat {
        let gutter = AppLayout.threadGutter(width: size.width)
        let column = min(AppLayout.threadMaxWidth, size.width - 2 * gutter)
        return (size.width - column) / 2
    }

    /// The field editor of the text field that has focus in the window (the model picker's
    /// search field while it is open).
    var focusedEditor: NSTextView? {
        window.window.firstResponder as? NSTextView
    }

    /// Types `text` at the end of the focused field, as the input system inserts it: no key
    /// events, and the window never becomes key.
    func type(_ text: String) {
        guard let editor = focusedEditor else { return }
        editor.insertText(text, replacementRange: NSRange(location: (editor.string as NSString).length, length: 0))
    }

    /// Deletes the focused field's last character.
    func deleteBackward() {
        guard let editor = focusedEditor, !editor.string.isEmpty else { return }
        let length = (editor.string as NSString).length
        editor.insertText("", replacementRange: NSRange(location: length - 1, length: 1))
    }

    func close() {
        store.stop()
        window.close()
    }
}
