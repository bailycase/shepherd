import SwiftUI
import ShepherdUI

// MARK: Appearance

struct AppearanceSettings: View {
    var vm: ShepherdViewModel
    private var themes: ThemeManager { .shared }
    @Bindable private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        SettingsPage(title: "Appearance", explanation: "How Shepherd looks. The terminal has its own font settings.") {
            SettingsGroup(title: "Theme") {
                SettingsRow(title: "Theme", subtitle: "Night Watch ships with Shepherd, in light and dark.") {
                    // One theme ships: a name, not a popup with nothing else to choose.
                    Text(ThemeStore.shared.theme.name)
                        .font(.nw(.ui))
                        .foregroundStyle(Color.nw.textSecondary)
                }
                SettingsRow(title: "Mode", subtitle: "System follows your Mac and switches with it.") {
                    NWSegmentedPicker("Mode", selection: Binding(
                        get: { themes.mode },
                        set: { vm.selectAppearance($0, systemColorScheme: systemColorScheme) }
                    ), options: AppearanceMode.allCases.map { ($0, $0.title) })
                }
            }
            // The sidebar reads the view model's settings (the app's own, a scratch set in tests).
            @Bindable var sidebar = vm.settings
            SettingsGroup(title: "Sidebar") {
                OrganizeByRow(style: Binding(get: { sidebar.sidebarStyle }, set: { vm.setSidebarStyle($0) }))
                if sidebar.sidebarStyle == .projects {
                    SettingsRow(title: "Group by host",
                                subtitle: "A section for each Mac or server, its projects inside. Off shows the host as a tag on the row.") {
                        SettingsSwitch(label: "Group by host", isOn: $sidebar.sidebarGroupByHost)
                    }
                    SettingsRow(title: "Keep idle threads",
                                subtitle: "Then they leave the sidebar; ⌘K still finds them. Running threads and anything waiting on you stay.") {
                        NWPopupMenu(Self.keepIdleTitle(sidebar.sidebarKeepIdleDays)) {
                            Picker("Keep idle threads", selection: $sidebar.sidebarKeepIdleDays) {
                                ForEach(AppSettings.sidebarKeepIdleChoices, id: \.self) { Text(Self.keepIdleTitle($0)).tag($0) }
                            }
                            .pickerStyle(.inline)
                            .labelsHidden()
                        }
                    }
                }
            }
            .nwAnimation(.disclosure, value: sidebar.sidebarStyle)
            SettingsGroup(title: "Layout") {
                SettingsRow(title: "Sidebar rows", subtitle: "Compact 22 · Standard 28 · Comfortable 36 pt, for the sidebar and menus.") {
                    NWSegmentedPicker("Sidebar rows", selection: $settings.sidebarRowDensity,
                                      options: NWDensity.allCases.map { ($0, $0.title) })
                }
                SettingsRow(title: "Density", subtitle: "Row heights across the sidebar and chrome. Lower fits more agents.") {
                    NWValueSlider("Density", value: $settings.uiDensity, in: AppSettings.uiDensityRange, step: 0.05, neutral: 1, unit: "percent") {
                        "\(Int(($0 * 100).rounded()))"
                    }
                }
                SettingsRow(title: "Text size", subtitle: "App chrome only.") {
                    NWValueSlider("Text size", value: $settings.uiTextScale, in: AppSettings.uiTextScaleRange, step: 0.05, neutral: 1, unit: "percent") {
                        "\(Int(($0 * 100).rounded()))"
                    }
                }
                SettingsRow(title: "Sidebar width") {
                    NWValueSlider("Sidebar width", value: $settings.sidebarWidth, in: AppSettings.sidebarWidthRange, step: 1,
                                neutral: Double(AppLayout.sidebarDefaultWidth), unit: "points") { "\(Int($0))" }
                }
            }
        }
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

/// Organize by: its title and what it does over the two cards (`NWSidebarStylePicker`).
private struct OrganizeByRow: View {
    @Binding var style: NWSidebarStyle

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsStackedRowSpacing) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text("Organize by")
                    .font(.nw(.body, weight: .medium))
                    .foregroundStyle(Color.nw.textPrimary)
                NWMarkupText("What the sidebar lists under New thread and the destinations. Also in View ▸ Organize Sidebar By.",
                             size: NWTextStyle.ui.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            NWSidebarStylePicker(selection: $style)
        }
        .padding(AppLayout.settingsStackedRowInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}
