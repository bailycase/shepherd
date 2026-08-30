import SwiftUI

// MARK: Terminal

struct TerminalSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject private var settings = AppSettings.shared

    private var families: [String] {
        AppSettings.monospacedFamilies(including: settings.terminalFontFamily)
    }

    var body: some View {
        SettingsGroup(title: "Font") {
            SettingsRow(
                title: "Font Family",
                subtitle: "Fixed-pitch families installed on this Mac. Ghostty falls back silently if a family cannot be loaded.",
                isFirst: true
            ) {
                Picker("", selection: $settings.terminalFontFamily) {
                    Text("System Font").tag(AppSettings.systemFontFamily)
                    Divider()
                    ForEach(families, id: \.self) { family in
                        Text(family).tag(family)
                    }
                }
                .labelsHidden()
                .onChange(of: settings.terminalFontFamily) { vm.rebuildSurfaces() }
            }
            SettingsRow(title: "Font Size") {
                HStack(spacing: 8) {
                    Slider(
                        value: $settings.terminalFontSize,
                        in: AppSettings.fontSizeRange,
                        step: 0.5
                    )
                    .frame(width: 170)
                    .onChange(of: settings.terminalFontSize) { vm.rebuildSurfaces() }
                    Text(String(format: "%.1f", settings.terminalFontSize))
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textMetadata)
                        .frame(width: 30, alignment: .trailing)
                }
            }
            SettingsRow(title: "Preview", subtitle: "Updates live as you change the family and size above.") {
                FontPreview(
                    family: settings.resolvedTerminalFontFamily,
                    size: settings.terminalFontSize
                )
            }
        }

        SettingsGroup(title: "Shell") {
            SettingsRow(
                title: "Shell for Plain Panes",
                subtitle: "Used by ⌘D splits, space workspaces, and panes an agent opens. Agent panes always run pi.",
                isFirst: true
            ) {
                Picker("", selection: $settings.shellPath) {
                    ForEach(AppSettings.knownShells(including: settings.shellPath), id: \.self) { shell in
                        Text(shell).tag(shell)
                    }
                }
                .labelsHidden()
            }
        }
        SettingsNote(text: "font changes rebuild every terminal surface · running processes are untouched · a new shell applies to panes opened afterwards")
    }
}

/// A mock pi transcript rendered in the configured terminal font, so font
/// changes are judged without leaving Settings. Reads live theme tokens and
/// the exact family ghostty will load (`resolvedTerminalFontFamily`).
private struct FontPreview: View {
    let family: String
    let size: Double

    private var font: Font { .custom(family, size: size) }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 0) {
                Text("❯ ").foregroundStyle(Tokens.focusAccent)
                Text("summarize the failing tests")
            }
            Text("⏺ Two failures in PaneNodeTests — both from")
                .foregroundStyle(Tokens.textSecondary)
            Text("  the split-ratio clamp. `0123456789 -> {}")
                .foregroundStyle(Tokens.textSecondary)
            Text("  ILil1| O0o — the quick brown fox")
                .foregroundStyle(Tokens.textMetadata)
        }
        .font(font)
        .foregroundStyle(Tokens.textPrimary)
        .lineLimit(1)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Tokens.terminalBg)
        .clipShape(RoundedRectangle(cornerRadius: 5))
        .overlay(
            RoundedRectangle(cornerRadius: 5)
                .strokeBorder(Tokens.paneBorder, lineWidth: 1)
        )
        .frame(maxWidth: 340)
    }
}

