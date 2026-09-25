import SwiftUI

/// Commenting on a selected diff line from the bottom of the phone's diff reader (MobileDiff
/// board): "line 16 selected", Delete while the line already has a comment, and Done to clear
/// the selection, over a 44pt capsule field ("Comment on line 16…") with a lantern send button
/// that dims until there is text. Delete removes the line's comment.
public struct NWLineCommentBar: View {
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(spacing: NW.Space.s) {
                Text(lineLabel).font(.nw(.mono)).foregroundStyle(nw.running)
                Text("selected").font(.nw(.caption)).foregroundStyle(nw.textTertiary)
                Spacer(minLength: NW.Space.s)
                if canDelete {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.nwLink(color: nw.failed, font: .nw(.caption)))
                        .nwTouchTarget(height: NW.Height.controlS)
                }
                Button("Done", action: onDone)
                    .buttonStyle(.nwLink(color: nw.textSecondary, font: .nw(.caption)))
                    .nwTouchTarget(height: NW.Height.controlS)
            }
            .padding(.horizontal, NW.Space.s)
            HStack(spacing: NW.Space.m) {
                TextField("Comment on \(lineLabel)…", text: $text, prompt: Text("Comment on \(lineLabel)…").foregroundStyle(nw.textTertiary),
                          axis: .vertical)
                    .lineLimit(1...5)
                    .textFieldStyle(.plain)
                    .font(.nw(.body, weight: .regular))
                    .foregroundStyle(nw.textPrimary)
                    .tint(nw.lantern)
                    .focused(isFocused)
                    .submitLabel(.send)
                    .onSubmit { if hasText { onSend() } }
                Button(action: onSend) {
                    Image(systemName: "arrow.up")
                        .font(.nw(.ui, weight: .bold))
                        .foregroundStyle(nw.textOnLantern)
                        .frame(width: NWLineCommentBar.sendSize, height: NWLineCommentBar.sendSize)
                        .background(nw.lantern, in: Circle())
                        .opacity(hasText ? 1 : 0.35)
                }
                .buttonStyle(.plain)
                .disabled(!hasText)
                .nwTouchTarget(height: NWLineCommentBar.sendSize, width: NWLineCommentBar.sendSize)
                .accessibilityLabel("Save comment")
            }
            .padding(.leading, NW.Space.xl)
            .padding(.trailing, NW.Space.s)
            .padding(.vertical, NW.Space.s)
            .frame(minHeight: NW.Height.touch)
            .background(nw.bgRaised, in: RoundedRectangle(cornerRadius: NW.Height.touch / 2))
            .nwBorder(nw.lineStrong, in: RoundedRectangle(cornerRadius: NW.Height.touch / 2))
        }
    }

    static let sendSize: CGFloat = 32
}

#Preview("Line comment bar") {
    @Previewable @State var text = ""
    @Previewable @FocusState var focused: Bool
    NWPreviewBoth {
        NWLineCommentBar(lineLabel: "line 16", text: $text, isFocused: $focused, canDelete: true,
                         onSend: {}, onDelete: {}, onDone: {})
            .frame(width: 360)
    }
}
