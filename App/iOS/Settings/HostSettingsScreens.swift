import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A host's own settings on iPhone and iPad (home track): the sections of Settings ▸ Models, Agents,
// Tools and Git, as the Mac groups them, as the host keeps them (`hostSettings.v1`). A change shows at once and goes to the host; one it refuses springs back
// with its reason. With several hosts, the page says which one it changes.

/// Settings ▸ Models, after Sign-in: what a host's new threads start with, and the models for its
/// small jobs.
struct ModelDefaultsSections: View {
    let store: SettingsStore
    @State private var models: [String] = []
    @State private var imageModels: [String] = []

    var body: some View {
        HostSettingsBody(store: store, explanation: nil) { settings, host in
            let agentDefaults = host.serves(RemoteProtocol.hostSettingsAgentDefaultsCapability)
            SettingsSection("Defaults for new threads") {
                SettingsCard {
                    SettingsControlRow("Model", note: "“Use the agent’s default” passes no model, so the agent picks.") {
                        Menu {
                            Button("Use the agent’s default") { store.hostSettings.post(.defaultModel(nil), on: host) }
                            Divider()
                            ForEach(Self.options(models, current: settings.defaultModel), id: \.self) { model in
                                Button(model) { store.hostSettings.post(.defaultModel(model), on: host) }
                            }
                        } label: {
                            SettingsMenuLabel(settings.defaultModel ?? "Agent’s default", mono: settings.defaultModel != nil)
                        }
                        .accessibilityLabel("Default model")
                    }
                    SettingsControlRow("Thinking", note: "Each thread can change it from its composer.") {
                        SettingsPicker("Thinking", selection: settings.defaultThinking, options: ThinkingLevel.allCases,
                                       title: HostSettingsPresentation.title) { store.hostSettings.post(.defaultThinking($0), on: host) }
                    }
                    if agentDefaults {
                        SettingsControlRow("Speed", note: "New threads start on this speed. Each thread keeps its own after that.") {
                            SettingsPicker("Speed", selection: settings.defaultServiceTier, options: ServiceTier.allCases,
                                           title: { $0.title }) { store.hostSettings.post(.defaultServiceTier($0), on: host) }
                        }
                    }
                }
            }
            if host.serves(RemoteProtocol.hostSettingsTextGenerationModelCapability) || host.serves(RemoteProtocol.hostSettingsVisionModelCapability) {
                SettingsSection("Small jobs") {
                    SettingsCard {
                        if host.serves(RemoteProtocol.hostSettingsTextGenerationModelCapability) {
                            SettingsControlRow("Text generation model", note: "The model the host uses to generate short text itself: a thread's title from its first prompt, and commit messages drafted from a diff. Your renames are never overwritten. Automatic prefers a low-cost model the host is signed in to.") {
                                Menu {
                                    Button("Automatic") { store.hostSettings.post(.textGenerationModel(nil), on: host) }
                                    Divider()
                                    ForEach(Self.options(models, current: settings.textGenerationModel), id: \.self) { model in
                                        Button(model) { store.hostSettings.post(.textGenerationModel(model), on: host) }
                                    }
                                } label: {
                                    SettingsMenuLabel(settings.textGenerationModel ?? "Automatic", mono: settings.textGenerationModel != nil)
                                }
                                .accessibilityLabel("Text generation model")
                            }
                        }
                        if host.serves(RemoteProtocol.hostSettingsVisionModelCapability) {
                            SettingsControlRow("Image reading model", note: "When a thread's model can't view images, this model describes each image for it: the pictures you attach, screenshots and board renders. Automatic uses the cheapest model the host is signed in to that takes images.") {
                                Menu {
                                    Button("Automatic") { store.hostSettings.post(.visionModel(nil), on: host) }
                                    Divider()
                                    ForEach(Self.options(imageModels, current: settings.visionModel), id: \.self) { model in
                                        Button(model) { store.hostSettings.post(.visionModel(model), on: host) }
                                    }
                                } label: {
                                    SettingsMenuLabel(settings.visionModel ?? "Automatic", mono: settings.visionModel != nil)
                                }
                                .accessibilityLabel("Image reading model")
                            }
                        }
                    }
                }
            }
            Color.clear.frame(height: 0)
                .task(id: host.id) {
                    let listing = await ModelCatalog.listing(of: store.mobileHost(host.id))
                    models = listing?.models ?? []
                    imageModels = listing?.imageCapableModels ?? []
                }
        }
    }

