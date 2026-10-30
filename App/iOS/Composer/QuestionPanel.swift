import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// pi's question in the composer's place (QuestionDockRadio, with the MobileQuestion and
/// iPadQuestion geometry), so a blocked agent is always answerable. It follows the question dock's
/// rules (docs/design/composer.md › Questions; `NativeQuestionPrompt`, as the Mac's dock does):
/// the question with its details folded, radio rows to pick, then Answer, or Skip to answer
/// nothing; a yes or a no that answers on a tap; an open question's field. Hiding (the grabber,
/// or iPad's Hide the question) folds it without answering.
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
    @FocusState private var field: SHQuestionDockField?

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
        let sh = Color.sh
        SHQuestionCard(docked: docked, count: count, question: prompt.question, hide: hide) {
            // The details and answers scroll inside a panel too tall for the screen (long
            // details, a large text size); Answer stays in reach under them.
            VStack(alignment: .leading, spacing: SH.Space.l) {
                if let details = prompt.details { SHQuestionDetails(details, maxHeight: nil) }
                if let message = prompt.message {
                    Text(message).font(.sh(.code)).foregroundStyle(sh.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(SH.Space.l)
                        .background(sh.bgSunken, in: RoundedRectangle(cornerRadius: SH.Radius.m))
                        .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                }
                choices.disabled(!enabled || prompt.blocked != nil)
                if let notice = prompt.blocked ?? (prompt.mayTimeOut ? QuestionPanel.timeoutNotice : nil) {
                    Text(notice).font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                }
            }
            .fittedScroll(maxHeight: maxHeight * MobileLayout.questionScrollShare)
            if prompt.showsAnswer {
                buttons
            }
        }
        .accessibilityLabel("Question: \(prompt.question)")
    }

    static let timeoutNotice = "The agent may stop waiting for this answer"

    /// The asker's answers: radio rows, a yes and a no, or the field.
    @ViewBuilder private var choices: some View {
        switch prompt.kind {
        case .choice:
            VStack(spacing: SH.Space.xxs) {
                ForEach(prompt.options) { option in
                    SHQuestionRadioRow(SHQuestionDockOption(number: option.number, title: option.title, detail: option.detail,
                                                            recommended: option.recommended),
                                       picked: picks.picked == option.number, showsNumber: false) {
                        // Picking another option moves the pick (and empties the field); nothing is answered until Answer.
                        var next = picks
                        next.picked = option.number
                        picks = NativeQuestionPicks.exclusive(picks, next)
                    }
                }
                if prompt.allowsText {
                    SHQuestionTextRow(text: Binding(get: { picks.text }, set: { text in
                        var next = picks
                        next.text = text
                        picks = NativeQuestionPicks.exclusive(picks, next)
                    }), focus: $field, number: nil)
                }
            }
            .padding(.horizontal, -SH.Space.m)
        case .yesNo:
            VStack(spacing: SH.Space.s) {
                // Side by side, each answering on a tap; stacked at accessibility sizes.
                let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(spacing: SH.Space.s))
                    : AnyLayout(HStackLayout(alignment: .top, spacing: SH.Space.s))
                layout {
                    ForEach(prompt.options) { option in
                        SHQuestionOptionCard(number: option.number, title: option.title, detail: option.detail,
                                             recommended: option.recommended, selected: picks.picked == option.number) {
                            picks.picked = option.number
                            send()
                        }
                        .frame(minHeight: SHTouchQuestionMetrics.yesNoHeight)
                    }
                }
            }
        case .open:
            answerField
        }
    }

    /// An open question's field.
    private var answerField: some View {
        TextField(prompt.placeholder, text: $picks.text, axis: .vertical)
            .textFieldStyle(SHTextFieldStyle(mono: prompt.multiline))
            .lineLimit(prompt.multiline ? 4...12 : 1...6)
            .textInputAutocapitalization(prompt.multiline ? .never : .sentences)
            .autocorrectionDisabled(prompt.multiline)
            .focused($field, equals: .text)
            .accessibilityLabel(prompt.multiline ? "Editor answer" : "Answer")
    }

    /// Skip and Answer (lit once there is an answer): docked, Answer is the phone's 48pt bar
    /// button with Skip before it; trailing on iPad's card.
    @ViewBuilder private var buttons: some View {
        let ready = enabled && prompt.answer(picks) != nil
        let canSkip = enabled && prompt.blocked == nil
        HStack(spacing: SH.Space.m) {
            if !docked { Spacer(minLength: 0) }
            Button("Skip") { skip() }
                .buttonStyle(.sh(.ghost, size: .l))
                .frame(minHeight: SH.Height.touch)
                .disabled(!canSkip)
                .accessibilityHint("The agent is told you didn't answer")
            if docked {
                Button("Answer") { send() }.buttonStyle(.shReviewBar(.primary)).disabled(!ready)
            } else {
                Button("Answer") { send() }.buttonStyle(.sh(.primary, size: .l)).disabled(!ready)
            }
        }
    }

    private func send() {
        guard enabled, let answer = prompt.answer(picks) else { return }
        field = nil
        self.answer(answer)
    }

    private func skip() {
        guard enabled, prompt.blocked == nil else { return }
        field = nil
        answer(.skip)
    }
}
