import SwiftUI
import AppKit
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings' host picker: a host-level page (Agents, Subagents, Worktrees, Extensions, Slash
// commands, MCP servers, Sign-in, Experiments) shows This Mac, bound to `AppSettings` as ever, or
// one of the remote hosts, read and changed over the remote protocol through the same shared
// models the iPhone and the iPad use (`ClientHostSettings`, `ClientHostConfig`). A host whose
// Shepherd predates a page's capability shows it read-only and says so.

extension SettingsSection {
    /// Pages that set something on a host: the picker heads them.
    var isHostLevel: Bool {
        switch self {
        case .agents, .subagents, .worktrees, .extensions, .piSlashCommands, .mcp, .piSignIn, .experiments: true
        default: false
        }
    }

    /// Pages that set this Mac's own app, never a host's.
    var isClientLocal: Bool {
        switch self {
        case .appearance, .terminal, .keyboard, .remote, .advanced: true
        default: false
        }
    }
}

extension ShepherdViewModel {
    /// The remote hosts as Settings' picker sees them now.
    var settingsHosts: [SettingsHost] {
        remoteHosts.connections.map { connection in
            SettingsHost(id: connection.id, name: connection.config.name, client: connection.settingsClient,
                         capabilities: connection.capabilities)
        }
    }

    /// The remote host a host-level page shows; nil for this Mac (or a host since removed).
    var remoteSettingsHost: SettingsHost? {
        settingsHostID.flatMap { id in settingsHosts.first { $0.id == id } }
    }
}

/// "Host: This Mac ▾" over a host-level page, when there are remote hosts.
struct SettingsHostPicker: View {
    var vm: ShepherdViewModel

    var body: some View {
        let hosts = vm.settingsHosts
        HStack(spacing: SH.Space.m) {
            Text("Host")
                .font(.sh(.ui, weight: .medium))
                .foregroundStyle(Color.sh.textSecondary)
            SHPopupMenu(vm.remoteSettingsHost?.name ?? "This Mac", minWidth: AppLayout.settingsPopupWidth) {
                Button("This Mac") { vm.settingsHostID = nil }
                Divider()
                ForEach(hosts) { host in
                    Button(host.isConnected ? host.name : "\(host.name) · offline") { vm.settingsHostID = host.id }
                }
            }
            .accessibilityLabel("Settings host")
            Spacer(minLength: 0)
        }
    }
}

/// A host-level page for a remote host.
struct RemoteHostSettingsPage: View {
    let section: SettingsSection
    let host: SettingsHost
    let settings: ClientHostSettings
    let config: ClientHostConfig

    var body: some View {
        Group {
            if !host.isConnected {
                SettingsPage(title: section.title, explanation: "\(host.name) is offline. Its settings show here once it's back.") {}
            } else {
                switch section {
                case .mcp: RemoteMCPPage(host: host, config: config)
                case .piSignIn: RemoteSignInPage(host: host, config: config)
                case .subagents: RemoteSubagentsPage(host: host, settings: settings, config: config)
                default: RemoteSettingsSectionPage(section: section, host: host, settings: settings)
                }
            }
        }
        .task(id: Load(host: host.id, connected: host.isConnected)) {
            await settings.refresh(host)
        }
    }

    private struct Load: Equatable {
        var host: UUID
        var connected: Bool
    }
}

/// Says a page can't change `host` from here.
private struct NeedsNewer: View {
    let host: SettingsHost
    var body: some View {
        SettingsNote(text: "Changing this from here needs a newer Shepherd on \(host.name).")
    }
}

/// A binding that posts each change to the host.
@MainActor
private func hostBinding<Value>(_ value: Value, _ change: @escaping (Value) -> HostSettingChange,
                                settings: ClientHostSettings, host: SettingsHost) -> Binding<Value> {
    Binding(get: { value }, set: { settings.post(change($0), on: host) })
}

/// The pages drawn from `HostSettings`: Agents, Worktrees, Extensions, Slash commands, Experiments.
private struct RemoteSettingsSectionPage: View {
    let section: SettingsSection
    let host: SettingsHost
    let settings: ClientHostSettings

