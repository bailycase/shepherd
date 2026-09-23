import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions

// MARK: Agents

struct AgentSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelOptions: [String] = []
    /// pi's own default from its settings.json, read with the catalog (never in `body`).
    @State private var piDefaultModel = "pi's own default"

    var body: some View {
        SettingsPage(title: "Agents",
                     explanation: "Defaults for agents you create with ⌘N or the New Agent sheet. Existing agents keep their settings.") {
            SettingsGroup(title: "New agents") {
                SettingsRow(title: "Default model",
                            subtitle: "Preselected in the New Agent sheet. “Use pi's default” passes no --model at all.") {
                    NWPopupMenu(settings.defaultModel.isEmpty ? "Use pi's default · \(piDefaultModel)" : settings.defaultModel,
                                mono: !settings.defaultModel.isEmpty, minWidth: AppLayout.settingsPopupWidth) {
                        Button("Use pi's default · \(piDefaultModel)") { settings.defaultModel = "" }
                        Divider()
                        ForEach(modelOptions, id: \.self) { id in
                            Button(id) { settings.defaultModel = id }
                        }
                    }
                    .accessibilityLabel("Default model")
                }
                SettingsRow(title: "Default thinking level", subtitle: "Can be changed per agent from the composer.") {
                    NWSegmentedPicker("Default thinking level", selection: $settings.defaultThinking,
                                      options: ThinkingLevel.allCases.map { ($0, $0.rawValue.capitalized) })
                }
            }
        }
        .task {
            let (ids, fallback) = await Task.detached(priority: .userInitiated) {
                (PiConfig.modelIDs(), PiConfig.defaultModel())
            }.value
            modelOptions = ids
            if let fallback { piDefaultModel = fallback }
        }
    }
}