    private static func options(_ models: [String], current: String?) -> [String] { ModelCatalog.options(models, current: current) }
}

/// The host's model catalog, asked once per connection.
enum ModelCatalog {
    static func listing(of host: MobileHost?) async -> ModelListing? {
        guard let host else { return nil }
        return await ComposerStates.shared.listing(for: host)
    }

    /// The catalog, with the current model kept even when the catalog lacks it.
    static func options(_ models: [String], current: String?) -> [String] {
        guard let current, !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }
}

/// Settings ▸ Agents: the queue, the threads a thread starts, context, and subagents (Profiles opens
/// its own page).
struct AgentSettingsSections: View {
    let store: SettingsStore
    @State private var models: [String] = []

    var body: some View {
        HostSettingsBody(store: store, explanation: nil) { settings, host in
            let agentDefaults = host.serves(RemoteProtocol.hostSettingsAgentDefaultsCapability)
            SettingsSection("Queue") {
                SettingsCard {
                    SettingsControlRow("When a turn ends, send the queue", note: "All at once arrives as one turn, in order.") {
                        SettingsPicker("Send the queue", selection: settings.queueDelivery, options: [.oneAtATime, .all],
                                       title: HostSettingsPresentation.title) { store.hostSettings.post(.queueDelivery($0), on: host) }
                    }
                }
            }
            if host.serves(RemoteProtocol.hostSettingsSubThreadsCapability) {
                SettingsSection("Threads a thread starts") {
                    SettingsCard {
                        SettingsSwitchRow("Threads can start threads",
                                          note: "A thread may start another for separate work without being asked. Off, it starts one only when you ask. Three deep at most.",
                                          isOn: settings.threadsStartThreads) { store.hostSettings.post(.threadsStartThreads($0), on: host) }
                        SettingsControlRow("Where they work", note: "When the thread starting one doesn't say.") {
                            SettingsPicker("Where they work", selection: settings.subThreadPlace, options: SpawnPlace.allCases,
                                           title: { $0 == .checkout ? "Same checkout" : "New worktree" }) { store.hostSettings.post(.subThreadPlace($0), on: host) }
                        }
                    }
                    SettingsFootnote("New threads follow a change; running ones at their next launch.")
                }
            }
            if agentDefaults {
                SettingsSection("Context") {
                    SettingsCard {
                        SettingsControlRow("Compact at", note: "How full an agent lets its context get before it compacts on its own, as a share of the model's window. The default leaves 16k tokens free.") {
                            SettingsPicker("Compact at", selection: settings.compactAtPercent, options: [Int?.none] + HostSettings.compactAtChoices.map { Int?($0) },
                                           title: { $0.map { "\($0)%" } ?? "Agent’s default" }) { store.hostSettings.post(.compactAtPercent($0), on: host) }
                        }
                        ForEach(settings.bundledExtensions.filter { Self.contextSwitches.contains($0.id) }) { bundled in
                            SettingsSwitchRow(bundled.name, note: HostSettingsPresentation.note(forBundled: bundled.id), isOn: bundled.on) {
                                store.hostSettings.post(.bundledExtension(id: bundled.id, on: $0), on: host)
                            }
                        }
                    }
                    SettingsFootnote("New threads follow a change; running ones at their next launch.")
                }
            }
            if host.serves(RemoteProtocol.hostSettingsV2Capability) {
                SubagentDefaultsSection(store: store, host: host, defaults: settings.subagentDefaults, models: models) {
                    store.hostSettings.post(.subagentDefaults($0), on: host)
                }
            }
            Color.clear.frame(height: 0)
                .task(id: host.id) {
                    models = await ModelCatalog.listing(of: store.mobileHost(host.id))?.models ?? []
                }
        }
    }