    var body: some View {
        switch settings.state(of: host) {
        case .loaded(let value):
            content(value)
                .overlay(alignment: .top) {
                    if let problem = settings.problem {
                        SHBanner(.failed, title: problem) { Button("OK") { settings.dismissProblem() }.buttonStyle(.sh(.secondary)) }
                    }
                }
        case .unsupported:
            SettingsPage(title: section.title, explanation: "\(host.name)'s Shepherd is too old to share its settings: update it to change them here.") {}
        case .failed(let reason):
            SettingsPage(title: section.title, explanation: reason) {}
        case .loading, .offline:
            SettingsPage(title: section.title, explanation: "Reading \(host.name)'s settings…") {}
        }
    }

    private func bind<Value>(_ value: Value, _ change: @escaping (Value) -> HostSettingChange) -> Binding<Value> {
        hostBinding(value, change, settings: settings, host: host)
    }

    @ViewBuilder private func content(_ s: HostSettings) -> some View {
        let v2 = host.serves(RemoteProtocol.hostSettingsV2Capability)
        switch section {
        case .agents:
            let defaults = host.serves(RemoteProtocol.hostSettingsAgentDefaultsCapability)
            SettingsPage(title: "Agents", explanation: "What new threads on \(host.name) start with. Running threads keep their own.") {
                SettingsGroup(title: "New threads") {
                    SettingsRow(title: "Default model", subtitle: "\"provider/id\"; empty uses the agent's own default.") {
                        CommitField(label: "Default model", prompt: "Agent's default", value: s.defaultModel ?? "") {
                            settings.post(.defaultModel($0.isEmpty ? nil : $0), on: host)
                        }
                    }
                    SettingsRow(title: "Default thinking level") {
                        SHPopupMenu(s.defaultThinking.title, minWidth: AppLayout.settingsPopupWidth) {
                            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                                Button(level.title) { settings.post(.defaultThinking(level), on: host) }
                            }
                        }
                    }
                    if defaults {
                        SettingsRow(title: "Speed for new threads") {
                            SHSegmentedPicker("Speed for new threads", selection: bind(s.defaultServiceTier) { .defaultServiceTier($0) },
                                              options: ServiceTier.allCases.map { ($0, $0.title) })
                        }
                        SettingsRow(title: "Session naming model", subtitle: "Empty is Automatic.") {
                            CommitField(label: "Session naming model", prompt: "Automatic", value: s.namingModel ?? "") {
                                settings.post(.namingModel($0.isEmpty ? nil : $0), on: host)
                            }
                        }
                    }
                    SettingsRow(title: "When a turn ends, send the queue") {
                        SHSegmentedPicker("When a turn ends, send the queue", selection: bind(s.queueDelivery) { .queueDelivery($0) },
                                          options: [(.oneAtATime, "One per turn"), (.all, "All at once")])
                    }
                }
                if defaults {
                    SettingsGroup(title: "Context") {
                        SettingsRow(title: "Compact at") {
                            SHPopupMenu(s.compactAtPercent.map { "\($0)%" } ?? "Agent's default", minWidth: AppLayout.settingsPopupWidth) {
                                Button("Agent's default") { settings.post(.compactAtPercent(nil), on: host) }
                                ForEach(HostSettings.compactAtChoices, id: \.self) { percent in
                                    Button("\(percent)%") { settings.post(.compactAtPercent(percent), on: host) }
                                }
                            }
                        }
                        ForEach(s.bundledExtensions.filter { ["context", "deferTools", "codemode"].contains($0.id) }) { bundled in
                            SettingsRow(title: bundled.name, subtitle: HostSettingsPresentation.note(forBundled: bundled.id)) {
                                SettingsSwitch(label: bundled.name, isOn: bind(bundled.on) { .bundledExtension(id: bundled.id, on: $0) })
                            }
                        }
                    }
                }
                SettingsGroup(title: "Goal checks") {
                    SettingsRow(title: "Allow cross-provider goal checks",
                                subtitle: "On may send conversation, tool output and written code to another provider.") {
                        SettingsSwitch(label: "Allow cross-provider goal checks",
                                       isOn: bind(s.goalCrossProviderEvaluation) { .goalCrossProviderEvaluation($0) })
                    }
                }
                SettingsNote(text: "Notify when a turn finishes is this Mac's own: switch to This Mac to change it.")
            }
        case .worktrees:
            SettingsPage(title: "Worktrees", explanation: "How \(host.name) creates worktrees, and what Finalize does.") {
                SettingsGroup(title: "New worktrees") {
                    SettingsRow(title: "Base branch") {
                        SHSegmentedPicker("Base branch", selection: bind(s.worktreeBase) { .worktreeBase($0) },
                                          options: [(.fresh, "Remote default"), (.head, "Current branch")])
                    }
                    switchRow("Fetch before creating", s.fetchBeforeCreating) { .fetchBeforeCreating($0) }
                }
                SettingsGroup(title: "Finalize") {
                    switchRow("Commit remaining work", s.commitRemainingWork) { .commitRemainingWork($0) }
                    switchRow("Generate PR descriptions", s.generatePRDescriptions) { .generatePRDescriptions($0) }
                    switchRow("Delete local branch", s.deleteLocalBranch) { .deleteLocalBranch($0) }
                    switchRow("Merge PR automatically", s.mergePRAutomatically) { .mergePRAutomatically($0) }
                    if s.mergePRAutomatically {
                        SettingsRow(title: "Merge method") {
                            SHSegmentedPicker("Merge method", selection: bind(s.mergeMethod) { .mergeMethod($0) },
                                              options: [(.squash, "Squash"), (.merge, "Merge"), (.rebase, "Rebase")])
                        }
                    }
                }
                SettingsGroup(title: "Delete") {
                    SettingsRow(title: "Deleting a worktree agent") {
                        SHSegmentedPicker("Deleting a worktree agent", selection: bind(s.worktreeDeleteAction) { .worktreeDeleteAction($0) },
                                          options: HostSettings.WorktreeDeleteAction.allCases.map { ($0, HostSettingsPresentation.title($0)) })
                    }
                    .disabled(!v2)
                }
                if !v2 { NeedsNewer(host: host) }
            }
        case .extensions:
            SettingsPage(title: "Extensions", explanation: "What the agent loads on \(host.name): the extensions Shepherd bundles and the ones installed there.") {
                SettingsGroup(title: "Bundled with Shepherd") {
                    ForEach(s.bundledExtensions.filter { !["context", "deferTools", "codemode"].contains($0.id) }) { bundled in
                        SettingsRow(title: bundled.name, subtitle: HostSettingsPresentation.note(forBundled: bundled.id)) {
                            SettingsSwitch(label: bundled.name, isOn: bind(bundled.on) { .bundledExtension(id: bundled.id, on: $0) })
                        }
                    }
                }
                SettingsGroup(title: "Agents") {
                    switchRow("Skills in the / menu", s.skillsInSlashMenu) { .skillsInSlashMenu($0) }
                    switchRow("Also use a repo’s .mcp.json", s.mcpProjectConfig) { .mcpProjectConfig($0) }
                }
                .disabled(!v2)
                if !v2 { NeedsNewer(host: host) }
                SettingsGroup(title: "Installed on \(host.name)") {
                    if s.installedExtensions.isEmpty {
                        SettingsRow(title: "None yet") { EmptyView() }
                    }
                    ForEach(s.installedExtensions, id: \.self) { source in
                        SettingsRow(title: source) { EmptyView() }
                    }
                }
            }
        case .piSlashCommands:
            SettingsPage(title: "Slash commands", explanation: "The commands \(host.name)'s pi lists in the / menu. Off leaves one out of the menu; typing it still runs it.") {
                if !v2 {
                    NeedsNewer(host: host)
                } else if s.slashCommands.isEmpty {
                    SettingsNote(text: "Commands show here once an agent on \(host.name) has listed them.")
                } else {
                    SettingsGroup(title: "Commands") {
                        ForEach(s.slashCommands, id: \.name) { command in
                            SettingsRow(title: "/" + command.name, subtitle: command.description) {
                                SettingsSwitch(label: "/" + command.name,
                                               isOn: bind(!s.hiddenSlashCommands.contains(command.name)) { .slashCommand(name: command.name, on: $0) })
                            }
                        }
                    }
                }
            }
        case .experiments:
            SettingsPage(title: "Experiments", explanation: "Features still being tried on \(host.name). Each is off until you turn it on.") {
                SettingsGroup(title: "On \(host.name)") {
                    experimentRow("Goals", RemoteProtocol.goalExperimentCapability, s.goalsEnabled) { .goalsEnabled($0) }
                    experimentRow("Projects", RemoteProtocol.projectsExperimentCapability, s.projectsEnabled) { .projectsEnabled($0) }
                    experimentRow("Design tool", RemoteProtocol.designToolExperimentCapability, s.designToolEnabled) { .designToolEnabled($0) }
                    let locked = s.missionsEnabled && s.missionsActive
                    SettingsRow(title: "Missions", subtitle: locked ? "Pause or stop running missions on \(host.name) before turning this off." : nil) {
                        SettingsSwitch(label: "Missions", isOn: bind(s.missionsEnabled) { .missionsEnabled($0) })
                            .disabled(locked || !host.serves(RemoteProtocol.missionsExperimentCapability))
                    }
                }
                if ![RemoteProtocol.goalExperimentCapability, RemoteProtocol.projectsExperimentCapability,
                     RemoteProtocol.designToolExperimentCapability, RemoteProtocol.missionsExperimentCapability].allSatisfy(host.serves) {
                    NeedsNewer(host: host)
                }
                SettingsNote(text: "Suggested instructions is set per host from This Mac's Experiments page and the iPhone.")
            }
        default:
            EmptyView()
        }
    }

    private func switchRow(_ title: String, _ value: Bool, _ change: @escaping (Bool) -> HostSettingChange) -> some View {
        SettingsRow(title: title) { SettingsSwitch(label: title, isOn: bind(value, change)) }
    }

    private func experimentRow(_ title: String, _ capability: String, _ value: Bool,
                               _ change: @escaping (Bool) -> HostSettingChange) -> some View {
        SettingsRow(title: title) {
            SettingsSwitch(label: title, isOn: bind(value, change)).disabled(!host.serves(capability))
        }
    }
}

