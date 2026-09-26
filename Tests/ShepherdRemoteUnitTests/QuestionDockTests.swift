import ShepherdProtocol
import Testing
@testable import ShepherdRemote

/// The question dock's presentation: each asker's question shaped by the answer it needs, only
/// the affordances the asker can take, the answer the picks make, and the dock's keys.
@Suite("Question dock")
struct QuestionDockTests {
    static let select = NativeThreadDialog(id: "d1", kind: .select, title: "How should I handle Horizon’s uncommitted edits?",
                                           options: ["Compare first (Recommended)\nDiff the 11 files against master.",
                                                     "Leave Horizon alone\nDeploy from a clean checkout.",
                                                     "Discard the edits"])

    // MARK: Kinds

    @Test(arguments: [
        (NativeThreadDialog(id: "a", kind: .select, title: "Pick", options: ["One\nwhy", "Two"]), NativeQuestionKind.choice),
        (NativeThreadDialog(id: "b", kind: .select, title: "Fix it?", options: ["Yes, fix it", "No"]), .yesNo),
        (NativeThreadDialog(id: "c", kind: .select, title: "Pick", options: ["A", "B", "C"]), .choice),
        (NativeThreadDialog(id: "d", kind: .select, title: "Pick", options: ["Keep the whole branch as it is today", "No"]), .choice),
        (NativeThreadDialog(id: "e", kind: .confirm, title: "Clear session?"), .yesNo),
        (NativeThreadDialog(id: "f", kind: .input, title: "Name?"), .open),
        (NativeThreadDialog(id: "g", kind: .editor, title: "Edit"), .open),
        (NativeThreadDialog(id: "h", kind: .select, title: "Pick", options: []), .open),
    ])
    func eachDialogTakesTheShapeOfTheAnswerItNeeds(dialog: NativeThreadDialog, kind: NativeQuestionKind) {
        #expect(NativeQuestionPrompt(dialog: dialog).kind == kind)
    }