    /// The Mac's Settings ▸ Agents ▸ Context switches, which the host lists with its bundled
    /// extensions; shown here, under Compact at, rather than with Tools' built-in ones.
    static let contextSwitches: Set<String> = ["context", "deferTools", "codemode"]
}

/// Settings ▸ Git: how a host creates worktrees, and what happens when a thread's work is done.
struct WorktreesScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        SettingsPageScaffold("Git", store: store) {
            HostSettingsBody(store: store, explanation: "How a host creates worktrees, and what happens when a thread's work is done.") { settings, host in
            let post: (HostSettingChange) -> Void = { store.hostSettings.post($0, on: host) }
            SettingsSection("New worktrees") {
                SettingsCard {
                    SettingsControlRow("Base branch",
                                       note: "**Remote default** starts clean from origin's default branch. **Current branch** stacks on the checkout's work in progress.") {
                        SettingsPicker("Base branch", selection: settings.worktreeBase, options: HostSettings.WorktreeBase.allCases,
                                       title: HostSettingsPresentation.title) { post(.worktreeBase($0)) }
                    }
                    SettingsSwitchRow("Fetch before creating",
                                      note: "So the remote default is the remote's latest, not a stale local copy.",
                                      isOn: settings.fetchBeforeCreating) { post(.fetchBeforeCreating($0)) }
                }
            }
            SettingsSection("Commits") {
                SettingsCard {
                    SettingsSwitchRow("Draft commit messages", note: "Commit from review drafts one from the diff.",
                                      isOn: settings.generatePRDescriptions) { post(.generatePRDescriptions($0)) }
                }
            }
            let closeOnMerge = host.serves(RemoteProtocol.hostSettingsCloseOnMergeCapability)
            if host.serves(RemoteProtocol.hostSettingsV2Capability) || closeOnMerge {
                SettingsSection("Deleting") {
                    SettingsCard {
                        if host.serves(RemoteProtocol.hostSettingsV2Capability) {
                            SettingsControlRow("Deleting a worktree agent",
                                               note: "**Ask** shows the confirmation. A remembered removal still asks when the checkout has unreconciled work.") {
                                SettingsPicker("Deleting a worktree agent", selection: settings.worktreeDeleteAction,
                                               options: HostSettings.WorktreeDeleteAction.allCases,
                                               title: HostSettingsPresentation.title) { post(.worktreeDeleteAction($0)) }
                            }
                        }
                        if closeOnMerge {
                            SettingsSwitchRow("Close threads when their pull request merges",
                                              note: "Deletes the thread, its worktree and its branch, here and on GitHub. A thread that is running, asking, or holds uncommitted or unpushed work stays open with a note.",
                                              isOn: settings.closeOnMerge) { post(.closeOnMerge($0)) }
                        }
                    }
                }
            }
            }
        }
    }
}

/// Settings ▸ Tools, after MCP: the extensions Shepherd bundles into pi on a host, its slash
/// commands, and the ones its pi loads itself. The engine updates with Shepherd.
struct ExtensionSections: View {
    let store: SettingsStore