/// A text field that sends its value when Return is pressed or it loses focus.
private struct CommitField: View {
    let label: String
    let prompt: String
    let value: String
    let commit: (String) -> Void
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        SettingsTextField(label: label, prompt: prompt, text: $text, mono: true)
            .focused($focused)
            .onSubmit { send() }
            .onChange(of: focused) { if !focused { send() } }
            .onAppear { text = value }
            .onChange(of: value) { if !focused { text = value } }
    }

    private func send() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed != value { commit(trimmed) }
    }
}

/// Settings ▸ Subagents on a remote host: its defaults, and its profiles with Edit, Delete and
/// Restore defaults (each fenced to what the host last said).
private struct RemoteSubagentsPage: View {
    let host: SettingsHost
    let settings: ClientHostSettings
    let config: ClientHostConfig
    @State private var editing: HostSubagentProfileText?
    @State private var newFile = ""
    @State private var text = ""

    var body: some View {
        let v2 = host.serves(RemoteProtocol.hostSettingsV2Capability)
        let editable = config.canEdit(host)
        SettingsPage(title: "Subagents", explanation: "Defaults and profiles for subagents on \(host.name).") {
            if let s = settings.settings(of: host) {
                let d = s.subagentDefaults
                let post: (HostSettings.SubagentDefaults) -> Void = { settings.post(.subagentDefaults($0), on: host) }
                SettingsGroup(title: "Defaults") {
                    SettingsRow(title: "Concurrency") {
                        SHStepper("Concurrency", value: Binding(get: { d.concurrency }, set: { var n = d; n.concurrency = $0; post(n) }),
                                  in: HostSettings.SubagentDefaults.concurrencyRange)
                    }
                    SettingsRow(title: "Model", subtitle: "Empty inherits the parent's.") {
                        CommitField(label: "Subagent model", prompt: "Inherit parent", value: d.model ?? "") {
                            var n = d; n.model = $0.isEmpty ? nil : $0; post(n)
                        }
                    }
                    SettingsRow(title: "Thinking") {
                        SHPopupMenu(d.thinking?.title ?? "Inherit parent", minWidth: AppLayout.settingsPopupWidth) {
                            Button("Inherit parent") { var n = d; n.thinking = nil; post(n) }
                            ForEach(ThinkingLevel.allCases, id: \.self) { level in
                                Button(level.title) { var n = d; n.thinking = level; post(n) }
                            }
                        }
                    }
                    SettingsRow(title: "Context") {
                        SHSegmentedPicker("Context", selection: Binding(get: { d.context }, set: { var n = d; n.context = $0; post(n) }),
                                          options: [(.fresh, "Fresh"), (.fork, "Fork")])
                    }
                }
                .disabled(!v2)
                if !v2 { NeedsNewer(host: host) }
            }
            if let editing {
                SettingsGroup(title: editing.file.isEmpty ? "New profile" : editing.file) {
                    if editing.file.isEmpty {
                        SettingsRow(title: "File") { SettingsTextField(label: "File", prompt: "reviewer.md", text: $newFile, mono: true) }
                    }
                    TextEditor(text: $text)
                        .font(.sh(.mono))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: AppLayout.instructionsEditorMinHeight)
                        .padding(SH.Space.m)
                        .accessibilityLabel("Profile Markdown")
                    SettingsActionRow {
                        Button("Cancel") { self.editing = nil }.buttonStyle(.sh(.secondary))
                        Button("Save") {
                            let file = editing.file.isEmpty ? newFile : editing.file
                            Task {
                                if await config.perform(.subagentSave(file: file, text: text,
                                                                      fingerprint: editing.file.isEmpty ? nil : editing.fingerprint), on: host) != nil {
                                    self.editing = nil
                                    await config.refresh(.subagents, on: host)
                                }
                            }
                        }
                        .buttonStyle(.sh(.primary))
                        .disabled(config.busy.contains(host.id))
                    }
                }
            }
            SettingsGroup(title: "Profiles") {
                ForEach(config.profiles[host.id] ?? []) { profile in
                    SettingsRow(title: profile.name, subtitle: HostInventoryPresentation.profileLine(profile)) {
                        if editable {
                            HStack(spacing: SH.Space.s) {
                                Button("Edit") {
                                    Task {
                                        if let read = await config.profile(profile.file, on: host) { editing = read; text = read.text }
                                    }
                                }
                                .buttonStyle(.sh(.secondary))
                                Button("Delete") {
                                    Task {
                                        if let read = await config.profile(profile.file, on: host) {
                                            await config.perform(.subagentDelete(file: profile.file, fingerprint: read.fingerprint), on: host)
                                        }
                                    }
                                }
                                .buttonStyle(.sh(.secondary))
                            }
                        }
                    }
                }
                if editable {
                    SettingsActionRow {
                        Button("Restore defaults") {
                            let profiles = config.profiles[host.id] ?? []
                            let expected = Dictionary(profiles.filter(\.isDefault).compactMap { p in p.fingerprint.map { (p.file, $0) } },
                                                      uniquingKeysWith: { first, _ in first })
                            Task { await config.perform(.subagentRestoreDefaults(expected: expected), on: host) }
                        }
                        .buttonStyle(.sh(.secondary))
                        Button("New subagent") {
                            newFile = ""
                            text = "---\nname: \ndescription: \ntools: [read, grep, find, ls]\n---\n"
                            editing = HostSubagentProfileText(file: "", text: text, fingerprint: "")
                        }
                        .buttonStyle(.sh(.secondary))
                    }
                }
            }
            if !editable { NeedsNewer(host: host) }
            ConfigProblem(host: host, config: config)
        }
        .task(id: host.id) { await config.refresh(.subagents, on: host) }
    }
}

