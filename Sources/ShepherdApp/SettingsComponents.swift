import SwiftUI
import AppKit
import ShepherdUI

// MARK: Page chrome

/// A settings page: the title in `display`, a one-line explanation, then its groups.
struct SettingsPage<Content: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.s) {
                Text(title)
                    .nwText(.display)
                    .foregroundStyle(Color.nw.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text(explanation)
                    .nwText(.body)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// A titled group: the section label, a group card of rows (rules inserted between them), and
/// an optional footnote under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            NWSectionHeader(title).padding(.horizontal, NW.Space.xs)
            NWGroupCard { content }
            if let footnote {
                SettingsNote(text: footnote).padding(.horizontal, NW.Space.xs)
            }
        }
    }
}

/// One row: title, optional description and inline problem, control trailing.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var problem: String?
    @ViewBuilder var control: Control

    var body: some View {
        NWCardRow(title, description: subtitle, problem: problem) { control }
            .accessibilityElement(children: .contain)
    }
}

/// A row with no title: its own content leading, actions trailing (a form's Save, pi's update
/// buttons). Same padding and minimum height as `SettingsRow`.
struct SettingsActionRow<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: NW.Space.xl) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: NW.Space.s) { actions }
        }
        .padding(.horizontal, NW.Space.xl)
        .padding(.vertical, NW.Space.l)
        .frame(minHeight: AppLayout.settingsRowMinHeight)
    }
}

extension SettingsActionRow where Leading == EmptyView {
    init(@ViewBuilder actions: () -> Actions) {
        self.init(leading: { EmptyView() }, actions: actions)
    }
}

/// Footnote under a group: caption sans in `textTertiary`, never a mono paragraph.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .nwText(.caption)
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The lantern switch every boolean setting uses. The row title is its accessibility label.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.nwSwitch)
    }
}

/// A labelled text field in a settings row: the label is for VoiceOver, the prompt is the
/// example shown while empty.
struct SettingsTextField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var mono = false
    var secure = false
    var width: CGFloat = AppLayout.settingsFieldWidth

    var body: some View {
        Group {
            if secure {
                SecureField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.nw.textTertiary))
            } else {
                TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.nw.textTertiary))
            }
        }
        .textFieldStyle(.nw(mono: mono))
        .frame(width: width)
    }
}

/// A file Shepherd owns: its name in mono (the full path on hover) and a Reveal button.
struct PathRow: View {
    let title: String
    let subtitle: String
    let url: URL

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: NW.Space.m) {
                Text(url.lastPathComponent)
                    .font(.nw(.mono))
                    .foregroundStyle(Color.nw.textSecondary)
                    .help(url.path)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .accessibilityLabel("Reveal \(url.lastPathComponent) in Finder")
            }
        }
    }
}
