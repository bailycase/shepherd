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
                PiModelsRow(catalog: pi.catalog)
            }
            if let yourPi { FromYourPiSettings(model: yourPi, openExtensions: openExtensions) }
        }
    }
}

/// Settings ▸ Pi ▸ Models (SettingsPiModels): checks pi.dev for a newer model catalog now instead of
/// at the host's daily check. pi writes the home's `models-store.json`, which the host's catalog
/// watches, so the model picker lists the new models on its next ask.
struct PiModelsRow: View {
    let catalog: PiModelCatalog
    @State private var state: RefreshState
    @State private var checked: Date?

    enum RefreshState { case idle, refreshing, current, failed }

    /// `state` other than idle only for previews of the row mid-refresh or after one.
    init(catalog: PiModelCatalog, state: RefreshState = .idle) {
        self.catalog = catalog
        _state = State(initialValue: state)
    }

    var body: some View {
        SettingsRow(title: "Models",
                    subtitle: "pi's bundled list, plus models pi.dev added since this release. Shepherd checks pi.dev once a day.") {
            HStack(spacing: SH.Space.l) {
                status
                Button(action: refresh) {
                    Label(state == .failed ? "Try again" : state == .refreshing ? "Refreshing…" : "Refresh models",
                          systemImage: "arrow.clockwise")
                }
                .buttonStyle(.sh(.secondary, size: .s))
                .disabled(state == .refreshing)
            }
        }
        .task { await readChecked() }
    }

    @ViewBuilder private var status: some View {
        VStack(alignment: .trailing, spacing: SH.Space.xxs) {
            switch state {
            case .idle:
                if let checked {
                    Text("Checked \(Self.checkedFormatter.string(from: checked))").foregroundStyle(Color.sh.textTertiary)
                }
            case .refreshing:
                HStack(spacing: SH.Space.s) {
                    ProgressView().progressViewStyle(.shSpinner).accessibilityHidden(true)
                    Text("Checking pi.dev…").foregroundStyle(Color.sh.textSecondary)
                }
            case .current:
                Text("Up to date").foregroundStyle(Color.sh.done)
                Text("Checked just now.").foregroundStyle(Color.sh.textSecondary)
            case .failed:
                Text("Couldn't reach pi.dev").foregroundStyle(Color.sh.failed)
                Text("The models you already have still work.").foregroundStyle(Color.sh.textSecondary)
            }
        }
        .font(.sh(.caption))
        .multilineTextAlignment(.trailing)
        .accessibilityElement(children: .combine)
    }

    private func refresh() {
        state = .refreshing
        let catalog = catalog
        Task {
            let ok = await Task.detached(priority: .userInitiated) { catalog.refresh() }.value
            state = ok ? .current : .failed
            await readChecked()
        }
    }

    private func readChecked() async {
        let catalog = catalog
        checked = await Task.detached(priority: .utility) { catalog.lastChecked }.value
    }

    /// "today at 9:41 AM", "yesterday at 6:02 PM", "Oct 3, 2026 at 8:15 AM".
    private static let checkedFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        formatter.formattingContext = .middleOfSentence
        return formatter
    }()
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
                        SHStepper("Concurrency", value: $settings.childConcurrency, in: 1...16)
                    }
                    SettingsRow(title: "Model", subtitle: "Agent files and explicit calls override this.") {
                        SHPopupMenu(settings.childModel.isEmpty ? "Inherit parent" : settings.childModel,
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
                        SHPopupMenu(settings.childThinking.isEmpty ? "Inherit parent" : settings.childThinking.capitalized,
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
                        SHSegmentedPicker("Context", selection: $settings.childContext, options: [("fresh", "Fresh"), ("fork", "Fork")])
                    }
                }
                .task {
                    // Shepherd's pi's catalog: its home's models.json names only custom providers.
                    let catalog = pi.catalog
                    modelOptions = await Task.detached(priority: .userInitiated) {
                        Array(Set(catalog.entriesOrConfigured().map(\.id))).sorted()
                    }.value
                }
                .shTransition(.disclosure)
            }
        }
        .shControlScale(.settings)
        .shAnimation(.disclosure, value: settings.piNativeSubagents)
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
    }
}