/// The host's last refusal, with OK.
private struct ConfigProblem: View {
    let host: SettingsHost
    let config: ClientHostConfig

    var body: some View {
        if let problem = config.problems[host.id] {
            SHBanner(.failed, title: problem) { Button("OK") { config.dismissProblem(on: host) }.buttonStyle(.sh(.secondary)) }
        }
    }
}

/// Settings ▸ MCP servers on a remote host.
private struct RemoteMCPPage: View {
    let host: SettingsHost
    let config: ClientHostConfig
    @State private var editing: String?
    @State private var replacing: String?
    @State private var secretName = ""
    @State private var secretValue = ""

    var body: some View {
        let editable = config.canEdit(host)
        let inventory = config.mcp[host.id]
        SettingsPage(title: "MCP servers", explanation: "The MCP servers agents on \(host.name) can use, as its last check found them.") {
            ConfigProblem(host: host, config: config)
            RemoteSignInPanel(host: host, config: config, page: .mcp,
                              codePrompt: "After approving, paste the address your browser ended on (it starts http://127.0.0.1).")
            if let problem = inventory?.problem { SHBanner(.failed, title: problem) }
            if let editing {
                SettingsGroup(title: replacing.map { "Edit \($0)" } ?? "Add a server",
                              footnote: "A secret: name a variable or header from the JSON; its value goes to \(host.name)'s Keychain.") {
                    TextEditor(text: Binding(get: { editing }, set: { self.editing = $0 }))
                        .font(.sh(.mono))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: AppLayout.instructionsEditorMinHeight)
                        .padding(SH.Space.m)
                        .accessibilityLabel("Server JSON")
                    SettingsRow(title: "Secret") {
                        HStack(spacing: SH.Space.s) {
                            SettingsTextField(label: "Secret name", prompt: "GITHUB_TOKEN", text: $secretName, mono: true)
                            SettingsTextField(label: "Secret value", prompt: "Value", text: $secretValue, mono: true, secure: true)
                        }
                    }
                    SettingsActionRow {
                        Button("Cancel") { self.editing = nil }.buttonStyle(.sh(.secondary))
                        Button("Save") {
                            let name = secretName.trimmingCharacters(in: .whitespaces)
                            let secrets = name.isEmpty || secretValue.isEmpty ? [:] : [name: secretValue]
                            Task {
                                if await config.perform(.mcpSave(json: editing, secrets: secrets, replacing: replacing), on: host) != nil {
                                    self.editing = nil
                                    secretValue = ""
                                }
                            }
                        }
                        .buttonStyle(.sh(.primary))
                        .disabled(config.busy.contains(host.id))
                    }
                }
            }
            SettingsGroup(title: "Servers", trailing: inventory?.configPath) {
                ForEach(inventory?.servers ?? []) { server in
                    SettingsRow(title: server.name, subtitle: server.signIn.map { "\(HostInventoryPresentation.serverLine(server)) · \($0)" }
                                ?? HostInventoryPresentation.serverLine(server)) {
                        if editable {
                            HStack(spacing: SH.Space.s) {
                                if server.oauth == true {
                                    Button(server.signedIn == true ? "Sign out" : "Sign in") {
                                        Task {
                                            await config.perform(server.signedIn == true ? .mcpSignOut(name: server.name) : .mcpSignIn(name: server.name), on: host)
                                        }
                                    }
                                    .buttonStyle(.sh(.secondary))
                                }
                                SHPopupMenu("More", minWidth: AppLayout.settingsPopupWidth) {
                                    Button("Edit…") {
                                        Task {
                                            if case .mcpEntry(let json)? = await config.perform(.mcpEntry(name: server.name), on: host) {
                                                replacing = server.name
                                                editing = json
                                            }
                                        }
                                    }
                                    Button("Search for tools when needed") { run(.mcpSetExposure(name: server.name, exposure: .proxy)) }
                                    Button("Put tools in every prompt") { run(.mcpSetExposure(name: server.name, exposure: .direct)) }
                                    Divider()
                                    Button("Remove") { run(.mcpRemove(name: server.name)) }
                                }
                                SettingsSwitch(label: server.name, isOn: Binding(get: { server.enabled },
                                                                                set: { run(.mcpSetEnabled(name: server.name, on: $0)) }))
                            }
                        }
                    }
                }
                if editable {
                    SettingsActionRow {
                        Button("Check again") { run(.mcpRefresh) }.buttonStyle(.sh(.secondary))
                        Button("Add server") {
                            replacing = nil
                            editing = MCPEditor.template
                        }
                        .buttonStyle(.sh(.secondary))
                    }
                }
            }
            if !editable { NeedsNewer(host: host) }
        }
        .task(id: host.id) { await config.refresh(.mcp, on: host) }
    }

    private func run(_ request: RemoteHostConfigRequest) { Task { await config.perform(request, on: host) } }
}

