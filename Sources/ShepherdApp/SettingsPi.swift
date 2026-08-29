import SwiftUI

struct PiSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updates = PiUpdateManager.shared

    var body: some View {
        SettingsGroup(title: "Pi") {
            SettingsRow(
                title: "Automatically Update Pi",
                subtitle: "Runs pi update and pi update --extensions once a day when updates are available.",
                isFirst: true
            ) {
                Toggle("", isOn: Binding(
                    get: { settings.autoUpdatePi },
                    set: {
                        settings.autoUpdatePi = $0
                        if $0 { updates.applyAutoUpdateSetting() }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            SettingsRow(title: "Installed Version") {
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
            if updates.isOutdated {
                SettingsRow(title: "Update Now") {
                    Button("Update") { updates.updateNow() }
                        .disabled(updates.isUpdating)
                }
            }
        }
        SettingsNote(text: "updates use the pi installation resolved from your login shell · running agents are not restarted")
    }

    private var statusText: String {
        if updates.isUpdating { return "updating…" }
        if updates.isOutdated { return "pi outdated · latest \(updates.latestVersion ?? "unknown")" }
        if let error = updates.lastError { return "error · \(error)" }
        return updates.lastChecked == nil ? "not checked" : "up to date"
    }
}