    var body: some View {
        HostSettingsBody(store: store, explanation: nil) { settings, host in
            let post: (HostSettingChange) -> Void = { store.hostSettings.post($0, on: host) }
            SettingsSection("Built in") {
                SettingsCard {
                    // The Context switches live on Agents where the host serves them there.
                    ForEach(settings.bundledExtensions.filter { !host.serves(RemoteProtocol.hostSettingsAgentDefaultsCapability) || !AgentSettingsSections.contextSwitches.contains($0.id) }) { bundled in
                        SettingsSwitchRow(bundled.name, note: HostSettingsPresentation.note(forBundled: bundled.id), isOn: bundled.on) {
                            post(.bundledExtension(id: bundled.id, on: $0))
                        }
                    }
                }
                SettingsFootnote("New threads follow a change; running ones keep theirs until they restart. Status and session tracking are always on.")
            }
            PiExtensionSections(store: store)
            if host.serves(RemoteProtocol.hostSettingsV2Capability) {
                SettingsSection("How the agent uses them") {
                    SettingsCard {
                        SettingsSwitchRow("Also use a repo’s .mcp.json", note: "Off: only the host's own MCP servers, in every repo.",
                                          isOn: settings.mcpProjectConfig) { post(.mcpProjectConfig($0)) }
                    }
                }
                SettingsSection("Slash commands") {
                    SettingsCard { SlashCommandsLink(commands: settings.slashCommands, hidden: Set(settings.hiddenSlashCommands)) }
                }
            }
            SettingsSection("Installed on \(host.name)") {
                if settings.installedExtensions.isEmpty {
                    SettingsFootnote("None yet. Extensions installed on \(host.name) show here.")
                } else {
                    SettingsCard {
                        ForEach(settings.installedExtensions, id: \.self) { source in
                            Text(source)
                                .font(.sh(.mono))
                                .foregroundStyle(Color.sh.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .padding(.horizontal, SH.Space.l)
                                .frame(maxWidth: .infinity, minHeight: SHListMetrics.rowHeight, alignment: .leading)
                        }
                    }
                }
            }
            SettingsSection("Updates") {
                SettingsFootnote(["The agent engine and bundled extensions update with Shepherd on the host.", HostSettingsPresentation.agentVersion(settings).map { "\(host.name) runs \($0)." }]
                    .compactMap { $0 }.joined(separator: " "))
            }
        }
    }
}

/// Settings ▸ Agents ▸ Subagents on a host: what a subagent starts with unless its profile says.
private struct SubagentDefaultsSection: View {
    let store: SettingsStore
    let host: SettingsHost
    let defaults: HostSettings.SubagentDefaults
    let models: [String]
    let change: (HostSettings.SubagentDefaults) -> Void

    var body: some View {
        SettingsSection("Subagents") {
            SettingsCard {
                SettingsControlRow("Concurrency", note: "How many subagents run at once.") {
                    SettingsPicker("Concurrency", selection: defaults.concurrency, options: Array(HostSettings.SubagentDefaults.concurrencyRange),
                                   title: { String($0) }) { set(\.concurrency, $0) }
                }
                SettingsControlRow("Model") {
                    Menu {
                        Button("Inherit parent") { set(\.model, nil) }
                        Divider()
                        ForEach(models, id: \.self) { model in Button(model) { set(\.model, model) } }
                    } label: {
                        SettingsMenuLabel(defaults.model ?? "Inherit parent", mono: defaults.model != nil)
                    }
                    .accessibilityLabel("Subagent model")
                }
                SettingsControlRow("Thinking") {
                    SettingsPicker("Subagent thinking", selection: defaults.thinking, options: [ThinkingLevel?.none] + ThinkingLevel.allCases.map { $0 },
                                   title: { $0?.title ?? "Inherit parent" }) { set(\.thinking, $0) }
                }
                SettingsControlRow("Context", note: "**Fresh** starts empty; **Fork** starts from the parent's conversation.") {
                    SettingsPicker("Subagent context", selection: defaults.context, options: HostSettings.SubagentDefaults.Context.allCases,
                                   title: { $0 == .fork ? "Fork" : "Fresh" }) { set(\.context, $0) }
                }
                SubagentProfilesRow(store: store, host: host)
            }
            SettingsFootnote("A profile's own settings win. New subagents follow a change.")
        }
    }

    private func set<Value>(_ keyPath: WritableKeyPath<HostSettings.SubagentDefaults, Value>, _ value: Value) {
        var next = defaults
        next[keyPath: keyPath] = value
        change(next)
    }
}

/// Tools' row for the slash commands: how many are on; opens their screen.
private struct SlashCommandsLink: View {
    let commands: [NativeCommand]
    let hidden: Set<String>
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        let off = commands.filter { hidden.contains($0.name) }.count
        Button { navigator.open(.settings(.slashCommands)) } label: {
            SettingsNavRow("Commands in the / menu", note: commands.isEmpty ? "None listed yet" : "\(commands.count - off) on, \(off) off", value: "Manage")
        }
        .buttonStyle(.shRow(radius: 0))
    }
}

