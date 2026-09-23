import SwiftUI
import AppKit
import ShepherdUI

// MARK: Terminal

/// Settings ▸ Terminal: the terminal panes opened beside a thread (⌘D, or by an agent).
/// Agents are native threads and never use these.
struct TerminalSettings: View {
    var vm: ShepherdViewModel
    @Bindable private var settings = AppSettings.shared
    @State private var families: [String] = []
    @State private var shells: [String] = []

    var body: some View {
        SettingsPage(title: "Terminal", explanation: "Terminal panes beside a thread: their font and which shell they run.") {
            SettingsGroup(title: "Font", footnote: "Font changes apply to open terminals in place; running processes are untouched.") {
                SettingsRow(title: "Font family",
                            subtitle: "Fixed-pitch families installed on this Mac. Ghostty falls back if a family can't be loaded.") {
                    NWPopupMenu(settings.terminalFontFamily == AppSettings.systemFontFamily ? "System font" : settings.terminalFontFamily,
                                minWidth: AppLayout.settingsPopupWidth) {
                        Button("System font") { settings.terminalFontFamily = AppSettings.systemFontFamily }
                        Divider()
                        ForEach(families, id: \.self) { family in
                            Button(family) { settings.terminalFontFamily = family }
                        }
                    }
                    .accessibilityLabel("Font family")
                    .onChange(of: settings.terminalFontFamily) { vm.rebuildSurfaces() }
                }
                SettingsRow(title: "Font size") {
                    NWValueSlider("Font size", value: $settings.terminalFontSize, in: AppSettings.fontSizeRange, step: 0.5) {
                        String(format: "%.1f pt", $0)
                    }
                    .onChange(of: settings.terminalFontSize) { vm.rebuildSurfaces() }
                }
                SettingsRow(title: "Preview", subtitle: "Updates as you change the family and size.") {
                    FontPreview(family: TerminalFontCatalog.resolved(settings.terminalFontFamily), size: settings.terminalFontSize)
                }
            }
            SettingsGroup(title: "Shell", footnote: "A new shell applies to panes opened afterwards.") {
                SettingsRow(title: "Shell",
                            subtitle: "Used by ⌘D splits and the panes an agent opens.") {
                    NWPopupMenu(settings.shellPath, mono: true, minWidth: AppLayout.settingsPopupWidth) {
                        ForEach(shells, id: \.self) { shell in
                            Button(shell) { settings.shellPath = shell }
                        }
                    }
                    .accessibilityLabel("Shell")
                }
            }
        }
        .task(id: settings.terminalFontFamily) { families = TerminalFontCatalog.families(including: settings.terminalFontFamily) }
        .task(id: settings.shellPath) { shells = AppSettings.knownShells(including: settings.shellPath) }
    }
}

/// Installed fixed-pitch families, enumerated once per launch: the walk builds an `NSFont` for
/// every family on the Mac, far too slow to repeat on each render of the page.
@MainActor
enum TerminalFontCatalog {
    private static let installed = AppSettings.monospacedFamilies(including: AppSettings.systemFontFamily)
    private static let visible = Set(NSFontManager.shared.availableFontFamilies)

    /// The installed families, plus the configured one when it is missing, so it stays visible
    /// and correctable.
    static func families(including current: String) -> [String] {
        guard current != AppSettings.systemFontFamily, !installed.contains(current) else { return installed }
        return (installed + [current]).sorted()
    }

    /// `AppSettings.resolvedTerminalFontFamily` against the cached family list.
    static func resolved(_ family: String) -> String {
        guard family == AppSettings.systemFontFamily else { return family }
        return ["SF Mono", "Menlo"].first(where: visible.contains) ?? "Menlo"
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
        VStack(alignment: .leading, spacing: NW.Space.xxs) {
            Text("\(Text("~/proj ").foregroundStyle(Color.nw.running))❯ git status --short")
            Text(" M Sources/App.swift").foregroundStyle(Color.nw.lanternText)
            Text("?? Tests/AppTests.swift").foregroundStyle(Color.nw.done)
            Text("ILil1| O0o {} -> the quick brown fox").foregroundStyle(Color.nw.textSecondary)
        }
        .font(font)
        .foregroundStyle(Color.nw.textPrimary)
        .lineLimit(1)
        .padding(NW.Space.l)
        .frame(width: AppLayout.settingsFontPreviewWidth, alignment: .leading)
        .nwCard(radius: NW.Radius.s, fill: Color.nw.bgWindow)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Preview of \(family) at \(size.formatted()) points")
    }
}
