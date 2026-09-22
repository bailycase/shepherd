import SwiftUI
import ShepherdDesign
import ShepherdCore
import ShepherdSessions

// MARK: Agents

struct AgentSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelOptions: [String] = []

    private var piDefaultModel: String { PiConfig.defaultModel() ?? "pi's own default" }

    var body: some View {
        SettingsPage(title: "Agents",
                     explanation: "Defaults for agents you create with ⌘N or the New Agent sheet. Existing agents keep their settings.") {
            SettingsGroup(title: "New agents") {
                SettingsRow(title: "Default model",
                            subtitle: "Preselected in the New Agent sheet. “Use pi's default” passes no --model at all.") {
                    PopupMenu(settings.defaultModel.isEmpty ? "Use pi's default · \(piDefaultModel)" : settings.defaultModel,
                              mono: !settings.defaultModel.isEmpty, minWidth: 220) {
                        Button("Use pi's default · \(piDefaultModel)") { settings.defaultModel = "" }
                        Divider()
                        ForEach(modelOptions, id: \.self) { id in
                            Button(id) { settings.defaultModel = id }
                        }
                    }
                }
                SettingsRow(title: "Default thinking level", subtitle: "Can be changed per agent from the composer.") {
                    SegmentedControl(selection: $settings.defaultThinking,
                                     options: ThinkingLevel.allCases.map { ($0, $0.rawValue.capitalized) })
                }
            }
        }
        .task { modelOptions = PiConfig.modelIDs() }
    }
}
