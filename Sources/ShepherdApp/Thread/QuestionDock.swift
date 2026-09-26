import AppKit
import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

// MARK: Hiding

/// Which of pi's questions the user hid. Only that one stays hidden: the next question pi asks
/// arrives open.
struct QuestionHiding: Equatable {
    private(set) var hiddenKey: String?

    func isHidden(_ key: String?) -> Bool { key != nil && key == hiddenKey }
    mutating func hide(_ key: String) { hiddenKey = key }
    mutating func show() { hiddenKey = nil }
}

// MARK: Dock

/// A question in the composer's place (the question dock): pi's own (select, confirm, input,
/// editor) or a subagent's, drawn by `NWQuestionDock` from its shared presentation
/// (`NativeQuestionPrompt`). It keeps the person's picks while it waits, answers through
/// `answer`, and takes the dock's keys (1–9, ↩, Esc) while its thread has the keyboard.
struct QuestionDock: View {
    let prompt: NativeQuestionPrompt
    /// Questions waiting; the head shows "1 / N".
    var count = 1
    /// The host takes answers.
    let enabled: Bool
    /// Folded to its line.
    let hidden: Bool
    /// The thread has the keyboard: the dock takes its keys, and an open question its field.
    let focused: Bool
    let answer: (NativeQuestionAnswer) -> Void
    let setHidden: (Bool) -> Void
    @State private var selection: NWQuestionDockSelection
    @FocusState private var field: NWQuestionDockField?
    @State private var keys = QuestionKeyMonitor()

    /// `picks`: what is already picked and typed (previews); else nothing, and an open
    /// question's prefill.
    init(prompt: NativeQuestionPrompt, count: Int = 1, enabled: Bool, hidden: Bool, focused: Bool, picks: NativeQuestionPicks? = nil,
         answer: @escaping (NativeQuestionAnswer) -> Void, setHidden: @escaping (Bool) -> Void) {
        self.prompt = prompt
        self.count = count
        self.enabled = enabled
        self.hidden = hidden
        self.focused = focused
        self.answer = answer
        self.setHidden = setHidden
        let picks = picks ?? NativeQuestionPicks(prompt)
        _selection = State(initialValue: NWQuestionDockSelection(picked: picks.picked, note: picks.note, other: picks.other, text: picks.text))
    }

    var body: some View {
        let hints = KeybindingsStore.shared.questionKeys
        Group {
            if hidden {
                NWQuestionDockHidden(Self.asker(prompt.asker), question: prompt.question, keys: hints) { setHidden(false) }
                    .nwTransition(.content)
            } else {
                // A question that cannot be answered here says why, and its answers stand down.
                NWQuestionDock(Self.content(prompt, count: count), selection: $selection, focus: $field,
                               enabled: enabled && prompt.blocked == nil,
                               answerEnabled: enabled && prompt.answer(Self.picks(selection)) != nil, keys: hints,
                               answer: { send($0) }, hide: { setHidden(true) })
                    .nwTransition(.content)
            }
        }
        .background { QuestionKeyReader(monitor: keys) }
        // The monitor reads the dock as it is when a key comes: its picks and focus through
        // their storage, the rest as this render has them.
        .onChange(of: KeyInputs(focused: focused, hidden: hidden, enabled: enabled), initial: true) { _, inputs in
            keys.perform = { key, editing in
                perform(prompt.action(for: key, picks: Self.picks(selection), hidden: inputs.hidden, editing: editing,
                                      enabled: inputs.enabled))
            }
            keys.editing = { [field = $field] in field.wrappedValue != nil }
            keys.watch(inputs.focused)
            if inputs.hidden { field = nil }
            // An open question is its field: it takes the keyboard as the composer's field would.
            else if inputs.focused, inputs.enabled, prompt.kind == .open { field = .text }
        }
        .onDisappear { keys.watch(false) }
    }

    private struct KeyInputs: Equatable {
        var focused: Bool
        var hidden: Bool
        var enabled: Bool
    }