/// A server being added or edited, as `{"mcpServers": …}` JSON.
enum MCPEditor {
    static let template = "{\n  \"mcpServers\": {\n    \"name\": { \"type\": \"http\", \"url\": \"https://\" }\n  }\n}"
}

/// Settings ▸ Sign-in on a remote host.
private struct RemoteSignInPage: View {
    let host: SettingsHost
    let config: ClientHostConfig
    @State private var keyFor: String?
    @State private var key = ""

    var body: some View {
        let editable = config.canEdit(host)
        let providers = config.providers[host.id] ?? []
        SettingsPage(title: "Sign-in", explanation: "Subscriptions and API keys for agents on \(host.name). They stay in its own pi.") {
            ConfigProblem(host: host, config: config)
            RemoteSignInPanel(host: host, config: config, page: .providers,
                              codePrompt: "After signing in, paste the code (or the whole address) the page shows.")
            if let provider = keyFor {
                SettingsGroup(title: "API key for \(providers.first { $0.id == provider }?.name ?? provider)",
                              footnote: "\(host.name) checks the key with the provider before saving it.") {
                    SettingsRow(title: "Key") {
                        SettingsTextField(label: "API key", prompt: "Key, or $VARIABLE", text: $key, mono: true, secure: true)
                    }
                    SettingsActionRow {
                        Button("Cancel") { key = ""; keyFor = nil }.buttonStyle(.sh(.secondary))
                        Button("Save") {
                            let value = key
                            key = ""
                            Task { if await config.perform(.providerKey(provider: provider, key: value), on: host) != nil { keyFor = nil } }
                        }
                        .buttonStyle(.sh(.primary))
                        .disabled(config.busy.contains(host.id))
                    }
                }
            }
            ForEach(["Subscription", "API key", "Custom"], id: \.self) { badge in
                let rows = providers.filter { $0.badge == badge }
                if !rows.isEmpty {
                    SettingsGroup(title: badge == "Subscription" ? "Subscriptions" : badge == "API key" ? "API keys" : "Custom providers") {
                        ForEach(rows) { provider in
                            SettingsRow(title: provider.name, subtitle: provider.problem ?? HostInventoryPresentation.providerLine(provider)) {
                                if editable, badge != "Custom" {
                                    let signedIn = provider.auth == .signedIn || provider.auth == .apiKey
                                    Button(signedIn ? (badge == "Subscription" ? "Sign out" : "Remove") : badge == "Subscription" ? "Sign in" : "Set key") {
                                        if signedIn { run(.providerSignOut(provider: provider.id)) }
                                        else if badge == "Subscription" { run(.providerSignIn(provider: provider.id)) }
                                        else { keyFor = provider.id }
                                    }
                                    .buttonStyle(.sh(.secondary))
                                }
                            }
                        }
                    }
                }
            }
            if !editable { NeedsNewer(host: host) }
        }
        .task(id: host.id) { await config.refresh(.providers, on: host) }
    }

