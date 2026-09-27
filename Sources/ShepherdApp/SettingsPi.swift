import SwiftUI
import ShepherdUI
import ShepherdSessions

struct PiSettings: View {
    /// Shepherd's pi on this Mac, whose catalog names the subagent model choices.
    let pi: PiSetup
    /// Shepherd's sign-ins and the user's own pi (Sign-in, From your pi, Your extensions).
    let yourPi: YourPiModel
    /// Opens Shepherd's pi to sign in, beside the agent selected on this Mac; nil with none.
    var signIn: (() -> Void)? = nil
    @Bindable private var settings = AppSettings.shared
    @State private var modelOptions: [String] = []

    var body: some View {
        SettingsPage(title: "Pi",
                     explanation: "Shepherd's own pi, the extensions Shepherd bundles into it, and defaults for native subagents.") {
            SettingsGroup(title: "Shepherd's pi",
                          footnote: "Shepherd runs its own copy of pi, with its own sign-ins, settings and conversations. The pi in your terminal is yours: Shepherd never runs it or changes its files.") {
                PathRow(title: pi.engine.version.map { "pi \($0)" } ?? "pi",
                        subtitle: "Included with Shepherd, and updated with it. Its home:", url: pi.home)
            }
            PiSignInGroup(model: yourPi, signIn: signIn)
            YourPiGroups(model: yourPi)
            SettingsGroup(title: "Bundled extensions",
                          footnote: "Applies to agents launched on this Mac, including automations and remote agents. Running agents keep their extensions until restarted. Status and session tracking are always on.") {
                SettingsRow(title: "Name agents automatically",
                            subtitle: "Titles each new agent from its first prompt using the cheapest authed model. A rename you type is always final.") {
                    SettingsSwitch(label: "Name agents automatically", isOn: $settings.autoNameAgents)
                }
                SettingsRow(title: "Panes and agent tools",
                            subtitle: "Let agents control panes, message or spawn agents, manage automations and send notifications.") {
                    SettingsSwitch(label: "Panes and agent tools", isOn: $settings.piPanesExtension)
                }
                SettingsRow(title: "Diff review tool", subtitle: "Let agents open the review pane with `review_diff`.") {
                    SettingsSwitch(label: "Diff review tool", isOn: $settings.piReviewExtension)
                }
                SettingsRow(title: "Native subagents",
                            subtitle: "Shepherd helpers, agent files, scripted workflows and durable missions. Needs pi 0.85.1+. Children stop with their parent.") {
                    SettingsSwitch(label: "Native subagents", isOn: $settings.piNativeSubagents)
                }
                SettingsRow(title: "Subagent display",
                            subtitle: "Show subagent runs in their agent's thread, the inspector and the palette. Off doesn't stop them running.") {
                    SettingsSwitch(label: "Subagent display", isOn: $settings.piSubagentsExtension)
                }
                SettingsRow(title: "MCP servers",
                            subtitle: "Let agents use the servers in Settings ▸ MCP servers through one `mcp` tool.") {
                    SettingsSwitch(label: "MCP servers", isOn: $settings.piMCPExtension)
                }
            }

            if settings.piNativeSubagents {
                SettingsGroup(title: "Native subagent defaults",
                              footnote: "Precedence: explicit call → agent file → these defaults → parent. Child tools run with your account's access.") {
                    SettingsRow(title: "Concurrency", subtitle: "Child process limit per parent, including workflows.") {
                        NWStepper("Concurrency", value: $settings.childConcurrency, in: 1...16)
                    }
                    SettingsRow(title: "Model", subtitle: "Agent files and explicit calls override this.") {
                        NWPopupMenu(settings.childModel.isEmpty ? "Inherit parent" : settings.childModel,
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
                        NWPopupMenu(settings.childThinking.isEmpty ? "Inherit parent" : settings.childThinking.capitalized,
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
                        NWSegmentedPicker("Context", selection: $settings.childContext, options: [("fresh", "Fresh"), ("fork", "Fork")])
                    }
                    SettingsRow(title: "Agent discovery", subtitle: "Project profiles require pi project trust. Files stay the source of truth.") {
                        NWPopupMenu(Self.scopes.first { $0.0 == settings.childScope }?.1 ?? settings.childScope,
                                    minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(Self.scopes, id: \.0) { scope in
                                Button(scope.1) { settings.childScope = scope.0 }
                            }
                        }
                        .accessibilityLabel("Agent discovery")
                    }
                }
                .task {
                    // Shepherd's pi's catalog: its home's models.json names only custom providers.
                    let catalog = pi.catalog
                    modelOptions = await Task.detached(priority: .userInitiated) {
                        Array(Set(catalog.entriesOrConfigured().map(\.id))).sorted()
                    }.value
                }
                .nwTransition(.disclosure)
            }
        }
        .nwAnimation(.disclosure, value: settings.piNativeSubagents)
        .task { await yourPi.refresh() }
    }

    /// The configured subagent model always stays listed, even when pi's catalog lacks it.
    private var childModelOptions: [String] {
        guard !settings.childModel.isEmpty, !modelOptions.contains(settings.childModel) else { return modelOptions }
        return (modelOptions + [settings.childModel]).sorted()
    }

    private static let scopes: [(String, String)] = [("both", "User + project"), ("user", "User"), ("project", "Project"), ("bundled", "Bundled only")]
}

/// Settings ▸ Pi ▸ Sign-in: a row per provider, what Shepherd's pi uses for it, Re-import where
/// the user's pi has a login for it, then Open pi (DESIGN.md › Settings ▸ Pi).
struct PiSignInGroup: View {
    let model: YourPiModel
    var signIn: (() -> Void)?

    var body: some View {
        SettingsGroup(title: "Sign-in",
                      footnote: "Sign-ins belong to Shepherd's pi. Those copied from your pi were copied once, at the first launch; from then on each pi refreshes its own.") {
            ForEach(model.survey?.logins ?? []) { login in
                let row = YourPiModel.rowID(.login(login.provider))
                SettingsRow(title: login.name, subtitle: YourPiText.description(login), problem: model.problems[row]) {
                    HStack(spacing: NW.Space.m) {
                        Text(YourPiText.state(login))
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textSecondary)
                        if login.yours != nil {
                            Button("Re-import") { Task { await model.reimport(.login(login.provider)) } }
                                .buttonStyle(.nw(.secondary, size: .s))
                                .disabled(model.busy.contains(row))
                                .accessibilityLabel("Re-import \(login.name) from your pi")
                        }
                    }
                }
            }
            SettingsRow(title: "Sign in",
                        subtitle: "Opens Shepherd's pi in a terminal beside the selected agent. Type `/login` there. Your terminal's pi stays signed in as it is.") {
                Button("Open pi") { signIn?() }
                    .buttonStyle(.nw(.secondary, size: .s))
                    .disabled(signIn == nil)
                    .help(signIn == nil ? "Select an agent on this Mac first." : "")
            }
        }
    }
}

/// Settings ▸ Pi ▸ From your pi and Your extensions: what Shepherd copied from the user's own pi
/// (with Re-import) and what it reads from there live (with a switch each), and their extensions,
/// listed and off.
struct YourPiGroups: View {
    let model: YourPiModel

