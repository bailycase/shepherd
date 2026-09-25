import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A host's own settings on iPhone and iPad (home track): Settings ▸ Defaults, Worktrees and Pi
// extensions, the Mac's Settings ▸ Agents, Worktrees and Pi as the host keeps them
// (`hostSettings.v1`). A change shows at once and goes to the host; one it refuses springs back
// with its reason. With several hosts, the page says which one it changes.

/// Settings ▸ Defaults: what a host's new threads start with.
struct DefaultsScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @State private var models: [String] = []

    var body: some View {
        let store = SettingsStore.of(hosts)
        HostSettingsPage(store: store, page: .defaults,
                         explanation: "What new threads on a host start with. Threads already running keep their own.") { settings, host in
            SettingsSection("New threads") {
                NWListCard {
                    SettingsControlRow("Model", note: "`pi's default` passes no model, so pi picks.") {
                        Menu {
                            Button("pi's default") { store.hostSettings.post(.defaultModel(nil), on: host) }
                            Divider()
                            ForEach(Self.options(models, current: settings.defaultModel), id: \.self) { model in
                                Button(model) { store.hostSettings.post(.defaultModel(model), on: host) }
                            }
                        } label: {
                            SettingsMenuLabel(settings.defaultModel ?? "pi's default", mono: settings.defaultModel != nil)
                        }
                        .accessibilityLabel("Default model")
                    }
                    SettingsControlRow("Thinking", note: "Each thread can change it from its composer.") {
                        SettingsPicker("Thinking", selection: settings.defaultThinking, options: ThinkingLevel.allCases,
                                       title: HostSettingsPresentation.title) { store.hostSettings.post(.defaultThinking($0), on: host) }
                    }
                }
            }
            SettingsSection("While pi is working") {
                NWListCard {
                    SettingsControlRow("When a turn ends, send the queue", note: "All at once arrives as one turn, in order.") {
                        SettingsPicker("Send the queue", selection: settings.queueDelivery, options: [.oneAtATime, .all],
                                       title: HostSettingsPresentation.title) { store.hostSettings.post(.queueDelivery($0), on: host) }
                    }
                }
            }
            .task(id: host.id) { models = await Self.models(of: store.mobileHost(host.id)) }
        }
    }

    /// The host's model catalog, asked once per connection.
    private static func models(of host: MobileHost?) async -> [String] {
        guard let host else { return [] }
        return await ComposerStates.shared.listing(for: host)?.models ?? []
    }

    /// The catalog, with the current model kept even when the catalog lacks it.
    private static func options(_ models: [String], current: String?) -> [String] {
        guard let current, !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }
}

/// Settings ▸ Worktrees: how a host creates worktrees, and what Finalize does.
struct WorktreesScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        HostSettingsPage(store: store, page: .worktrees,
                         explanation: "How a host creates worktrees, and what Finalize does when a thread's work is done.") { settings, host in
            let post: (HostSettingChange) -> Void = { store.hostSettings.post($0, on: host) }
            SettingsSection("New worktrees") {
                NWListCard {
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
            SettingsSection("Finalize") {
                NWListCard {
                    SettingsSwitchRow("Commit remaining work",
                                      note: "Commits what's left with the PR's title. Off stops Finalize on a dirty worktree.",
                                      isOn: settings.commitRemainingWork) { post(.commitRemainingWork($0)) }
                    SettingsSwitchRow("Generate PR descriptions", note: "Drafts one from the branch's commits and diff.",
                                      isOn: settings.generatePRDescriptions) { post(.generatePRDescriptions($0)) }
                    SettingsSwitchRow("Delete local branch", note: "Once the worktree is gone and everything is on the remote.",
                                      isOn: settings.deleteLocalBranch) { post(.deleteLocalBranch($0)) }
                    SettingsSwitchRow("Merge PR automatically", note: "Uses GitHub auto-merge, so required checks still gate it.",
                                      isOn: settings.mergePRAutomatically) { post(.mergePRAutomatically($0)) }
                    if settings.mergePRAutomatically {
                        SettingsControlRow("Merge method", note: "The repository must allow it.") {
                            SettingsPicker("Merge method", selection: settings.mergeMethod, options: [.squash, .merge, .rebase],
                                           title: HostSettingsPresentation.title) { post(.mergeMethod($0)) }
                        }
                    }
                }
                SettingsFootnote("Shepherd never deletes the remote branch: merging the PR cleans it up on GitHub.")
            }
            .nwAnimation(.disclosure, value: settings.mergePRAutomatically)
        }
    }
}

