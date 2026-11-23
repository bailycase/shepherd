import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdSessions
import ShepherdProtocol

// MARK: Agents

/// The model groups on Settings ▸ Models: new agents' defaults, text generation and image reading.
struct AgentModelGroups: View {
    /// This Mac's pi: its catalog and settings.json give the model choices and pi's default.
    let pi: PiSetup
    @Bindable private var settings: AppSettings
    @State private var modelOptions: [String] = []
    /// The models pi's catalog does not call text-only, for the image reading pick.
    @State private var imageModelOptions: [String] = []
    /// pi's own default from its settings.json, read with the catalog (never in `body`).
    @State private var piDefaultModel: String?

    /// Tests and previews may supply isolated settings.
    init(pi: PiSetup, settings: AppSettings? = nil) {
        self.pi = pi
        self.settings = settings ?? .shared
    }

    /// "Use the agent’s default · gpt-6-astra", or without the model while it is unknown.
    private var agentDefault: String { "Use the agent’s default" + (piDefaultModel.map { " · \($0)" } ?? "") }

    var body: some View {
        VStack(alignment: .leading, spacing: AppLayout.settingsGroupSpacing) {
            SettingsGroup(title: "Defaults for new threads") {
                SettingsRow(title: "Model", subtitle: settings.defaultModel.isEmpty ? agentDefault : nil) {
                    SHPopupMenu(settings.defaultModel.isEmpty ? "Use the agent’s default" : settings.defaultModel,
                                mono: !settings.defaultModel.isEmpty, minWidth: 0) {
                        Button(agentDefault) { settings.defaultModel = "" }
                        Divider()
                        ForEach(modelOptions, id: \.self) { id in
                            Button(id) { settings.defaultModel = id }
                        }
                    }
                    .accessibilityLabel("Default model")
                }
                SettingsRow(title: "Thinking") {
                    SHPopupMenu(settings.defaultThinking.title, minWidth: 0) {
                        ForEach(ThinkingLevel.allCases, id: \.self) { level in
                            Button(level.title) { settings.defaultThinking = level }
                        }
                    }
                    .accessibilityLabel("Default thinking level")
                }
                SettingsRow(title: "Speed") {
                    SHSegmentedPicker("Speed for new threads", selection: $settings.defaultServiceTier,
                                      options: ServiceTier.allCases.map { ($0, $0.title) })
                }
            }
            SettingsGroup(title: "Small jobs") {
                SettingsRow(title: "Titles and commit messages") {
                    SHPopupMenu(settings.textGenerationModel.isEmpty ? "Automatic" : settings.textGenerationModel,
                                mono: !settings.textGenerationModel.isEmpty, minWidth: 0) {
                        Button("Automatic") { settings.textGenerationModel = "" }
                        Divider()
                        ForEach(modelOptions, id: \.self) { id in
                            Button(id) { settings.textGenerationModel = id }
                        }
                    }
                    .accessibilityLabel("Text generation model")
                }
                SettingsRow(title: "Describe images for", subtitle: "Used when a thread’s model can’t see images") {
                    SHPopupMenu(settings.visionModel.isEmpty ? "Automatic" : settings.visionModel,
                                mono: !settings.visionModel.isEmpty, minWidth: 0) {
                        Button("Automatic") { settings.visionModel = "" }
                        Divider()
                        ForEach(imageModelOptions, id: \.self) { id in
                            Button(id) { settings.visionModel = id }
                        }
                    }
                    .accessibilityLabel("Image reading model")
                }
            }
        }
        .shControlScale(.settings)
        .task {
            let pi = pi
            let (entries, fallback) = await Task.detached(priority: .userInitiated) {
                (pi.catalog.entriesOrConfigured(), PiConfig.defaultModel(in: pi.home))
            }.value
            modelOptions = entries.map(\.id)
            imageModelOptions = entries.filter { $0.images != false }.map(\.id)
            if let fallback { piDefaultModel = fallback }
        }
    }
}

struct AgentSettings: View {
    /// This Mac's pi: its catalog names the subagent model choices.
    let pi: PiSetup
    @Bindable private var settings: AppSettings
    /// The profiles' names, for Profiles' hint; empty until the list is read.
    var profiles: [String] = []
    /// Opens Settings ▸ Subagents (the profiles).
    let editProfiles: () -> Void

    /// Tests and previews may supply isolated settings.
    init(pi: PiSetup, settings: AppSettings? = nil, profiles: [String] = [], editProfiles: @escaping () -> Void = {}) {
        self.pi = pi
        self.settings = settings ?? .shared
        self.profiles = profiles
        self.editProfiles = editProfiles
    }

    var body: some View {
        SettingsPage(title: "Agents") {
            SettingsGroup(title: "Queue") {
                SettingsRow(title: "Send queued messages") {
                    SHSegmentedPicker("When a turn ends, send the queue", selection: $settings.queueDelivery,
                                      options: [(NativeQueueMode.oneAtATime, "One per turn"), (.all, "All at once")])
                }
            }
            SettingsGroup(title: "Threads a thread starts") {
                SettingsRow(title: "Threads can start threads", subtitle: "Three deep at most") {
                    SettingsSwitch(label: "Threads can start threads", isOn: $settings.threadsStartThreads)
                }
                SettingsRow(title: "Where they work") {
                    SHSegmentedPicker("Where they work", selection: $settings.subThreadPlace,
                                      options: [(SpawnPlace.checkout, "Same checkout"), (.worktree, "New worktree")])
                }
            }
            SettingsGroup(title: "Context", footnote: "Changes reach running agents when they next start.") {
                SettingsRow(title: "Compact at") {
                    SHPopupMenu(Self.compactAtTitle(settings.compactAtPercent, defaultLabel: "Default"), minWidth: 0) {
                        Button(Self.compactAtTitle(nil, defaultLabel: "Default")) { settings.compactAtPercent = nil }
                        ForEach(PiCompactionThreshold.choices, id: \.self) { percent in
                            Button(Self.compactAtTitle(percent)) { settings.compactAtPercent = percent }
                        }
                    }
                    .accessibilityLabel("Compact at")
                }
                SettingsRow(title: "Trim old tool output") {
                    SettingsSwitch(label: "Trim old tool output from the model's context", isOn: $settings.trimToolOutput)
                }
                SettingsRow(title: "Load rarely used tools on demand") {
                    SettingsSwitch(label: "Defer rarely used tools", isOn: $settings.deferTools)
                }
                SettingsRow(title: "Codemode", subtitle: "Batch tool calls in one script") {
                    SettingsSwitch(label: "Codemode", isOn: $settings.codemode)
                }
            }
            NativeSubagentSettings(pi: pi, settings: settings, profiles: profiles, editProfiles: editProfiles)
        }
    }

    /// "Default", or "80%": the label for a Compact at choice.
    static func compactAtTitle(_ percent: Int?, defaultLabel: String = "Default") -> String {
        percent.map { "\($0)%" } ?? defaultLabel
    }
}
