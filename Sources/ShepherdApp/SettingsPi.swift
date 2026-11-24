import SwiftUI
import ShepherdCore
import ShepherdUI
import ShepherdSessions

/// Settings ▸ Models: sign-in, the model defaults, Shepherd's own pi, and a way into the pi in
/// your terminal. The bundled extensions are on Settings ▸ Tools, native subagents on Settings ▸ Agents.
struct ModelsSettings: View {
    /// Shepherd's pi on this Mac: its version and home.
    let pi: PiSetup
    let yourPi: YourPiModel
    let auth: PiAuthStore
    var settings: AppSettings? = nil
    /// Opens Settings ▸ Your pi.
    var openYourPi: () -> Void = {}
    /// Opens Settings ▸ Tools' extensions (Sign-in's Add a provider).
    var openExtensions: (() -> Void)? = nil
    /// Opens Settings ▸ Tools at one extension (a provider's Show the extension).
    var openExtension: ((String) -> Void)? = nil

    private var yourPiHint: String {
        if yourPi.survey?.stateProblem != nil { return "Import history unavailable" }
        guard let survey = yourPi.survey, survey.folder != nil else { return "No pi of yours found" }
        return survey.copiedAt.map { "Imported \(FromYourPiSettings.day($0))" } ?? "Not imported yet"
    }

    var body: some View {
        SettingsPage(title: "Models") {
            PiSignInSettings(yourPi: yourPi, auth: auth, openExtensions: openExtensions, openExtension: openExtension)
            AgentModelGroups(pi: pi, settings: settings)
            SettingsGroup(title: "Shepherd’s pi") {
                PathRow(title: pi.engine.version.map { "pi \($0)" } ?? "pi",
                        subtitle: "Included with Shepherd, updated with it", url: pi.home)
                PiModelsRow(catalog: pi.catalog)
                SettingsDrillRow(title: "Your pi", subtitle: yourPiHint,
                                 value: yourPi.survey?.folder.map { ($0 as NSString).abbreviatingWithTildeInPath }, action: openYourPi)
            }
        }
    }
}

/// Settings ▸ Models ▸ Shepherd's pi ▸ Models (SettingsPiModels): checks pi.dev for a newer model catalog now instead of
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

    private var hint: String? {
        switch state {
        case .idle: checked.map { "Checked \(Self.checkedFormatter.string(from: $0))" }
        case .refreshing: "Checking pi.dev…"
        case .current: "Up to date · checked just now"
        case .failed: "Couldn't reach pi.dev. The models you already have still work."
        }
    }

    var body: some View {
        SettingsRow(title: "Models", subtitle: hint) {
            Button(action: refresh) {
                Text(state == .failed ? "Try again" : state == .refreshing ? "Refreshing…" : "Refresh models")
            }
            .buttonStyle(.sh(.secondary, size: .s))
            .disabled(state == .refreshing)
        }
        .task { await readChecked() }
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

/// Settings ▸ Agents ▸ Subagents: whether agents run native subagents, whether the app shows them,
/// the defaults a child run starts with, and the Profiles drill-in as the card's last row.
struct NativeSubagentSettings: View {
    /// Shepherd's pi on this Mac, whose catalog names the subagent model choices.
    let pi: PiSetup
    @Bindable var settings: AppSettings
    var profiles: [String] = []
    var editProfiles: () -> Void = {}
    @State private var modelOptions: [String] = []

    var body: some View {
        SettingsGroup(title: "Subagents", footnote: "Explicit call, then agent file, then these, then the parent.") {
            SettingsRow(title: "Native subagents", subtitle: "Helpers, agent files and workflows") {
                SettingsSwitch(label: "Native subagents", isOn: $settings.piNativeSubagents)
            }
            SettingsRow(title: "Show subagent runs") {
                SettingsSwitch(label: "Subagent display", isOn: $settings.subagentDisplay)
            }
            if settings.piNativeSubagents {
                SettingsRow(title: "Run at most", subtitle: "Per parent, workflows included") {
                    SHStepper("Concurrency", value: $settings.childConcurrency, in: 1...16)
                }
                SettingsRow(title: "Model") {
                    SHPopupMenu(settings.childModel.isEmpty ? "Inherit parent" : settings.childModel,
                                mono: !settings.childModel.isEmpty, minWidth: 0) {
                        Button("Inherit parent") { settings.childModel = "" }
                        Divider()
                        ForEach(childModelOptions, id: \.self) { id in
                            Button(id) { settings.childModel = id }
                        }
                    }
                    .accessibilityLabel("Subagent model")
                }
                SettingsRow(title: "Thinking") {
                    SHPopupMenu(settings.childThinking.isEmpty ? "Inherit parent" : settings.childThinking.capitalized, minWidth: 0) {
                        Button("Inherit parent") { settings.childThinking = "" }
                        Divider()
                        ForEach(["off", "minimal", "low", "medium", "high", "xhigh", "max"], id: \.self) { level in
                            Button(level.capitalized) { settings.childThinking = level }
                        }
                    }
                    .accessibilityLabel("Subagent thinking")
                }
                SettingsRow(title: "Context") {
                    SHSegmentedPicker("Context", selection: $settings.childContext, options: [("fresh", "Fresh"), ("fork", "Fork")])
                }
            }
            SettingsDrillRow(title: "Profiles", subtitle: profiles.isEmpty ? nil : profiles.joined(separator: ", "),
                             value: profiles.isEmpty ? nil : "\(profiles.count)", action: editProfiles)
        }
        .task {
            // Shepherd's pi's catalog: its home's models.json names only custom providers.
            let catalog = pi.catalog
            modelOptions = await Task.detached(priority: .userInitiated) {
                Array(Set(catalog.entriesOrConfigured().map(\.id))).sorted()
            }.value
        }
        .shAnimation(.disclosure, value: settings.piNativeSubagents)
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
    }
}
