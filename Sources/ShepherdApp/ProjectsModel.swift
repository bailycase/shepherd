import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

struct ProjectsHost: Equatable, Identifiable {
    var id: String
    var name: String
    var endpointID: UUID?
    var supportsDetails = true
    var supportsMCP = true
    var supportsProjectTrust = true
    var unavailable: String?
    var known: [ProjectSummary]
}

struct ProjectsRow: Equatable, Identifiable {
    var host: ProjectsHost
    var project: ProjectSummary
    /// Its subprojects on the same host, shown under it (a top-level row only).
    var children = 0
    var sharesConfigurationWithChildren = false
    /// Its parent's name, for "From <parent>" (a subproject only).
    var parentName: String?
    var ancestorIDs: [String] = []
    var id: String { host.id + "\n" + project.directory }
    var unavailable: String? { host.unavailable ?? project.error }
    var isSubproject: Bool { parentName != nil }

    /// The board's CONFIGURATION line: a parent's "2 shared MCP servers", a subproject's
    /// "2 inherited · 1 local MCP" (its own servers counted apart), else the host's summary.
    var configuration: String {
        let own = project.mcpServers.count, inherited = project.inheritedMCP.count
        if inherited > 0 {
            return own > 0 ? "\(inherited) inherited · \(own) local MCP" : "\(inherited) inherited MCP \(inherited == 1 ? "server" : "servers")"
        }
        if sharesConfigurationWithChildren, own > 0 { return "\(own) shared MCP \(own == 1 ? "server" : "servers")" }
        return project.summary
    }

    /// Top-level projects in the host's order, each followed by its subprojects, by folder.
    static func tree(_ rows: [ProjectsRow]) -> [ProjectsRow] {
        let byKey = Dictionary(rows.map { ($0.host.id + "\n" + $0.project.directory, $0) }, uniquingKeysWith: { first, _ in first })
        func parentKey(_ row: ProjectsRow) -> String? {
            row.project.parent.map { row.host.id + "\n" + $0 }.flatMap { byKey[$0] == nil ? nil : $0 }
        }
        let children = Dictionary(grouping: rows.filter { parentKey($0) != nil }, by: { parentKey($0)! })
        func branch(_ row: ProjectsRow, ancestors: [String], parentName: String?) -> [ProjectsRow] {
            var row = row
            row.ancestorIDs = ancestors
            row.parentName = parentName
            let kids = (children[row.id] ?? []).filter { !ancestors.contains($0.id) }.flatMap {
                branch($0, ancestors: ancestors + [row.id], parentName: row.project.name)
            }
            row.children = kids.count
            row.sharesConfigurationWithChildren = kids.contains { ProjectNesting.parent(of: $0.project.directory, among: [row.project.directory]) != nil }
            return [row] + kids
        }
        return rows.filter { parentKey($0) == nil }.flatMap { branch($0, ancestors: [], parentName: nil) }
    }
}