    @Test func aConfirmOffersYesThenNo() {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "c", kind: .confirm, title: "Clear session?", message: "All messages will be lost."))
        #expect(prompt.options.map(\.title) == ["Yes", "No"])
        #expect(prompt.options.map(\.number) == [1, 2])
        #expect(prompt.message == "All messages will be lost.")
        #expect(!prompt.showsAnswer, "a yes or a no answers on click")
    }

    @Test func optionsAreNumberedAndTheRecommendedOneMarkedNeverPicked() {
        let prompt = NativeQuestionPrompt(dialog: Self.select)
        #expect(prompt.options.map(\.number) == [1, 2, 3])
        #expect(prompt.options.map(\.recommended) == [true, false, false])
        #expect(prompt.options[0].title == "Compare first")
        #expect(prompt.options[0].detail == "Diff the 11 files against master.")
        #expect(NativeQuestionPicks(prompt).picked == nil)
        #expect(prompt.answer(NativeQuestionPicks(prompt)) == nil, "Answer waits for a pick")
    }

    @Test func anOpenQuestionStartsWithWhatTheAskerPutInItsField() {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "e", kind: .editor, title: "Edit the message", prefill: "fix: typo"))
        #expect(NativeQuestionPicks(prompt).text == "fix: typo")
        #expect(prompt.multiline)
        #expect(prompt.showsAnswer)
    }

    // MARK: Honest affordances

    /// pi's select returns one of its options, confirm a bool, input and editor a string: none
    /// takes a note or a free answer beside its options.
    @Test(arguments: [NativeThreadDialog.Kind.select, .confirm, .input, .editor])
    func pisQuestionsOfferNoNoteAndNoSomethingElse(kind: NativeThreadDialog.Kind) {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "d", kind: kind, title: "Q", options: kind == .select ? ["A", "B", "C"] : nil))
        #expect(!prompt.takesNote)
        #expect(!prompt.takesOther)
        #expect(prompt.otherNumber == nil)
    }

    /// A subagent's answer is a message to its run, so it takes a note and words of its own.
    @Test func aSubagentsQuestionTakesANoteAndSomethingElse() {
        let prompt = NativeQuestionPrompt(runID: "r1", name: "reviewer", question: "Rename, or replace?",
                                          options: ["Replace everywhere (Recommended)\n41 call sites.", "Rename the new ones\nKeeps both."])
        #expect(prompt.asker == .subagent("reviewer"))
        #expect(prompt.takesNote && prompt.takesOther)
        #expect(prompt.otherNumber == 3, "Something else is the last row")
        #expect(prompt.kind == .choice)
    }

    @Test func aSubagentsQuestionWithoutAnswersIsAReply() {
        let prompt = NativeQuestionPrompt(runID: "r1", name: "reviewer", question: "What next?", options: nil)
        #expect(prompt.kind == .open)
        #expect(prompt.otherNumber == nil)
        #expect(prompt.placeholder == "Reply to reviewer…")
    }

    @Test func aSubagentsYesOrNoKeepsAnswerForSomethingElse() {
        let prompt = NativeQuestionPrompt(runID: "r1", name: "tests", question: "Is this a regression?", options: ["Yes, fix it", "No"])
        #expect(prompt.kind == .yesNo)
        #expect(prompt.showsAnswer)
    }

    // MARK: Answers

    @Test func aSelectAnswersWithTheOptionExactlyAsOffered() throws {
        let prompt = NativeQuestionPrompt(dialog: Self.select)
        let answer = try #require(prompt.answer(NativeQuestionPicks(picked: 1, note: "ignored")))
        #expect(prompt.dialogAnswer(answer) == .select(value: Self.select.options![0]))
        #expect(prompt.messageReply(answer) == nil)
    }

    @Test(arguments: [(1, true), (2, false)])
    func aConfirmAnswersYesOrNo(picked: Int, value: Bool) throws {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "c", kind: .confirm, title: "Clear?"))
        let answer = try #require(prompt.answer(NativeQuestionPicks(picked: picked)))
        #expect(prompt.dialogAnswer(answer) == .confirm(value: value))
    }

    @Test(arguments: [
        (NativeThreadDialog.Kind.input, "  main  ", NativeDialogAnswer?.some(.input(value: "main"))),
        (.input, "   ", nil),
        (.editor, "line one\nline two\n", .editor(value: "line one\nline two\n")),
        (.editor, "\n", nil),
    ])
    func anOpenQuestionAnswersWithItsText(kind: NativeThreadDialog.Kind, text: String, expected: NativeDialogAnswer?) {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "o", kind: kind, title: "Q"))
        #expect(prompt.answer(NativeQuestionPicks(text: text)).flatMap(prompt.dialogAnswer) == expected)
    }

    @Test(arguments: ["external-editor", "payload-limit"])
    func aQuestionThatCannotBeAnsweredHereSaysWhyAndTakesNoAnswer(reason: String) {
        let prompt = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "x", kind: .select, title: "Q", options: ["A", "B", "C"], unavailable: reason))
        #expect(prompt.blocked != nil)
        #expect(prompt.answer(NativeQuestionPicks(picked: 1)) == nil)
        #expect(prompt.action(for: .number(1), picks: NativeQuestionPicks(), hidden: false, editing: false) == .pass)
    }

    @Test func aTimeoutIsSaid() {
        #expect(NativeQuestionPrompt(dialog: NativeThreadDialog(id: "t", kind: .confirm, title: "Q", timeout: 60_000)).mayTimeOut)
        #expect(!NativeQuestionPrompt(dialog: NativeThreadDialog(id: "t", kind: .confirm, title: "Q")).mayTimeOut)
    }

    @Test(arguments: [
        (NativeQuestionPicks(picked: 1), "Replace everywhere (Recommended)\n41 call sites."),
        (NativeQuestionPicks(picked: 1, note: " Keep the old names as aliases. "), "Replace everywhere (Recommended)\n41 call sites.\n\nKeep the old names as aliases."),
        (NativeQuestionPicks(picked: 3, note: "not sent", other: "Ask the design team first"), "Ask the design team first"),
    ])
    func aSubagentGetsTheOptionWithItsNoteOrTheWordsTyped(picks: NativeQuestionPicks, reply: String) throws {
        let prompt = NativeQuestionPrompt(runID: "r1", name: "reviewer", question: "Rename, or replace?",
                                          options: ["Replace everywhere (Recommended)\n41 call sites.", "Rename the new ones"])
        let answer = try #require(prompt.answer(picks))
        #expect(prompt.messageReply(answer) == reply)
        #expect(prompt.dialogAnswer(answer) == nil)
    }

    @Test func somethingElseAnswersOnlyOnceItHasWords() {
        let prompt = NativeQuestionPrompt(runID: "r1", name: "reviewer", question: "Q", options: ["A\nwhy", "B\nwhy"])
        #expect(prompt.answer(NativeQuestionPicks(picked: 3, other: "  ")) == nil)
        #expect(prompt.answer(NativeQuestionPicks(picked: 3, other: "C")) == .words("C"))
    }

    // MARK: Keys

    static let choice = NativeQuestionPrompt(dialog: select)
    static let yesNo = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "c", kind: .confirm, title: "Clear?"))
    static let subagent = NativeQuestionPrompt(runID: "r1", name: "reviewer", question: "Q", options: ["A\nwhy", "B\nwhy"])
    static let open = NativeQuestionPrompt(dialog: NativeThreadDialog(id: "i", kind: .input, title: "Name?"))

    @Test(arguments: [
        // Numbers pick; past the options they are not the dock's.
        (choice, NativeQuestionKey.number(2), NativeQuestionPicks(), false, false, NativeQuestionKeyAction.pick(2)),
        (choice, .number(4), NativeQuestionPicks(), false, false, .pass),
        // A yes or a no answers as it is picked.
        (yesNo, .number(1), NativeQuestionPicks(), false, false, .pickAndAnswer(1)),
        // Something else's number puts the keyboard in it.
        (subagent, .number(3), NativeQuestionPicks(), false, false, .writeOther),
        // In a field, numbers type.
        (subagent, .number(1), NativeQuestionPicks(), false, true, .pass),
        (open, .number(1), NativeQuestionPicks(), false, true, .pass),
        // ↩ answers once there is an answer, from a field too.
        (choice, .answer, NativeQuestionPicks(), false, false, .pass),
        (choice, .answer, NativeQuestionPicks(picked: 1), false, false, .answer),
        (subagent, .answer, NativeQuestionPicks(picked: 1, note: "why"), false, true, .answer),
        (open, .answer, NativeQuestionPicks(text: "main"), false, true, .answer),
        (open, .answer, NativeQuestionPicks(), false, true, .pass),
        // Esc hides, from a field too, and shows again.
        (choice, .escape, NativeQuestionPicks(), false, false, .hide),
        (open, .escape, NativeQuestionPicks(), false, true, .hide),
        (choice, .escape, NativeQuestionPicks(), true, false, .show),
        // Hidden, only Esc is the dock's.
        (choice, .number(1), NativeQuestionPicks(), true, false, .pass),
        (choice, .answer, NativeQuestionPicks(picked: 1), true, false, .pass),
    ])
    func theDocksKeys(prompt: NativeQuestionPrompt, key: NativeQuestionKey, picks: NativeQuestionPicks, hidden: Bool, editing: Bool,
                      action: NativeQuestionKeyAction) {
        #expect(prompt.action(for: key, picks: picks, hidden: hidden, editing: editing) == action)
    }

    @Test func aHostThatTakesNoAnswersLeavesOnlyHiding() {
        let picks = NativeQuestionPicks(picked: 1)
        #expect(Self.choice.action(for: .number(1), picks: picks, hidden: false, editing: false, enabled: false) == .pass)
        #expect(Self.choice.action(for: .answer, picks: picks, hidden: false, editing: false, enabled: false) == .pass)
        #expect(Self.choice.action(for: .escape, picks: picks, hidden: false, editing: false, enabled: false) == .hide)
    }
}
