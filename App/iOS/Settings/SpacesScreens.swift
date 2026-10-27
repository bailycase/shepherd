import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Spaces on iPhone and iPad (home track): the folders a host keeps as spaces, with
// their configuration files and whether their resources are approved, read-only, over the
// existing space-file API (`projects.v2`, `projects.mcp.v1`). Not the Projects experiment's
// logical Projects: these are folders on the host.

/// Settings ▸ Spaces: the host's spaces by folder, each with what its configuration holds.
struct SpacesScreen: View {
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @Environment(\.settingsColumn) private var inColumn
    @State private var phase: Phase = .loading
    @State private var generation = 0

    private enum Phase: Equatable {
        case loading
        case loaded([ProjectSummary])
        case failed(String)
    }

    var body: some View {
        let store = SettingsStore.of(hosts)
        let host = store.settingsHost(chosenHost: navigator.settingsSelection.chosenHost)
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text("The folders a host keeps as spaces, and what each one's .shepherd or .pi folder holds. Hidden spaces are listed too.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if store.hosts.count > 1 { HostChooser(store: store) }
                if let host {
                    if !host.isConnected {
                        SettingsFootnote("\(host.name) is offline. Its spaces show here once it's back.")
                    } else if !host.serves(RemoteProtocol.projectsV2Capability) {
                        SettingsFootnote("\(host.name)'s Shepherd is too old to share its spaces. Update it to see them here.")
                    } else {
                        switch phase {
                        case .loading:
                            ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
                        case .loaded(let spaces):
                            if spaces.isEmpty {
                                SettingsFootnote("No spaces on \(host.name) yet.")
                            } else {
                                SHListCard {
                                    ForEach(spaces) { space in
                                        Button { navigator.open(.settings(.space(space.directory))) } label: {
                                            SHListRow(space.name, subtitle: HostInventoryPresentation.spaceLine(space), subtitleMono: false,
                                                      subtitleTone: space.error != nil ? .failed : nil,
                                                      leading: .state(AgentState(rawValue: HostInventoryPresentation.tone(space).rawValue) ?? .idle),
                                                      trailing: .value(space.displayPath))
                                        }
                                        .buttonStyle(.shRow(radius: 0))
                                    }
                                }
                            }
                            SettingsFootnote(HostInventoryPresentation.spacesGuidance(host: host.name))
                        case .failed(let reason):
                            SettingsFootnote(reason, tone: .failed)
                        }
                    }
                } else {
                    SettingsFootnote("Add a host in Settings ▸ Hosts to see its spaces.")
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
        .navigationTitle(SettingsPage.spaces.title)
        .navigationBarTitleDisplayMode(inColumn ? .inline : .large)
        .task(id: "\(host?.id.uuidString ?? "")/\(host?.isConnected == true)/\(generation)") { await load(host) }
    }

    /// Every page of the host's history (`ProjectSettingsStore.pageSize` at a time), ordered as it keeps them.
    private func load(_ host: SettingsHost?) async {
        guard let host, let client = host.client as? RemoteHostClient, host.serves(RemoteProtocol.projectsV2Capability) else { return }
        if case .loaded = phase {} else { phase = .loading }
        do {
            var spaces: [ProjectSummary] = []
            var offset: Int? = 0
            while let next = offset, spaces.count < Self.mostSpaces {
                guard case .listing(let page) = try await client.projects(.list(offset: next)) else { break }
                spaces += page.projects
                offset = page.nextOffset
            }
            guard !Task.isCancelled else { return }
            phase = .loaded(spaces)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(settingsProblem(error))
        }
    }

    /// ponytail: a flat list stops here; page it on screen if a host ever keeps more.
    private static let mostSpaces = 512
}

/// One space: its path, the configuration files it holds, and whether its resources are approved.
struct SpaceScreen: View {
    let directory: String
    @Environment(MobileHosts.self) private var hosts
    @Environment(MobileNavigator.self) private var navigator
    @State private var files: [ProjectFile]?
    @State private var context: ProjectContext?
    @State private var trusted: Bool??
    @State private var problem: String?

    var body: some View {
        let store = SettingsStore.of(hosts)
        let host = store.settingsHost(chosenHost: navigator.settingsSelection.chosenHost)
        let sh = Color.sh
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text(directory)
                    .font(.sh(.mono))
                    .foregroundStyle(sh.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if let problem {
                    SettingsFootnote(problem, tone: .failed)
                } else if let files {
                    SettingsSection("Resources") {
                        SHListCard {
                            let resources = context?.resources ?? files.filter { $0.category == .skills || $0.category == .extensions }.count
                            let servers = context?.mcpServers ?? 0
                            SHListRow("Skills, extensions and MCP servers",
                                      subtitle: resources == 0 && servers == 0 ? "None" : "\(resources) resource\(resources == 1 ? "" : "s") · \(servers) MCP server\(servers == 1 ? "" : "s")",
                                      subtitleMono: false, chevron: false)
                            if let word = HostInventoryPresentation.trustWord(trusted ?? nil) {
                                SHListRow("Approval", subtitle: word, subtitleMono: false,
                                          subtitleTone: trusted == false ? .attention : nil,
                                          leading: .state(trusted == true ? .done : .attention), chevron: false)
                            }
                        }
                        SettingsFootnote("Executable resources load only once the space is approved on the Mac.")
                    }
                    ForEach(ProjectFile.Category.allCases, id: \.self) { category in
                        let held = files.filter { $0.category == category && $0.exists }
                        if !held.isEmpty {
                            SettingsSection(category.title) {
                                SHListCard {
                                    ForEach(held) { file in
                                        Text(file.path)
                                            .font(.sh(.mono))
                                            .foregroundStyle(sh.textPrimary)
                                            .lineLimit(2)
                                            .truncationMode(.middle)
                                            .padding(.horizontal, SH.Space.l)
                                            .frame(maxWidth: .infinity, minHeight: SHListMetrics.rowHeight, alignment: .leading)
                                    }
                                }
                            }
                        }
                    }
                    if let host {
                        SettingsFootnote(HostInventoryPresentation.spacesGuidance(host: host.name))
                    }
                } else {
                    ProgressView().progressViewStyle(SHSpinnerStyle()).frame(maxWidth: .infinity)
                }
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .background(Color.sh.bgWindow)
        .navigationTitle((directory as NSString).lastPathComponent)
        .navigationBarTitleDisplayMode(.inline)
        .task(id: host?.id) { await load(host) }
    }

    private func load(_ host: SettingsHost?) async {
        guard let host, let client = host.client as? RemoteHostClient else {
            problem = "The host is offline. Its spaces show once it's back."
            return
        }
        do {
            guard case .files(let inventory) = try await client.projects(.files(directory: directory)) else { return }
            files = inventory
            if host.serves(RemoteProtocol.projectDetailsCapability), case .context(let found) = try await client.projects(.context(directory: directory)) {
                context = found
            }
            if host.serves(RemoteProtocol.projectMCPCapability),
               let mcp = inventory.first(where: { $0.category == .mcp && $0.path.hasSuffix("/mcp.json") }),
               case .mcp(let result) = try await client.projects(.mcp(directory: directory, file: mcp.path, action: .credentials)) {
                trusted = .some(result.projectTrusted)
            }
        } catch {
            problem = settingsProblem(error)
        }
    }
}
