import SwiftUI

// MARK: Appearance

struct AppearanceSettings: View {
    var vm: ShepherdViewModel
    @ObservedObject private var themes = ThemeManager.shared
    @ObservedObject private var settings = AppSettings.shared
    @Environment(\.colorScheme) private var systemColorScheme

    var body: some View {
        SettingsGroup(title: "Appearance") {
            SettingsRow(
                title: "Mode",
                subtitle: "System follows your Mac automatically. Shepherd uses the Basalt palette in both modes.",
                isFirst: true
            ) {
                Picker("", selection: Binding(
                    get: { themes.mode },
                    set: { vm.selectAppearance($0, systemColorScheme: systemColorScheme) }
                )) {
                    ForEach(AppearanceMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(width: 120)
            }
        }

        SettingsGroup(title: "Layout") {
            SettingsRow(
                title: "Density",
                subtitle: "Row heights across the sidebar and chrome. Lower fits more agents.",
                isFirst: true
            ) {
                scaleSlider($settings.uiDensity, range: AppSettings.uiDensityRange, neutral: 1)
            }
            SettingsRow(
                title: "Text Size",
                subtitle: "App chrome only — the terminal has its own font size."
            ) {
                scaleSlider($settings.uiTextScale, range: AppSettings.uiTextScaleRange, neutral: 1)
            }
            SettingsRow(title: "Sidebar Width") {
                HStack(spacing: 8) {
                    Slider(value: $settings.sidebarWidth, in: AppSettings.sidebarWidthRange, step: 10)
                        .frame(width: 170)
                    Text("\(Int(settings.sidebarWidth))")
                        .font(Fonts.mono(10.5))
                        .foregroundStyle(Tokens.textMetadata)
                        .frame(width: 34, alignment: .trailing)
                }
            }
        }
        SettingsNote(text: "Basalt palette · system mode follows macOS appearance changes")
    }

    /// Percent-labelled slider with a double-click-to-reset neutral point.
    private func scaleSlider(
        _ value: Binding<Double>, range: ClosedRange<Double>, neutral: Double
    ) -> some View {
        HStack(spacing: 8) {
            Slider(value: value, in: range, step: 0.05)
                .frame(width: 170)
            Text("\(Int((value.wrappedValue * 100).rounded()))%")
                .font(Fonts.mono(10.5))
                .foregroundStyle(Tokens.textMetadata)
                .frame(width: 34, alignment: .trailing)
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { value.wrappedValue = neutral }
                .help("Double-click to reset")
        }
    }
}
