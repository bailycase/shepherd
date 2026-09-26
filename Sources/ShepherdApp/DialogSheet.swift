import SwiftUI
import ShepherdUI

/// One labeled row shared by every sheet and dialog (`NWSheetRow`): a label column, the
/// control on the right, a hairline underneath. No form chrome, no grouped boxes.
typealias SheetRow = NWSheetRow

/// A footer action for `DialogSheet`. Exactly one action should be `.prominent` (the sheet's
/// ⏎ default); `.destructive` is never the default: destroying things takes a click.
struct DialogAction: Identifiable {
    enum Kind {
        /// Secondary, ⎋.
        case cancel
        case normal
        /// Primary (lantern), ⏎.
        case prominent
        /// The failed fill of a confirmed destructive action, never ⏎.
        case destructive
    }

    let label: String
    let kind: Kind
    let isEnabled: Bool
    let action: () -> Void

    /// The label: stable across renders (a fresh id per render would rebuild every button),
    /// and unique within one dialog.
    var id: String { label }

    init(_ label: String, kind: Kind = .normal, isEnabled: Bool = true, action: @escaping () -> Void) {
        self.label = label
        self.kind = kind
        self.isEnabled = isEnabled
        self.action = action
    }
}

/// The app's modal dialog, in place of system alerts and confirmation dialogs everywhere: the
/// same anatomy as the creation sheets (`NWDialog`), so a confirmation reads like the rest of
/// Shepherd.
struct DialogSheet<Content: View>: View {
    let title: String
    var subtitle: String?
    var width: CGFloat = NWDialogMetrics.width
    /// A caption at the footer's leading edge ("Checking for unsaved work…").
    var status: String?
    let actions: [DialogAction]
    @ViewBuilder var content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        width: CGFloat = NWDialogMetrics.width,
        status: String? = nil,
        actions: [DialogAction],
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.width = width
        self.status = status
        self.actions = actions
        self.content = content
    }

    var body: some View {
        NWDialog(title, message: subtitle, width: width) {
            content()
        } status: {
            if let status { NWDialogStatus(status) }
        } actions: {
            ForEach(actions) { button(for: $0) }
        }
    }

    @ViewBuilder
    private func button(for action: DialogAction) -> some View {
        let button = Button(action.label, action: action.action).disabled(!action.isEnabled)
        switch action.kind {
        case .cancel:
            button.buttonStyle(.nw(.secondary)).keyboardShortcut(.cancelAction)
        case .normal:
            button.buttonStyle(.nw(.secondary))
        case .prominent:
            button.buttonStyle(.nw(.primary)).keyboardShortcut(.defaultAction)
        case .destructive:
            button.buttonStyle(.nw(.dangerFill))
        }
    }
}

extension DialogSheet where Content == EmptyView {
    /// Text-only dialog: title, subtitle, buttons.
    init(title: String, subtitle: String? = nil, width: CGFloat = NWDialogMetrics.width, status: String? = nil,
         actions: [DialogAction]) {
        self.init(title: title, subtitle: subtitle, width: width, status: status, actions: actions) { EmptyView() }
    }
}

extension View {
    /// A dialog presented as a `.sheet`. When a row discloses or withdraws, SwiftUI gives the
    /// sheet window its new height at once while the rows ease to their places; the group keeps
    /// the dialog pinned to that frame, so its title stays still instead of drifting with the
    /// window's centering, and the background fills the window from the first frame.
    func dialogSheetFrame() -> some View {
        geometryGroup().background(Color.nw.bgWindow)
    }
}

/// A banner inside a dialog, at the dialog's margins: what a destructive action would destroy
/// (`.attention`), or why something failed (`.failed`). Never a system alert triangle. It
/// discloses when it arrives late (a probe's warning, a failed step): animate the dialog on
/// what it shows (`nwAnimation(.disclosure, value:)`) so the sheet grows in step.
struct DialogBanner: View {
    var state: AgentState = .attention
    let title: String
    var message: String?

    var body: some View {
        NWBanner(state, title: title, message: message)
            .padding(.horizontal, NWDialogMetrics.inset)
            .padding(.top, NW.Space.l)
            .nwTransition(.disclosure)
    }
}

/// Shared rename dialog: one focused field seeded with the current name, ⏎ confirms, ⎋
/// cancels. An empty name cannot be confirmed.
struct RenameDialog: View {
    let title: String
    var caption: String?
    let onRename: (String) -> Void
    let onCancel: () -> Void
    /// A blank name is a choice (a terminal tab goes back to naming itself).
    var allowsEmpty = false
    @State private var name: String
    @FocusState private var focused: Bool

    init(title: String, caption: String? = nil, name: String, allowsEmpty: Bool = false, onRename: @escaping (String) -> Void,
         onCancel: @escaping () -> Void) {
        self.title = title
        self.caption = caption
        self.allowsEmpty = allowsEmpty
        self.onRename = onRename
        self.onCancel = onCancel
        _name = State(initialValue: name)
    }

    private var canRename: Bool { allowsEmpty || !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var body: some View {
        DialogSheet(
            title: title,
            subtitle: caption,
            width: AppLayout.renameSheetWidth,
            actions: [
                DialogAction("Cancel", kind: .cancel, action: onCancel),
                DialogAction("Rename", kind: .prominent, isEnabled: canRename) { onRename(name) },
            ]
        ) {
            TextField("Name", text: $name)
                .focused($focused)
                .onSubmit { if canRename { onRename(name) } }
                .nwField(focused: focused)
                .padding(.horizontal, NWDialogMetrics.inset)
                .padding(.top, NW.Space.xs)
        }
        .onAppear { focused = true }
    }
}

/// Stop while subagents run: stop only the agent, or the agent and every subagent.
struct StopAllDialog: View {
    let runningSubagents: Int
    let stopAgent: () -> Void
    let stopAll: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogSheet(title: "Stop the agent and every running subagent?",
                    // The count is live: subagents can finish while the dialog is open.
                    subtitle: runningSubagents == 1 ? "1 subagent is still running."
                        : "\(runningSubagents) subagents are still running.",
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: cancel),
                        DialogAction("Stop only the agent", action: stopAgent),
                        DialogAction("Stop all", kind: .destructive, action: stopAll),
                    ])
    }
}

/// The review pane's per-file Revert: tracked files return to HEAD, new files move to the Trash.
/// It names the repository, since an agent's review may be of one the user isn't working in.
struct RevertFileDialog: View {
    let path: String
    let repository: String
    let isNew: Bool
    let revert: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogSheet(title: "Discard the changes to \(path)?",
                    subtitle: isNew ? "The new file moves to the Trash."
                        : "The file returns to its last committed version. This cannot be undone from Shepherd.",
                    actions: [
                        DialogAction("Cancel", kind: .cancel, action: cancel),
                        DialogAction("Discard changes", kind: .destructive, action: revert),
                    ]) {
            SheetRow("Repository") {
                Text(repository)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(repository)
                    .textSelection(.enabled)
            }
        }
    }
}

/// A failed agent action (rename, delete, a remote request): the error, selectable.
struct ActionErrorDialog: View {
    let message: String
    let dismiss: () -> Void

    var body: some View {
        DialogSheet(title: "Agent action failed", actions: [DialogAction("OK", kind: .prominent, action: dismiss)]) {
            Text(message)
                .nwText(.body)
                .foregroundStyle(Color.nw.textSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NWDialogMetrics.inset)
        }
    }
}