/// Settings ▸ Tools ▸ Slash commands: every command the host's pi listed, each with a switch.
struct SlashCommandsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        SettingsPageScaffold("Slash commands", store: store) {
            HostSettingsBody(store: store, explanation: nil) { settings, host in
                SlashCommandsSection(commands: settings.slashCommands, hidden: Set(settings.hiddenSlashCommands)) { name, on in
                    store.hostSettings.post(.slashCommand(name: name, on: on), on: host)
                }
            }
        }
    }
}

/// Skills ▸ Options: whether the composer's / menu lists every skill.
struct SkillsSlashMenuSection: View {
    let store: SettingsStore

    var body: some View {
        HostSettingsBody(store: store, explanation: nil) { settings, host in
            if host.serves(RemoteProtocol.hostSettingsV2Capability) {
                SettingsSection("Options") {
                    SettingsCard {
                        SettingsSwitchRow("Skills in the / menu", note: "List every skill as /skill:name in the composer’s slash menu.",
                                          isOn: settings.skillsInSlashMenu) { store.hostSettings.post(.skillsInSlashMenu($0), on: host) }
                    }
                }
            }
        }
    }
}

/// Settings ▸ Slash commands on a host: every command its pi listed, each with a switch.
private struct SlashCommandsSection: View {
    let commands: [NativeCommand]
    let hidden: Set<String>
    let toggle: (String, Bool) -> Void

    var body: some View {
        SettingsSection("Slash commands") {
            if commands.isEmpty {
                SettingsFootnote("Commands show here once an agent on the host has listed them.")
            } else {
                SettingsCard {
                    ForEach(commands, id: \.name) { command in
                        SettingsSwitchRow("/" + command.name, note: command.description, isOn: !hidden.contains(command.name)) {
                            toggle(command.name, $0)
                        }
                    }
                }
                SettingsFootnote("Off leaves a command out of the / menu; typing it still runs it.")
            }
        }
    }
}

// MARK: The page

/// A Settings page of stacked sections (MobileSettingsGeneral, MobileExperiments, MobileHooks): the page's
/// title large over its lead, pulling it reads every host again, and beside the iPad's list it keeps the
/// title inline and starts a step lower. Host pages put their bodies in it, so one page can hold sections
/// of several host models (Models, Tools).
struct SettingsPageScaffold<Content: View>: View {
    let title: String
    let lead: String?
    let store: SettingsStore?
    @ViewBuilder let content: () -> Content
    @Environment(\.settingsColumn) private var inColumn

    init(_ title: String, lead: String? = nil, store: SettingsStore? = nil, @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.lead = lead
        self.store = store
        self.content = content
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
                if let lead { SettingsLead(lead) }
                content()
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store?.refresh() }
        .background(Color.sh.bgWindow)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .task { if !inColumn { await store?.watch() } }
    }
}

/// A host's settings as sections: an explanation, which host they change when there are several,
/// then the host's settings once read, or why they can't be shown.
struct HostSettingsBody<Content: View>: View {
    let store: SettingsStore
    let explanation: String?
    @ViewBuilder let content: (HostSettings, SettingsHost) -> Content

    var body: some View {
        let host = store.settingsHost
        VStack(alignment: .leading, spacing: MobileLayout.settingsSectionSpacing) {
            if let explanation {
                SettingsLead(explanation)
            }
            if let problem = store.hostSettings.problem {
                SHBanner(.failed, title: problem) {
                    Button("OK") { store.hostSettings.dismissProblem() }.buttonStyle(.settingsPill)
                }
            }
            if let host {
                switch store.hostSettings.state(of: host) {
                case .loaded(let settings):
                    content(settings, host)
                case .loading:
                    SHBusyLabel("Reading the settings…")
                        .frame(maxWidth: .infinity)
                case .offline:
                    SettingsFootnote("\(host.name) is offline. Its settings show here once it's back.")
                case .unsupported:
                    SettingsFootnote("\(host.name)'s Shepherd is too old to share its settings. Update it to change them here.")
                case .failed(let reason):
                    SettingsFootnote(reason, tone: .failed)
                }
            } else {
                SettingsFootnote("Add a host in Settings ▸ Fleet to change its settings here.")
            }
        }
        .shAnimation(.content, value: host.map { store.hostSettings.state(of: $0) })
    }
}

