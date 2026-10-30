import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A host's inventory on iPhone and iPad (home track): Settings ▸ MCP, Subagents and Sign-in, the
// Mac's Settings ▸ MCP, Subagents and Pi ▸ Sign-in as the host reads them (`hostInventory.v1`).
// A host with `hostConfig.v1` takes changes from here (`ClientHostConfig`): servers added,
// edited, switched, signed in or removed; profiles edited, deleted or restored; keys saved and
// accounts signed in. A secret typed here goes to the host in one request and is never kept.

/// Settings ▸ MCP: the host's servers, each with its last known status and sign-in column.
struct MCPServersScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        let store = SettingsStore.of(hosts)
        let config = store.hostConfig
        let editor = store.mcpEditor
        HostConfigPage(store: store, page: .mcp, configPage: .mcp,
                       explanation: "The MCP servers a host's agents can use, as its last check found them.") { host in
            if let inventory = config.mcp[host.id] {
                let editable = config.canEdit(host)
                if let problem = inventory.problem {
                    SHBanner(.failed, title: problem)
                }
                HostSignInPanel(config: config, host: host, page: .mcp,
                                codePrompt: "After approving, paste the address your browser ended on (it starts http://127.0.0.1).")
                if let editor {
                    MCPServerEditor(editor: editor, busy: config.busy.contains(host.id)) { json, secrets in
                        Task {
                            if await config.perform(.mcpSave(json: json, secrets: secrets, replacing: editor.replacing), on: host) != nil {
                                store.mcpEditor = nil
                            }
                        }
                    } cancel: { store.mcpEditor = nil }
                }
                if inventory.servers.isEmpty {
                    SettingsFootnote("No MCP servers on \(host.name) yet.")
                } else {
                    SHListCard {
                        ForEach(inventory.servers) { server in
                            HStack(spacing: SH.Space.s) {
                                MCPServerLine(server: server)
                                if editable {
                                    MCPServerControls(server: server, config: config, host: host) {
                                        Task {
                                            if case .mcpEntry(let json)? = await config.perform(.mcpEntry(name: server.name), on: host) {
                                                store.mcpEditor = MCPEditor(replacing: server.name, json: json)
                                            }
                                        }
                                    }
                                    .padding(.trailing, SH.Space.l)
                                }
                            }
                        }
                    }
                }
                if editable {
                    HStack(spacing: SH.Space.l) {
                        Button("Add server") { store.mcpEditor = MCPEditor(replacing: nil, json: MCPEditor.template) }
                            .buttonStyle(.sh(.secondary))
                            .disabled(editor != nil)
                        Button("Check again") { Task { await config.perform(.mcpRefresh, on: host) } }
                            .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                            .disabled(config.busy.contains(host.id))
                    }
                    SettingsFootnote("Servers are kept in \(inventory.configPath) on \(host.name). Secrets go to its Keychain.")
                } else {
                    SettingsFootnote(HostInventoryPresentation.mcpGuidance(host: host.name, configPath: inventory.configPath))
                }
                if let checked = inventory.checkedAt {
                    SettingsFootnote("Last checked \(Date(timeIntervalSince1970: checked).formatted(date: .omitted, time: .shortened)) on \(host.name).")
                }
            }
        }
    }
}

/// A server being added (`replacing` nil) or edited, as `{"mcpServers": …}` JSON.
struct MCPEditor: Equatable {
    var replacing: String?
    var json: String
    static let template = "{\n  \"mcpServers\": {\n    \"name\": { \"type\": \"http\", \"url\": \"https://\" }\n  }\n}"
}

/// The server's JSON, and its secrets: each a variable or header name with the value the host
/// keeps in its Keychain.
private struct MCPServerEditor: View {
    let editor: MCPEditor
    let busy: Bool
    let save: (String, [String: String]) -> Void
    let cancel: () -> Void
    @State private var json = ""
    @State private var secretName = ""
    @State private var secretValue = ""

