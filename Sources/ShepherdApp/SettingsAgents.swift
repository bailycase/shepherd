import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

// MARK: Agents

struct AgentSettings: View {
    @Bindable private var settings = AppSettings.shared
    private var keys: KeybindingsStore { .shared }
    @State private var modelOptions: [String] = []
    /// pi's own default from its settings.json, read with the catalog (never in `body`).
    @State private var piDefaultModel = "its own default"

    var body: some View {
        SettingsPage(title: "Agents", explanation: Self.explanation(keys)) {
            SettingsGroup(title: "New agents") {
                SettingsRow(title: "Default model",
                            subtitle: "Preselected in the New Agent sheet. “Use the agent’s default” passes no --model at all.") {
                    NWPopupMenu(settings.defaultModel.isEmpty ? "Use the agent’s default · \(piDefaultModel)" : settings.defaultModel,
                                mono: !settings.defaultModel.isEmpty, minWidth: AppLayout.settingsPopupWidth) {
                        Button("Use the agent’s default · \(piDefaultModel)") { settings.defaultModel = "" }
                        Divider()
                        ForEach(modelOptions, id: \.self) { id in
                            Button(id) { settings.defaultModel = id }
                        }
                    }
                    .accessibilityLabel("Default model")
                }
                SettingsRow(title: "Default thinking level", subtitle: "Can be changed per agent from the composer.") {
                    NWSegmentedPicker("Default thinking level", selection: $settings.defaultThinking,
                                      options: ThinkingLevel.allCases.map { ($0, $0.title) })
                }
            }
            SettingsGroup(title: "While the agent is working") {
                SettingsRow(title: "Return while the agent is working", subtitle: "\(keys.display(.alternateSend)) always does the other one.") {
                    NWSegmentedPicker("Return while the agent is working", selection: $settings.returnWhileWorking,
                                      options: [(.queue, "Queue"), (.steer, "Steer")])
                }
                SettingsRow(title: "When a turn ends, send the queue", subtitle: "All at once arrives as one turn, in order.") {
                    NWSegmentedPicker("When a turn ends, send the queue", selection: $settings.queueDelivery,
                                      options: [(NativeQueueMode.oneAtATime, "One per turn"), (.all, "All at once")])
                }
            }
        }
        .task {
            let (ids, fallback) = await Task.detached(priority: .userInitiated) {
                (PiModelCatalog.entriesOrConfigured().map(\.id), PiConfig.defaultModel())
            }.value
            modelOptions = ids
            if let fallback { piDefaultModel = fallback }
        }
    }

    /// Names New Agent's chord as it is bound now, so a rebind never leaves the copy wrong.
    static func explanation(_ keys: KeybindingsStore) -> String {
        "Defaults for agents you create with \(keys.display(.newAgent)) or the New Agent sheet. Existing agents keep their settings."
    }
}
