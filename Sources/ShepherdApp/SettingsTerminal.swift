import SwiftUI
import AppKit
import ShepherdUI

// MARK: Terminal

/// Settings ▸ Terminal: the terminal panes opened beside a thread (⌘D, or by an agent).
/// Agents are native threads and never use these.
struct TerminalSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject private var settings = AppSettings.shared

    private var families: [String] {
        AppSettings.monospacedFamilies(including: settings.terminalFontFamily)
    }

    var body: some View {
        SettingsPage(title: "Terminal", explanation: "Terminal panes beside a thread: their font and which shell they run.") {
            SettingsGroup(title: "Font", footnote: "Font changes apply to open terminals in place; running processes are untouched.") {
                SettingsRow(title: "Font family",
                            subtitle: "Fixed-pitch families installed on this Mac. Ghostty falls back if a family can't be loaded.") {
                    NWPopupMenu(settings.terminalFontFamily == AppSettings.systemFontFamily ? "System font" : settings.terminalFontFamily,
                              minWidth: 200) {
                        Button("System font") { settings.terminalFontFamily = AppSettings.systemFontFamily }
                        Divider()
                        ForEach(families, id: \.self) { family in
                            Button(family) { settings.terminalFontFamily = family }
                        }
                    }
                    .onChange(of: settings.terminalFontFamily) { vm.rebuildSurfaces() }
                }
                SettingsRow(title: "Font size") {
                    NWValueSlider(value: $settings.terminalFontSize, in: AppSettings.fontSizeRange, step: 0.5) {
                        String(format: "%.1f pt", $0)
                    }
                    .onChange(of: settings.terminalFontSize) { vm.rebuildSurfaces() }
                }
                SettingsRow(title: "Preview", subtitle: "Updates as you change the family and size.") {
                    FontPreview(family: settings.resolvedTerminalFontFamily, size: settings.terminalFontSize)
                }
            }
            SettingsGroup(title: "Shell", footnote: "A new shell applies to panes opened afterwards.") {
                SettingsRow(title: "Shell",
                            subtitle: "Used by ⌘D splits and the panes an agent opens.") {
                    NWPopupMenu(settings.shellPath, mono: true, minWidth: 180) {
                        ForEach(AppSettings.knownShells(including: settings.shellPath), id: \.self) { shell in
                            Button(shell) { settings.shellPath = shell }
                        }
                    }
                }
            }
        }
    }
}

/// A few shell lines in the configured terminal font and the theme's terminal colors, so font
/// changes are judged without leaving Settings.
private struct FontPreview: View {
    let family: String
    let size: Double

    /// By family name, as ghostty loads it (`Font.custom` wants a PostScript name).
    private var font: Font {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size).map { Font($0) }
            ?? .system(size: size, design: .monospaced)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(Text("~/proj ").foregroundStyle(Color.nw.running))❯ git status --short")
            Text(" M Sources/App.swift").foregroundStyle(Color.nw.lanternText)
            Text("?? Tests/AppTests.swift").foregroundStyle(Color.nw.done)
            Text("ILil1| O0o {} -> the quick brown fox").foregroundStyle(Color.nw.textSecondary)
        }
        .font(font)
        .foregroundStyle(Color.nw.textPrimary)
        .lineLimit(1)
        .padding(10)
        .frame(width: 320, alignment: .leading)
        .background(Color.nw.bgBase, in: RoundedRectangle(cornerRadius: NW.Radius.m))
        .overlay { RoundedRectangle(cornerRadius: NW.Radius.m).strokeBorder(Color.nw.lineSubtle, lineWidth: 1) }
    }
}
