import SwiftUI
import ShepherdUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Settings ▸ Spaces edits folders on a paired host over projects.v2. These are not logical Projects. Organize renames, hides, reorders and
// removes them (`SpacesOrganizeScreen`).

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
        let host = store.settingsHost
        ScrollView {
            VStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                Text("The folders a host keeps as spaces, and what each one's .shepherd or .pi folder holds. Hidden spaces are listed too.")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, SH.Space.xs)
                if let host {
                    if !host.isConnected {
                        SettingsFootnote("\(host.name) is offline. Its spaces show here once it's back.")
                    } else if !host.serves(RemoteProtocol.projectsV2Capability) {
                        SettingsFootnote("\(host.name)'s Shepherd is too old to share its spaces. Update it to see them here.")
                    } else {
                        if host.serves(RemoteProtocol.spaceLifecycleCapability) {
                            SettingsCard {
                                Button { navigator.open(.settings(.organizeSpaces)) } label: {
                                    SettingsRow("Organize spaces", subtitle: "Rename, hide, reorder or remove", subtitleMono: false,
                                              leading: .symbol("arrow.up.arrow.down"))
                                }
                                .buttonStyle(.shRow(radius: 0))
                            }
                        }
                        switch phase {
                        case .loading:
                            SHBusyLabel("Reading the spaces…").frame(maxWidth: .infinity)
                        case .loaded(let spaces):
                            if spaces.isEmpty {
                                SettingsFootnote("No spaces on \(host.name) yet.")
                            } else {
                                SettingsCard {
                                    ForEach(spaces) { space in
                                        Button { navigator.open(.settings(.spaceConfiguration(host: host.id, directory: space.directory, name: space.name))) } label: {
                                            SettingsRow(space.name, subtitle: HostInventoryPresentation.spaceLine(space), subtitleMono: false,
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
                    SettingsFootnote("Add a host in Settings ▸ Fleet to see its spaces.")
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

/// Pin the host in the route: falling back to another Mac could edit an unrelated folder.
struct SpaceScreen: View {
    let hostID: UUID
    let directory: String
    let name: String
    let section: SpaceConfigurationSection?
    @Environment(MobileHosts.self) private var hosts
    @State private var model: ClientSpaceConfiguration?
    @State private var loaded = false

    var body: some View {
        let host = SettingsStore.of(hosts).hosts.first { $0.id == hostID }
        Group {
            // The route and its pushed editors outlive a connection. Keep their view identity.
            if let model {
                if let section, loaded, model.files != nil {
                    SpaceSectionScreen(model: model, name: name, section: section)
                } else {
                    SpaceOverview(model: model, name: name)
                }
            } else {
                VStack {
                    if host?.isConnected != true {
                        SHBanner(.attention, title: "Host offline", message: "Reconnect to edit this space.")
                    } else if host?.supports(.projectsV2) != true {
                        SettingsFootnote("Update Shepherd on the host to edit this space.")
                    } else {
                        SHBusyLabel("Loading…")
                    }
                }
                .padding(MobileLayout.gutter)
                .navigationTitle(name)
            }
        }
        .background(Color.sh.bgWindow)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.spaceSettingsConnection, .init(store: SettingsStore.of(hosts), hostID: hostID))
        .task(id: host?.isConnected == true ? host?.capabilities : nil) {
            guard let host, host.isConnected else { return }
            if let model {
                model.updateCapabilities(host.capabilities)
                if (!loaded || model.files == nil) && host.supports(.projectsV2) {
                    await model.load()
                    loaded = !Task.isCancelled
                }
                return
            }
            guard host.serves(RemoteProtocol.projectsV2Capability) else { return }
            let store = SettingsStore.of(hosts)
            let model = ClientSpaceConfiguration(directory: directory, capabilities: host.capabilities) { request in
                guard let client = store.hosts.first(where: { $0.id == hostID })?.client as? RemoteHostClient,
                      client.supports(.projectsV2) else {
                    throw ProjectFileError("offline", "Reconnect to this host to edit the space.")
                }
                return try await client.projects(request)
            }
            self.model = model
            await model.load()
            loaded = !Task.isCancelled
        }
    }
}

private struct SpaceSettingsConnection {
    let store: SettingsStore
    let hostID: UUID

    @MainActor var host: SettingsHost? { store.hosts.first { $0.id == hostID } }
}

private extension EnvironmentValues {
    @Entry var spaceSettingsConnection: SpaceSettingsConnection?
}

private struct SpaceOverview: View {
    let model: ClientSpaceConfiguration
    let name: String
    @Environment(\.spaceSettingsConnection) private var connection

    var body: some View {
        SpacePage(title: name, model: model) {
            Text(model.directory)
                .shText(.mono)
                .foregroundStyle(Color.sh.textSecondary)
                .textSelection(.enabled)
                .padding(.horizontal, SH.Space.xs)
            if let files = model.files {
                SettingsSection("Instructions") {
                    if let file = files[.instructions]?.first, model.drafts[file.path] != nil {
                        SpaceDraftCard(file: file.path, model: model, compact: true)
                    }
                    DisclosureGroup {
                        SpaceFileLinks(files: Array((files[.instructions] ?? []).dropFirst()), model: model)
                    } label: {
                        Text("Other instruction files").shText(.caption)
                    }
                    .tint(Color.sh.textSecondary)
                }
                if let settings = files[.pi] {
                    SettingsSection("Pi settings") { SpaceFileLinks(files: settings, model: model) }
                }
                SettingsSection("Skills and extensions") {
                    SettingsCard {
                        sectionLink(.skills, count: files[.skills]?.count ?? 0)
                        sectionLink(.extensions, count: files[.extensions]?.count ?? 0)
                        sectionLink(.mcp, count: model.context?.mcpServers)
                    }
                }
                if model.canManageResources {
                    SettingsSection("More resources") {
                        SettingsCard { sectionLink(.prompts); sectionLink(.agents) }
                    }
                }
            } else if model.busy {
                SHBusyLabel("Loading…").frame(maxWidth: .infinity)
            }
        }
        .refreshable { if connection?.host?.isConnected == true { await model.load() } }
    }

    private func sectionLink(_ section: SpaceConfigurationSection, count: Int? = nil) -> some View {
        NavigationLink {
            SpaceSectionScreen(model: model, name: name, section: section)
                .environment(\.spaceSettingsConnection, connection)
        } label: {
            SettingsNavRow(section.title, note: count.map { $0 == 0 ? "None" : "\($0) in this space" })
        }
        .buttonStyle(.shRow(radius: 0))
        .disabled(model.busy)
    }
}

private struct SpacePage<Content: View>: View {
    let title: String
    let model: ClientSpaceConfiguration
    @ViewBuilder let content: () -> Content
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: MobileLayout.sectionSpacing) {
                if host?.isConnected != true {
                    SHBanner(.attention, title: "Host offline", message: "Reconnect to save changes.")
                } else if !model.canEdit {
                    SHBanner(.attention, title: "Update Shepherd on the host to edit this space.")
                } else if let problem = model.problem {
                    SHBanner(.failed, title: problem)
                }
                content()
            }
            .padding(.horizontal, MobileLayout.gutter)
            .padding(.bottom, MobileLayout.sectionSpacing)
            .frame(maxWidth: MobileLayout.homeMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Color.sh.bgWindow)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SpaceFileLinks: View {
    let files: [ProjectFile]
    let model: ClientSpaceConfiguration
    @Environment(\.spaceSettingsConnection) private var connection

    var body: some View {
        SettingsLazyCard(files) { file in
            NavigationLink {
                SpaceFileScreen(file: file.path, model: model)
                    .environment(\.spaceSettingsConnection, connection)
            } label: {
                SettingsNavRow((file.path as NSString).lastPathComponent,
                               note: file.exists ? file.path : "\(file.path) · Not created", value: "Edit")
            }
            .buttonStyle(.shRow(radius: 0))
            .disabled(model.busy)
        }
    }
}

private struct SpaceDraftCard: View {
    let file: String
    let model: ClientSpaceConfiguration
    var compact = false
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }
    @State private var focus = InstructionsEditorFocus()
    @State private var reload = false

    var body: some View {
        if let draft = model.drafts[file] {
            SettingsCard {
                HStack(spacing: SH.Space.m) {
                    Text((file as NSString).lastPathComponent)
                        .shText(.code)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if draft.conflict {
                        Button("Reload…") { reload = true }
                            .buttonStyle(.settingsPill)
                            .disabled(host?.isConnected != true || !model.canEdit || model.busy)
                    } else {
                        Button("Save") { Task { await model.save(file) } }
                            .buttonStyle(.settingsPrimary)
                            .disabled(host?.isConnected != true || !model.canEdit || !draft.isEdited || model.busy)
                    }
                }
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.touch)
                InstructionsTextEditor(text: Binding(get: { model.drafts[file]?.text ?? "" }, set: { model.setText($0, file: file) }),
                                       saved: draft.saved.text ?? "", metrics: .phone, focus: focus, accessibilityLabel: file)
                    .frame(height: compact ? MobileLayout.spaceInlineEditorHeight : MobileLayout.instructionsEditorMinHeight)
            }
            .confirmationDialog("Reload the host's version?", isPresented: $reload, titleVisibility: .visible) {
                Button("Discard edits and reload", role: .destructive) { Task { await model.open(file, discard: true) } }
            } message: { Text("Any unsaved edits in this editor will be lost.") }
        } else if model.busy {
            SHBusyLabel("Loading…").frame(maxWidth: .infinity)
        }
    }
}

private struct SpaceFileScreen: View {
    let file: String
    let model: ClientSpaceConfiguration
    var resource: ProjectResource? = nil
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }
    @Environment(\.dismiss) private var dismiss
    @State private var deleting = false

    var body: some View {
        SpacePage(title: (file as NSString).lastPathComponent, model: model) {
            SettingsFootnote(file)
            SpaceDraftCard(file: file, model: model)
            if let resource, model.canManageResources, let draft = model.drafts[file], draft.saved.text != nil {
                Button("Delete file…", role: .destructive) { deleting = true }
                    .buttonStyle(.settingsPill)
                    .disabled(host?.isConnected != true || model.busy || draft.isEdited || draft.conflict)
                    .confirmationDialog("Delete \(resource.name)?", isPresented: $deleting, titleVisibility: .visible) {
                        Button("Delete file", role: .destructive) {
                            Task { if await model.delete(resource) { dismiss() } }
                        }
                    } message: { Text("This removes the file from the space on its host.") }
            }
        }
        .task(id: host?.isConnected == true) {
            if host?.isConnected == true { await model.open(file) }
        }
    }
}

private struct SpaceSectionScreen: View {
    let model: ClientSpaceConfiguration
    let name: String
    let section: SpaceConfigurationSection
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }
    @State private var install = false

    var body: some View {
        SpacePage(title: section.title, model: model) {
            if let kind = section.resourceKind {
                SpaceResources(model: model, kind: kind)
            } else {
                SpaceMCP(model: model)
            }
            if model.busy { SHBusyLabel("Loading…").frame(maxWidth: .infinity) }
        }
        .task(id: host?.isConnected == true) { await load() }
        .refreshable { await load() }
        .toolbar {
            if section == .skills, model.canManageResources {
                Button("Add from repo") { install = true }.disabled(host?.isConnected != true || model.busy)
            }
        }
        .sheet(isPresented: $install) {
            SpaceSkillInstall(model: model, name: name)
                .environment(\.spaceSettingsConnection, connection)
        }
    }

    private func load() async {
        guard host?.isConnected == true else { return }
        if section == .mcp { await model.loadMCP() } else { await model.loadResources() }
    }
}

private extension SpaceConfigurationSection {
    var resourceKind: ProjectResource.Kind? {
        switch self {
        case .skills: .skill
        case .extensions: .extension
        case .prompts: .prompt
        case .agents: .agent
        case .mcp: nil
        }
    }
}

private struct SpaceResources: View {
    let model: ClientSpaceConfiguration
    let kind: ProjectResource.Kind
    @Environment(\.spaceSettingsConnection) private var connection

    var body: some View {
        if model.canManageResources {
            if let resources = model.resources[kind], !resources.isEmpty {
                SettingsLazyCard(resources) { resource in
                    if resource.global {
                        SettingsRow(resource.name, subtitle: resource.description, subtitleMono: false, trailing: .value("Global"))
                    } else {
                        NavigationLink {
                            SpaceFileScreen(file: resource.path, model: model, resource: resource)
                                .environment(\.spaceSettingsConnection, connection)
                        } label: {
                            SettingsNavRow(resource.name, note: resource.description.isEmpty ? resource.path : resource.description)
                        }
                        .buttonStyle(.shRow(radius: 0))
                        .disabled(model.busy)
                    }
                }
            } else if !model.busy {
                SettingsFootnote("None in this space.")
            }
            if let inherited = model.inheritedResources[kind], !inherited.isEmpty {
                SettingsSection(inheritanceTitle(model)) {
                    SettingsLazyCard(inherited) { resource in
                        SpaceInheritedRow(model: model, kind: inheritanceKind, name: resource.name, note: resource.description)
                    }
                }
            }
        } else {
            SpaceFileLinks(files: model.files?[kind == .skill ? .skills : .extensions] ?? [], model: model)
            SettingsFootnote("Update Shepherd on the host to install or delete space resources.")
        }
    }

    private var inheritanceKind: ClientSpaceConfiguration.Inherited {
        switch kind {
        case .prompt: .prompt
        case .extension: .extension
        default: .skill
        }
    }
}

@MainActor private func inheritanceTitle(_ model: ClientSpaceConfiguration) -> String {
    "Inherited from \(((model.context?.inheritsFrom ?? "") as NSString).lastPathComponent)"
}

private struct SpaceInheritedRow: View {
    let model: ClientSpaceConfiguration
    let kind: ClientSpaceConfiguration.Inherited
    let name: String
    let note: String?
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }

    var body: some View {
        let on = model.inherits(kind, name)
        HStack(spacing: SH.Space.m) {
            SettingsRow(name, subtitle: note, subtitleMono: false, chevron: false)
            if model.canSetInheritance(kind) {
                Toggle(name, isOn: Binding(get: { on }, set: { value in Task { await model.setInherited(kind, name, on: value) } }))
                    .labelsHidden()
                    .toggleStyle(.settingsSwitch)
                    .disabled(host?.isConnected != true || model.busy)
                    .padding(.trailing, SH.Space.l)
            } else {
                Text(on ? "Enabled" : "Disabled")
                    .shText(.caption)
                    .foregroundStyle(Color.sh.textSecondary)
                    .padding(.trailing, SH.Space.l)
            }
        }
    }
}

private struct SpaceMCP: View {
    let model: ClientSpaceConfiguration
    @Environment(\.spaceSettingsConnection) private var connection
    @State private var browser = MobileMCPBrowser()
    @State private var active: ClientSpaceConfiguration.Server.ID?
    @State private var authTask: Task<Void, Never>?
    @State private var problem: String?
    private var host: SettingsHost? { connection?.host }

    var body: some View {
        if !model.inheritedServers.isEmpty {
            SettingsSection(inheritanceTitle(model)) {
                SettingsLazyCard(model.inheritedServers) { server in
                    SpaceInheritedRow(model: model, kind: .mcp, name: server.name, note: server.endpoint)
                }
            }
        }
        SettingsSection("Defined here") {
            SettingsLazyCard(model.servers) { server in
                let signedIn = model.signedIn[server.file]?.contains(server.name) == true
                let signingIn = active == server.id
                let status = host?.isConnected == true ? "Signing in…" : "Waiting for host…"
                HStack(spacing: SH.Space.m) {
                    SettingsRow(server.name, subtitle: signingIn ? status : server.endpoint, subtitleMono: !signingIn, chevron: false)
                    if signingIn {
                        Button("Cancel") { authTask?.cancel() }
                            .buttonStyle(.settingsPill)
                            .padding(.trailing, SH.Space.l)
                    } else if model.canUseMCP, server.usesOAuth {
                        Button(signedIn ? "Sign out" : "Sign in") {
                            if signedIn { Task { await model.signOut(server) } }
                            else { signIn(server) }
                        }
                        .buttonStyle(.settingsPill)
                        .disabled(host?.isConnected != true || model.busy || model.drafts[server.file]?.isEdited == true || (!signedIn && active != nil))
                        .padding(.trailing, SH.Space.l)
                    }
                }
            }
            SpaceFileLinks(files: model.files?[.mcp] ?? [], model: model)
            if let problem { SettingsFootnote(problem, tone: .failed) }
            SettingsFootnote(model.canUseMCP ? "Credentials stay on the host." : "Sign in on the host. Credentials stay there.")
        }
        .background { MobileMCPBrowserAnchor(browser: browser).allowsHitTesting(false) }
    }

    private func signIn(_ server: ClientSpaceConfiguration.Server) {
        guard active == nil else { return }
        active = server.id
        problem = nil
        // Leaving the view doesn't cancel an active sheet. Requests still use the route's pinned host.
        authTask = Task {
            defer { active = nil; authTask = nil }
            do { try await model.signIn(server, authorize: browser.authorize) }
            catch is CancellationError {}
            catch {
                problem = (error as? ProjectFileError)?.description ?? (error as? MCPCallbackError)?.description
                    ?? (error as? LocalizedError)?.errorDescription ?? settingsProblem(error)
            }
        }
    }
}

private struct SpaceSkillInstall: View {
    let model: ClientSpaceConfiguration
    let name: String
    @Environment(\.spaceSettingsConnection) private var connection
    private var host: SettingsHost? { connection?.host }
    @Environment(\.dismiss) private var dismiss
    @State private var repo = ""
    @State private var revision = ""
    @State private var paths = ""
    @State private var found: RepoSkills?
    @State private var picked: Set<String> = []
    @State private var lookingUp = false
    @State private var problem: String?

    var body: some View {
        NavigationStack {
            SpacePage(title: "Add skills to \(name)", model: model) {
                SpaceInput(label: "Repository URL", placeholder: "https://github.com/owner/skills", text: $repo)
                SpaceInput(label: "Revision", placeholder: "Branch or commit", text: $revision)
                if revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, host?.supports(.skills) == true {
                    Button("Preview skills") { Task { await preview() } }
                        .buttonStyle(.settingsPill)
                        .disabled(host?.isConnected != true || repo.isEmpty || lookingUp || model.busy)
                    if lookingUp { SHBusyLabel("Looking up…") }
                    if let found {
                        SettingsLazyCard(found.skills) { skill in
                            Toggle(skill.name, isOn: Binding(get: { picked.contains(skill.path) }, set: { _ in picked.formSymmetricDifference([skill.path]) }))
                                .toggleStyle(.settingsSwitch)
                                .padding(SH.Space.l)
                        }
                    }
                }
                if found == nil {
                    SpaceInput(label: "Skill folders", placeholder: "skills/review, skills/docs", text: $paths)
                    SettingsFootnote("Enter repository-relative folders separated by commas. Preview is available for the default branch only.")
                }
                if let problem { SettingsFootnote(problem, tone: .failed) }
                SettingsFootnote("Destination · \(model.directory)/.pi/skills")
                SettingsFootnote("Global Skills stays unchanged.")
                Button(selectedPaths.count == 1 ? "Add 1 skill" : "Add \(selectedPaths.count) skills") { Task { await install() } }
                    .buttonStyle(.settingsPrimary)
                    .disabled(host?.isConnected != true || !model.canManageResources || repo.isEmpty || selectedPaths.isEmpty || lookingUp || model.busy)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(model.busy) }
            }
            .interactiveDismissDisabled(model.busy)
            .onChange(of: repo) { clearPreview() }
            .onChange(of: revision) { clearPreview() }
        }
    }

    private var selectedPaths: [String] {
        if found != nil { return picked.sorted() }
        return paths.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private func preview() async {
        guard let client = host?.client as? RemoteHostClient, !lookingUp else { return }
        lookingUp = true
        defer { lookingUp = false }
        let input = repo
        do {
            guard case .repo(let result) = try await client.skills(.lookUp(repo: input)), input == repo,
                  revision.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            found = result.skills.isEmpty ? nil : result
            picked = []
            problem = result.skills.isEmpty ? "No skills found on the default branch." : nil
        } catch { if input == repo { problem = settingsProblem(error) } }
    }

    private func clearPreview() { found = nil; picked = []; problem = nil }

    private func install() async {
        let ref = revision.trimmingCharacters(in: .whitespacesAndNewlines)
        if await model.installSkills(repo: repo, paths: selectedPaths, commit: ref.isEmpty ? found?.commit : ref) { dismiss() }
    }
}

private struct SpaceInput: View {
    let label: String
    let placeholder: String
    @Binding var text: String

    var body: some View {
        SettingsSection(label) {
            TextField(placeholder, text: $text)
                .shText(.code)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .padding(.horizontal, SH.Space.l)
                .frame(minHeight: SH.Height.touch)
                .shCard()
                .accessibilityLabel(label)
        }
    }
}
