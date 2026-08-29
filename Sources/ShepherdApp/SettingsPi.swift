import SwiftUI

struct PiSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updates = PiUpdateManager.shared

    var body: some View {
        SettingsGroup(title: "Automatic Updates") {
            SettingsRow(
                title: "Update Pi",
                subtitle: "Runs pi update once a day.",
                isFirst: true
            ) {
                updateToggle($settings.autoUpdatePi)
            }
            SettingsRow(
                title: "Update Extensions",
                subtitle: "Runs pi update --extensions once a day."
            ) {
                updateToggle($settings.autoUpdateExtensions)
            }
        }

        SettingsGroup(title: "Pi") {
            SettingsRow(title: "Installed Version", isFirst: true) {
                Text(updates.currentVersion ?? "unknown")
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
            }
            SettingsRow(title: "Status") {
                Text(statusText)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(updates.isOutdated ? Tokens.destructive : Tokens.textMetadata)
            }
            SettingsRow(title: "Check Now") {
                Button(updates.isUpdating ? "Updating…" : "Check") {
                    updates.checkNow()
                }
                .disabled(updates.isUpdating)
            }
            SettingsRow(title: "Update Pi Now") {
                Button("Update") { updates.updatePiNow() }
                    .disabled(updates.isUpdating)
            }
            SettingsRow(title: "Update Extensions Now") {
                Button("Update") { updates.updateExtensionsNow() }
                    .disabled(updates.isUpdating)
            }
        }
        SettingsNote(text: "updates use the pi installation resolved from your login shell · running agents are not restarted")
    }

    private func updateToggle(_ binding: Binding<Bool>) -> some View {
        Toggle("", isOn: Binding(
            get: { binding.wrappedValue },
            set: {
                binding.wrappedValue = $0
                if $0 { updates.applyAutoUpdateSetting() }
            }
        ))
        .labelsHidden()
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    private var statusText: String {
        if updates.isUpdating { return "updating…" }
        if updates.isOutdated { return "pi outdated · latest \(updates.latestVersion ?? "unknown")" }
        if let error = updates.lastError { return "error · \(error)" }
        return updates.lastChecked == nil ? "not checked" : "up to date"
    }
}
