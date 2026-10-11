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
    /// The composer's images, held here so a test can attach one.
    let input = ThreadInput()
    let size: CGSize
    private(set) var snapshot: NativeThreadSnapshot
    /// Every request the thread sent its host, in order (its pulls included).
    private(set) var requests: [NativeThreadRequest] = []
    /// The thread's own scroll view, found before any menu (which may bring its own) opens.
    private(set) var threadScroll: NSScrollView?
    private var hosted: () -> AnyView = { AnyView(EmptyView()) }

    /// `focused` gives the thread the keyboard, so its field takes it as the app's does.
    /// `speed` puts the thread on a model that offers a service tier, so its popover has a Speed
    /// control. The host applies a speed, a level and a model as the real one does (`requests`).
    init(messages: Int = 40, size: CGSize = CGSize(width: 900, height: 600), models: [PiModelCatalog.Entry] = ModelCatalogFixture.entries,
         commands: [NativeCommand] = ModelCatalogFixture.commands, dialogs: [NativeThreadDialog] = [], dark: Bool = false,
         focused: Bool = false, animated: Bool = true, speed: Bool = false, fast: Bool = false, model: String = "anthropic/claude-opus-4-5",
         thinkingLevels: [String]? = nil, designReferences: DesignReferenceChips? = nil, running: Bool = false) {
        self.size = size
        snapshot = Self.snapshot(messages: messages, commands: commands, dialogs: dialogs, model: speed ? "openai/gpt-6-luna" : model, speed: speed)
        if fast { snapshot.serviceTier = "fast" }
        if running { snapshot.running = true }
        if let thinkingLevels { snapshot.thinkingLevels = thinkingLevels }
        // A local thread whose host takes design references: the @ picker is on.
        if designReferences != nil { snapshot.supportedActions.append("designReferences") }
        window = OffscreenWindow(size: size, dark: dark)
        let request: NativeThreadStore.Request = { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "harness released") }
            self.requests.append(value)
            switch value {
            case .send(_, _, let operation, _, _, _, _, _, _): return .accepted(operationID: operation)
            // The host applies a speed, a level and a model as the real one does, so the next pull shows them.
            case .setServiceTier(_, _, let operation, let tier):
                self.snapshot.serviceTier = tier
                self.snapshot.revision += 1
                return .accepted(operationID: operation)
            case .setThinking(_, _, let operation, let level):
                self.snapshot.thinking = level
                self.snapshot.revision += 1
                return .accepted(operationID: operation)
            case .setModel(_, _, let operation, let model):
                self.snapshot.model = model
                self.snapshot.revision += 1
                return .accepted(operationID: operation)
            default: return .snapshot(value: self.snapshot)
            }
        }
        hosted = { [store, input = self.input, commands = self.commands] in
            AnyView(ThreadView(store: store, active: true, isFocused: focused, request: request, commandKey: Self.key, listModels: { ModelCatalog(models) }, retainedInput: input)
                .environment(\.threadCommands, commands)
                .environment(\.designReferences, designReferences)
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
                         model: String = "anthropic/claude-opus-4-5", revision: UInt64 = 1, speed: Bool = false) -> NativeThreadSnapshot {
        let messages = (0..<count).map { index -> NativeThreadMessage in
            let user = index % 2 == 0
            let text = user ? "Question \(index): what changed in the composer, and why does the picker lag?"
                : Array(repeating: "Answer paragraph \(index) with enough words to wrap a line or two in the column, the way a real reply reads.",
                        count: 3).joined(separator: "\n\n")
            return NativeThreadMessage(entryID: "m\(index)", role: user ? "user" : "assistant",
                                       blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
        }
        return NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: false, model: model,
                                    thinking: "medium",
                                    supportedActions: ["send", "abort", "answer", "setModel", "setThinking"] + (speed ? ["setServiceTier"] : []),
                                    dialogsSupported: true, dialogs: dialogs, messages: messages, provisional: [], clipped: false, commands: commands,
                                    serviceTier: speed ? "standard" : nil, serviceTiers: speed ? ["standard", "fast"] : nil)
    }

    /// The host's turn starts or ends: the next pull carries it, as a poll's does.
    func setRunning(_ running: Bool) async {
        snapshot.running = running
        snapshot.revision += 1
        await store.refresh(fresh: true)
    }

    /// Loaded, laid out, and drawing the same picture twice in a row.
    func waitUntilReady() async throws {
        try await eventuallyOnMain("the thread to load") { store.ready }
        try await settle()
        threadScroll = scrollViews().first
    }

    /// Waits until the whole window draws the same picture for a few polls.
    func settle(file: StaticString = #fileID, line: UInt = #line) async throws {
        let all = CGRect(origin: .zero, size: size)
        var last = FrameTimer.capture(window, all), still = 0
        var previous = last, draws = 0, best = 0
        var lastDraw = ContinuousClock.now, longestGap = Duration.zero
        var longestWake = Duration.zero, longestLayout = Duration.zero, longestCapture = Duration.zero
        do {
            try await eventuallyOnMain("the window to come to rest", timeout: .seconds(10), poll: .milliseconds(20)) {
                let woke = ContinuousClock.now
                longestWake = max(longestWake, lastDraw.duration(to: woke))
                window.layout()
                let laidOut = ContinuousClock.now
                longestLayout = max(longestLayout, woke.duration(to: laidOut))
                let now = FrameTimer.capture(window, all)
                let time = ContinuousClock.now
                longestCapture = max(longestCapture, laidOut.duration(to: time))
                longestGap = max(longestGap, lastDraw.duration(to: time))
                lastDraw = time
                draws += 1
                previous = last
                still = now == last ? still + 1 : 0
                best = max(best, still)
                last = now
                return still >= 5
            }
        } catch let error as WaitTimeout {
            let rgb = Pixels.bounds(differing: previous, last, rows: 0..<last.height)
            let responder = window.window.firstResponder.map { String(describing: Swift.type(of: $0)) } ?? "none"
            print("Composer settle at \(file):\(line): draws=\(draws), best identical=\(best)/5, longest gap=\(longestGap), wake/layout/capture=\(longestWake)/\(longestLayout)/\(longestCapture), RGB change=\(String(describing: rgb)), responder=\(responder), scroll bounds=\(scrollViews().map { $0.contentView.bounds })")
            throw error
        }
    }

    // MARK: Opening menus

    func openModelPicker() { commands.send(.modelPicker, to: Self.key) }

    func openSlashMenu() { store.draft = "/" }

    func openSpeedMenu() { commands.send(.speedMenu, to: Self.key) }

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

    /// The composer's measured height, excluding the separate transcript gap.
    var composerInset: CGFloat {
        window.layout()
        return (threadScroll?.contentInsets.bottom ?? .nan) - AppLayout.composerTranscriptGap
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
