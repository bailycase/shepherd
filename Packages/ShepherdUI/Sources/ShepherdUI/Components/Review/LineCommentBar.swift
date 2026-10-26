import SwiftUI

/// Commenting on a selected diff line from the bottom of the phone's diff reader (MobileDiff
/// board): "line 16 selected", Delete while the line already has a comment, and Done to clear
/// the selection, over a 44pt capsule field ("Comment on line 16…") with a lantern send button
/// that dims until there is text. Delete removes the line's comment.
public struct SHLineCommentBar: View {
    let lineLabel: String
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let canDelete: Bool
    let onSend: () -> Void
    let onDelete: () -> Void
    let onDone: () -> Void

    public init(lineLabel: String, text: Binding<String>, isFocused: FocusState<Bool>.Binding, canDelete: Bool,
                onSend: @escaping () -> Void, onDelete: @escaping () -> Void, onDone: @escaping () -> Void) {
        self.lineLabel = lineLabel
        _text = text
        self.isFocused = isFocused
        self.canDelete = canDelete
        self.onSend = onSend
        self.onDelete = onDelete
        self.onDone = onDone
    }

    private var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                Text(lineLabel).font(.sh(.mono)).foregroundStyle(sh.running)
                Text("selected").font(.sh(.caption)).foregroundStyle(sh.textTertiary)
                Spacer(minLength: SH.Space.s)
                if canDelete {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.shLink(color: sh.failed, font: .sh(.caption)))
                        .shTouchTarget(height: SH.Height.controlS)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.shLink(color: sh.textSecondary, font: .sh(.caption)))
                    .shTouchTarget(height: SH.Height.controlS)
            }
            .padding(.horizontal, SH.Space.s)
            HStack(spacing: SH.Space.m) {
                TextField("Comment on \(lineLabel)…", text: $text, prompt: Text("Comment on \(lineLabel)…").foregroundStyle(sh.textTertiary),
                          axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.sh(.body, weight: .regular))
                    .foregroundStyle(sh.textPrimary)
                    .tint(sh.lantern)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit { if hasText { onSend() } }
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.sh(.ui, weight: .bold))
                        .foregroundStyle(sh.textOnLantern)
                        .frame(width: SHLineCommentBar.sendSize, height: SHLineCommentBar.sendSize)
                        .background(sh.lantern, in: Circle())
                        .opacity(hasText ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
                .shTouchTarget(height: SHLineCommentBar.sendSize, width: SHLineCommentBar.sendSize)
                .accessibilityLabel("Save comment")
            }
            .padding(.leading, SH.Space.xl)
            .padding(.trailing, SH.Space.s)
            .padding(.vertical, SH.Space.s)
            .frame(minHeight: SH.Height.touch)
            .background(sh.bgRaised, in: RoundedRectangle(cornerRadius: SH.Height.touch / 2))
            .shBorder(sh.lineStrong, in: RoundedRectangle(cornerRadius: SH.Height.touch / 2))
        }
    }

    static let sendSize: CGFloat = 32
}

#Preview("Line comment bar") {
    @Previewable @State var text = ""
    @Previewable @FocusState var focused: Bool
    SHPreviewBoth {
        SHLineCommentBar(lineLabel: "line 16", text: $text, isFocused: $focused, canDelete: true,
                         onSend: {}, onDelete: {}, onDone: {})
            .frame(width: 360)
    }
}
