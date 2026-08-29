import SwiftUI

/// One flat labeled row shared by every sheet and dialog: dim mono label
/// column, control on the right, hairline separator underneath. This is the
/// sheet look (see DESIGN.md) — no Form chrome, no grouped boxes.
struct SheetRow<Content: View>: View {
    let label: String
    @ViewBuilder var control: () -> Content

    init(_ label: String, @ViewBuilder control: @escaping () -> Content) {
        self.label = label
        self.control = control
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Text(label)
                    .font(Fonts.mono(10.5, .semibold))
                    .tracking(0.74)
                    .foregroundStyle(Tokens.textDim)
                    .frame(width: 84, alignment: .leading)
                control()
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 20)
            .frame(minHeight: 38)
            Rectangle().fill(Tokens.separator).frame(height: 1)
                .padding(.leading, 20)
        }
    }
}

/// A footer action for `DialogSheet`. Exactly one action should be
/// `.prominent` (the single sheet default button, per DESIGN.md);
/// `.destructive` is deliberately never the ↩ default — destroying things
/// takes a click.
struct DialogAction: Identifiable {
    enum Kind {
        case cancel, normal, prominent, destructive
    }

    let id = UUID()
    let label: String
    var kind: Kind = .normal
    let action: () -> Void

    init(_ label: String, kind: Kind = .normal, action: @escaping () -> Void) {
        self.label = label
        self.kind = kind
        self.action = action
    }
}

/// The app's modal dialog: replaces NSAlert-style `.alert()` everywhere.
/// Same anatomy as the creation sheets — mono title block, optional labeled
/// rows, footer buttons — so a confirmation reads like the rest of Shepherd
/// instead of a system alert with text crushed into a narrow column.
struct DialogSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = 460
    let actions: [DialogAction]
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = 460,
        actions: [DialogAction],
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.actions = actions
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(Fonts.mono(13.5, .semibold))
                    .foregroundStyle(Tokens.textPrimary)
                if let subtitle {
                    Text(subtitle)
                        .font(Fonts.mono(11.5))
                        .foregroundStyle(Tokens.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .lineSpacing(2)
                }
            }
            .padding(EdgeInsets(top: 16, leading: 20, bottom: 10, trailing: 20))

            content()

            HStack(spacing: 10) {
                Spacer(minLength: 12)
                ForEach(actions) { action in
                    button(for: action)
                }
            }
            .padding(EdgeInsets(top: 14, leading: 20, bottom: 16, trailing: 20))
        }
        .frame(width: width)
        .background(Tokens.workspaceBg)
    }

    @ViewBuilder
    private func button(for action: DialogAction) -> some View {
        switch action.kind {
        case .cancel:
            Button(action.label, action: action.action)
                .keyboardShortcut(.cancelAction)
        case .normal:
            Button(action.label, action: action.action)
        case .prominent:
            Button(action.label, action: action.action)
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.accentButton)
        case .destructive:
            Button(action.label, action: action.action)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.destructive)
        }
    }
}

extension DialogSheet where Content == EmptyView {
    /// Text-only dialog: title, subtitle, buttons.
    init(title: String, subtitle: String? = nil, width: CGFloat = 460, actions: [DialogAction]) {
        self.init(title: title, subtitle: subtitle, width: width, actions: actions) { EmptyView() }
    }
}

/// The attention strip inside a dialog: work that a destructive action would
/// destroy. Status-colored text behind a 2px bar of the same color — the
/// sidebar's blocked language, not a yellow system triangle.
struct DialogWarning: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            Rectangle()
                .fill(Tokens.statusBlocked)
                .frame(width: 2)
            Text(text)
                .font(Fonts.mono(11))
                .foregroundStyle(Tokens.statusBlocked)
                .fixedSize(horizontal: false, vertical: true)
                .lineSpacing(2)
            Spacer(minLength: 0)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}

/// Shared rename dialog: one focused mono field, ↩ confirms, ⎋ cancels.
struct RenameDialog: View {
    let title: String
    var caption: String? = nil
    @Binding var text: String
    let onRename: () -> Void
    let onCancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        DialogSheet(
            title: title,
            subtitle: caption,
            width: 420,
            actions: [
                DialogAction("Cancel", kind: .cancel, action: onCancel),
                DialogAction("Rename", kind: .prominent, action: onRename),
            ]
        ) {
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .font(Fonts.mono(11.5))
                .foregroundStyle(Tokens.textPrimary)
                .focused($focused)
                .onSubmit(onRename)
                .padding(8)
                .background(Color.black.opacity(0.25))
                .overlay(
                    RoundedRectangle(cornerRadius: 5)
                        .stroke(focused ? Tokens.focusAccent.opacity(0.4) : Tokens.chipBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .padding(.horizontal, 20)
        }
        .onAppear { focused = true }
    }
}
