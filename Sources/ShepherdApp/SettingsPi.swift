import SwiftUI
import ShepherdDesign
import ShepherdSessions

struct PiSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @ObservedObject private var updates = PiUpdateManager.shared
    @State private var modelOptions: [String] = []

    var body: some View {
        SettingsPage(title: "Pi",
                     explanation: "Extensions Shepherd bundles into pi, defaults for native subagents, and keeping pi up to date.") {
            SettingsGroup(title: "Bundled extensions",
                          footnote: "Applies to agents launched on this Mac, including automations and remote agents. Running agents keep their extensions until restarted. Status and session tracking are always on.") {
                SettingsRow(title: "Name agents automatically",
                            subtitle: "Titles each new agent from its first prompt using the cheapest authed model. A rename you type is always final.") {
                    SettingsSwitch(label: "Name agents automatically", isOn: $settings.autoNameAgents)
                }
                SettingsRow(title: "Sync pi theme",
                            subtitle: "Use Shepherd's palette when you run pi by hand in a shell, and follow theme changes.") {
                    SettingsSwitch(label: "Sync pi theme", isOn: $settings.piThemeExtension)
                }
                SettingsRow(title: "Panes and agent tools",
                            subtitle: "Let agents control panes, message or spawn agents, manage automations and send notifications.") {
                    SettingsSwitch(label: "Panes and agent tools", isOn: $settings.piPanesExtension)
                }
                SettingsRow(title: "Diff review tool", subtitle: "Let agents open the review pane with review_diff.") {
                    SettingsSwitch(label: "Diff review tool", isOn: $settings.piReviewExtension)
                }
                SettingsRow(title: "Native subagents",
                            subtitle: "Shepherd helpers, agent files, scripted workflows and durable missions. Needs pi 0.85.1+. Children stop with their parent.") {
                    SettingsSwitch(label: "Native subagents", isOn: $settings.piNativeSubagents)
                }
                SettingsRow(title: "Subagent display",
                            subtitle: "Show subagent runs in the sidebar and open their inspector. Off doesn't stop them running.") {
                    SettingsSwitch(label: "Subagent display", isOn: $settings.piSubagentsExtension)
                }
            }

            if settings.piNativeSubagents {
                SettingsGroup(title: "Native subagent defaults",
                              footnote: "Precedence: explicit call → agent file → these defaults → parent. Child tools run with your account's access.") {
                    SettingsRow(title: "Concurrency", subtitle: "Child process limit per parent, including workflows.") {
                        ShepherdStepper(value: $settings.childConcurrency, in: 1...16)
                    }
                    SettingsRow(title: "Model", subtitle: "Agent files and explicit calls override this.") {
                        PopupMenu(settings.childModel.isEmpty ? "Inherit parent" : settings.childModel,
                                  mono: !settings.childModel.isEmpty, minWidth: 140) {
                            Button("Inherit parent") { settings.childModel = "" }
                            Divider()
                            ForEach(Array(Set(modelOptions + (settings.childModel.isEmpty ? [] : [settings.childModel]))).sorted(), id: \.self) { id in
                                Button(id) { settings.childModel = id }
                            }
                        }
                    }
                    SettingsRow(title: "Thinking") {
                        PopupMenu(settings.childThinking.isEmpty ? "Inherit parent" : settings.childThinking.capitalized, minWidth: 140) {
                            Button("Inherit parent") { settings.childThinking = "" }
                            Divider()
                            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                Button(level.capitalized) { settings.childThinking = level }
                            }
                        }
                    }
                    SettingsRow(title: "Context", subtitle: "Start each child fresh, or fork the parent's conversation.") {
                        SegmentedControl(selection: $settings.childContext, options: [("fresh", "Fresh"), ("fork", "Fork")])
                    }
                    SettingsRow(title: "Agent discovery", subtitle: "Project profiles require pi project trust. Files stay the source of truth.") {
                        PopupMenu(Self.scopes.first { $0.0 == settings.childScope }?.1 ?? settings.childScope, minWidth: 140) {
                            ForEach(Self.scopes, id: \.0) { scope in
                                Button(scope.1) { settings.childScope = scope.0 }
                            }
                        }
                    }
                }
                .task { modelOptions = PiConfig.modelIDs() }
            }

            SettingsGroup(title: "Updates", footnote: "Updating never restarts running agents.") {
                SettingsRow(title: "Update pi daily", subtitle: "Runs pi update once a day.") {
                    updateSwitch("Update pi daily", $settings.autoUpdatePi)
                }
                SettingsRow(title: "Update extensions daily", subtitle: "Runs pi update --extensions once a day.") {
                    updateSwitch("Update extensions daily", $settings.autoUpdateExtensions)
                }
                HStack(alignment: .center, spacing: 16) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("pi \(updates.currentVersion ?? "—")").font(Fonts.rowTitle).foregroundStyle(Tokens.text)
                        status
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    HStack(spacing: 8) {
                        Button(updates.isChecking ? "Checking…" : "Check now") { updates.checkNow() }
                            .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                            .disabled(updates.isBusy)
                        Button(piUpdateTitle) { updates.updatePiNow() }
                            .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                            .disabled(!updates.canUpdatePi)
                        Button(extensionsUpdateTitle) { updates.updateExtensionsNow() }
                            .buttonStyle(ShepherdButtonStyle(.secondary, size: .small))
                            .disabled(!updates.canUpdateExtensions)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .frame(minHeight: Metrics.settingsRowMinHeight)
            }
        }
    }

    private static let scopes: [(String, String)] = [("both", "User + project"), ("user", "User"), ("project", "Project"), ("bundled", "Bundled only")]

    private func updateSwitch(_ label: String, _ binding: Binding<Bool>) -> some View {
        SettingsSwitch(label: label, isOn: Binding(
            get: { binding.wrappedValue },
            set: {
                binding.wrappedValue = $0
                if $0 { updates.applyAutoUpdateSetting() }
            }
        ))
    }

    /// "● Up to date · extensions updated · uses the pi resolved from your login shell"
    private var status: some View {
        let (text, color): (String, Color) = {
            if updates.isChecking { return ("Checking…", Tokens.textMuted) }
            switch updates.activeUpdate {
            case .pi: return ("Updating pi…", Tokens.accentText)
            case .extensions: return ("Updating extensions…", Tokens.accentText)
            case .both: return ("Updating pi and extensions…", Tokens.accentText)
            case nil: break
            }
            if updates.isOutdated { return ("Update available · \(updates.latestVersion ?? "newer version")", Tokens.warningText) }
            if let error = updates.lastError { return (error, Tokens.dangerText) }
            if updates.lastChecked == nil { return ("Not checked yet", Tokens.textMuted) }
            return ("Up to date" + (updates.extensionsUpdatedAt == nil ? "" : " · extensions updated"), Tokens.successText)
        }()
        return HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text("\(Text(text).foregroundStyle(color))\(Text(" · uses the pi resolved from your login shell").foregroundStyle(Tokens.textTertiary))")
                .fixedSize(horizontal: false, vertical: true)
        }
        .font(Fonts.description)
    }

    private var piUpdateTitle: String {
        switch updates.activeUpdate {
        case .pi, .both: "Updating…"
        default: "Update pi"
        }
    }

    private var extensionsUpdateTitle: String {
        switch updates.activeUpdate {
        case .extensions, .both: "Updating…"
        default: updates.extensionsUpdatedAt == nil ? "Update extensions" : "Extensions updated"
        }
    }
}