// MARK: Rows

/// A row of a Settings card with a control (the boards' `gt-r`): its title over an optional note (`code`
/// and **names** marked as the Mac's Settings mark them), the control trailing.
struct SettingsControlRow<Control: View>: View {
    let title: String
    let note: String?
    @ViewBuilder let control: () -> Control

    init(_ title: String, note: String? = nil, @ViewBuilder control: @escaping () -> Control) {
        self.title = title
        self.note = note
        self.control = control
    }

    var body: some View {
        HStack(spacing: SH.Space.l) {
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                Text(title)
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    SHMarkupText(note, size: MobileLayout.settingsNoteSize, codeSize: MobileLayout.settingsNoteCodeSize)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, MobileLayout.settingsRowInset)
        .padding(.vertical, MobileLayout.settingsRowPadding)
        .frame(maxWidth: .infinity, minHeight: MobileLayout.settingsRowHeight, alignment: .leading)
    }
}

/// A row with a switch.
struct SettingsSwitchRow: View {
    let title: String
    let note: String?
    let isOn: Bool
    let toggle: (Bool) -> Void

    init(_ title: String, note: String? = nil, isOn: Bool, toggle: @escaping (Bool) -> Void) {
        self.title = title
        self.note = note
        self.isOn = isOn
        self.toggle = toggle
    }

    var body: some View {
        SettingsControlRow(title, note: note) {
            Toggle(title, isOn: Binding(get: { isOn }, set: toggle))
                .toggleStyle(.settingsSwitch)
                .labelsHidden()
        }
    }
}

/// A choice among a few options, as a menu showing the current one.
struct SettingsPicker<Option: Hashable>: View {
    let label: String
    let selection: Option
    let options: [Option]
    let title: (Option) -> String
    let choose: (Option) -> Void

    init(_ label: String, selection: Option, options: [Option], title: @escaping (Option) -> String,
         choose: @escaping (Option) -> Void) {
        self.label = label
        self.selection = selection
        self.options = options
        self.title = title
        self.choose = choose
    }

    var body: some View {
        Menu {
            ForEach(options, id: \.self) { option in
                Button { choose(option) } label: {
                    if option == selection { Label(title(option), systemImage: "checkmark") } else { Text(title(option)) }
                }
            }
        } label: {
            SettingsMenuLabel(title(selection))
        }
        .accessibilityLabel(label)
        .accessibilityValue(title(selection))
    }
}

/// A menu's current value with its up-down chevrons.
struct SettingsMenuLabel: View {
    let text: String
    let mono: Bool

    init(_ text: String, mono: Bool = false) {
        self.text = text
        self.mono = mono
    }

    var body: some View {
        HStack(spacing: SH.Space.xs) {
            Text(text)
                .font(mono ? .shMono(MobileLayout.settingsNoteSize) : .shSans(MobileLayout.settingsNoteSize))
                .foregroundStyle(Color.sh.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.shSans(MobileLayout.settingsChevronSize, .medium))
                .foregroundStyle(Color.sh.textTertiary)
        }
        .frame(maxWidth: MobileLayout.settingsMenuMaxWidth, alignment: .trailing)
        .contentShape(Rectangle())
    }
}

/// A line under a card, or in place of one: `textTertiary`, `failed` for a problem.
struct SettingsFootnote: View {
    let text: String
    let tone: Tone

    enum Tone { case quiet, failed }

    init(_ text: String, tone: Tone = .quiet) {
        self.text = text
        self.tone = tone
    }

    var body: some View {
        Text(text)
            .font(.shSans(MobileLayout.settingsCaptionSize))
            .foregroundStyle(tone == .failed ? Color.sh.failed : Color.sh.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, SH.Space.xs)
    }
}
