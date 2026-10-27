import SwiftUI

/// A comment under a diff line (ChangesSplit): a raised card with a strong 1px line and radius
/// 8. A 16pt lantern avatar with the author's initial, the author in semibold, "line 103 · just
/// now" in mono 10.5, and Edit trailing (Delete joins it on hover, and both are VoiceOver
/// actions); then the comment at 12.5.
public struct SHInlineComment: View {
    let initial: String
    let author: String
    let meta: String
    let text: String
    let onEdit: (() -> Void)?
    let onDelete: (() -> Void)?
    @State private var hovering = false

    public init(initial: String, author: String, meta: String, text: String,
                onEdit: (() -> Void)? = nil, onDelete: (() -> Void)? = nil) {
        self.initial = initial
        self.author = author
        self.meta = meta
        self.text = text
        self.onEdit = onEdit
        self.onDelete = onDelete
    }

    public var body: some View {
        let _ = SHRenderProbe.tick("review.comment")
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.s) {
            HStack(spacing: SH.Space.s) {
                SHCommentAvatar(initial: initial)
                Text(author).font(.sh(.caption, weight: .semibold)).foregroundStyle(sh.textPrimary)
                Text(meta).font(.shMono(10.5)).foregroundStyle(sh.textSecondary).lineLimit(1)
                Spacer(minLength: SH.Space.m)
                HStack(spacing: SH.Space.m) {
                    if let onDelete {
                        Button("Delete", action: onDelete)
                            .opacity(SHPlatform.showsHoverDetails || hovering ? 1 : 0)
                    }
                    if let onEdit { Button("Edit", action: onEdit) }
                }
                .buttonStyle(.shLink(color: sh.textSecondary, font: .sh(.caption)))
                .accessibilityHidden(true)
            }
            Text(text)
                .font(.sh(.ui, weight: .regular))
                .lineSpacing(SHTextStyle.ui.lineSpacing + SH.Space.xxs)
                .foregroundStyle(sh.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SHInlineComment.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SH.Radius.m, line: sh.lineStrong)
        .onHover { hovering = $0 }
        .shAnimation(.hover, value: hovering)
        .accessibilityElement(children: .combine)
        // Selectable Text is not consistently included in the combined label.
        .accessibilityLabel("\(author), \(meta), \(text)")
        .accessibilityActions {
            if let onEdit { Button("Edit", action: onEdit) }
            if let onDelete { Button("Delete", action: onDelete) }
        }
    }

    static let horizontalInset: CGFloat = 10
}

/// The 16pt lantern circle with the author's initial.
private struct SHCommentAvatar: View {
    let initial: String

    var body: some View {
        Text(initial)
            .font(.shSans(9, .bold))
            .foregroundStyle(.sh.textOnLantern)
            .frame(width: 16, height: 16)
            .background(Color.sh.lantern, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Writing or editing a comment (ChangesLastTurn): the comment's card with a lantern line and a
/// 3pt lantern-tint ring while it is open. The field, then "on line 103" in mono 10.5 and Cancel
/// and Add comment. ⏎ saves, ⇧⏎ adds a line, esc cancels. Saving an empty comment removes it.
public struct SHCommentEditor: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let placeholder: String
    /// "on line 103", or "on the file".
    let context: String?
    let onSave: () -> Void
    let onCancel: () -> Void

    public init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, placeholder: String = "Comment for the agent on this line",
                context: String? = nil, onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _text = text
        self.isFocused = isFocused
        self.placeholder = placeholder
        self.context = context
        self.onSave = onSave
        self.onCancel = onCancel
    }

    public var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.m) {
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(sh.textTertiary), axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(.sh(.ui, weight: .regular))
                .foregroundStyle(sh.textPrimary)
                .tint(sh.lantern)
                .focused(isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if let result = SHReturnKey.lineBreak(for: press) { return result }
                    onSave()
                    return .handled
                }
                .onKeyPress(.escape) { onCancel(); return .handled }
            HStack(spacing: SH.Space.s) {
                if let context {
                    Text(context).font(.shMono(10.5)).foregroundStyle(sh.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).buttonStyle(.sh(.ghost, size: .s))
                Button("Add comment", action: onSave).buttonStyle(.sh(.secondary, size: .s))
            }
        }
        .padding(.vertical, SH.Space.m)
        .padding(.horizontal, SHInlineComment.horizontalInset)
        .shCard(radius: SH.Radius.m, line: sh.lantern)
        .background {
            RoundedRectangle(cornerRadius: SH.Radius.m).inset(by: -SHCommentEditor.ringWidth / 2)
                .stroke(sh.lanternTint, lineWidth: SHCommentEditor.ringWidth)
        }
        .onAppear { isFocused.wrappedValue = true }
    }

    static let ringWidth: CGFloat = 3
}
