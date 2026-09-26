import SwiftUI
import ShepherdUI
import ShepherdProtocol
import ShepherdRemote

/// A question from pi or an extension, in the composer's place (MobileQuestion, iPadQuestion
/// boards), so a blocked agent is always answerable. Select questions list the asker's answers
/// as numbered cards (side by side on a wide iPad), one to choose and then Answer; the asker's
/// own "(Recommended)" marks one. Confirm questions answer Yes or No, the asker's wording being
/// the question itself. Input and editor questions take text. Dismiss always cancels.
struct QuestionPanel: View {
    let dialog: NativeThreadDialog
    let count: Int
    let enabled: Bool
    /// On a phone the panel docks to the bottom edge; on iPad it is a card in the column.
    let docked: Bool
    /// Who asks ("Agent is asking", "reviewer is asking"), and what the panel's way out says:
    /// Dismiss cancels pi's question; a subagent's is only hidden (Hide).
    var title = "Agent is asking"
    var dismissTitle = "Dismiss"
    /// iPad's Hide the question: folds the card to read the thread; never answers it.
    var hide: (() -> Void)?
    let answer: (NativeDialogAnswer) -> Void
    @Environment(\.composerMaxHeight) private var maxHeight
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var text: String
    @State private var chosen: Int?
    /// The panel's width: a wide one (iPad) lays two answers side by side.
    @State private var width: CGFloat = 0
    private let options: [NativeQuestionOption]

    init(dialog: NativeThreadDialog, count: Int = 1, enabled: Bool, docked: Bool = false, title: String = "Agent is asking",
         dismissTitle: String = "Dismiss", hide: (() -> Void)? = nil, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.title = title
        self.dismissTitle = dismissTitle
        self.hide = hide
        self.dialog = dialog
        self.count = count
        self.enabled = enabled
        self.docked = docked
        self.answer = answer
        options = NativeQuestionOption.options(dialog)
        _text = State(initialValue: dialog.prefill ?? "")
        _chosen = State(initialValue: nil)
    }

    var body: some View {
        let nw = Color.nw
        let blocked = !enabled || dialog.unavailable != nil
        NWQuestionCard(docked: docked, count: count, title: title, hide: hide) {
            // The question and its answers scroll inside a panel too tall for the screen (a
            // long message, a large text size); the actions stay in reach under them.
            VStack(alignment: .leading, spacing: NW.Space.l) {
                Text(dialog.title).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .accessibilityAddTraits(.isHeader)
                if let message = dialog.message {
                    Text(message).font(.nw(.code)).foregroundStyle(nw.textPrimary).textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(NW.Space.l)
                        .background(nw.bgSunken, in: RoundedRectangle(cornerRadius: NW.Radius.m))
                        .nwBorder(nw.lineSubtle, radius: NW.Radius.m)
                }
                if let unavailable = dialog.unavailable {
                    Text(unavailable == "external-editor" ? "An external editor is open on the host · finish it there" : "This question is too large to show here · answer it on the host")
                        .font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                }
                choices.disabled(blocked)
                if dialog.timeout != nil {
                    Text("The agent may stop waiting for this answer").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                }
            }
            .fittedScroll(maxHeight: maxHeight * MobileLayout.questionScrollShare)
            footer.disabled(blocked)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .accessibilityLabel("Question: \(dialog.title)")
    }

    /// The asker's answers: numbered cards, or the field.
    @ViewBuilder private var choices: some View {
        switch dialog.kind {
        case .select:
            if !docked, options.count > 1, !typeSize.isAccessibilitySize, width >= 2 * MobileLayout.questionColumn + NW.Space.m {
                Grid(horizontalSpacing: NW.Space.m, verticalSpacing: NW.Space.m) {
                    ForEach(Array(stride(from: 0, to: options.count, by: 2)), id: \.self) { start in
                        GridRow(alignment: .top) {
                            optionButton(options[start]).frame(maxHeight: .infinity, alignment: .top)
                            if start + 1 < options.count {
                                optionButton(options[start + 1]).frame(maxHeight: .infinity, alignment: .top)
                            } else {
                                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                            }
                        }
                    }
                }
            } else {
                VStack(spacing: NW.Space.m) {
                    ForEach(options) { optionButton($0) }
                }
            }
        case .confirm:
            EmptyView()
        case .input, .editor:
            TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                .textFieldStyle(NWTextFieldStyle(mono: dialog.kind == .editor))
                .lineLimit(dialog.kind == .editor ? 4...10 : 1...4)
                .textInputAutocapitalization(dialog.kind == .editor ? .never : .sentences)
                .autocorrectionDisabled(dialog.kind == .editor)
                .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Answer")
        }
    }

    /// What answers: Answer for a chosen option, Yes and No, or Send answer; always Dismiss.
    @ViewBuilder private var footer: some View {
        switch dialog.kind {
        case .select:
            actions(primary: "Answer", enabled: chosen != nil) {
                if let chosen, let option = options.first(where: { $0.number == chosen }) { answer(.select(value: option.value)) }
            }
        case .confirm:
            HStack(spacing: NW.Space.m) {
                Button { answer(.confirm(value: true)) } label: { Text(NativeConfirmAnswers.yes).frame(maxWidth: .infinity) }
                    .buttonStyle(.nw(.primary, size: .l))
                Button { answer(.confirm(value: false)) } label: { Text(NativeConfirmAnswers.no).frame(maxWidth: .infinity) }
                    .buttonStyle(.nw(.secondary, size: .l))
            }
            dismissButton
        case .input, .editor:
            actions(primary: "Send answer", enabled: true) {
                answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text))
            }
        }
    }

    private func optionButton(_ option: NativeQuestionOption) -> some View {
        Button {
            chosen = chosen == option.number ? nil : option.number
        } label: {
            NWQuestionOptionCard(number: option.number, title: option.title, detail: option.detail,
                                 recommended: option.recommended, selected: chosen == option.number)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(option.number). \(option.title)\(option.recommended ? ", recommended" : "")")
        .accessibilityHint(option.detail ?? "")
    }

    /// Dismiss, then the primary answer, trailing on a card (iPad) and full width docked (phone).
    private func actions(primary: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        HStack(spacing: NW.Space.m) {
            if !docked { Spacer(minLength: 0) }
            Button(dismissTitle) { answer(.cancel) }
                .buttonStyle(.nw(.ghost, size: .l))
            Button(action: action) { Text(primary).frame(maxWidth: docked ? .infinity : nil) }
                .buttonStyle(.nw(.primary, size: .l))
                .disabled(!enabled)
        }
    }

    private var dismissButton: some View {
        Button { answer(.cancel) } label: { Text(dismissTitle).frame(maxWidth: .infinity) }
            .buttonStyle(.nw(.ghost, size: .l))
    }
}