    var body: some View {
        VStack(alignment: .leading, spacing: SH.Space.m) {
            Text(editor.replacing.map { "Edit \($0)" } ?? "Add a server")
                .font(.sh(.ui, weight: .semibold))
                .foregroundStyle(Color.sh.textPrimary)
            TextEditor(text: $json)
                .font(.sh(.mono))
                .scrollContentBackground(.hidden)
                .frame(minHeight: MobileLayout.instructionsEditorMinHeight)
                .shField(focused: false)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .accessibilityLabel("Server JSON")
            Text("A secret: name a variable or header from the JSON, and its value is kept in the host's Keychain.")
                .shText(.caption)
                .foregroundStyle(Color.sh.textTertiary)
            TextField("Variable or header", text: $secretName)
                .textFieldStyle(SHTextFieldStyle(mono: true))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            SecureField("Secret value", text: $secretValue)
                .textFieldStyle(SHTextFieldStyle(mono: true))
            HStack(spacing: SH.Space.l) {
                Button("Save") {
                    let name = secretName.trimmingCharacters(in: .whitespaces)
                    save(json, name.isEmpty || secretValue.isEmpty ? [:] : [name: secretValue])
                }
                .buttonStyle(.sh(.primary))
                .disabled(busy || json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel", action: cancel).buttonStyle(.sh(.secondary))
            }
        }
        .padding(SH.Space.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shCard(radius: SHListMetrics.cardRadius)
        .onAppear { json = editor.json }
    }
}

/// A server's switch and its menu: Edit, sign in or out, how agents find its tools, Remove.
private struct MCPServerControls: View {
    let server: HostMCPServer
    let config: ClientHostConfig
    let host: SettingsHost
    let edit: () -> Void
    @State private var removing = false

    var body: some View {
        let run: (RemoteHostConfigRequest) -> Void = { request in Task { await config.perform(request, on: host) } }
        HStack(spacing: SH.Space.s) {
            Toggle("\(server.name) on", isOn: Binding(get: { server.enabled }, set: { run(.mcpSetEnabled(name: server.name, on: $0)) }))
                .toggleStyle(.shSwitch)
                .labelsHidden()
            Menu {
                Button("Edit…", action: edit)
                if server.oauth == true {
                    if server.signedIn == true {
                        Button("Sign out") { run(.mcpSignOut(name: server.name)) }
                    } else {
                        Button("Sign in") { run(.mcpSignIn(name: server.name)) }
                    }
                }
                if let exposure = server.exposure {
                    Picker("Tools", selection: Binding(get: { exposure }, set: { run(.mcpSetExposure(name: server.name, exposure: $0)) })) {
                        Text("Search when needed").tag(HostMCPExposure.proxy)
                        Text("In every prompt").tag(HostMCPExposure.direct)
                    }
                }
                Divider()
                Button("Remove…", role: .destructive) { removing = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.sh(.ui))
                    .foregroundStyle(Color.sh.textSecondary)
                    .frame(minWidth: SHListMetrics.rowHeight, minHeight: SHListMetrics.rowHeight)
            }
            .accessibilityLabel("\(server.name) actions")
        }
        .confirmationDialog("Remove \(server.name) from \(host.name)?", isPresented: $removing) {
            Button("Remove", role: .destructive) { run(.mcpRemove(name: server.name)) }
        } message: {
            Text("Its Keychain secrets and sign-in go with it.")
        }
    }
}

/// One server: its dot, name and kind, the error or endpoint, the sign-in column and its tools.
private struct MCPServerLine: View {
    let server: HostMCPServer

    var body: some View {
        let sh = Color.sh
        HStack(alignment: .top, spacing: SH.Space.m) {
            MCPStatusDot(MCPDotState(rawValue: server.status.rawValue) ?? .idle)
                .padding(.top, SH.Space.xs)
            VStack(alignment: .leading, spacing: SH.Space.xxs) {
                HStack(spacing: SH.Space.s) {
                    Text(server.name)
                        .font(.sh(.ui, weight: .medium))
                        .foregroundStyle(sh.textPrimary)
                    Text(HostInventoryPresentation.statusWord(server.status))
                        .font(.sh(.caption))
                        .foregroundStyle(tone.color)
                }
                Text(HostInventoryPresentation.serverLine(server))
                    .font(.sh(.mono))
                    .foregroundStyle(server.note != nil ? sh.failed : sh.textTertiary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                if let signIn = HostInventoryPresentation.signInWord(server.signIn) {
                    Text(signIn)
                        .font(.sh(.caption))
                        .foregroundStyle(sh.textSecondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, SH.Space.l)
        .padding(.vertical, SH.Space.m)
        .frame(minHeight: SHListMetrics.twoLineRowHeight)
        .opacity(server.enabled ? 1 : SHMCPMetrics.offOpacity)
        .accessibilityElement(children: .combine)
    }

    private var tone: AgentState { AgentState(rawValue: HostInventoryPresentation.tone(server.status).rawValue) ?? .idle }
}

/// Settings ▸ Subagents: the host's profiles, each opening its Markdown.
struct SubagentProfilesScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var restoring = false

    var body: some View {
        let store = SettingsStore.of(hosts)
        let config = store.hostConfig
        HostConfigPage(store: store, page: .subagents, configPage: .subagents,
                       explanation: "A subagent is a Markdown file: a name, a description and the instructions it runs with. An agent starts one by name. These are the host's profiles; its live runs show in each thread.") { host in
            if let profiles = config.profiles[host.id] {
                if profiles.isEmpty {
                    SettingsFootnote("No subagents on \(host.name).")
                } else {
                    SHListCard {
                        ForEach(profiles) { profile in
                            Button { navigator.open(.settings(.subagent(profile.file))) } label: {
                                SHListRow(profile.name, subtitle: HostInventoryPresentation.profileLine(profile), subtitleMono: false,
                                          subtitleTone: profile.error != nil ? .failed : nil,
                                          leading: .state(AgentState(rawValue: HostInventoryPresentation.tone(profile).rawValue) ?? .idle),
                                          trailing: .meta(HostInventoryPresentation.capability(profile)))
                            }
                            .buttonStyle(.shRow(radius: 0))
                        }
                    }
                }
                if config.canEdit(host) {
                    HStack(spacing: SH.Space.l) {
                        Button("New profile") { navigator.open(.settings(.subagent(SubagentProfileScreen.newFile))) }
                            .buttonStyle(.sh(.secondary))
                        if profiles.contains(where: \.isDefault) || profiles.isEmpty {
                            Button("Restore defaults…") { restoring = true }
                                .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                        }
                    }
                    .confirmationDialog("Restore the default subagents on \(host.name)?", isPresented: $restoring) {
                        Button("Restore defaults", role: .destructive) {
                            let expected = Dictionary(profiles.filter(\.isDefault).compactMap { p in p.fingerprint.map { (p.file, $0) } },
                                                      uniquingKeysWith: { first, _ in first })
                            Task { await config.perform(.subagentRestoreDefaults(expected: expected), on: host) }
                        }
                    } message: {
                        Text("scout, reviewer, planner and worker go back to how Shepherd ships them. Your own profiles stay.")
                    }
                } else {
                    SettingsFootnote("Edit, add, delete or restore profiles in Settings ▸ Subagents on \(host.name).")
                }
            }
        }
    }
}

/// One profile's Markdown: editable on a host that takes changes, fenced to the version read.
struct SubagentProfileScreen: View {
    /// The route's file for a new profile.
    static let newFile = "+new"

    let file: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(\.dismiss) private var dismiss
    @State private var loaded: HostSubagentProfileText?
    @State private var text = ""
    @State private var name = ""
    @State private var deleting = false

    private var isNew: Bool { file == Self.newFile }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let config = store.hostConfig
        HostConfigPage(store: store, page: .subagents, configPage: nil, title: isNew ? "New profile" : file, explanation: nil) { host in
            let editable = config.canEdit(host)
            if isNew {
                TextField("File name, like reviewer.md", text: $name)
                    .textFieldStyle(SHTextFieldStyle(mono: true))
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
            }
            if editable {
                TextEditor(text: $text)
                    .font(.sh(.mono))
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: MobileLayout.instructionsEditorMinHeight)
                    .shField(focused: false)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .accessibilityLabel("Profile Markdown")
                HStack(spacing: SH.Space.l) {
                    Button("Save") {
                        let target = isNew ? name.trimmingCharacters(in: .whitespaces) : file
                        Task {
                            if case .subagent(let saved)? = await config.perform(
                                .subagentSave(file: target, text: text, fingerprint: isNew ? nil : loaded?.fingerprint), on: host) {
                                loaded = saved
                                if isNew { dismiss() }
                            }
                        }
                    }
                    .buttonStyle(.sh(.primary))
                    .disabled(config.busy.contains(host.id) || (!isNew && text == loaded?.text) || (isNew && name.isEmpty))
                    if !isNew, loaded != nil {
                        Button("Delete…", role: .destructive) { deleting = true }
                            .buttonStyle(.sh(.secondary))
                    }
                }
                .confirmationDialog("Delete \(file) on \(host.name)?", isPresented: $deleting) {
                    Button("Delete", role: .destructive) {
                        guard let fingerprint = loaded?.fingerprint else { return }
                        Task {
                            if await config.perform(.subagentDelete(file: file, fingerprint: fingerprint), on: host) != nil { dismiss() }
                        }
                    }
                }
                SettingsFootnote("A file changed on \(host.name) since it was opened here isn't overwritten: open it again.")
            } else if let loaded {
                Text(loaded.text)
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shCard(radius: SHListMetrics.cardRadius)
                SettingsFootnote("Edit it in Settings ▸ Subagents on \(host.name).")
            }
            Color.clear.frame(height: 0)
                .task(id: host.id) {
                    if isNew {
                        if text.isEmpty { text = "---\nname: \ndescription: \ntools: [read, grep, find, ls]\n---\n" }
                    } else if let read = await config.profile(file, on: host) {
                        loaded = read
                        text = read.text
                    }
                }
        }
    }
}

/// Settings ▸ Sign-in: each provider of the host's pi and whether it is signed in; never a value.
struct ProvidersScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @State private var keyFor: String?
    /// The key form adds a key beside the saved one (Add key) rather than replacing it.
    @State private var addingKey = false
    @State private var key = ""

    var body: some View {
        let store = SettingsStore.of(hosts)
        let config = store.hostConfig
        HostConfigPage(store: store, page: .signIn, configPage: .providers,
                       explanation: "Subscriptions and API keys for agents on a host. They live in the host's own pi.") { host in
            if let providers = config.providers[host.id] {
                let editable = config.canEdit(host)
                HostSignInPanel(config: config, host: host, page: .providers,
                                codePrompt: "After signing in, paste the code (or the whole address) the page shows.")
                if let provider = keyFor {
                    VStack(alignment: .leading, spacing: SH.Space.m) {
                        Text((addingKey ? "Another API key for " : "API key for ") + (providers.first { $0.id == provider }?.name ?? provider))
                            .font(.sh(.ui, weight: .semibold))
                            .foregroundStyle(Color.sh.textPrimary)
                        SecureField("Key, or $VARIABLE set on the host", text: $key)
                            .textFieldStyle(SHTextFieldStyle(mono: true))
                        HStack(spacing: SH.Space.l) {
                            Button("Save") {
                                let value = key
                                key = ""
                                Task {
                                    let request: RemoteHostConfigRequest = addingKey
                                        ? .providerAccount(provider: provider, action: .addKey(value)) : .providerKey(provider: provider, key: value)
                                    if await config.perform(request, on: host) != nil { keyFor = nil }
                                }
                            }
                            .buttonStyle(.sh(.primary))
                            .disabled(key.isEmpty || config.busy.contains(host.id))
                            Button("Cancel") { key = ""; keyFor = nil }.buttonStyle(.sh(.secondary))
                        }
                        SettingsFootnote("The host checks the key with the provider before saving it.")
                    }
                    .padding(SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shCard(radius: SHListMetrics.cardRadius)
                }
                let groups = Dictionary(grouping: providers, by: \.badge)
                ForEach(["Subscription", "API key", "Custom"], id: \.self) { badge in
                    if let rows = groups[badge], !rows.isEmpty {
                        SettingsSection(badge == "Subscription" ? "Subscriptions" : badge == "API key" ? "API keys" : "Custom providers") {
                            SHListCard {
                                ForEach(rows) { provider in
                                    HStack(spacing: SH.Space.s) {
                                        SHListRow(provider.name, subtitle: provider.problem ?? HostInventoryPresentation.providerLine(provider),
                                                  subtitleMono: false,
                                                  subtitleTone: provider.problem != nil ? .failed : provider.auth == .expired ? .attention : nil,
                                                  leading: .state(AgentState(rawValue: HostInventoryPresentation.tone(provider.auth).rawValue) ?? .idle),
                                                  chevron: false)
                                        if editable, badge != "Custom" {
                                            ProviderAction(provider: provider, subscription: badge == "Subscription") { request in
                                                Task { await config.perform(request, on: host) }
                                            } setKey: { adding in addingKey = adding; keyFor = provider.id }
                                            .padding(.trailing, SH.Space.l)
                                        }
                                    }
                                    if let accounts = provider.accountList {
                                        ProviderAccounts(provider: provider, accounts: accounts, editable: editable) { action in
                                            Task { await config.perform(.providerAccount(provider: provider.id, action: action), on: host) }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
                if providers.isEmpty {
                    SettingsFootnote("\(host.name) has no sign-ins yet.")
                }
                if !editable {
                    SettingsFootnote(HostInventoryPresentation.providersGuidance(host: host.name))
                }
            }
        }
    }
}

/// A provider's saved accounts, once there are two: each with Use, Rename and Remove, then
/// whether the next takes over at a limit.
private struct ProviderAccounts: View {
    let provider: HostProviderStatus
    let accounts: [HostProviderAccount]
    let editable: Bool
    let act: (HostProviderAccountAction) -> Void
    @State private var renaming: HostProviderAccount?
    @State private var name = ""

    var body: some View {
        ForEach(accounts) { account in
            SettingsControlRow(account.name, note: HostInventoryPresentation.accountLine(account)) {
                if editable {
                    HStack(spacing: SH.Space.s) {
                        if !account.active {
                            Button("Use") { act(.use(id: account.id)) }
                                .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                                .accessibilityLabel("Use \(account.name) for \(provider.name)")
                        }
                        Menu {
                            Button("Rename…") { name = account.name; renaming = account }
                            Button("Remove", role: .destructive) { act(.remove(id: account.id)) }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                                .font(.sh(.ui))
                                .foregroundStyle(Color.sh.textSecondary)
                                .frame(minWidth: SHListMetrics.rowHeight, minHeight: SHListMetrics.rowHeight)
                        }
                        .accessibilityLabel("\(account.name) actions")
                    }
                }
            }
            // Under their provider: in line with its name, past its status dot.
            .padding(.leading, SHListMetrics.leadingWidth + SH.Space.l)
        }
        SettingsSwitchRow("Switch accounts at a limit", note: "When the active account hits its limit, the next one takes over.",
                          isOn: provider.rotate == true) { act(.rotate($0)) }
            .padding(.leading, SHListMetrics.leadingWidth + SH.Space.l)
            .disabled(!editable)
            .alert("Rename \(renaming?.name ?? "account")", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $name)
                Button("Rename") { if let renaming { act(.rename(id: renaming.id, name: name)) } }
                Button("Cancel", role: .cancel) {}
            }
    }
}

/// A provider's one action: Sign in or Sign out for a subscription, Set key or Remove for a key.
private struct ProviderAction: View {
    let provider: HostProviderStatus
    let subscription: Bool
    let run: (RemoteHostConfigRequest) -> Void
    /// Opens the key form; true adds a key beside the saved one.
    let setKey: (Bool) -> Void

    var body: some View {
        let signedIn = provider.auth == .signedIn || provider.auth == .apiKey
        if signedIn {
            Menu {
                if subscription {
                    Button("Add account") { run(.providerAccount(provider: provider.id, action: .add)) }
                } else if provider.auth == .apiKey {
                    Button("Add key") { setKey(true) }
                }
                Button(subscription ? "Sign out" : "Remove", role: .destructive) { run(.providerSignOut(provider: provider.id)) }
            } label: {
                // Drawn as the row's other actions are (`shLink`): running blue, so it reads as one.
                Text(subscription ? "Account" : "Key")
                    .font(.sh(.caption, weight: .medium))
                    .foregroundStyle(Color.sh.running)
            }
        } else if subscription {
            Button(provider.auth == .expired ? "Sign in again" : "Sign in") { run(.providerSignIn(provider: provider.id)) }
                .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
        } else {
            Button("Set key") { setKey(false) }
                .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
        }
    }
}

/// A sign-in the host runs for this device: the page to open (or the device code to enter), the
/// code or address to send back, then how it ended. Followed while it shows.
private struct HostSignInPanel: View {
    let config: ClientHostConfig
    let host: SettingsHost
    let page: ClientHostConfig.Page
    let codePrompt: String
    @Environment(\.openURL) private var openURL
    @State private var code = ""

    var body: some View {
        if let progress = config.signIns[host.id] {
            VStack(alignment: .leading, spacing: SH.Space.m) {
                Text("Sign in to \(progress.name)")
                    .font(.sh(.ui, weight: .semibold))
                    .foregroundStyle(Color.sh.textPrimary)
                switch progress.phase {
                case .starting:
                    ProgressView().progressViewStyle(SHSpinnerStyle())
                case .waiting:
                    if let device = progress.deviceCode {
                        Text(device)
                            .font(.sh(.mono, weight: .semibold))
                            .foregroundStyle(Color.sh.textPrimary)
                            .textSelection(.enabled)
                        SettingsFootnote("Enter this code on the page.")
                    }
                    if let address = progress.authorizationURL.flatMap(URL.init(string:)) {
                        Button(progress.deviceCode == nil ? "Open sign-in page" : "Open the page") { openURL(address) }
                            .buttonStyle(.sh(.primary))
                    }
                    if progress.wantsCode {
                        SettingsFootnote(codePrompt)
                        TextField("Code or address", text: $code)
                            .textFieldStyle(SHTextFieldStyle(mono: true))
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                        Button("Send") {
                            let value = code
                            code = ""
                            Task { await config.complete(signInOn: host, with: value) }
                        }
                        .buttonStyle(.sh(.secondary))
                        .disabled(code.isEmpty)
                    }
                    Button("Cancel") { Task { await config.cancelSignIn(on: host) } }
                        .buttonStyle(.shLink(font: .sh(.caption, weight: .medium)))
                case .done:
                    SettingsFootnote("Signed in on \(host.name).")
                    Button("Done") { config.clearSignIn(on: host) }.buttonStyle(.sh(.secondary))
                case .failed:
                    SettingsFootnote(progress.message ?? "The sign-in didn't finish.", tone: .failed)
                    Button("OK") { config.clearSignIn(on: host) }.buttonStyle(.sh(.secondary))
                }
            }
            .padding(SH.Space.l)
            .frame(maxWidth: .infinity, alignment: .leading)
            .shCard(radius: SHListMetrics.cardRadius)
            .task(id: progress.id) { await config.follow(signInOn: host, page: page) }
        }
    }
}

// MARK: The page

/// A page of a host's configuration: its explanation, which host when there are several, the
/// host's last problem, then the page, or why there is none. Read again when the host
/// reconnects or the page is pulled.
private struct HostConfigPage<Content: View>: View {
    let store: SettingsStore
    let page: SettingsPage
    /// What the page reads on appearing; nil for a page that reads its own.
    let configPage: ClientHostConfig.Page?
    var title: String?
    let explanation: String?
    @ViewBuilder let content: (SettingsHost) -> Content
    @Environment(\.settingsColumn) private var inColumn
    @Environment(MobileNavigator.self) private var navigator
    @State private var generation = 0

    var body: some View {
        let host = store.settingsHost(chosenHost: navigator.settingsSelection.chosenHost)
        let config = store.hostConfig
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if let explanation {
                    Text(explanation)
                        .shText(.caption)
                        .foregroundStyle(Color.sh.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, SH.Space.xs)
                }
                if store.hosts.count > 1 {
                    HostChooser(store: store)
                }
                if let host {
                    if let problem = config.problems[host.id] {
                        SHBanner(.failed, title: problem) {
                            Button("OK") { config.dismissProblem(on: host) }.buttonStyle(.sh(.secondary))
                        }
                    }
                    if !host.isConnected {
                        SettingsFootnote("\(host.name) is offline. This shows once it's back.")
                    } else if !config.canRead(host) {
                        SettingsFootnote("\(host.name)'s Shepherd is too old to share this. Update it to see it here.")
                    } else {
                        content(host)
                        if !config.canEdit(host) {
                            SettingsFootnote("Changing this from here needs a newer Shepherd on \(host.name).")
                        }
                    }
                } else {
                    SettingsFootnote("Add a host in Settings ▸ Hosts to see this.")
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.top, inColumn ? MobileLayout.settingsColumnTop : 0)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { generation += 1 }
        .background(Color.sh.bgWindow)
        .navigationTitle(title ?? (inColumn ? page.listTitle : page.title))
        .navigationBarTitleDisplayMode(inColumn && title == nil ? .inline : title == nil ? .large : .inline)
        .task(id: Load(host: host?.id, connected: host?.isConnected == true, generation: generation)) {
            if let host, let configPage { await config.refresh(configPage, on: host) }
        }
    }

    private struct Load: Equatable {
        var host: UUID?
        var connected: Bool
        var generation: Int
    }
}
