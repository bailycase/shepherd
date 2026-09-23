import SwiftUI
import AppKit
import ShepherdUI

// MARK: Page chrome (spec §12)

/// A settings page: 22/600 title with a one-line explanation, then its groups.
struct SettingsPage<Content: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(Font.nw(.display)).foregroundStyle(Color.nw.textPrimary)
                Text(explanation).font(Font.nw(.body)).foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content
        }
    }
}

/// A titled group: caps header, a GroupCard of rows (dividers inserted between them), and an
/// optional footnote under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            NWSectionHeader(title).padding(.horizontal, 4)
            NWGroupCard { content }
            if let footnote { SettingsNote(text: footnote).padding(.horizontal, 4).padding(.top, 2) }
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
    }
}

/// Footnote under a group: 12pt sans, muted — never a mono paragraph.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(Font.nw(.caption))
            .foregroundStyle(Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The accent switch every boolean setting uses.
struct SettingsSwitch: View {
    let label: String
    @Binding var isOn: Bool

    var body: some View {
        Toggle(label, isOn: $isOn).labelsHidden().toggleStyle(.nwSwitch)
    }
}

/// A file Shepherd owns: its name in mono and a Reveal button.
struct PathRow: View {
    let title: String
    let subtitle: String
    let url: URL

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent).font(Font.nw(.micro)).foregroundStyle(Color.nw.textSecondary).help(url.path)
                Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                    .buttonStyle(NWButtonStyle(.secondary, size: .s))
            }
        }
    }
}
