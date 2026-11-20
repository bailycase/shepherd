import SwiftUI
import AppKit
import ShepherdUI

// MARK: Terminal

/// Settings ▸ Appearance ▸ Font and Shell: the terminals opened under a thread (⌘D, or by an agent).
/// Agents are native threads and never use these.
struct TerminalSettings: View {
    var vm: ShepherdViewModel
    @Bindable private var settings = AppSettings.shared
    private var keys: KeybindingsStore { .shared }
    @State private var families: [String] = []
    @State private var shells: [String] = []

    var body: some View {
        SettingsGroup(title: "Terminal", footnote: "Font changes apply to open terminals; a new shell to terminals opened after.") {
            SettingsRow(title: "Font") {
                SHPopupMenu(settings.terminalFontFamily == AppSettings.systemFontFamily ? "System font" : settings.terminalFontFamily,
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
            SettingsRow(title: "Size") {
                AppearanceSettings.stepMenu("Font size", value: $settings.terminalFontSize, range: AppSettings.fontSizeRange, step: 0.5) {
                    $0.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int($0)) pt" : String(format: "%.1f pt", $0)
                }
                .onChange(of: settings.terminalFontSize) { vm.rebuildSurfaces() }
            }
            FontPreview(family: TerminalFontCatalog.resolved(settings.terminalFontFamily), size: settings.terminalFontSize)
            SettingsRow(title: "Shell", subtitle: Self.shellSubtitle(keys)) {
                SHPopupMenu(settings.shellPath, mono: true, minWidth: AppLayout.settingsPopupWidth) {
                    ForEach(shells, id: \.self) { shell in
                        Button(shell) { settings.shellPath = shell }
                    }
                }
                .accessibilityLabel("Shell")
            }
        }
        .task(id: settings.terminalFontFamily) { families = TerminalFontCatalog.families(including: settings.terminalFontFamily) }
        .task(id: settings.shellPath) { shells = AppSettings.knownShells(including: settings.shellPath) }
    }

    /// Names the New Terminal chord as it is bound now, so a rebind never leaves the copy wrong.
    static func shellSubtitle(_ keys: KeybindingsStore) -> String {
        "Used by \(keys.display(.newTerminal)) and the terminals an agent opens."
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

/// The mono sample row: one line in the configured terminal font, on the sunken fill.
private struct FontPreview: View {
    let family: String
    let size: Double

    /// By family name, as ghostty loads it (`Font.custom` wants a PostScript name).
    private var font: Font {
        NSFontManager.shared.font(withFamily: family, traits: [], weight: 5, size: size).map { Font($0) }
            ?? .system(size: size, design: .monospaced)
    }

    var body: some View {
        Text("The quick brown fox jumps over the lazy dog  0123456789 {}[]")
            .font(font)
            .foregroundStyle(Color.sh.textSecondary)
            .lineLimit(1)
            .padding(.horizontal, SH.Space.l)
            .padding(.vertical, SH.Space.m)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.sh.bgSunken)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Preview of \(family) at \(size.formatted()) points")
    }
}
