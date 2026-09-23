import SwiftUI
import ShepherdUI

// MARK: Appearance

struct AppearanceSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        SettingsPage(title: "Appearance", explanation: "How Shepherd looks. The terminal has its own font settings.") {
            SettingsGroup(title: "Theme") {
                SettingsRow(title: "Theme", subtitle: "Night Watch ships with Shepherd, in light and dark.") {
                    NWPopupMenu(ThemeStore.shared.theme.name, minWidth: 140) {
                        Button(ThemeStore.shared.theme.name) {}
                    }
                }
                SettingsRow(title: "Mode", subtitle: "System follows your Mac and switches with it.") {
                    NWSegmentedPicker(selection: Binding(
                        get: { themes.mode },
                        set: { vm.selectAppearance($0, systemColorScheme: systemColorScheme) }
                    ), options: AppearanceMode.allCases.map { ($0, $0.title) })
                }
            }
            SettingsGroup(title: "Layout") {
                SettingsRow(title: "Density", subtitle: "Row heights across the sidebar and chrome. Lower fits more agents.") {
                    NWValueSlider(value: $settings.uiDensity, in: AppSettings.uiDensityRange, step: 0.05, neutral: 1) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
                SettingsRow(title: "Text size", subtitle: "App chrome only.") {
                    NWValueSlider(value: $settings.uiTextScale, in: AppSettings.uiTextScaleRange, step: 0.05, neutral: 1) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
                SettingsRow(title: "Sidebar width") {
                    NWValueSlider(value: $settings.sidebarWidth, in: AppSettings.sidebarWidthRange, step: 1,
                                neutral: Double(AppLayout.sidebarDefaultWidth)) { "\(Int($0)) pt" }
                }
            }
        }
    }
}
