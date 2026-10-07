import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Pi (SettingsPi, SettingsPiFromPi, SettingsPiExtensions): Shepherd's own pi, then
/// From pi, what came over from the user's pi. The bundled extensions are on Settings ▸ Extensions,
/// native subagents on Settings ▸ Subagents.
struct PiSettings: View {
    /// Shepherd's pi on this Mac: its version and home.
    let pi: PiSetup
    /// The user's own pi, for From pi; nil leaves the section out (a test of the switches alone).
    var yourPi: YourPiModel? = nil
    var openExtensions: () -> Void = {}

    var body: some View {
        SettingsPage(title: "Pi", explanation: "Shepherd's own copy of pi.") {
            SettingsGroup(title: "Shepherd's pi",
                          footnote: "Shepherd runs its own copy of pi, with its own sign-ins, settings and conversations. The pi in your terminal is yours: Shepherd never runs it or changes its files.") {
                PathRow(title: pi.engine.version.map { "pi \($0)" } ?? "pi",
                        subtitle: "Included with Shepherd, and updated with it. Its home:", url: pi.home)
            }
            if let yourPi { FromYourPiSettings(model: yourPi, openExtensions: openExtensions) }
        }
    }
}

/// Settings ▸ Subagents, under the list: whether agents run native subagents, whether the app shows
/// them, and the defaults a child run starts with. No board draws these; they moved here from Pi
/// (the user's decision, 2026-10-07).
struct NativeSubagentSettings: View {
    /// Shepherd's pi on this Mac, whose catalog names the subagent model choices.
    let pi: PiSetup
    @Bindable var settings: AppSettings
    @State private var modelOptions: [String] = []

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
            SettingsGroup(title: "Native subagents") {
                SettingsRow(title: "Native subagents",
                            subtitle: "Shepherd helpers, agent files and scripted workflows. Needs pi 0.85.1+. Children stop with their parent.") {
                    SettingsSwitch(label: "Native subagents", isOn: $settings.piNativeSubagents)
                }
                SettingsRow(title: "Subagent display",
                            subtitle: "Show subagent runs in their agent's thread, the inspector and the palette. Off doesn't stop them running.") {
                    SettingsSwitch(label: "Subagent display", isOn: $settings.subagentDisplay)
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
        .nwControlScale(.settings)
        .nwAnimation(.disclosure, value: settings.piNativeSubagents)
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
    }
}
