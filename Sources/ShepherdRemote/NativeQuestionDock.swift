import Foundation
import ShepherdProtocol

// The question dock's presentation (QuestionAsk, QuestionPick, QuestionStates), shared by the
// Mac and the touch clients: pi's own question (an extension's select, confirm, input or editor)
// shaped by the answer it needs, what it can take (Honest affordances), the answer a person's
// picks make, and what the dock's keys do. A subagent never asks the user, so no question here is
// its: it asks its parent. Pure, so every rule is a unit test.

/// The dock's shape, from the answer the asker needs (QuestionStates › Kinds of question).
public enum NativeQuestionKind: Equatable, Sendable {
    /// Numbered options: pick one, then Answer.
    case choice
    /// Two short options side by side that answer on click.
    case yesNo
    /// No options: a field, then Answer.
    case open
}

/// One question as the dock draws it.
public struct NativeQuestionPrompt: Equatable, Sendable {
    /// What the asker takes back.
    public enum Reply: Equatable, Sendable {
        /// pi's select: one of the options exactly as offered.
        case select
        /// pi's confirm: yes or no.
        case confirm
        /// pi's input (one line) or editor (several): the text.
        case input
        case editor
    }

    /// Identity: a new id is a new question, which arrives with nothing picked.
    public var id: String
    public var reply: Reply
    public var question: String
    /// The asker's longer message (a confirm's), drawn under the question.
    public var message: String?
    public var kind: NativeQuestionKind
    public var options: [NativeQuestionOption]
    /// An open question's field: its placeholder, its first text, and whether it takes lines.
    public var placeholder: String
    public var prefill: String
    public var multiline: Bool
    /// pi stops waiting for the answer when its timeout passes.
    public var mayTimeOut: Bool
    /// Why it cannot be answered here, when it cannot.
    public var blocked: String?

    /// Options at most this long, two of them with nothing under their titles, sit side by side.
    public static let shortOption = 24

    /// pi's question: select, confirm, input or editor.
    public init(dialog: NativeThreadDialog) {
        id = dialog.id
        question = dialog.title
        message = dialog.message.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        placeholder = dialog.placeholder ?? "Type your answer…"
        prefill = dialog.prefill ?? ""
        mayTimeOut = (dialog.timeout ?? 0) > 0
        blocked = dialog.unavailable.map(Self.blockedText)
        // pi's select returns one of its options and nothing else, confirm a yes or a no, and
        // input and editor a string: none takes a note, and only the fields take words.
        switch dialog.kind {
        case .select:
            reply = .select
            options = NativeQuestionOption.options(dialog)
            kind = Self.kind(options)
        case .confirm:
            reply = .confirm
            options = NativeQuestionOption.options([NativeConfirmAnswers.yes, NativeConfirmAnswers.no])
            kind = .yesNo
        case .input:
            reply = .input
            options = []
            kind = .open
        case .editor:
            reply = .editor
            options = []
            kind = .open
        }
        multiline = reply == .editor
    }

    /// Two short options with nothing under them are a yes or a no; none is an open question.
    static func kind(_ options: [NativeQuestionOption]) -> NativeQuestionKind {
        if options.isEmpty { return .open }
        if options.count == 2, options.allSatisfy({ $0.detail == nil && $0.title.count <= shortOption }) { return .yesNo }
        return .choice
    }

    static func blockedText(_ reason: String) -> String {
        reason == "external-editor" ? "An external editor is open · finish it before answering here" : "This question is too large to show here"
    }

    /// Answer is drawn: for a choice or an open question. A yes or a no answers on click.
    public var showsAnswer: Bool {
        kind != .yesNo
    }
}

/// What the person has chosen or typed so far.
public struct NativeQuestionPicks: Equatable, Sendable {
    /// An option's number.
    public var picked: Int?
    /// An open question's text.
    public var text: String

    public init(picked: Int? = nil, text: String = "") {
        self.picked = picked
        self.text = text
    }

    /// Nothing picked, the open question's field holding what the asker put there.
    public init(_ prompt: NativeQuestionPrompt) {
        self.init(text: prompt.prefill)
    }
}

/// An answer the picks make.
public enum NativeQuestionAnswer: Equatable, Sendable {
    /// An option, exactly as offered.
    case option(NativeQuestionOption)
    /// The person's own words, in an open question's field.
    case words(String)
}

extension NativeQuestionPrompt {
    /// The answer `picks` make, nil while there is none: nothing picked, an open question still
    /// empty, or a question that cannot be answered here.
    public func answer(_ picks: NativeQuestionPicks) -> NativeQuestionAnswer? {
        guard blocked == nil else { return nil }
        if kind == .open {
            // An editor's answer is the text as typed; an input's, trimmed.
            let text = picks.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : .words(reply == .editor ? picks.text : text)
        }
        guard let picked = picks.picked, let option = options.first(where: { $0.number == picked }) else { return nil }
        return .option(option)
    }

    /// What pi's dialog gets for `answer`; nil for an answer the dialog cannot take.
    public func dialogAnswer(_ answer: NativeQuestionAnswer) -> NativeDialogAnswer? {
        switch (reply, answer) {
        case (.select, .option(let option)): return .select(value: option.value)
        case (.confirm, .option(let option)): return .confirm(value: option.number == 1)
        case (.input, .words(let text)): return .input(value: text)
        case (.editor, .words(let text)): return .editor(value: text)
        default: return nil
        }
    }
}

// MARK: Keys

/// A key the dock answers (QuestionStates › Keyboard): 1–9 pick, ↩ answers, Esc hides or shows.
public enum NativeQuestionKey: Equatable, Sendable {
    case number(Int)
    case answer
    case escape
}

/// What a key does to the dock.
public enum NativeQuestionKeyAction: Equatable, Sendable {
    /// Pick that option (moving the pick).
    case pick(Int)
    /// Pick and answer at once: a yes or a no.
    case pickAndAnswer(Int)
    case answer
    case hide
    case show
    /// Not the dock's: the key goes on (typing in a field, a number with no option).
    case pass
}

extension NativeQuestionPrompt {
    /// What `key` does. `hidden`: the dock is folded to its line. `editing`: one of the dock's
    /// fields has the keyboard, so numbers type. `enabled`: the host takes answers.
    public func action(for key: NativeQuestionKey, picks: NativeQuestionPicks, hidden: Bool, editing: Bool,
                       enabled: Bool = true) -> NativeQuestionKeyAction {
        switch key {
        case .escape:
            return hidden ? .show : .hide
        case _ where hidden:
            return .pass
        case .answer:
            return enabled && answer(picks) != nil ? .answer : .pass
        case .number(let number):
            guard !editing, enabled, blocked == nil else { return .pass }
            if options.contains(where: { $0.number == number }) { return kind == .yesNo ? .pickAndAnswer(number) : .pick(number) }
            return .pass
        }
    }
}
