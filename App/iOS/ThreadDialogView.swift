import SwiftUI
import ShepherdProtocol

/// Approval sheet content (DESIGN.md › iOS): warning glyph + title,
/// optional command block, stacked 50pt actions. pi's standard dialogs map as confirm →
/// Allow once / Deny, select → stacked options, input/editor → field + Submit. "Always for
/// this agent" only appears when a select option literally says so; pi's dialogs carry no
/// such option today, so it is normally absent. Cancel is a plain secondary action.
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
        ScrollView {
            VStack(alignment: .leading, spacing: MobileTokens.inset) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "exclamationmark.circle")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(tokens.warning)
                        .frame(width: 32, height: 32)
                        .background(tokens.warningBg, in: Circle())
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(dialog.title).font(MobileTokens.heading).foregroundStyle(tokens.text)
                        Text("Agent is asking").font(MobileTokens.caption12).foregroundStyle(tokens.textTertiary)
                    }
                }
                if let message = dialog.message {
                    Text(message).font(MobileTokens.code).foregroundStyle(tokens.text).textSelection(.enabled)
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(tokens.muted, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
                        .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.border, lineWidth: 1))
                }
                if let unavailable = dialog.unavailable {
                    Label(unavailable == "external-editor"
                          ? "An editor is open on your Mac. Close it there to answer here."
                          : "Answer this one on your Mac.", systemImage: "desktopcomputer")
                        .font(MobileTokens.caption12)
                        .foregroundStyle(tokens.textTertiary)
                }
                VStack(spacing: MobileTokens.spacing) {
                    switch dialog.kind {
                    case .confirm:
                        Button("Allow once") { answer(.confirm(value: true)) }
                            .buttonStyle(MobileActionStyle(kind: .primary, tokens: tokens))
                        Button("Deny") { answer(.confirm(value: false)) }
                            .buttonStyle(MobileActionStyle(kind: .destructive, tokens: tokens))
                    case .select:
                        ForEach(Array((dialog.options ?? []).enumerated()), id: \.offset) { index, option in
                            Button { answer(.select(value: option)) } label: {
                                Text(option).multilineTextAlignment(.center).padding(.horizontal, 12)
                            }
                            .buttonStyle(MobileActionStyle(kind: index == 0 ? .primary : .secondary, tokens: tokens))
                            .accessibilityLabel("Choose \(option)")
                        }
                    case .input, .editor:
                        TextField(dialog.placeholder ?? "Answer", text: $text, axis: .vertical)
                            .lineLimit(dialog.kind == .editor ? 5...12 : 1...5)
                            .font(dialog.kind == .editor ? MobileTokens.code : MobileTokens.bubble)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .padding(.horizontal, 14).padding(.vertical, 12)
                            .frame(minHeight: MobileTokens.touch)
                            .background(tokens.raised, in: RoundedRectangle(cornerRadius: MobileTokens.radius))
                            .overlay(RoundedRectangle(cornerRadius: MobileTokens.radius).strokeBorder(tokens.borderStrong, lineWidth: 1))
                            .accessibilityLabel(dialog.kind == .editor ? "Editor answer" : "Input answer")
                        Button("Submit") { answer(dialog.kind == .editor ? .editor(value: text) : .input(value: text)) }
                            .buttonStyle(MobileActionStyle(kind: .primary, tokens: tokens))
                    }
                    Button("Cancel") { answer(.cancel) }
                        .buttonStyle(MobileActionStyle(kind: .ghost, tokens: tokens))
                        .accessibilityLabel("Cancel dialog")
                }
                .disabled(blocked)
                if dialog.timeout != nil {
                    Text("May time out on the host").font(MobileTokens.micro).foregroundStyle(tokens.textMuted)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, MobileTokens.homeIndicatorPadding)
        }
        .scrollBounceBehavior(.basedOnSize)
        .background(tokens.surface)
        .foregroundStyle(tokens.text)
        .tint(tokens.accent)
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(MobileTokens.sheetRadius)
        .presentationDetents(dialog.kind == .editor ? [.large] : [.medium, .large])
        .presentationBackground(tokens.surface)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Agent is asking: \(dialog.title)")
    }
}
