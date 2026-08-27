import SwiftUI
import AppKit
import ShepherdProtocol

// MARK: Advanced

struct AdvancedSettings: View {
    @ObservedObject var vm: ShepherdViewModel
    @ObservedObject private var updater = AppUpdater.shared
    @State private var confirmingReset = false

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        return "\(short) (\(build))"
    }

    var body: some View {
        SettingsGroup(title: "Files") {
            PathRow(
                title: "Workspace State",
                subtitle: "Spaces, agents, and pane layouts restored on relaunch.",
                url: ShepherdPaths.stateURL(),
                isFirst: true
            )
            PathRow(
                title: "Extension Socket",
                subtitle: "Where each pi process reports agent status and pane requests.",
                url: ShepherdPaths.socketURL()
            )
        }

        SettingsGroup(title: "Reset") {
            SettingsRow(
                title: "Reset Settings",
                subtitle: "Restores appearance, font, agent, shell, and keyboard preferences. Spaces, agents, and layouts are untouched.",
                isFirst: true
            ) {
                Button("Reset…") { confirmingReset = true }
            }
        }

        if updater.available {
            SettingsGroup(title: "Updates") {
                SettingsRow(
                    title: "Automatically Check for Updates",
                    isFirst: true
                ) {
                    Toggle("", isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                }
                SettingsRow(
                    title: "Nightly Builds",
                    subtitle: "Bleeding-edge updates from every push, less tested than releases."
                ) {
                    Toggle("", isOn: $updater.nightly)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                SettingsRow(title: "Check Now") {
                    Button("Check for Updates…") { updater.checkForUpdates() }
                }
            }
        }

        SettingsGroup(title: "About") {
            SettingsRow(title: "Version", isFirst: true) {
                Text(version)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
            }
        }
        SettingsNote(text: "sessions live and die with the app · quitting Shepherd stops every agent")
            .alert("Reset Settings to Defaults?", isPresented: $confirmingReset) {
                Button("Reset", role: .destructive) {
                    vm.resetSettings()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Your spaces, agents, and pane layouts are not affected.")
            }
    }
}

struct PathRow: View {
    let title: String
    let subtitle: String
    let url: URL
    var isFirst = false

    var body: some View {
        SettingsRow(title: title, subtitle: subtitle, isFirst: isFirst) {
            HStack(spacing: 8) {
                Text(url.lastPathComponent)
                    .font(Fonts.mono(10.5))
                    .foregroundStyle(Tokens.textMetadata)
                    .help(url.path)
                Button("Reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
