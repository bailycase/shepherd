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
                    .nwTransition(.disclosure)
                    UpdateChannelRow(edition: updater.edition, channel: Binding(
                        get: { updater.channel },
                        set: { updater.select($0) }
                    ))
                    .nwTransition(.disclosure)
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
        // Sparkle reports whether it can update once it has started.
        .nwAnimation(.disclosure, value: updater.available)
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

/// Settings ▸ Advanced ▸ Updates: Shepherd picks Stable or Beta; Shepherd Nightly has one
/// channel and names it.
struct UpdateChannelRow: View {
    let edition: ShepherdEdition
    @Binding var channel: UpdateChannel

    var body: some View {
        switch edition {
        case .main:
            SettingsRow(title: "Update channel",
                        subtitle: "Stable: tagged releases. Beta: pre-releases, plus newer stable builds. Nightly builds are a separate app, Shepherd Nightly.") {
                NWSegmentedPicker("Update channel", selection: $channel,
                                  options: UpdateChannel.choices(for: edition).map { ($0, $0.label) })
            }
        case .nightly:
            SettingsRow(title: "Update channel",
                        subtitle: "Every push to the integration branch, least tested. Tagged releases ship as Shepherd.") {
                Text(UpdateChannel.nightly.label)
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textSecondary)
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
