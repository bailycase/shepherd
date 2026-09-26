import SwiftUI
import AppKit
import ShepherdUI

// MARK: Page chrome

/// A settings page: the title in Geist 22/600, a one-line explanation in `body` (it may carry
/// inline markup, `NWMarkupText`), then its groups 28pt apart.
struct SettingsPage<Content: View>: View {
    let title: String
    let explanation: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
            SettingsHeader(title: title, explanation: explanation)
            content
        }
        // The Settings boards draw their pages' controls larger than the Controls board's.
        .nwControlScale(.settings)
    }
}

/// A page's title and the line under it that says what the page is for.
struct SettingsHeader: View {
    let title: String
    let explanation: String

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xs) {
            Text(title)
                .font(.nwSans(AppLayout.settingsTitleSize, .semibold))
                .tracking(AppLayout.settingsTitleSize * AppLayout.settingsTitleTracking)
                .foregroundStyle(Color.nw.textPrimary)
                .accessibilityAddTraits(.isHeader)
            NWMarkupText(explanation, size: NWTextStyle.body.size, codeSize: NWTextStyle.code.size,
                           lineHeight: AppLayout.settingsExplanationLineHeight)
                .foregroundStyle(Color.nw.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// A titled group: the section label (Geist 11/600 caps), a flat group card of rows at radius 10
/// (rules inserted between them), and an optional footnote under it.
struct SettingsGroup<Content: View>: View {
    let title: String
    var footnote: String?
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.m) {
            NWSectionHeader(title, style: .settings).padding(.horizontal, NW.Space.xs)
            NWGroupCard(fill: Color.nw.bgWindow, radius: NWCardRowMetrics.settingsCardRadius) { content }
            if let footnote {
                SettingsNote(text: footnote).padding(.horizontal, NW.Space.xs)
            }
        }
        .nwControlScale(.settings)
    }
}

/// One row: title, optional description (inline markup: `` `code` `` and `**option**`) and
/// inline problem, control trailing. `problemHelp` is the problem's tooltip: the technical
/// reason, never the message.
struct SettingsRow<Control: View>: View {
    let title: String
    var subtitle: String?
    var problem: String?
    var problemHelp: String?
    @ViewBuilder var control: Control

    var body: some View {
        NWCardRow(title, description: subtitle, problem: problem, problemHelp: problemHelp, style: .settings) { control }
            .accessibilityElement(children: .contain)
    }
}

/// A row with no title: its own content leading, actions trailing (a form's Save, pi's update
/// buttons). Same padding and minimum height as `SettingsRow`.
struct SettingsActionRow<Leading: View, Actions: View>: View {
    @ViewBuilder var leading: Leading
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .center, spacing: NW.Space.xxl) {
            leading
            Spacer(minLength: 0)
            HStack(spacing: NW.Space.s) { actions }
        }
        .modifier(NWCardRowFrame(settings: true))
    }
}

extension SettingsActionRow where Leading == EmptyView {
    init(@ViewBuilder actions: () -> Actions) {
        self.init(leading: { EmptyView() }, actions: actions)
    }
}

/// Footnote under a group: Geist 12/1.5 in `textTertiary`, a sentence or two about the whole
/// group, never a mono paragraph.
struct SettingsNote: View {
    let text: String

    var body: some View {
        Text(text)
            .nwText(size: AppLayout.settingsFootnoteSize, lineHeight: AppLayout.settingsFootnoteLineHeight)
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
