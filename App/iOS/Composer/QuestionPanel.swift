import SwiftUI
import ShepherdUI
import ShepherdProtocol

/// A question from the agent, in the composer's place (MobileQuestion board). The foundation's
/// version answers every kind pi asks (select, confirm, input, editor); the thread track brings
/// it to the board: numbered options, Recommended, "Something else…".
struct QuestionPanel: View {
    let dialog: NativeThreadDialog
    let enabled: Bool
    let answer: (NativeDialogAnswer) -> Void
    @State private var text: String

    init(dialog: NativeThreadDialog, enabled: Bool, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.dialog = dialog
        self.enabled = enabled
        self.answer = answer
        _text = State(initialValue: dialog.prefill ?? "")
    }

    var body: some View {
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.l) {
            VStack(alignment: .leading, spacing: NW.Space.xs) {
                Text("Question").nwSectionLabel()
                Text(dialog.title).font(.nw(.headline)).foregroundStyle(nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let message = dialog.message {
                    Text(message).font(.nw(.ui)).foregroundStyle(nw.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if dialog.unavailable != nil {
                Text("Answer this one on the host.").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
            }
            VStack(spacing: NW.Space.s) {
                switch dialog.kind {
                case .confirm:
                    Button("Yes") { answer(.confirm(value: true)) }.buttonStyle(.nw(.primary, size: .l))
                    Button("No") { answer(.confirm(value: false)) }.buttonStyle(.nw(.secondary, size: .l))
                case .select:
                    ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                        Button { answer(.select(value: option)) } label: {
                            HStack(spacing: NW.Space.m) {
                                NWQueueNumber(index + 1)
                                Text(option).multilineTextAlignment(.leading)
                                Spacer(minLength: 0)
                            }
                        }
                        .buttonStyle(.nw(.secondary, size: .l))
                        .accessibilityLabel("Choose \(option)")
                    }
                case .input, .editor:
                    TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                        .textFieldStyle(NWTextFieldStyle(mono: dialog.kind == .editor))
                        .lineLimit(dialog.kind == .editor ? 4...10 : 1...4)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Send answer") { answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text)) }
                        .buttonStyle(.nw(.primary, size: .l))
                }
                Button("Dismiss") { answer(.cancel) }.buttonStyle(.nw(.ghost, size: .l))
            }
            .frame(maxWidth: .infinity)
            .disabled(!enabled || dialog.unavailable != nil)
        }
        .padding(NW.Space.l)
        .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .nwBorder(nw.lineStrong, radius: NW.Radius.m)
        .accessibilityElement(children: .contain)
    }
}
