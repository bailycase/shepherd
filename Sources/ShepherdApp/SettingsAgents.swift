import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

// MARK: Agents

struct AgentSettings: View {
    /// This Mac's pi: its catalog and settings.json give the model choices and pi's default.
    let pi: PiSetup
    @Bindable var settings: AppSettings
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
                SettingsRow(title: "When a turn ends, send the queue", subtitle: "All at once arrives as one turn, in the order you queued it.") {
                    NWSegmentedPicker("When a turn ends, send the queue", selection: $settings.queueDelivery,
                                      options: [(NativeQueueMode.oneAtATime, "One per turn"), (.all, "All at once")])
                }
            }
            SettingsGroup(title: "Context") {
                SettingsRow(title: "Compact at",
                            subtitle: "How full an agent lets its context get before it compacts on its own, as a share of the model’s window. "
                                + "pi’s default leaves 16k tokens free, about 94% of a 272k window. New agents follow a change; running ones at their next launch.") {
                    NWSegmentedPicker("Compact at", selection: Binding(get: { settings.compactAtPercent ?? 0 },
                                                                       set: { settings.compactAtPercent = $0 == 0 ? nil : $0 }),
                                      options: [(0, Self.compactAtTitle(nil))] + PiCompactionThreshold.choices.map { ($0, Self.compactAtTitle($0)) })
                }
                SettingsRow(title: "Trim old tool output from the model’s context",
                            subtitle: "Clips one huge tool result in what the model is sent and, as the context fills, replaces the oldest tool output, "
                                + "file contents, reasoning and screenshots with a line saying what they were. The thread keeps all of it. "
                                + "New agents follow a change; running ones at their next launch.") {
                    SettingsSwitch(label: "Trim old tool output from the model’s context", isOn: $settings.trimToolOutput)
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

    /// "pi’s default", or "80%": the popup's label for a Compact at choice.
    static func compactAtTitle(_ percent: Int?) -> String {
        percent.map { "\($0)%" } ?? "pi’s default"
    }

    /// Names New Agent's chord as it is bound now, so a rebind never leaves the copy wrong.
    static func explanation(_ keys: KeybindingsStore) -> String {
        "Defaults for agents you create with \(keys.display(.newAgent)) or the New Agent sheet. Existing agents keep their settings."
    }
}
