import SwiftUI
import ShepherdUI
import AppKit
import UniformTypeIdentifiers
import ShepherdProtocol
import ShepherdSessions

// MARK: Advanced

struct AdvancedSettings: View {
    var vm: ShepherdViewModel
    @State private var confirmingReset = false

    /// Which confirmations "Don't ask again" turned off, by name.
    private var skippedSummary: String {
        let names = SkippableConfirmation.allCases.filter { vm.settings.skipped($0) != nil }.map(\.title)
            + (vm.settings.worktreeDeleteAction == .ask ? [] : ["Delete worktree agent"])
        return names.isEmpty ? "Every confirmation asks first" : names.formatted(.list(type: .and))
    }

    var body: some View {
        SettingsPage(title: "Advanced") {
            DiagnosticsSettings(settings: vm.settings, configured: ShepherdDiagnostics.shared.configured,
                                active: ShepherdDiagnostics.shared.isActive)
            SettingsGroup(title: "Files") {
                PathRow(title: "Workspace state", subtitle: "Spaces, agents and terminals", url: ShepherdPaths.stateURL())
                PathRow(title: "Extension socket", subtitle: "Where agents report status", url: ShepherdPaths.socketURL())
            }
            SettingsGroup(title: "Reset") {
                SettingsRow(title: "Confirmations you skipped", subtitle: skippedSummary) {
                    Button("Ask again") { vm.settings.askAgainEverywhere() }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .disabled(vm.settings.skippedConfirmationCount == 0)
                }
                SettingsRow(title: "All settings", subtitle: "Spaces, agents and layouts stay") {
                    Button("Reset…") { confirmingReset = true }
                        .buttonStyle(.sh(.danger, size: .s))
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

/// Settings ▸ General: what happens when you quit, notifications, the editor files open in, and
/// app updates.
struct GeneralSettings: View {
    var vm: ShepherdViewModel
    private var updater: AppUpdater { .shared }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "dev"
        return short
    }

    var body: some View {
        @Bindable var settings = vm.settings
        SettingsPage(title: "General") {
            // Only while it needs you: otherwise the row has nothing to change.
            if vm.backgroundServiceStatus == .requiresApproval {
                SettingsGroup(title: "When you quit") {
                    SettingsRow(title: "Keep agents running", subtitle: "Turn on Shepherd in Login Items to keep them running") {
                        Button("Open Login Items") { vm.backgroundService?.openLoginItems() }
                            .buttonStyle(.sh(.secondary, size: .s))
                    }
                }
            }
            SettingsGroup(title: "Notifications") {
                SettingsRow(title: "Turn finished", subtitle: "Only for threads you aren’t viewing") {
                    SettingsSwitch(label: "Turn finished", isOn: $settings.notifyOnTurnFinished)
                }
            }
            EditorSettings(settings: vm.settings)
            SettingsGroup(title: "Updates") {
                UpdateChannelRow(edition: updater.edition, channel: Binding(
                    get: { updater.channel },
                    set: { updater.select($0) }
                ))
                if updater.available {
                    SettingsRow(title: "Check automatically") {
                        SettingsSwitch(label: "Check automatically", isOn: Binding(
                            get: { updater.automaticallyChecks },
                            set: { updater.automaticallyChecks = $0 }
                        ))
                    }
                    .shTransition(.disclosure)
                }
                SettingsRow(title: "Version \(version)", subtitle: vm.pi.engine.version.map { "agent \($0)" }) {
                    if updater.available {
                        Button("Check now") { updater.checkForUpdates() }
                            .buttonStyle(.sh(.secondary, size: .s))
                    }
                }
            }
        }
        // Sparkle reports whether it can update once it has started.
        .shAnimation(.disclosure, value: updater.available)
        // Login Items may have changed while the window was elsewhere.
        .onAppear { if let service = vm.backgroundService { vm.backgroundServiceStatus = service.status() } }
    }
}

/// Settings ▸ General ▸ Editor: the app local files open in (file links in replies, review, project files), and the apps
/// file types were given from a file's Open in menu.
struct EditorSettings: View {
    @Bindable var settings: AppSettings
    @State private var editors: [URL] = []

    private var title: String {
        guard let id = settings.editor else { return "System default" }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map(EditorOpener.name(of:)) ?? id
    }

    var body: some View {
        SettingsGroup(title: "Files") {
            SettingsRow(title: "Open files in", subtitle: "File links, reviewed files and space files") {
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
            if !settings.editorsByType.isEmpty {
                SettingsRow(title: "By file type", subtitle: byType) {
                    Button("Reset") { settings.editorsByType = [:] }
                        .buttonStyle(.sh(.secondary, size: .s))
                        .accessibilityLabel("Reset the apps picked for file types")
                }
                .shTransition(.disclosure)
            }
        }
        .shAnimation(.disclosure, value: settings.editorsByType.isEmpty)
        .task { editors = EditorOpener.installedEditors() }
    }

    /// ".md: Quillmark · .tsx: Zed"
    private var byType: String {
        settings.editorsByType.sorted { $0.key < $1.key }.map { type, id in
            let name = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id).map(EditorOpener.name(of:)) ?? id
            return "\(type): \(name)"
        }
        .joined(separator: " · ")
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

    /// What turning it on or off does, when the build can report at all.
    private var status: String? {
        guard configured else { return nil }
        guard settings.shareDiagnostics else { return "Off. Turning on takes effect after you quit and reopen Shepherd." }
        return active ? nil : "Not active yet. Quit and reopen Shepherd to start reporting."
    }

    var body: some View {
        SettingsGroup(title: "Privacy", footnote: status) {
            SettingsRow(title: "Share diagnostics", subtitle: configured
                        ? "Crashes and timings. Never prompts or code." : "Not configured in this build") {
                SettingsSwitch(label: "Share diagnostics", isOn: $settings.shareDiagnostics)
                    .accessibilityHint(configured ? Self.disclosure : "Diagnostics reporting is not configured in this build.")
                    .disabled(!configured && !settings.shareDiagnostics)
            }
            .help(configured ? Self.disclosure : "")
        }
    }
}

/// Settings ▸ General ▸ Updates: Shepherd picks Stable or Beta; Shepherd Nightly has one
/// channel, so no row.
struct UpdateChannelRow: View {
    let edition: ShepherdEdition
    @Binding var channel: UpdateChannel

    var body: some View {
        if edition == .main {
            SettingsRow(title: "Channel") {
                SHSegmentedPicker("Update channel", selection: $channel,
                                  options: UpdateChannel.choices(for: edition).map { ($0, $0.label) })
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
