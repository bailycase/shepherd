import SwiftUI
import ShepherdUI
import ShepherdSessions

struct PiSettings: View {
    @Bindable private var settings = AppSettings.shared
    private var updates: PiUpdateManager { .shared }
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
                SettingsRow(title: "Diff review tool", subtitle: "Let agents open the review pane with `review_diff`.") {
                    SettingsSwitch(label: "Diff review tool", isOn: $settings.piReviewExtension)
                }
                SettingsRow(title: "Native subagents",
                            subtitle: "Shepherd helpers, agent files, scripted workflows and durable missions. Needs pi 0.85.1+. Children stop with their parent.") {
                    SettingsSwitch(label: "Native subagents", isOn: $settings.piNativeSubagents)
                }
                SettingsRow(title: "Subagent display",
                            subtitle: "Show subagent runs in their agent's thread, the inspector and the palette. Off doesn't stop them running.") {
                    SettingsSwitch(label: "Subagent display", isOn: $settings.piSubagentsExtension)
                }
            }

            if settings.piNativeSubagents {
                SettingsGroup(title: "Native subagent defaults",
                              footnote: "Precedence: explicit call → agent file → these defaults → parent. Child tools run with your account's access.") {
                    SettingsRow(title: "Concurrency", subtitle: "Child process limit per parent, including workflows.") {
                        NWStepper("Concurrency", value: $settings.childConcurrency, in: 1...16)
                    }
                    SettingsRow(title: "Model", subtitle: "Agent files and explicit calls override this.") {
                        NWPopupMenu(settings.childModel.isEmpty ? "Inherit parent" : settings.childModel,
                                    mono: !settings.childModel.isEmpty, minWidth: AppLayout.settingsPopupWidth) {
                            Button("Inherit parent") { settings.childModel = "" }
                            Divider()
                            ForEach(childModelOptions, id: \.self) { id in
                                Button(id) { settings.childModel = id }
                            }
                        }
                        .accessibilityLabel("Subagent model")
                    }
                    SettingsRow(title: "Thinking") {
                        NWPopupMenu(settings.childThinking.isEmpty ? "Inherit parent" : settings.childThinking.capitalized,
                                    minWidth: AppLayout.settingsPopupWidth) {
                            Button("Inherit parent") { settings.childThinking = "" }
                            Divider()
                            ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                                Button(level.capitalized) { settings.childThinking = level }
                            }
                        }
                        .accessibilityLabel("Subagent thinking")
                    }
                    SettingsRow(title: "Context", subtitle: "Start each child fresh, or fork the parent's conversation.") {
                        NWSegmentedPicker("Context", selection: $settings.childContext, options: [("fresh", "Fresh"), ("fork", "Fork")])
                    }
                    SettingsRow(title: "Agent discovery", subtitle: "Project profiles require pi project trust. Files stay the source of truth.") {
                        NWPopupMenu(Self.scopes.first { $0.0 == settings.childScope }?.1 ?? settings.childScope,
                                    minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(Self.scopes, id: \.0) { scope in
                                Button(scope.1) { settings.childScope = scope.0 }
                            }
                        }
                        .accessibilityLabel("Agent discovery")
                    }
                }
                .task { modelOptions = await Task.detached(priority: .userInitiated) { Array(Set(PiConfig.modelIDs())).sorted() }.value }
                .nwTransition(.disclosure)
            }

            SettingsGroup(title: "Updates", footnote: "Updating never restarts running agents.") {
                SettingsRow(title: "Update pi daily", subtitle: "Runs `pi update` once a day.") {
                    updateSwitch("Update pi daily", $settings.autoUpdatePi)
                }
                SettingsRow(title: "Update extensions daily", subtitle: "Runs `pi update --extensions` once a day.") {
                    updateSwitch("Update extensions daily", $settings.autoUpdateExtensions)
                }
                SettingsActionRow {
                    VStack(alignment: .leading, spacing: NW.Space.xxs) {
                        Text("pi \(updates.currentVersion ?? "—")")
                            .font(.nw(.body, weight: .medium))
                            .foregroundStyle(Color.nw.textPrimary)
                        status
                    }
                } actions: {
                    Button(updates.isChecking ? "Checking…" : "Check now") { updates.checkNow() }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .disabled(updates.isBusy)
                    Button(updates.isUpdating ? "Updating…" : "Update now") { updates.updateNow() }
                        .buttonStyle(.nw(.secondary, size: .s))
                        .disabled(!updates.canUpdate)
                }
            }
        }
        .nwAnimation(.disclosure, value: settings.piNativeSubagents)
        // Checking → up to date, updating → updated: the words, the dot and the buttons' titles
        // fade in place.
        .nwAnimation(.content, value: statusLine.text)
        .nwAnimation(.content, value: updates.isUpdating)
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
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

    /// What the updates row reports, and the dot beside it.
    private var statusLine: (text: String, state: AgentState) {
        if updates.isChecking { return ("Checking…", .running) }
        switch updates.activeUpdate {
        case .pi: return ("Updating pi…", .running)
        case .extensions: return ("Updating extensions…", .running)
        case .both: return ("Updating pi and extensions…", .running)
        case nil: break
        }
        if updates.isOutdated { return ("Update available · \(updates.latestVersion ?? "newer version")", .attention) }
        if let error = updates.lastError { return (error, .failed) }
        if updates.lastChecked == nil { return ("Not checked yet", .idle) }
        return ("Up to date" + (updates.extensionsUpdatedAt == nil ? "" : " · extensions updated"), .done)
    }

    /// "● Up to date · extensions updated · uses the pi resolved from your login shell", in the
    /// description's size.
    private var status: some View {
        let (text, state) = statusLine
        return HStack(spacing: NW.Space.s) {
            NWStatusDot(state)
            Text("\(Text(text).foregroundStyle(state.textColor))\(Text(" · uses the pi resolved from your login shell").foregroundStyle(Color.nw.textSecondary))")
                .fixedSize(horizontal: false, vertical: true)
                .nwContentTransition(.crossFade)
        }
        .nwText(size: NWTextStyle.ui.size, lineHeight: NWCardRowMetrics.settingsDescriptionLineHeight)
        .accessibilityElement(children: .combine)
    }
}
