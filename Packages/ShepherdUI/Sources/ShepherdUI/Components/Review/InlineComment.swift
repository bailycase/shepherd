import SwiftUI

/// A comment under a diff line (ChangesSplit): a raised card with a strong 1px line and radius
/// 8. A 16pt lantern avatar with the author's initial, the author in semibold, "line 103 · just
/// now" in mono 10.5, and Edit trailing (Delete joins it on hover, and both are VoiceOver
/// actions); then the comment at 12.5.
public struct NWInlineComment: View {
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
        let _ = NWRenderProbe.tick("review.comment")
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.s) {
            HStack(spacing: NW.Space.s) {
                NWCommentAvatar(initial: initial)
                Text(author).font(.nw(.caption, weight: .semibold)).foregroundStyle(nw.textPrimary)
                Text(meta).font(.nwMono(10.5)).foregroundStyle(nw.textSecondary).lineLimit(1)
                Spacer(minLength: NW.Space.m)
                HStack(spacing: NW.Space.m) {
                    if let onDelete {
                        Button("Delete", action: onDelete)
                            .opacity(NWPlatform.showsHoverDetails || hovering ? 1 : 0)
                    }
                    if let onEdit { Button("Edit", action: onEdit) }
                }
                .buttonStyle(.nwLink(color: nw.textSecondary, font: .nw(.caption)))
                .accessibilityHidden(true)
            }
            Text(text)
                .font(.nw(.ui, weight: .regular))
                .lineSpacing(NWTextStyle.ui.lineSpacing + NW.Space.xxs)
                .foregroundStyle(nw.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NWInlineComment.horizontalInset)
        .frame(maxWidth: .infinity, alignment: .leading)
        .nwCard(radius: NW.Radius.m, line: nw.lineStrong)
        .onHover { hovering = $0 }
        .nwAnimation(.hover, value: hovering)
        .accessibilityElement(children: .combine)
        .accessibilityActions {
            if let onEdit { Button("Edit", action: onEdit) }
            if let onDelete { Button("Delete", action: onDelete) }
        }
    }

    static let horizontalInset: CGFloat = 10
}

/// The 16pt lantern circle with the author's initial.
private struct NWCommentAvatar: View {
    let initial: String

    var body: some View {
        Text(initial)
            .font(.nwSans(9, .bold))
            .foregroundStyle(.nw.textOnLantern)
            .frame(width: 16, height: 16)
            .background(Color.nw.lantern, in: Circle())
            .accessibilityHidden(true)
    }
}

/// Writing or editing a comment (ChangesLastTurn): the comment's card with a lantern line and a
/// 3pt lantern-tint ring while it is open. The field, then "on line 103" in mono 10.5 and Cancel
/// and Add comment. ⏎ saves, ⇧⏎ adds a line, esc cancels. Saving an empty comment removes it.
public struct NWCommentEditor: View {
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
        let nw = Color.nw
        VStack(alignment: .leading, spacing: NW.Space.m) {
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(nw.textTertiary), axis: .vertical)
                .lineLimit(1...8)
                .textFieldStyle(.plain)
                .font(.nw(.ui, weight: .regular))
                .foregroundStyle(nw.textPrimary)
                .tint(nw.lantern)
                .focused(isFocused)
                .onKeyPress(.return, phases: .down) { press in
                    if press.modifiers.contains(.shift) { text += "\n"; return .handled }
                    onSave()
                    return .handled
                }
                .onKeyPress(.escape) { onCancel(); return .handled }
            HStack(spacing: NW.Space.s) {
                if let context {
                    Text(context).font(.nwMono(10.5)).foregroundStyle(nw.textTertiary).lineLimit(1)
                }
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).buttonStyle(.nw(.ghost, size: .s))
                Button("Add comment", action: onSave).buttonStyle(.nw(.secondary, size: .s))
            }
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NWInlineComment.horizontalInset)
        .nwCard(radius: NW.Radius.m, line: nw.lantern)
        .background {
            RoundedRectangle(cornerRadius: NW.Radius.m).inset(by: -NWCommentEditor.ringWidth / 2)
                .stroke(nw.lanternTint, lineWidth: NWCommentEditor.ringWidth)
        }
        .onAppear { isFocused.wrappedValue = true }
    }

    static let ringWidth: CGFloat = 3
}