/// Settings ▸ Pi extensions: the extensions Shepherd bundles into pi on a host, the ones its pi
/// loads itself, and the daily updates.
struct PiExtensionsScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        HostSettingsPage(store: store, page: .pi,
                         explanation: "What pi loads on a host: the extensions Shepherd bundles, the ones installed with pi, and their updates.") { settings, host in
            let post: (HostSettingChange) -> Void = { store.hostSettings.post($0, on: host) }
            SettingsSection("Bundled with Shepherd") {
                NWListCard {
                    ForEach(settings.bundledExtensions) { bundled in
                        SettingsSwitchRow(bundled.name, note: HostSettingsPresentation.note(forBundled: bundled.id), isOn: bundled.on) {
                            post(.bundledExtension(id: bundled.id, on: $0))
                        }
                    }
                }
                SettingsFootnote("New threads follow a change; running ones keep theirs until they restart. Status and session tracking are always on.")
            }
            SettingsSection("Installed with pi") {
                if settings.installedExtensions.isEmpty {
                    SettingsFootnote("None yet. What \(host.name)'s pi installs itself shows here.")
                } else {
                    NWListCard {
                        ForEach(settings.installedExtensions, id: \.self) { source in
                            Text(source)
                                .font(.nw(.mono))
                                .foregroundStyle(Color.nw.textPrimary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .padding(.horizontal, NW.Space.l)
                                .frame(maxWidth: .infinity, minHeight: NWListMetrics.rowHeight, alignment: .leading)
                        }
                    }
                }
            }
            SettingsSection("Updates") {
                NWListCard {
                    SettingsSwitchRow("Update pi daily", note: "Runs `pi update` once a day.", isOn: settings.updatePiDaily) {
                        post(.updatePiDaily($0))
                    }
                    SettingsSwitchRow("Update extensions daily", note: "Runs `pi update --extensions` once a day.",
                                      isOn: settings.updateExtensionsDaily) { post(.updateExtensionsDaily($0)) }
                }
                SettingsFootnote(["Updating never restarts running threads.", HostSettingsPresentation.piVersion(settings).map { "\(host.name) runs \($0)." }]
                    .compactMap { $0 }.joined(separator: " "))
            }
        }
    }
}

// MARK: The page

/// A host settings page: its explanation, which host it changes when there are several, then the
/// host's settings once read, or why they can't be shown.
private struct HostSettingsPage<Content: View>: View {
    let store: SettingsStore
    let page: SettingsPage
    let explanation: String
    @ViewBuilder let content: (HostSettings, SettingsHost) -> Content
    @Environment(\.settingsColumn) private var inColumn

    var body: some View {
        let host = store.settingsHost
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text(explanation)
                    .nwText(.caption)
                    .foregroundStyle(Color.nw.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, NW.Space.xs)
                if store.hosts.count > 1 {
                    HostChooser(store: store)
                }
                if let problem = store.hostSettings.problem {
                    NWBanner(.failed, title: problem) {
                        Button("OK") { store.hostSettings.dismissProblem() }.buttonStyle(.nw(.secondary))
                    }
                }
                if let host {
                    switch store.hostSettings.state(of: host) {
                    case .loaded(let settings):
                        content(settings, host)
                    case .loading:
                        ProgressView().progressViewStyle(NWSpinnerStyle())
                            .frame(maxWidth: .infinity)
                    case .offline:
                        SettingsFootnote("\(host.name) is offline. Its settings show here once it's back.")
                    case .unsupported:
                        SettingsFootnote("\(host.name)'s Shepherd is too old to share its settings. Update it to change them here.")
                    case .failed(let reason):
                        SettingsFootnote(reason, tone: .failed)
                    }
                } else {
                    SettingsFootnote("Add a host in Settings ▸ Hosts to change its settings here.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { await store.refresh() }
        .background(Color.nw.bgWindow)
        .nwAnimation(.content, value: host.map { store.hostSettings.state(of: $0) })
        .navigationTitle(inColumn ? page.listTitle : page.title)
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .task { if !inColumn { await store.watch() } }
    }
}

/// Which host the page changes, when there are several.
private struct HostChooser: View {
    let store: SettingsStore

    var body: some View {
        NWListCard {
            SettingsControlRow("Host") {
                Menu {
                    ForEach(store.hosts) { host in
                        Button { store.chosenHost = host.id } label: {
                            if host.id == store.settingsHost?.id {
                                Label(Self.title(host), systemImage: "checkmark")
                            } else {
                                Text(Self.title(host))
                            }
                        }
                    }
                } label: {
                    SettingsMenuLabel(store.settingsHost?.name ?? "None", mono: true)
                }
                .accessibilityLabel("Host")
            }
        }
    }

    private static func title(_ host: SettingsHost) -> String {
        host.isConnected ? host.name : "\(host.name) · offline"
    }
}

// MARK: Rows

/// A row of a Settings card with a control: its title over an optional note (`code` and
/// **names** marked as the Mac's Settings mark them), the control trailing.
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
        HStack(spacing: NW.Space.l) {
            VStack(alignment: .leading, spacing: NW.Space.xxs) {
                Text(title)
                    .font(.nw(.ui))
                    .foregroundStyle(Color.nw.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                if let note {
                    NWMarkupText(note, size: MobileLayout.settingsNoteSize, codeSize: MobileLayout.settingsNoteCodeSize)
                        .foregroundStyle(Color.nw.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control()
        }
        .padding(.horizontal, NW.Space.l)
        .padding(.vertical, NW.Space.m)
        .frame(minHeight: note == nil ? NWListMetrics.rowHeight : NWListMetrics.twoLineRowHeight)
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
                .toggleStyle(.nwSwitch)
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
        HStack(spacing: NW.Space.xs) {
            Text(text)
                .font(mono ? .nw(.mono) : .nw(.ui))
                .foregroundStyle(Color.nw.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Image(systemName: "chevron.up.chevron.down")
                .font(.nw(.caption, weight: .semibold))
                .foregroundStyle(Color.nw.textTertiary)
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
            .nwText(.caption)
            .foregroundStyle(tone == .failed ? Color.nw.failed : Color.nw.textTertiary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, NW.Space.xs)
    }
}
