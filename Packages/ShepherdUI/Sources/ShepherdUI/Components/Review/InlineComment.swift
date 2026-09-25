import SwiftUI

/// A comment under a diff line (Review board): a raised card with a strong 1px line and radius
/// 8. A 16pt lantern avatar with the author's initial, the author in semibold, "line 33 · just
/// now" in mono, then the comment at 12.5. Edit and Delete appear on hover (and are always
/// VoiceOver actions).
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
                Text(meta).font(.nw(.mono)).foregroundStyle(nw.textSecondary).lineLimit(1)
                Spacer(minLength: NW.Space.m)
                if onEdit != nil || onDelete != nil {
                    HStack(spacing: NW.Space.m) {
                        if let onEdit { Button("Edit", action: onEdit) }
                        if let onDelete { Button("Delete", action: onDelete) }
                    }
                    .buttonStyle(.nwLink(color: nw.textSecondary, font: .nw(.caption)))
                    .opacity(NWPlatform.showsHoverDetails || hovering ? 1 : 0)
                    .accessibilityHidden(true)
                }
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

/// Writing or editing a line comment: the inline comment's card with a running line while it is
/// open. ⏎ saves, ⇧⏎ adds a line, esc cancels. Saving an empty comment removes it.
public struct NWCommentEditor: View {
    @Binding var text: String
    var isFocused: FocusState<Bool>.Binding
    let placeholder: String
    let onSave: () -> Void
    let onCancel: () -> Void

    public init(text: Binding<String>, isFocused: FocusState<Bool>.Binding, placeholder: String = "Comment for the agent on this line",
                onSave: @escaping () -> Void, onCancel: @escaping () -> Void) {
        _text = text
        self.isFocused = isFocused
        self.placeholder = placeholder
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
                Spacer(minLength: 0)
                Button("Cancel", action: onCancel).buttonStyle(.nw(.ghost, size: .s))
                Button("Comment", action: onSave).buttonStyle(.nw(.secondary, size: .s))
            }
        }
        .padding(.vertical, NW.Space.m)
        .padding(.horizontal, NWInlineComment.horizontalInset)
        .nwCard(radius: NW.Radius.m, line: nw.running)
        .onAppear { isFocused.wrappedValue = true }
    }
}
