import SwiftUI
import ShepherdProtocol

struct ThreadDialogView: View {
    let dialog: NativeThreadDialog
    let enabled: Bool
    let answer: (NativeDialogAnswer) -> Void
    @Environment(\.colorScheme) private var scheme
    @State private var text: String

    init(dialog: NativeThreadDialog, enabled: Bool, answer: @escaping (NativeDialogAnswer) -> Void) {
        self.dialog = dialog
        self.enabled = enabled
        self.answer = answer
        _text = State(initialValue: dialog.prefill ?? "")
    }

    var body: some View {
        let tokens = MobileTokens(scheme: scheme)
        let blocked = !enabled || dialog.unavailable != nil
        VStack(alignment: .leading, spacing: 12) {
            Label("Agent is asking", systemImage: "questionmark.circle")
                .font(MobileTokens.caption)
                .foregroundStyle(tokens.status(.blocked))
            Text(dialog.title).font(MobileTokens.heading)
            if let message = dialog.message {
                Text(message).font(MobileTokens.prose).textSelection(.enabled)
            }
            if let unavailable = dialog.unavailable {
                Label(unavailable == "external-editor"
                      ? "An editor is open on your Mac. Close it there to answer here."
                      : "Answer this one on your Mac.", systemImage: "desktopcomputer")
                    .font(MobileTokens.caption)
                    .foregroundStyle(tokens.secondary)
            }
            Group {
                switch dialog.kind {
                case .select:
                    VStack(spacing: MobileTokens.spacing) {
                        ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { _, option in
                            Button { answer(.select(value: option)) } label: {
                                Text(option).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 12)
                            }
                            .buttonStyle(.bordered)
                            .accessibilityLabel("Choose \(option)")
                        }
                    }
                case .confirm:
                    HStack(spacing: MobileTokens.spacing) {
                        Button { answer(.confirm(value: true)) } label: {
                            Text("Confirm").foregroundStyle(tokens.onAccent).frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.borderedProminent)
                        Button { answer(.confirm(value: false)) } label: {
                            Text("Decline").frame(maxWidth: .infinity, minHeight: 32)
                        }
                        .buttonStyle(.bordered)
                    }
                    .controlSize(.large)
                case .input, .editor:
                    TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                        .lineLimit(dialog.kind == .editor ? 5...12 : 1...5)
                        .font(dialog.kind == .editor ? MobileTokens.mono : MobileTokens.prose)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .padding(10)
                        .background(tokens.background, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.border, lineWidth: 1))
                        .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Input answer")
                    Button {
                        answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text))
                    } label: {
                        Text("Submit").foregroundStyle(tokens.onAccent).frame(maxWidth: .infinity, minHeight: 32)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                Button("cancel dialog", role: .cancel) { answer(.cancel) }
                    .font(MobileTokens.caption)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(blocked)
            if dialog.timeout != nil {
                Text("May time out on the host.")
                    .font(MobileTokens.caption)
                    .foregroundStyle(tokens.secondary)
            }
        }
        .padding(MobileTokens.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tokens.raised, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
        .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius)
            .strokeBorder(blocked ? tokens.border : tokens.status(.blocked), lineWidth: 1))
    }
}