    private func run(_ request: RemoteHostConfigRequest) { Task { await config.perform(request, on: host) } }
}

/// A sign-in the host runs for this Mac: the page to open here, the code to send back, and how it
/// ended. Followed while it shows.
private struct RemoteSignInPanel: View {
    let host: SettingsHost
    let config: ClientHostConfig
    let page: ClientHostConfig.Page
    let codePrompt: String
    @State private var code = ""

    var body: some View {
        if let progress = config.signIns[host.id] {
            SettingsGroup(title: "Sign in to \(progress.name) on \(host.name)", footnote: progress.message) {
                switch progress.phase {
                case .starting:
                    SettingsRow(title: "Starting…") { ProgressView().controlSize(.small) }
                case .waiting:
                    if let address = progress.authorizationURL.flatMap(URL.init(string:)) {
                        SettingsRow(title: progress.deviceCode.map { "Enter \($0) on the page" } ?? "Open the sign-in page") {
                            Button("Open in browser") { NSWorkspace.shared.open(address) }.buttonStyle(.sh(.primary))
                        }
                    }
                    if progress.wantsCode {
                        SettingsRow(title: "Code", subtitle: codePrompt) {
                            HStack(spacing: SH.Space.s) {
                                SettingsTextField(label: "Code", prompt: "Code or address", text: $code, mono: true)
                                Button("Send") {
                                    let value = code
                                    code = ""
                                    Task { await config.complete(signInOn: host, with: value) }
                                }
                                .buttonStyle(.sh(.secondary))
                                .disabled(code.isEmpty)
                            }
                        }
                    }
                    SettingsActionRow {
                        Button("Cancel") { Task { await config.cancelSignIn(on: host) } }.buttonStyle(.sh(.secondary))
                    }
                case .done:
                    SettingsRow(title: "Signed in") { Button("Done") { config.clearSignIn(on: host) }.buttonStyle(.sh(.secondary)) }
                case .failed:
                    SettingsRow(title: "Didn't finish") { Button("OK") { config.clearSignIn(on: host) }.buttonStyle(.sh(.secondary)) }
                }
            }
            .task(id: progress.id) { await config.follow(signInOn: host, page: page) }
        }
    }
}
