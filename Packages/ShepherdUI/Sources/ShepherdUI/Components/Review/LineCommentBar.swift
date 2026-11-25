import SwiftUI

/// Commenting on a selected diff line from the bottom of the phone's diff reader (MobileDiff
/// board): a raised card with "Comment on line 33" in secondary, Delete while the line already
/// has a comment, Done to clear the selection and Save (dim until there is text), over the field.
/// Delete removes the line's comment.
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
        let shape = RoundedRectangle(cornerRadius: SHLineCommentBar.radius)
        VStack(alignment: .leading, spacing: SH.Space.m) {
            HStack(spacing: SH.Space.xl) {
                Text("Comment on \(lineLabel)")
                    .font(.shSans(SHLineCommentBar.headSize))
                    .foregroundStyle(sh.textSecondary)
                    .lineLimit(1)
                Spacer(minLength: SH.Space.s)
                if canDelete {
                    Button("Delete", action: onDelete)
                        .buttonStyle(.shLink(color: sh.failed, font: .shSans(SHLineCommentBar.headSize, .medium)))
                }
                Button("Done", action: onDone)
                    .buttonStyle(.shLink(color: sh.textSecondary, font: .shSans(SHLineCommentBar.headSize)))
                Button("Save", action: onSend)
                    .buttonStyle(.shLink(color: hasText ? sh.textPrimary : sh.textTertiary, font: .shSans(SHLineCommentBar.headSize, .medium)))
                    .disabled(!hasText)
            }
            .frame(minHeight: SH.Height.touch - SH.Space.l)
            TextField("Comment on \(lineLabel)…", text: $text, prompt: Text("Comment on \(lineLabel)…").foregroundStyle(sh.textTertiary),
                      axis: .vertical)
                .lineLimit(1...5)
                .textFieldStyle(.plain)
                .font(.shSans(SHLineCommentBar.fieldSize))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.textPrimary)
                .focused(isFocused)
                .submitLabel(.send)
                .onSubmit { if hasText { onSend() } }
        }
        .padding(.horizontal, SH.Space.xl)
        .padding(.top, SH.Space.s)
        .padding(.bottom, SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .shLift(shape)
        .shBorder(sh.lineSubtle, radius: SHLineCommentBar.radius)
    }

    static let radius: CGFloat = SH.Radius.xxl + SH.Radius.xs
    static let headSize: CGFloat = 13
    static let fieldSize: CGFloat = 15
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