    /// Does what a key's action says; false for a key that is not the dock's.
    private func perform(_ action: NativeQuestionKeyAction) -> Bool {
        switch action {
        case .pick(let number):
            selection.picked = number
        case .pickAndAnswer(let number):
            selection.picked = number
            send(selection)
        case .writeOther:
            if let other = prompt.otherNumber { selection.picked = other }
            field = .other
        case .answer:
            send(selection)
        case .hide:
            field = nil
            setHidden(true)
        case .show:
            setHidden(false)
        case .pass:
            return false
        }
        return true
    }

    private func send(_ selection: NWQuestionDockSelection) {
        guard enabled, let answer = prompt.answer(Self.picks(selection)) else { return }
        self.answer(answer)
    }

    static func picks(_ selection: NWQuestionDockSelection) -> NativeQuestionPicks {
        NativeQuestionPicks(picked: selection.picked, note: selection.note, other: selection.other, text: selection.text)
    }

    static func asker(_ asker: NativeQuestionAsker) -> NWQuestionAsker {
        switch asker {
        case .agent: .agent
        case .subagent(let name): .subagent(name)
        }
    }

    /// What the dock draws for `prompt`.
    static func content(_ prompt: NativeQuestionPrompt, count: Int = 1) -> NWQuestionDockContent {
        let kind: NWQuestionDockKind = switch prompt.kind {
        case .choice: .choice
        case .yesNo: .yesNo
        case .open: .open
        }
        return NWQuestionDockContent(
            asker: asker(prompt.asker), count: count, question: prompt.question, message: prompt.message, kind: kind,
            options: prompt.options.map { NWQuestionDockOption(number: $0.number, title: $0.title, detail: $0.detail, recommended: $0.recommended) },
            takesNote: prompt.takesNote, takesOther: prompt.takesOther, placeholder: prompt.placeholder, multiline: prompt.multiline,
            notice: prompt.blocked ?? (prompt.mayTimeOut ? timeoutNotice : nil), showsAnswer: prompt.showsAnswer)
    }

    static let timeoutNotice = "The agent may stop waiting for this answer"
}

// MARK: Keys

/// Takes the dock's keys (1–9 pick, ↩ answers, Esc hides or shows) in its window while its
/// thread has the keyboard, ahead of anything else: never with ⌘, ⌃ or ⌥ held (⌘1–9 still
/// select agents, ⇧↩ still breaks a line), and never from a text field outside the dock (the
/// palette's search, a sheet's). Tests hand it events directly.
@MainActor
final class QuestionKeyMonitor {
    weak var window: NSWindow?
    /// Whether one of the dock's own fields has the keyboard (numbers then type).
    var editing: () -> Bool = { false }
    /// Does what the key does; false leaves it to the window.
    var perform: (NativeQuestionKey, _ editing: Bool) -> Bool = { _, _ in false }
    private var monitor: Any?

    func watch(_ on: Bool) {
        if on, monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                let taken = MainActor.assumeIsolated { self?.handle(event) == true }
                return taken ? nil : event
            }
        } else if !on, let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    var watching: Bool { monitor != nil }

    @discardableResult
    func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let key = Self.key(event) else { return false }
        let editing = editing()
        // Another text field (the palette's search, a sheet's) keeps its keys; a terminal pane
        // with the keyboard is not the thread's (`focused` goes false).
        if !editing, window.firstResponder is NSText { return false }
        return perform(key, editing)
    }

    /// The dock's key for `event`, if it is one: a plain 1–9, ↩ (or Enter), or Esc.
    static func key(_ event: NSEvent) -> NativeQuestionKey? {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        guard modifiers.isEmpty else { return nil }
        switch event.keyCode {
        case 36, 76: return .answer
        case 53: return .escape
        default:
            guard let characters = event.charactersIgnoringModifiers, characters.count == 1,
                  let digit = Int(characters), (1...9).contains(digit) else { return nil }
            return .number(digit)
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }
}

/// Tells the key monitor which window the dock is in.
struct QuestionKeyReader: NSViewRepresentable {
    let monitor: QuestionKeyMonitor

    final class Reader: NSView {
        weak var monitor: QuestionKeyMonitor?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            monitor?.window = window
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.monitor = monitor
        return reader
    }

    func updateNSView(_ reader: Reader, context: Context) {
        reader.monitor = monitor
        monitor.window = reader.window
    }
}