@MainActor
@Observable
final class ProjectsModel {
    typealias Request = @MainActor (ProjectsHost, RemoteProjectsRequest) async throws -> RemoteProjectsResult
    @ObservationIgnored let request: Request
    @ObservationIgnored var openMCPURL: @MainActor (URL) -> Void = { NSWorkspace.shared.open($0) }
    @ObservationIgnored var copyMCPLink: @MainActor (String) -> Void = {
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString($0, forType: .string)
    }
    var mcpSignIn: MCPSignInFlow?
    @ObservationIgnored var mcpSignOut: Task<Void, Never>?
    var mcpSignedIn: Set<String> = []
    var mcpProjectTrusted: Bool?
    var mcpTrustError: String?
    var mcpTrustChecking = false
    var mcpTrustSaving = false
    @ObservationIgnored var mcpTrustRequestID = UUID()
    private(set) var hosts: [ProjectsHost] = []
    private(set) var rows: [ProjectsRow] = []
    private(set) var visible: [ProjectsRow] = []
    /// Parents whose subprojects are folded away, by row id.
    var collapsed: Set<String> = [] { didSet { if collapsed != oldValue { derive() } } }
    var filter = "" { didSet { derive() } }
    var host = "all" { didSet { derive() } }
    private(set) var loading = false
    var error: String?
    var selected: ProjectsRow?
    private(set) var files: [ProjectFile] = []
    var category: ProjectFile.Category = .instructions
    var showingBrowser = false
    var selectedFile: ProjectFile?
    var savedNotice: String {
        if category == .mcp { return "Saved to the project folder. MCP changes apply to new threads." }
        if selectedFile?.path == ".shepherd/settings.json" {
            return selectedFile?.exists == true
                ? "Saved to the project folder. Start or restart the agent to apply Pi settings."
                : "Save project settings, then start or restart the agent to apply them."
        }
        return "Saved to the project folder. It takes effect in new turns."
    }
    var draft = "" { didSet {
        tokenText = InstructionsText.sizeNote(draft)
        deriveCodemode()
        if category == .mcp { deriveMCP() }
    } }
    enum CodemodeChoice: String { case inherit, on, off }
    private(set) var codemodeChoice: CodemodeChoice = .inherit
    private(set) var codemodeProblem: String?
    var projectCodemode: CodemodeChoice {
        get { codemodeChoice }
        set {
            guard fileLoaded, selectedFile?.path == ".shepherd/settings.json", selected?.unavailable == nil, !saving else { return }
            do {
                let settings = try codemodeSettings()
                let enabled: Bool? = newValue == .inherit ? nil : newValue == .on
                let updated = try PiCodemode.setting(enabled, in: settings)
                let data = try JSONSerialization.data(withJSONObject: updated, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
                draft = String(decoding: data, as: UTF8.self) + "\n"
            } catch { codemodeProblem = String(describing: error) }
        }
    }

    private func codemodeSettings() throws -> [String: Any] {
        if draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, selectedFile?.exists == false { return [:] }
        guard let settings = try JSONSerialization.jsonObject(with: Data(draft.utf8)) as? [String: Any] else {
            throw ProjectFileError("invalid_json", "Pi settings must be a JSON object.")
        }
        return settings
    }

    private func deriveCodemode() {
        guard selectedFile?.path == ".shepherd/settings.json" else { codemodeChoice = .inherit; codemodeProblem = nil; return }
        do {
            let settings = try codemodeSettings()
            _ = try PiCodemode.setting(nil, in: settings)
            codemodeChoice = PiCodemode.projectOverride(in: settings).map { $0 ? .on : .off } ?? .inherit
            codemodeProblem = nil
        } catch {
            codemodeProblem = "Fix the JSON and codemode settings below before using this control."
        }
    }
    private(set) var mcp = ProjectMCPConfiguration()

    func deriveMCP() {
        mcp = ProjectMCPConfiguration(text: draft, path: selectedFile?.path ?? ".shepherd/mcp.json", host: selected?.host.name ?? "This Mac",
                                      signedIn: mcpSignedIn, canSignIn: selected?.host.supportsMCP == true, projectTrusted: mcpProjectTrusted)
    }
    private(set) var tokenText = "empty"
    private(set) var modifiedAt: Double?
    private(set) var context = ProjectContext()
    struct ReadRow: Equatable, Identifiable {
        var id: String; var label: String; var scope: String; var selected: Bool
    }
    private(set) var readRows: [ReadRow] = []
    struct Peer: Equatable, Identifiable {
        var id: String; var host: String; var note: String; var status: String; var tone: InstructionsChip.Tone
    }
    private(set) var peers: [Peer] = []
    private(set) var openingEditor = false
    private(set) var saved: String?
    private(set) var fileLoaded = false
    private(set) var fileLoading = false
    private(set) var saving = false
    var fileError: String?
    var notice: String?
    enum Pending: Equatable { case close, file(ProjectFile), category(ProjectFile.Category), browser }
    var pending: Pending?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var loadInFlight = false
    @ObservationIgnored private var loadedHosts: [ProjectsHost]?

    init(request: @escaping Request) { self.request = request }
    var dirty: Bool { fileLoaded && draft != (saved ?? "") }
    var selectedFiles: [ProjectFile] {
        files.filter { $0.category == category || (category == .extensions || category == .skills) && ($0.category == .skills || $0.category == .extensions) }
    }
    var hostOptions: [(String, String)] { [("all", "All hosts")] + hosts.map { ($0.id, $0.name) } }
    var addHost: ProjectsHost? { hosts.first { $0.id == (host == "all" ? "local" : host) } }

    /// The tree, filtered: a subproject that matches keeps its parent above it, and a parent that
    /// matches keeps its subprojects. A collapsed parent's subprojects stay folded unless a filter
    /// matched them.
    private func derive() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        func matches(_ row: ProjectsRow) -> Bool {
            query.isEmpty || [row.project.name, row.project.directory, row.project.displayPath, row.host.name].contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
        let tree = ProjectsRow.tree(rows.filter { host == "all" || $0.host.id == host })
        let matching = tree.filter(matches)
        let matchingIDs = Set(matching.map(\.id))
        let ancestors = Set(matching.flatMap(\.ancestorIDs))
        let next = tree.filter { row in
            let included = matchingIDs.contains(row.id) || ancestors.contains(row.id) || row.ancestorIDs.contains { matchingIDs.contains($0) }
            return included && (!query.isEmpty || !row.ancestorIDs.contains { collapsed.contains($0) })
        }
        if visible != next { visible = next }
    }

    /// Projects counted the board's way: every project the hosts list, subprojects included.
    var countText: String { rows.count == 1 ? "1 project" : "\(rows.count) projects" }

    @discardableResult
    func load(_ sources: [ProjectsHost], force: Bool = false) async -> Bool {
        guard force || loadedHosts != sources else { return true }
        // A Settings .task caused by adoption must not supersede the tool's identical reload.
        guard force || !loadInFlight || hosts != sources else { return false }
        loadGeneration += 1
        let revision = loadGeneration
        loadInFlight = true
        defer { if revision == loadGeneration { loadInFlight = false } }
        hosts = sources
        if host != "all", !sources.contains(where: { $0.id == host }) { host = "all" }
        loading = rows.isEmpty; error = nil
        var next: [ProjectsRow] = []
        for source in sources {
            var source = source, projects = source.known
            if source.unavailable == nil {
                do {
                    var offset = 0, pages = 0
                    projects = []
                    repeat {
                        guard revision == loadGeneration else { return false }
                        guard !Task.isCancelled else { loading = false; return false }
                        guard case .listing(let page) = try await request(source, .list(offset: offset)) else {
                            throw ProjectFileError("protocol", "Unexpected project listing.")
                        }
                        guard revision == loadGeneration, !Task.isCancelled else { return false }
                        projects += page.projects
                        pages += 1
                        guard let next = page.nextOffset else { break }
                        guard next > offset, pages < 1000 else { throw ProjectFileError("too_many", "Project listing exceeded its page limit.") }
                        offset = next
                    } while true
                } catch {
                    guard revision == loadGeneration else { return false }
                    source.unavailable = String(describing: error)
                    projects = rows.filter { $0.host.id == source.id && $0.host.endpointID == source.endpointID }.map(\.project)
                    if projects.isEmpty { projects = source.known }
                    if source.id == "local" { self.error = String(describing: error) }
                }
            } else {
                let previous = rows.filter { $0.host.id == source.id && $0.host.endpointID == source.endpointID }.map(\.project)
                if !previous.isEmpty { projects = previous }
            }
            next += projects.map { ProjectsRow(host: source, project: $0) }
        }
        guard revision == loadGeneration else { return false }
        guard !Task.isCancelled else { loading = false; return false }
        rows = next; loading = false; loadedHosts = sources; derive()
        if let selected, let current = rows.first(where: { $0.id == selected.id }) {
            if current.host.endpointID == selected.host.endpointID { self.selected = current }
            else {
                var invalid = selected
                invalid.host.unavailable = "Host changed. Reopen this project before editing it."
                self.selected = invalid
            }
        }
        if self.selected?.unavailable != nil || self.selected?.host.supportsMCP == false { closeMCPSignIn() }
        return true
    }

    func open(_ row: ProjectsRow) async {
        closeMCPSignIn()
        mcpSignedIn = []
        mcpProjectTrusted = nil; mcpTrustError = nil
        mcpTrustRequestID = UUID(); mcpTrustChecking = false
        guard row.unavailable == nil else { error = row.unavailable; return }
        generation += 1
        let token = generation
        showingBrowser = false
        selected = row; fileError = nil; notice = nil; fileLoading = true
        category = .instructions; files = []; selectedFile = nil; fileLoaded = false
        context = ProjectContext(); readRows = []; peers = []
        do {
            guard case .files(let files) = try await request(row.host, .files(directory: row.project.directory)) else { throw ProjectFileError("protocol", "Unexpected project files reply.") }
            guard token == generation, selected?.id == row.id else { return }
            self.files = files
            if case .context(let context) = try? await request(row.host, .context(directory: row.project.directory)), token == generation { self.context = context }
            guard token == generation, selected?.id == row.id else { return }
            if let file = selectedFiles.first { await read(file) } else { fileLoading = false }
        } catch { if token == generation { fileError = String(describing: error); fileLoading = false } }
    }

    func navigate(_ action: Pending) async {
        guard !saving else { return }
        if dirty { pending = action } else { await apply(action) }
    }

    func discard() async {
        guard !saving else { return }
        guard let action = pending else { return }
        pending = nil
        await apply(action)
    }

    private func apply(_ action: Pending) async {
        closeMCPSignIn()
        switch action {
        case .close:
            showingBrowser = false; generation += 1; selected = nil; selectedFile = nil; files = []; fileLoaded = false; fileError = nil
        case .file(let file): showingBrowser = false; await read(file)
        case .category(let category):
            showingBrowser = false; self.category = category; selectedFile = nil; fileLoaded = false; fileError = nil; notice = nil
            if let file = selectedFiles.first { await read(file) }
        case .browser:
            showingBrowser = true; draft = saved ?? ""
        }
    }

    func read(_ file: ProjectFile) async {
        closeMCPSignIn()
        mcpSignedIn = []
        mcpProjectTrusted = nil; mcpTrustError = nil
        mcpTrustRequestID = UUID(); mcpTrustChecking = false
        guard let selected, selected.unavailable == nil else { return }
        generation += 1
        let token = generation
        selectedFile = file; fileLoaded = false; fileLoading = true; fileError = nil; notice = nil
        do {
            guard case .text(let value) = try await request(selected.host, .read(directory: selected.project.directory, file: file.path)) else { throw ProjectFileError("protocol", "Unexpected project file reply.") }
            guard token == generation else { return }
            selectedFile = value.file; saved = value.text; draft = value.text ?? ""; modifiedAt = value.modifiedAt; fileLoaded = true
            if category == .mcp {
                deriveMCP()
                fileLoading = false // Credential metadata must not hold an already-loaded file's controls disabled.
                await refreshMCPCredentials()
                guard token == generation else { return }
            }
            deriveReadRows()
            await compareHosts(token: token, text: value.text, file: file, selected: selected)
        } catch { if token == generation { fileError = String(describing: error) } }
        if token == generation { fileLoading = false }
    }

    func openInEditor() async {
        guard !openingEditor, let selected, selected.host.supportsDetails, selected.unavailable == nil, let file = selectedFile, file.exists else { return }
        openingEditor = true
        defer { openingEditor = false }
        do { _ = try await request(selected.host, .open(directory: selected.project.directory, file: file.path)) }
        catch { fileError = String(describing: error) }
    }

    var language: String {
        switch (selectedFile?.path as NSString?)?.pathExtension {
        case "json": "JSON"
        case "ts": "TypeScript"
        case "js", "mjs", "cjs": "JavaScript"
        default: "Markdown"
        }
    }

    var editedLabel: String {
        if dirty { return "Unsaved changes" }
        guard let modifiedAt else { return "Not saved yet" }
        let hours = Int(Date().timeIntervalSince1970 - modifiedAt) / 3_600
        let days = hours / 24
        return days > 0 ? "Edited by hand \(days) \(days == 1 ? "day" : "days") ago" : hours > 0 ? "Edited by hand \(hours) \(hours == 1 ? "hour" : "hours") ago" : "Edited by hand \(InstructionsPresentation.age(modifiedAt))"
    }

    var fileDisplayPath: String {
        guard let selected, let selectedFile else { return "" }
        return selected.project.displayPath + "/" + selectedFile.path
    }

    private func deriveReadRows() {
        guard let selected else { readRows = []; return }
        let folder = selected.project.directory + "/"
        let selectedPath = selectedFile.map { folder + $0.path }
        readRows = [ReadRow(id: "global", label: "Your instructions", scope: "all projects", selected: false)] + context.files.filter { $0.isGlobal != true }.map { file in
            let current = file.path.hasPrefix(folder)
            let label = current ? selected.project.name + "/" + URL(fileURLWithPath: file.path).lastPathComponent : file.displayPath
            return ReadRow(id: file.path, label: label, scope: file.path == selectedPath ? "this file" : current ? "project" : "parent", selected: file.path == selectedPath)
        }
    }

    private func compareHosts(token: Int, text: String?, file: ProjectFile, selected: ProjectsRow) async {
        var peers: [Peer] = []
        var seen = Set<String>()
        for row in rows where row.host.id != selected.host.id && row.project.name == selected.project.name {
            guard seen.count < 8, seen.insert(row.host.id).inserted else { continue }
            var peer = Peer(id: row.id, host: row.host.name, note: "This is the copy on \(selected.host.name). \(row.host.name) has its own checkout of \(selected.project.name).", status: "Not compared", tone: .quiet)
            if row.unavailable != nil { peer.status = "Host unavailable" }
            else {
                do {
                    if case .text(let other) = try await request(row.host, .read(directory: row.project.directory, file: file.path)) {
                        let name = URL(fileURLWithPath: file.path).lastPathComponent
                        let matches = other.text == text && text != nil
                        peer.note = "This is the copy on \(selected.host.name). \(row.host.name) has its own checkout of \(selected.project.name), and its \(name) \(matches ? "matches." : "differs.")"
                        peer.status = matches ? "In sync" : "Differs"; peer.tone = matches ? .done : .attention
                    }
                } catch { peer.status = "Could not compare" }
            }
            guard token == generation else { return }
            peers.append(peer)
        }
        if token == generation { self.peers = peers }
    }

    func save() async {
        guard fileLoaded, !saving, let selected, selected.unavailable == nil, let file = selectedFile else { return }
        saving = true; fileError = nil; notice = nil
        let token = generation, text = draft
        do {
            guard case .text(let value) = try await request(selected.host, .save(directory: selected.project.directory, file: file.path, text: text, expected: saved)) else { throw ProjectFileError("protocol", "Unexpected project save reply.") }
            guard token == generation else { saving = false; return }
            saved = value.text; selectedFile = value.file; modifiedAt = value.modifiedAt
            notice = savedNotice
            await load(hosts, force: true)
            if case .context(let context) = try? await request(selected.host, .context(directory: selected.project.directory)), token == generation { self.context = context; deriveReadRows() }
            await compareHosts(token: token, text: value.text, file: file, selected: selected)
            if category == .mcp, token == generation { await refreshMCPCredentials() }
        } catch { if token == generation { fileError = String(describing: error) } }
        saving = false
    }
}

extension ShepherdViewModel {
    var projectsSources: [ProjectsHost] {
        func known(_ state: ShepherdState, reason: String?) -> [ProjectSummary] {
            var seen = Set<String>()
            let parents = ProjectNesting.parents(in: state.spaces)
            let spaces = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id, $0) })
            return ProjectSettingsStore.directories(in: state).compactMap { directory, name in
                guard seen.insert(directory).inserted else { return nil }
                let space = state.spaces.first { $0.path == directory }
                let parent = space.flatMap { parents[$0.id] }.flatMap { spaces[$0]?.path }
                return ProjectSummary(directory: directory, name: name, displayPath: directory, summary: reason ?? "loading project settings", minimal: true,
                                      projectID: space?.id, parent: parent)
            }
        }
        return [ProjectsHost(id: "local", name: "This Mac", known: known(state, reason: nil))] + remoteHosts.connections.map { connection in
            let reason: String? = connection.phase == .connected
                ? connection.supportsProjects ? nil : "Update Shepherd on this host to edit project settings."
                : "Host offline. Reconnect in Settings > Remote to edit its projects."
            return ProjectsHost(id: connection.id.uuidString, name: connection.config.name, endpointID: connection.endpointID, supportsDetails: connection.supportsProjectDetails, supportsMCP: connection.supportsProjectMCP, supportsProjectTrust: connection.supportsProjectTrust, unavailable: reason, known: known(connection.state, reason: reason))
        }
    }

    var projects: ProjectsModel {
        if let madeProjects { return madeProjects }
        let model = ProjectsModel { [weak self] host, request in
            guard let self else { throw ProjectFileError("unavailable", "Shepherd is closing.") }
            if host.id == "local" { return try await self.server.projects.request(request, state: self.server.state) }
            guard let id = UUID(uuidString: host.id) else { throw ProjectFileError("invalid", "Unknown project host.") }
            return try await self.remoteHosts.projects(hostID: id, endpointID: host.endpointID, request: request)
        }
        madeProjects = model
        return model
    }

    func childProjectModel(path: String, name: String) -> ChildProjectModel {
        ChildProjectModel(parentPath: path, parentName: name) { [weak self] request in
            guard let self else { throw ProjectFileError("unavailable", "Shepherd is closing.") }
            _ = try await self.handleProjectRequest(request)
        }
    }

    func installProjectControl() {
        server.onProjectRequest = { [weak self] request, respond in
            MainActor.assumeIsolated {
                _ = Task<Void, Never> { @MainActor in
                    guard let self else {
                        respond(.failure(ProjectFileError("unavailable", "Shepherd is closing.")))
                        return
                    }
                    do { respond(.success(try await self.handleProjectRequest(request))) }
                    catch let error as ProjectFileError { respond(.failure(error)) }
                    catch { respond(.failure(ProjectFileError("failed", String(describing: error)))) }
                }
            }
        }
    }

    func handleProjectRequest(_ request: ProjectRequest) async throws -> (space: Space?, created: Bool) {
        let result: (space: Space?, created: Bool)
        var revealHierarchy = false
        switch request {
        case .register(let path, let name):
            let registered = try await server.registerProject(path: path, name: name)
            result = (registered.space, registered.created)
        case .refresh:
            result = (nil, false)
        case .edit(let id, let request):
            result = (try await server.editProject(id, edit: request), request.folderAction == .copy)
            revealHierarchy = request.parentProjectID != nil
        case .delete(let id):
            guard let space = server.state.spaces.first(where: { $0.id == id && !$0.hidden }) else {
                throw ProjectFileError("no_such_project", "No registered local project has that ID.")
            }
            guard spaceDeleteTarget == nil || spaceDeleteTarget == id else {
                throw ProjectFileError("confirmation_busy", "Another project removal is awaiting confirmation.")
            }
            adopt(server.state)
            spaceDeleteTarget = id
            return (space, false)
        case .child(let parentPath, let path, let name, let create):
            let registered = try await server.addChildProject(parentPath: parentPath, path: path, name: name, create: create)
            result = (registered.space, registered.created)
        }
        // Adopt before replying, without selecting a project or touching editor drafts.
        let canonical = server.state
        sessions.stateDidChange(canonical)
        adopt(canonical)
        if result.created || revealHierarchy, let space = result.space, let project = sidebarTree.projects.first(where: { $0.space == space.id }) {
            for parent in project.ancestorIDs { setProject(parent, expanded: true) }
        }
        guard await projects.load(projectsSources, force: true) else {
            throw ProjectFileError("refresh_superseded", "Another project reload started. Registration, if requested, is preserved. Retry project_refresh.")
        }
        if let error = projects.error { throw ProjectFileError("refresh_failed", error) }
        return result
    }

    func addSettingsProject(path: String, host: ProjectsHost) async throws {
        if host.id == "local" {
            _ = try await handleProjectRequest(.register(path: path, name: URL(fileURLWithPath: path).lastPathComponent))
            return
        } else if let hostID = UUID(uuidString: host.id) {
            guard remoteHosts.connections.first(where: { $0.id == hostID })?.endpointID == host.endpointID else {
                throw ProjectFileError("host_changed", "The host address changed. Close the picker and choose the host again.")
            }
            _ = try await remoteHosts.addSpace(hostID: hostID, path: path)
        }
        await projects.load(projectsSources, force: true)
    }
}
