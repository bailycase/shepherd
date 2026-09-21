import SwiftUI
import ShepherdCore
import ShepherdSessions

// MARK: Agents

struct AgentSettings: View {
    var presentation: NativePresentation
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
            SettingsRow(
                title: "Runtime",
                subtitle: "Terminal runs pi in a PTY you can always drop into. Native (RPC) runs pi headless with Shepherd as its only UI: model, thinking, slash commands and images work in the thread, but there is no terminal to show. Fixed when the agent is created."
            ) {
                Picker("", selection: $settings.defaultRuntime) {
                    Text("Terminal").tag(AgentRuntime.terminal)
                    Text("Native (RPC)").tag(AgentRuntime.rpc)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 200)
            }
        }
        SettingsGroup(title: "Conversation") {
            SettingsRow(
                title: "Default View",
                subtitle: "How a terminal agent's pane opens. The header's Terminal/Native switch still overrides it per agent. Native (RPC) agents are always native.",
                isFirst: true
            ) {
                Picker("", selection: Binding(
                    get: { presentation.defaultNative },
                    set: { presentation.defaultNative = $0 }
                )) {
                    Text("Terminal").tag(false)
                    Text("Native").tag(true)
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 160)
            }
        }
        .task { modelOptions = PiConfig.modelIDs() }
    }
}
