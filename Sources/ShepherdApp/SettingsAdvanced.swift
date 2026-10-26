import SwiftUI
import ShepherdUI
import AppKit
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdSessions

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
                PathRow(title: "Workspace state", subtitle: "Spaces, agents and terminals restored on relaunch.",
                        url: ShepherdPaths.stateURL())
                PathRow(title: "Extension socket", subtitle: "Where each agent process reports status and terminal requests.",
                        url: ShepherdPaths.socketURL())
            }
            EditorSettings(settings: vm.settings)
            SettingsGroup(title: "Updates") {
                if updater.available {
                    SettingsRow(title: "Check for updates automatically") {
                        SettingsSwitch(label: "Check for updates automatically", isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.automaticallyChecks = $0 }
                        ))
                    }
                    .shTransition(.disclosure)
                    UpdateChannelRow(edition: updater.edition, channel: Binding(
                        get: { updater.channel },
                        set: { updater.select($0) }
                    ))
                    .shTransition(.disclosure)
                }
                SettingsRow(title: "Version \(version)") {
                    if updater.available {
                        Button("Check for updates") { updater.checkForUpdates() }
                            .buttonStyle(.sh(.secondary, size: .s))
                    }
                }
            }
            DiagnosticsSettings(settings: vm.settings, configured: ShepherdDiagnostics.shared.configured,
                                active: ShepherdDiagnostics.shared.isActive)
            SettingsGroup(title: "Reset") {
                SettingsRow(title: "Reset settings",
                            subtitle: "Restores appearance, terminal, agent, worktree, extension, keyboard and diagnostics preferences. Spaces, agents, layouts and Remote are untouched.") {
                    Button("Reset…") { confirmingReset = true }
                        .buttonStyle(.sh(.danger, size: .s))
                }
            }
        }
        // Sparkle reports whether it can update once it has started.
        .shAnimation(.disclosure, value: updater.available)
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

/// Settings ▸ Advanced ▸ Editor: the app local files open in (file links in replies, review, project files).
struct EditorSettings: View {
    @Bindable var settings: AppSettings
    @State private var editors: [URL] = []

    private var title: String {
        guard let id = settings.editor else { return "System default" }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map(EditorOpener.name(of:)) ?? id
    }

    var body: some View {
        SettingsGroup(title: "Editor") {
            SettingsRow(title: "Open files in", subtitle: "File links in replies, reviewed files and project files. System default uses each file's own app.") {
                SHPopupMenu(title, minWidth: AppLayout.settingsPopupWidth) {
                    Button("System default") { settings.editor = nil }
                    Divider()
                    ForEach(editors, id: \.self) { app in
                        Button(EditorOpener.name(of: app)) { settings.editor = Bundle(url: app)?.bundleIdentifier }
                    }
                    Divider()
                    Button("Choose…") { choose() }
                }
                .accessibilityLabel("Open files in")
            }
        }
        .task { editors = EditorOpener.installedEditors() }
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        guard panel.runModal() == .OK, let app = panel.url, let id = Bundle(url: app)?.bundleIdentifier else { return }
        settings.editor = id
    }
}

struct DiagnosticsSettings: View {
    @Bindable var settings: AppSettings
    let configured: Bool
    var active = false

    static let disclosure = "Send crash and hang stacks, app and device details, resource metrics, operation timings, fixed diagnostic logs and app-session health to Sentry. No prompts, replies, tool output, file contents, command lines or session replay. Performance reports upload while Shepherd runs; crashes upload when you reopen it."

    private var status: String? {
        guard configured else {
            return settings.shareDiagnostics ? "Reporting is unavailable. Turn this off to revoke saved consent." : nil
        }
        let state = !settings.shareDiagnostics ? "Off. Turning on takes effect after you quit and reopen Shepherd."
            : active ? "Reporting is active." : "Not active yet. Quit and reopen Shepherd to start reporting."
        return state + " Turning off stops reporting and discards pending reports, but does not delete reports already sent."
    }

    var body: some View {
        SettingsGroup(title: "Diagnostics", footnote: status) {
            SettingsRow(title: "Share diagnostics", subtitle: configured
                        ? Self.disclosure : "Diagnostics reporting is not configured in this build.") {
                SettingsSwitch(label: "Share diagnostics", isOn: $settings.shareDiagnostics)
                    .accessibilityHint(configured ? Self.disclosure : "Diagnostics reporting is not configured in this build.")
                    .disabled(!configured && !settings.shareDiagnostics)
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
                // SettingsAdvanced draws this one as the Controls board's segmented control.
                SHSegmentedPicker("Update channel", selection: $channel,
                                  options: UpdateChannel.choices(for: edition).map { ($0, $0.label) })
                    .shControlScale(.standard)
            }
        case .nightly:
            SettingsRow(title: "Update channel",
                        subtitle: "Every push to the integration branch, least tested. Tagged releases ship as Shepherd.") {
                Text(UpdateChannel.nightly.label)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
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
            subtitle: "Your spaces, agents and terminals are not affected.",
            actions: [
                DialogAction("Cancel", kind: .cancel, action: cancel),
                DialogAction("Reset", kind: .destructive, action: reset),
            ]
        )
    }
}