    var body: some View {
        let survey = model.survey ?? YourPiSurvey()
        SettingsGroup(title: "From your pi",
                      footnote: "Shepherd only reads your pi. What it copied stays as it was copied until you re-import it; instructions, skills and prompts are read from your pi as they are now.") {
            if let folder = survey.folder {
                let url = URL(fileURLWithPath: folder, isDirectory: true)
                SettingsRow(title: "Your pi",
                            subtitle: "The pi in your terminal. Logins, custom providers, the default model and trusted folders were copied from it at the first launch.",
                            problem: survey.problems.first) {
                    HStack(spacing: NW.Space.m) {
                        Text((folder as NSString).abbreviatingWithTildeInPath)
                            .font(.nw(.mono))
                            .foregroundStyle(Color.nw.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(folder)
                        Button("Reveal") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                            .buttonStyle(.nw(.secondary, size: .s))
                            .accessibilityLabel("Reveal your pi in Finder")
                    }
                }
                reimportRow("Custom providers", item: .customProviders, enabled: !survey.customProviders.isEmpty,
                            subtitle: survey.customProviders.isEmpty ? "None in your pi."
                                : survey.customProviders.map { "`\($0)`" }.joined(separator: ", ") + ".")
                reimportRow("Default model", item: .defaultModel, enabled: survey.defaultModel != nil,
                            subtitle: Self.defaultModel(survey))
                reimportRow("Trusted folders", item: .trust, enabled: survey.trustedFolders > 0,
                            subtitle: survey.trustedFolders == 0 ? "None in your pi. Your home folder is never trusted as a project."
                                : "\(YourPiText.count(survey.trustedFolders, "folder")). Your home folder is never trusted as a project.")
                SettingsRow(title: "Instructions",
                            subtitle: survey.instructionsFile.map { "Reads `\(($0 as NSString).lastPathComponent)` from your pi before every turn." }
                                ?? "Your pi has no `AGENTS.md` or `CLAUDE.md`.",
                            problem: model.problems["instructions"]) {
                    SettingsSwitch(label: "Instructions", isOn: Binding(get: { survey.instructionsOn },
                                                                        set: { on in Task { await model.setInstructions(on) } }))
                }
                resourceRow("Skills", key: "skills", entries: survey.skills, on: survey.skillsOn)
                resourceRow("Prompts", key: "prompts", entries: survey.prompts, on: survey.promptsOn)
            } else {
                SettingsRow(title: "No pi found", subtitle: "Shepherd found no pi of yours to read. Sign in above.") { EmptyView() }
            }
        }
        if !survey.extensions.isEmpty {
            SettingsGroup(title: "Your extensions",
                          footnote: "Off in Shepherd. Switching one on (coming in a later version) runs your code with full access, as your own pi does.") {
                ForEach(survey.extensions) { item in
                    SettingsRow(title: item.name, subtitle: "`\((item.path as NSString).abbreviatingWithTildeInPath)`") {
                        Text("Off")
                            .font(.nw(.caption))
                            .foregroundStyle(Color.nw.textTertiary)
                    }
                }
            }
        }
    }

    private func reimportRow(_ title: String, item: YourPiImport.Item, enabled: Bool, subtitle: String) -> some View {
        let row = YourPiModel.rowID(item)
        return SettingsRow(title: title, subtitle: subtitle, problem: model.problems[row]) {
            Button("Re-import") { Task { await model.reimport(item) } }
                .buttonStyle(.nw(.secondary, size: .s))
                .disabled(!enabled || model.busy.contains(row))
                .accessibilityLabel("Re-import \(title.lowercased()) from your pi")
        }
    }

    private func resourceRow(_ title: String, key: String, entries: [String], on: Bool) -> some View {
        let folders = entries.filter { !$0.hasPrefix("!") }.count
        return SettingsRow(title: title,
                           subtitle: folders == 0 ? "Your pi has none." : "Reads \(YourPiText.count(folders, "folder")) in place.",
                           problem: model.problems[key]) {
            SettingsSwitch(label: title, isOn: Binding(get: { on }, set: { value in Task { await model.setResources(key, on: value) } }))
        }
    }

    static func defaultModel(_ survey: YourPiSurvey) -> String {
        guard let theirs = survey.defaultModel else { return "None set in your pi." }
        if let mine = survey.shepherdDefaultModel, mine != theirs { return "`\(theirs)`. Shepherd's pi uses `\(mine)`." }
        return "`\(theirs)`."
    }
}
