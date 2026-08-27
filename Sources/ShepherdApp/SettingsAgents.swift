import SwiftUI
import ShepherdCore
import ShepherdSessions

// MARK: Agents

struct AgentSettings: View {
    @ObservedObject private var settings = AppSettings.shared
    @State private var modelOptions: [String] = []

    private var piDefaultModel: String { PiConfig.defaultModel() ?? "pi's own default" }

    var body: some View {
        SettingsGroup(title: "New Agents") {
            SettingsRow(
                title: "Default Model",
                subtitle: "Applied by ⌘N and preselected in the New Agent sheet. \"Use pi's default\" passes no --model at all.",
                isFirst: true
            ) {
                Picker("", selection: $settings.defaultModel) {
                    Text("Use pi's default (\(piDefaultModel))").tag("")
                    ForEach(modelOptions, id: \.self) { id in
                        Text(id).tag(id)
                    }
                }
                .labelsHidden()
            }
            SettingsRow(title: "Default Thinking Level") {
                Picker("", selection: $settings.defaultThinking) {
                    ForEach(ThinkingLevel.allCases, id: \.self) { level in
                        Text(level.rawValue.capitalized).tag(level)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 240)
            }
        }

        SettingsGroup(title: "Naming") {
            SettingsRow(
                title: "Name Agents Automatically",
                subtitle: "Pi titles each new agent from its opening prompt on the first turn, using the cheapest model it is authed for. Off keeps the truncated prompt as the name.",
                isFirst: true
            ) {
                Toggle("", isOn: $settings.autoNameAgents)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        SettingsNote(text: "a hand-typed rename is always final · naming never blocks pi's first turn")
            .task { modelOptions = PiConfig.modelIDs() }
    }
}

