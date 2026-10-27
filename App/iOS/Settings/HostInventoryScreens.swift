import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// A host's inventory on iPhone and iPad (home track): Settings ▸ MCP, Subagents and Sign-in, the
// Mac's Settings ▸ MCP, Subagents and Pi ▸ Sign-in as the host reads them (`hostInventory.v1`),
// read-only. Each page says what the Mac shows and where to change it; nothing here holds a
// key, a token or a server's secret.

/// Settings ▸ MCP: the host's servers, each with its last known status and sign-in column.
struct MCPServersScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        HostInventoryPage(store: SettingsStore.of(hosts), page: .mcp, request: .mcp,
                          explanation: "The MCP servers a host's agents can use, as its last check found them.") { result, host in
            if case .mcp(let inventory) = result {
                if let problem = inventory.problem {
                    SHBanner(.failed, title: problem)
                }
                if inventory.servers.isEmpty {
                    SettingsFootnote("No MCP servers on \(host.name) yet.")
                } else {
                    SHListCard {
                        ForEach(inventory.servers) { server in
                            MCPServerLine(server: server)
                        }
                    }
                }
                SettingsFootnote(HostInventoryPresentation.mcpGuidance(host: host.name, configPath: inventory.configPath))
                if let checked = inventory.checkedAt {
                    SettingsFootnote("Last checked \(Date(timeIntervalSince1970: checked).formatted(date: .omitted, time: .shortened)) on \(host.name).")
                }
            }
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
                if let signIn = server.signIn {
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

/// Settings ▸ Subagents: the host's profiles, each opening its Markdown read-only.
struct SubagentProfilesScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator

    var body: some View {
        HostInventoryPage(store: SettingsStore.of(hosts), page: .subagents, request: .subagents,
                          explanation: "A subagent is a Markdown file: a name, a description and the instructions it runs with. An agent starts one by name. These are the host's profiles; its live runs show in each thread.") { result, host in
            if case .subagents(let profiles) = result {
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
                SettingsFootnote("Edit, add, delete or restore profiles in Settings ▸ Subagents on \(host.name).")
            }
        }
    }
}

/// One profile's Markdown, read-only.
struct SubagentProfileScreen: View {
    let file: String
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        HostInventoryPage(store: SettingsStore.of(hosts), page: .subagents, request: .subagent(file: file), title: file,
                          explanation: nil) { result, host in
            if case .subagent(let text) = result {
                Text(text.text)
                    .font(.sh(.mono))
                    .foregroundStyle(Color.sh.textPrimary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(SH.Space.l)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .shCard(radius: SHListMetrics.cardRadius)
                SettingsFootnote("Edit it in Settings ▸ Subagents on \(host.name).")
            }
        }
    }
}

/// Settings ▸ Sign-in: each provider of the host's pi and whether it is signed in; never a value.
struct ProvidersScreen: View {
    @Environment(MobileHosts.self) private var hosts

    var body: some View {
        HostInventoryPage(store: SettingsStore.of(hosts), page: .signIn, request: .providers,
                          explanation: "Subscriptions and API keys for agents on a host. They live in the host's own pi.") { result, host in
            if case .providers(let providers) = result {
                let groups = Dictionary(grouping: providers, by: \.badge)
                ForEach(["Subscription", "API key", "Custom"], id: \.self) { badge in
                    if let rows = groups[badge], !rows.isEmpty {
                        SettingsSection(badge == "Subscription" ? "Subscriptions" : badge == "API key" ? "API keys" : "Custom providers") {
                            SHListCard {
                                ForEach(rows) { provider in
                                    SHListRow(provider.name, subtitle: provider.problem ?? HostInventoryPresentation.providerLine(provider),
                                              subtitleMono: false,
                                              subtitleTone: provider.problem != nil ? .failed : provider.auth == .expired ? .attention : nil,
                                              leading: .state(AgentState(rawValue: HostInventoryPresentation.tone(provider.auth).rawValue) ?? .idle),
                                              chevron: false)
                                }
                            }
                        }
                    }
                }
                if providers.isEmpty {
                    SettingsFootnote("\(host.name) has no sign-ins yet.")
                }
                SettingsFootnote(HostInventoryPresentation.providersGuidance(host: host.name))
            }
        }
    }
}

// MARK: The page

/// A read of a host's inventory: its explanation, which host when there are several, then the
/// answer, or why there is none. Read again when the host reconnects or the page is pulled.
private struct HostInventoryPage<Content: View>: View {
    let store: SettingsStore
    let page: SettingsPage
    let request: RemoteHostInventoryRequest
    var title: String?
    let explanation: String?
    @ViewBuilder let content: (RemoteHostInventoryResult, SettingsHost) -> Content
    @Environment(\.settingsColumn) private var inColumn
    @Environment(MobileNavigator.self) private var navigator
    @State private var phase: Phase = .loading
    @State private var generation = 0

    private enum Phase: Equatable {
        case loading
        case loaded(RemoteHostInventoryResult)
        case failed(String)
    }

    var body: some View {
        let host = store.settingsHost(chosenHost: navigator.settingsSelection.chosenHost)
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
                    if !host.isConnected {
                        SettingsFootnote("\(host.name) is offline. This shows once it's back.")
                    } else if !host.serves(RemoteProtocol.hostInventoryCapability) {
                        SettingsFootnote("\(host.name)'s Shepherd is too old to share this. Update it to see it here.")
                    } else {
                        switch phase {
                        case .loading:
                            ProgressView().progressViewStyle(SHSpinnerStyle())
                                .frame(maxWidth: .infinity)
                        case .loaded(let result):
                            content(result, host)
                        case .failed(let reason):
                            SettingsFootnote(reason, tone: .failed)
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
        .shAnimation(.content, value: phase)
        .navigationTitle(title ?? (inColumn ? page.listTitle : page.title))
        .navigationBarTitleDisplayMode(inColumn && title == nil ? .inline : title == nil ? .large : .inline)
        .task(id: Load(host: host?.id, connected: host?.isConnected == true, generation: generation)) {
            await load(host)
        }
    }

    private struct Load: Equatable {
        var host: UUID?
        var connected: Bool
        var generation: Int
    }

    private func load(_ host: SettingsHost?) async {
        guard let host, let client = host.client as? RemoteHostClient, host.serves(RemoteProtocol.hostInventoryCapability) else { return }
        if case .loaded = phase {} else { phase = .loading }
        do {
            let result = try await client.hostInventory(request)
            guard !Task.isCancelled else { return }
            phase = .loaded(result)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(settingsProblem(error))
        }
    }
}
