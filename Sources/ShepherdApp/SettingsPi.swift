import SwiftUI

struct PiSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updates = PiUpdateManager.shared

    var body: some View {
        SettingsGroup(title: "Bundled Pi Extensions") {
            SettingsRow(
                title: "Name Agents Automatically",
                subtitle: "Pi titles each new agent from its opening prompt on the first turn, using the cheapest model it is authed for. Off keeps the truncated prompt as the name.",
                isFirst: true
            ) {
                Toggle("Name agents automatically", isOn: $settings.autoNameAgents)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "sync pi theme",
                subtitle: "Use Shepherd's palette in pi and follow theme changes. Off uses pi's own theme."
            ) {
                Toggle("sync pi theme", isOn: $settings.piThemeExtension)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "panes and agent tools",
                subtitle: "Let agents control panes, message or spawn agents, manage automations, and send notifications. Off removes these tools, including notifications from automation runs."
            ) {
                Toggle("panes and agent tools", isOn: $settings.piPanesExtension)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "diff review tool",
                subtitle: "Let agents open a native diff review with review_diff."
            ) {
                Toggle("diff review tool", isOn: $settings.piReviewExtension)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
            SettingsRow(
                title: "subagent display",
                subtitle: "Show pi subagent runs in the sidebar and open their inspector. Off does not stop subagents from running."
            ) {
                Toggle("subagent display", isOn: $settings.piSubagentsExtension)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        SettingsNote(text: "applies to agents launched on this Mac, including automations and remotely created agents · running agents keep their extensions until restarted; quit and reopen Shepherd to apply to all · user-installed pi extensions are unchanged")
        SettingsNote(text: "status and session tracking are always on so lifecycle updates and /new or /resume restoration keep working")
        SettingsNote(text: "a hand-typed rename is always final · naming never blocks pi's first turn")

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
                Button(updates.isChecking ? "Checking…" : "Check") {
                    updates.checkNow()
                }
                .disabled(updates.isBusy)
            }
            SettingsRow(title: "Update Pi Now") {
                Button(piUpdateButtonTitle) { updates.updatePiNow() }
                    .disabled(!updates.canUpdatePi)
            }
            SettingsRow(title: "Update Extensions Now") {
                Button(extensionUpdateButtonTitle) { updates.updateExtensionsNow() }
                    .disabled(!updates.canUpdateExtensions)
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

    private var piUpdateButtonTitle: String {
        switch updates.activeUpdate {
        case .pi, .both: return "Updating…"
        default: return updates.lastChecked != nil && !updates.isOutdated ? "Up to Date" : "Update"
        }
    }

    private var extensionUpdateButtonTitle: String {
        switch updates.activeUpdate {
        case .extensions, .both: return "Updating…"
        default: return updates.extensionsUpdatedAt == nil ? "Update" : "Updated"
        }
    }

    private var statusText: String {
        if updates.isChecking { return "checking…" }
        if let target = updates.activeUpdate {
            switch target {
            case .pi: return "updating Pi…"
            case .extensions: return "updating extensions…"
            case .both: return "updating Pi and extensions…"
            }
        }
        if updates.isOutdated { return "pi outdated · latest \(updates.latestVersion ?? "unknown")" }
        if let error = updates.lastError { return "error · \(error)" }
        return updates.lastChecked == nil ? "not checked" : "Pi up to date"
    }
}
