import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A question in the composer's place (MobileQuestion, iPadQuestion boards), pi's own or a
/// subagent's, so a blocked agent is always answerable. It follows the question dock's rules
/// (DESIGN.md › Questions; `NativeQuestionPrompt`, as the Mac's dock does): numbered options to
/// pick, then Answer; a yes or a no that answers on a tap; an open question's field; and, for an
/// asker that takes them, a note on the picked option and Something else… for an answer in the
/// person's own words. Answer is the only button: Stop in the thread's header refuses pi's
/// question, and hiding (the grabber, or iPad's Hide the question) folds it without answering.
struct QuestionPanel: View {
    let prompt: NativeQuestionPrompt
    let count: Int
    let enabled: Bool
    /// On a phone the panel docks to the bottom edge; on iPad it is a card in the column.
    let docked: Bool
    let hide: (() -> Void)?
    let answer: (NativeQuestionAnswer) -> Void
    @Environment(\.composerMaxHeight) private var maxHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var picks: NativeQuestionPicks
    @FocusState private var field: Field?
    /// The panel's width: a wide one (iPad) lays two answers side by side.
    @State private var width: CGFloat = 0

    private enum Field: Hashable { case note, other, text }

    init(prompt: NativeQuestionPrompt, count: Int = 1, enabled: Bool, docked: Bool = false, hide: (() -> Void)? = nil,
         answer: @escaping (NativeQuestionAnswer) -> Void) {
        self.prompt = prompt
        self.count = count
        self.enabled = enabled
        self.docked = docked
        self.hide = hide
        self.answer = answer
        _picks = State(initialValue: NativeQuestionPicks(prompt))
    }

    var body: some View {
        let nw = Color.nw
        NWQuestionCard(docked: docked, count: count, asker: Self.asker(prompt.asker), hide: hide) {
            // The question and its answers scroll inside a panel too tall for the screen (a
            // long message, a large text size); Answer stays in reach under them.
            VStack(alignment: .leading, spacing: NW.Space.l) {
                Text(prompt.question).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let message = prompt.message {
                    Text(message).font(.nw(.code)).foregroundStyle(nw.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NW.Space.l)
                        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                }
                choices.disabled(!enabled || prompt.blocked != nil)
                if let notice = prompt.blocked ?? (prompt.mayTimeOut ? QuestionPanel.timeoutNotice : nil) {
                    Text(notice).font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                }
            }
            .fittedScroll(maxHeight: maxHeight * MobileLayout.questionScrollShare)
            if prompt.showsAnswer {
                answerButton
            }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .onChange(of: picks.other) { _, other in
            // Typing in Something else picks it.
            if let number = prompt.otherNumber, !other.isEmpty { picks.picked = number }
        }
        .accessibilityLabel("Question: \(prompt.question)")
    }

    static let timeoutNotice = "The agent may stop waiting for this answer"

    static func asker(_ asker: NativeQuestionAsker) -> NWQuestionAsker {
        switch asker {
        case .agent: .agent
        case .subagent(let name): .subagent(name)
        }
    }

    /// The asker's answers: numbered options, a yes and a no, or the field.
    @ViewBuilder private var choices: some View {
        switch prompt.kind {
        case .choice:
            VStack(spacing: NW.Space.s) {
                if !docked, prompt.options.count > 1, !typeSize.isAccessibilitySize, width >= 2 * MobileLayout.questionColumn + NW.Space.m {
                    Grid(horizontalSpacing: NW.Space.m, verticalSpacing: NW.Space.m) {
                        ForEach(Array(stride(from: 0, to: prompt.options.count, by: 2)), id: \.self) { start in
                            GridRow(alignment: .top) {
                                option(prompt.options[start]).frame(maxHeight: .infinity, alignment: .top)
                                if start + 1 < prompt.options.count {
                                    option(prompt.options[start + 1]).frame(maxHeight: .infinity, alignment: .top)
                                } else {
                                    Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                                }
                            }
                        }
                    }
                } else {
                    ForEach(prompt.options) { option($0) }
                }
                other
            }
        case .yesNo:
            VStack(spacing: NW.Space.s) {
                // Side by side, each answering on a tap; stacked at accessibility sizes.
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: NW.Space.s))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: NW.Space.s))
                layout {
                    ForEach(prompt.options) { option in
                        NWQuestionOptionCard(number: option.number, title: option.title, detail: option.detail,
                                             recommended: option.recommended, selected: picks.picked == option.number) {
                            picks.picked = option.number
                            send()
                        }
                        .frame(minHeight: NWTouchQuestionMetrics.yesNoHeight)
                    }
                }
                other
            }
        case .open:
            TextField(prompt.placeholder, text: $picks.text, axis: .vertical)
                .textFieldStyle(NWTextFieldStyle(mono: prompt.multiline))
                .lineLimit(prompt.multiline ? 4...12 : 1...6)
                .textInputAutocapitalization(prompt.multiline ? .never : .sentences)
                .autocorrectionDisabled(prompt.multiline)
                .focused($field, equals: .text)
                .accessibilityLabel(prompt.multiline ? "Editor answer" : "Answer")
        }
    }

    private func option(_ option: NativeQuestionOption) -> some View {
        let picked = picks.picked == option.number
        return NWQuestionOptionCard(number: option.number, title: option.title, detail: option.detail,
                                    recommended: option.recommended, selected: picked) {
            // Picking another option moves the pick; nothing is answered until Answer.
            picks.picked = option.number
            if field == .other { field = nil }
        } footer: {
            if picked, prompt.takesNote {
                NWQuestionNoteField(text: $picks.note)
                    .focused($field, equals: .note)
            }
        }
    }

    /// Something else…: the last row, for an asker that takes words of its own.
    @ViewBuilder private var other: some View {
        if let number = prompt.otherNumber {
            NWQuestionOtherCard(number: number, selected: picks.picked == number) {
                TextField("Something else…", text: $picks.other, axis: .vertical)
                    .lineLimit(1...4)
                    .focused($field, equals: .other)
                    .accessibilityLabel("\(number). Something else")
            }
            .onChange(of: field) { _, field in
                if field == .other { picks.picked = number }
            }
        }
    }

    /// Answer, lit once there is an answer: full width docked (the phone's 48pt bar button),
    /// trailing on iPad's card.
    @ViewBuilder private var answerButton: some View {
        let ready = enabled && prompt.answer(picks) != nil
        if docked {
            Button("Answer") { send() }
                .buttonStyle(.nwReviewBar(.primary))
                .disabled(!ready)
        } else {
            HStack {
                Spacer(minLength: 0)
                Button("Answer") { send() }
                    .buttonStyle(.nw(.primary, size: .l))
                    .disabled(!ready)
            }
        }
    }

    private func send() {
        guard enabled, let answer = prompt.answer(picks) else { return }
        field = nil
        self.answer(answer)
    }
}
