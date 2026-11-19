import SwiftUI
import ShepherdUI

// MARK: Appearance

struct AppearanceSettings: View {
    var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    @Bindable private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        // The sidebar reads the view model's settings (the app's own, a scratch set in tests).
        @Bindable var sidebar = vm.settings
        SettingsPage(title: "Appearance") {
            SettingsGroup(title: "") {
                SettingsRow(title: "Mode") {
                    SHSegmentedPicker("Mode", selection: Binding(
                        get: { themes.mode },
                        set: { vm.selectAppearance($0, systemColorScheme: systemColorScheme) }
                    ), options: AppearanceMode.allCases.map { ($0, $0.title) })
                }
                SettingsRow(title: "Theme") { SettingsValue(text: ThemeStore.shared.theme.name) }
            }
            SettingsGroup(title: "Size") {
                SettingsRow(title: "Sidebar rows") {
                    SHSegmentedPicker("Sidebar rows", selection: $settings.sidebarRowDensity,
                                      options: SHDensity.allCases.map { ($0, $0.title) })
                }
                SettingsRow(title: "Density") {
                    Self.stepMenu("Density", value: $settings.uiDensity, range: AppSettings.uiDensityRange, step: 0.05) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
                SettingsRow(title: "Text size") {
                    Self.stepMenu("Text size", value: $settings.uiTextScale, range: AppSettings.uiTextScaleRange, step: 0.05) {
                        "\(Int(($0 * 100).rounded()))%"
                    }
                }
                SettingsRow(title: "Sidebar width") {
                    SHValueSlider("Sidebar width", value: $settings.sidebarWidth, in: AppSettings.sidebarWidthRange, step: 1,
                                neutral: Double(AppLayout.sidebarDefaultWidth), unit: "points") { "\(Int($0))" }
                }
            }
            SettingsGroup(title: "Sidebar") {
                SettingsRow(title: "Organize by") {
                    SHSegmentedPicker("Organize by", selection: Binding(get: { sidebar.sidebarStyle }, set: { vm.setSidebarStyle($0) }),
                                      options: SHSidebarStyle.allCases.map { ($0, $0.title) })
                }
                if sidebar.sidebarStyle == .projects {
                    SettingsRow(title: "Keep idle threads", subtitle: "⌘K still finds them") {
                        SHPopupMenu(Self.keepIdleTitle(sidebar.sidebarKeepIdleDays)) {
                            Picker("Keep idle threads", selection: $sidebar.sidebarKeepIdleDays) {
                                ForEach(AppSettings.sidebarKeepIdleChoices, id: \.self) { Text(Self.keepIdleTitle($0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
            .shAnimation(.disclosure, value: sidebar.sidebarStyle)
            TerminalSettings(vm: vm)
        }
    }

    /// A menu of a setting's existing steps: 100%, 95%, …
    @MainActor static func stepMenu(_ label: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                                    format: @escaping (Double) -> String) -> some View {
        let count = Int(((range.upperBound - range.lowerBound) / step).rounded())
        let steps = (0...count).map { range.lowerBound + Double($0) * step }
        return SHPopupMenu(format(value.wrappedValue), minWidth: 0) {
            ForEach(steps.reversed(), id: \.self) { stop in
                Button(format(stop)) { value.wrappedValue = stop }
            }
        }
        .accessibilityLabel(label)
    }

    /// "7 days", "1 day", "Forever".
    static func keepIdleTitle(_ days: Int) -> String {
        switch days {
        case 0: "Forever"
        case 1: "1 day"
        default: "\(days) days"
        }
    }
}
