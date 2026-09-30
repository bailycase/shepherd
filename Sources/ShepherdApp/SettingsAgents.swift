import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

// MARK: Agents

struct AgentSettings: View {
    /// This Mac's pi: its catalog and settings.json give the model choices and pi's default.
    let pi: PiSetup
    @Bindable private var settings = AppSettings.shared
    private var keys: KeybindingsStore { .shared }
    @State private var modelOptions: [String] = []
    /// pi's own default from its settings.json, read with the catalog (never in `body`).
    @State private var piDefaultModel: String?

    /// "Use the agent’s default · gpt-6-astra", or without the model while it is unknown.
    private var agentDefault: String { "Use the agent’s default" + (piDefaultModel.map { " · \($0)" } ?? "") }

    var body: some View {
        SettingsPage(title: "Agents", explanation: Self.explanation(keys)) {
            SettingsGroup(title: "New agents") {
                SettingsRow(title: "Default model",
                            subtitle: "Preselected in the New Agent sheet. “Use the agent’s default” passes no `--model` at all.") {
                    NWPopupMenu(settings.defaultModel.isEmpty ? agentDefault : settings.defaultModel,
                                mono: !settings.defaultModel.isEmpty, minWidth: AppLayout.settingsPopupWidth) {
                        Button(agentDefault) { settings.defaultModel = "" }
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
                SettingsRow(title: "Speed for new threads",
                            subtitle: "New threads start on this speed. Each thread keeps its own after that.") {
                    NWSegmentedPicker("Speed for new threads", selection: $settings.defaultServiceTier,
                                      options: ServiceTier.allCases.map { ($0, $0.title) })
                }
            }
            SettingsGroup(title: "While the agent is working") {
                ReturnWhileWorkingRow(selection: $settings.returnWhileWorking, keys: keys)
                SettingsRow(title: "When a turn ends, send the queue", subtitle: "All at once arrives as one turn, in the order you queued it.") {
                    NWSegmentedPicker("When a turn ends, send the queue", selection: $settings.queueDelivery,
                                      options: [(NativeQueueMode.oneAtATime, "One per turn"), (.all, "All at once")])
                }
            }
        }
        .task {
            let pi = pi
            let (ids, fallback) = await Task.detached(priority: .userInitiated) {
                (pi.catalog.entriesOrConfigured().map(\.id), PiConfig.defaultModel(in: pi.home))
            }.value
            modelOptions = ids
            if let fallback { piDefaultModel = fallback }
        }
    }

    /// What each choice does, and what the alternate chord always does (as it is bound now).
    /// Steering says what pi does: it waits for the tool calls in flight, then reads the message
    /// before its next step; steering now stops it first.
    static func returnDescription(_ keys: KeybindingsStore) -> String {
        "Steering lands once the agent’s current tool calls finish. Waiting holds the message in Up next until the turn ends. "
            + "\(keys.display(.alternateSend)) always steers now: it stops the agent and sends at once."
    }

    /// Names New Agent's chord as it is bound now, so a rebind never leaves the copy wrong.
    static func explanation(_ keys: KeybindingsStore) -> String {
        "Defaults for agents you create with \(keys.display(.newAgent)) or the New Agent sheet. Existing agents keep their settings."
    }
}

/// Settings ▸ Agents ▸ Return while the agent is working: what ↩ does with a message while the
/// agent works. The first choice is the default; ⌘↩ always steers now.
struct ReturnWhileWorkingRow: View {
    @Binding var selection: ReturnWhileWorking
    let keys: KeybindingsStore

    var body: some View {
        SettingsRow(title: "Return while the agent is working", subtitle: AgentSettings.returnDescription(keys)) {
            NWSegmentedPicker("Return while the agent is working", selection: $selection,
                              options: [(.steer, ReturnWhileWorking.steer.title), (.queue, ReturnWhileWorking.queue.title)])
        }
    }
}
