import SwiftUI
import ShepherdUI
import AppKit
import ShepherdProtocol

// MARK: Advanced

struct AdvancedSettings: View {
    var vm: ShepherdViewModel
    private var updater: AppUpdater { .shared }
    @State private var confirmingReset = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsPage(title: "Advanced", explanation: "Files, resets and app updates. Quitting Shepherd stops every agent.") {
            SettingsGroup(title: "Files") {
                PathRow(title: "Workspace state", subtitle: "Spaces, agents and pane layouts restored on relaunch.",
                        url: ShepherdPaths.stateURL())
                PathRow(title: "Extension socket", subtitle: "Where each pi process reports status and pane requests.",
                        url: ShepherdPaths.socketURL())
            }
            SettingsGroup(title: "Updates") {
                if updater.available {
                    SettingsRow(title: "Check for updates automatically") {
                        SettingsSwitch(label: "Check for updates automatically", isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.automaticallyChecks = $0 }
                        ))
                    }
                    SettingsRow(title: "Update channel",
                                subtitle: "Stable: tagged releases. Release Candidate and Beta also get newer stable builds. Nightly: every push, least tested.") {
                        NWPopupMenu(updater.channel.label, minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(UpdateChannel.allCases) { channel in
                                Button(channel.label) { updater.channel = channel }
                            }
                        }
                        .accessibilityLabel("Update channel")
                    }
                }
                SettingsRow(title: "Version \(version)") {
                    if updater.available {
                        Button("Check for updates") { updater.checkForUpdates() }
                            .buttonStyle(.nw(.secondary, size: .s))
                    }
                }
            }
            SettingsGroup(title: "Reset") {
                SettingsRow(title: "Reset settings",
                            subtitle: "Restores appearance, font, agent, shell and keyboard preferences. Spaces, agents and layouts are untouched.") {
                    Button("Reset…") { confirmingReset = true }
                        .buttonStyle(.nw(.danger, size: .s))
                }
            }
        }
        .sheet(isPresented: $confirmingReset) {
            ResetSettingsDialog {
                confirmingReset = false
                vm.resetSettings()
            } cancel: {
                confirmingReset = false
            }
        }
    }
}

/// Settings ▸ Advanced ▸ Reset: preferences only; the workspace is untouched.
struct ResetSettingsDialog: View {
    let reset: () -> Void
    let cancel: () -> Void

    var body: some View {
        DialogSheet(
            title: "Reset settings to defaults?",
            subtitle: "Your spaces, agents and pane layouts are not affected.",
            actions: [
                DialogAction("Cancel", kind: .cancel, action: cancel),
                DialogAction("Reset", kind: .destructive, action: reset),
            ]
        )
    }
}
