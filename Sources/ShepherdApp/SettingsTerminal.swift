import SwiftUI

// MARK: Terminal

struct TerminalSettings: View {
    @ObservedObject var vm: ShepherdViewModel
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

