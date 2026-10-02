import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdSessions

struct PiSettings: View {
    /// Shepherd's pi on this Mac, whose catalog names the subagent model choices.
    let pi: PiSetup
    /// The view model's settings, so a preview's own settings draw the page.
    @Bindable var settings: AppSettings
    @State private var modelOptions: [String] = []

    var body: some View {
        SettingsPage(title: "Pi",
                     explanation: "Shepherd's own pi, the extensions Shepherd bundles into it, and defaults for native subagents.") {
            SettingsGroup(title: "Shepherd's pi",
                          footnote: "Shepherd runs its own copy of pi, with its own sign-ins, settings and conversations. The pi in your terminal is yours: Shepherd never runs it or changes its files.") {
                PathRow(title: pi.engine.version.map { "pi \($0)" } ?? "pi",
                        subtitle: "Included with Shepherd, and updated with it. Its home:", url: pi.home)
            }
            SettingsGroup(title: "Bundled extensions",
                          footnote: "Applies to agents launched on this Mac, including automations and remote agents. Running agents keep their extensions until restarted. Status and session tracking are always on.") {
                SettingsRow(title: "Name agents automatically",
                            subtitle: "Titles each new agent from its first prompt using the cheapest authed model. A rename you type is always final.") {
                    SettingsSwitch(label: "Name agents automatically", isOn: $settings.autoNameAgents)
                }
                SettingsRow(title: "Terminals and agent tools",
                            subtitle: "Let agents open and drive terminals, message or spawn agents, manage automations and send notifications.") {
                    SettingsSwitch(label: "Terminals and agent tools", isOn: $settings.piPanesExtension)
                }
                SettingsRow(title: "Agent-to-agent messages",
                            subtitle: "Whether an agent may message, steer, read or start another thread. Ask me opens a dialog each time. Automations can't answer one, so they need Always allow.") {
                    NWPopupMenu(settings.agentMessages.title, minWidth: AppLayout.settingsPopupWidth) {
                        ForEach(AgentMessagePolicy.allCases, id: \.self) { choice in
                            Button(choice.title) { settings.agentMessages = choice }
                        }
                    }
                    .accessibilityLabel("Agent-to-agent messages")
                    .disabled(!settings.piPanesExtension)
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
                SettingsRow(title: "MCP servers",
                            subtitle: "Let agents use the servers in Settings ▸ MCP servers, through pi's own MCP and tool search.") {
                    SettingsSwitch(label: "MCP servers", isOn: $settings.piMCPExtension)
                }
                SettingsRow(title: "Browser tools",
                            subtitle: "Let agents open pages in their thread's Browser, read and click through them, and take screenshots.") {
                    SettingsSwitch(label: "Browser tools", isOn: $settings.piBrowserExtension)
                }
                if settings.designToolEnabled {
                    SettingsRow(title: "Design references",
                                subtitle: "Let a thread read the design pieces you hand it with `design_get`. Only a thread you sent one to gets the tool.") {
                        SettingsSwitch(label: "Design references", isOn: $settings.piDesignReferences)
                    }
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
                .task {
                    // Shepherd's pi's catalog: its home's models.json names only custom providers.
                    let catalog = pi.catalog
                    modelOptions = await Task.detached(priority: .userInitiated) {
                        Array(Set(catalog.entriesOrConfigured().map(\.id))).sorted()
                    }.value
                }
                .nwTransition(.disclosure)
            }
        }
        .nwAnimation(.disclosure, value: settings.piNativeSubagents)
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
    }

    private static let scopes: [(String, String)] = [("both", "User + project"), ("user", "User"), ("project", "Project"), ("bundled", "Bundled only")]
}
