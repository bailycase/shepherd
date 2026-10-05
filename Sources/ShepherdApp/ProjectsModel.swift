import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdRemote

struct ProjectsHost: Equatable, Identifiable {
    var id: String
    var name: String
    var endpointID: UUID?
    var supportsDetails = true
    var unavailable: String?
    var known: [ProjectSummary]
}

struct ProjectsRow: Equatable, Identifiable {
    var host: ProjectsHost
    var project: ProjectSummary
    var id: String { host.id + "\n" + project.directory }
    var unavailable: String? { host.unavailable ?? project.error }
}

@MainActor
@Observable
final class ProjectsModel {
    typealias Request = @MainActor (ProjectsHost, RemoteProjectsRequest) async throws -> RemoteProjectsResult
    @ObservationIgnored private let request: Request
    private(set) var hosts: [ProjectsHost] = []
    private(set) var rows: [ProjectsRow] = []
    private(set) var visible: [ProjectsRow] = []
    var filter = "" { didSet { derive() } }
    var host = "all" { didSet { derive() } }
    private(set) var loading = false
    var error: String?
    var selected: ProjectsRow?
    private(set) var files: [ProjectFile] = []
    var category: ProjectFile.Category = .instructions
    var showingBrowser = false
    var selectedFile: ProjectFile?
    var draft = "" { didSet {
        tokenText = InstructionsText.sizeNote(draft)
        if category == .mcp { deriveMCP() }
    } }
    private(set) var mcp = ProjectMCPConfiguration()

    private func deriveMCP() {
        mcp = ProjectMCPConfiguration(text: draft, path: selectedFile?.path ?? ".pi/mcp.json", host: selected?.host.name ?? "This Mac")
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
    @ObservationIgnored private var loadedHosts: [ProjectsHost]?

    init(request: @escaping Request) { self.request = request }
    var dirty: Bool { fileLoaded && draft != (saved ?? "") }
    var selectedFiles: [ProjectFile] {
        files.filter { $0.category == category || (category == .extensions || category == .skills) && ($0.category == .skills || $0.category == .extensions) }
    }
    var hostOptions: [(String, String)] { [("all", "All hosts")] + hosts.map { ($0.id, $0.name) } }
    var addHost: ProjectsHost? { hosts.first { $0.id == (host == "all" ? "local" : host) } }

    private func derive() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        let next = rows.filter { row in
            (host == "all" || row.host.id == host) && (query.isEmpty || [row.project.name, row.project.directory, row.project.displayPath, row.host.name].contains {
                $0.localizedCaseInsensitiveContains(query)
            })
        }
        if visible != next { visible = next }
    }

    func load(_ sources: [ProjectsHost], force: Bool = false) async {
        guard force || loadedHosts != sources else { return }
        loadGeneration += 1
        let revision = loadGeneration
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
                        guard revision == loadGeneration else { return }
                        guard !Task.isCancelled else { loading = false; return }
                        guard case .listing(let page) = try await request(source, .list(offset: offset)) else {
                            throw ProjectFileError("protocol", "Unexpected project listing.")
                        }
                        guard revision == loadGeneration, !Task.isCancelled else { return }
                        projects += page.projects
                        pages += 1
                        guard let next = page.nextOffset else { break }
                        guard next > offset, pages < 1000 else { throw ProjectFileError("too_many", "Project listing exceeded its page limit.") }
                        offset = next
                    } while true
                } catch {
                    guard revision == loadGeneration else { return }
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
        guard revision == loadGeneration else { return }
        guard !Task.isCancelled else { loading = false; return }
        rows = next; loading = false; loadedHosts = sources; derive()
        if let selected, let current = rows.first(where: { $0.id == selected.id }) {
            if current.host.endpointID == selected.host.endpointID { self.selected = current }
            else {
                var invalid = selected
                invalid.host.unavailable = "Host changed. Reopen this project before editing it."
                self.selected = invalid
            }
        }
    }

    func open(_ row: ProjectsRow) async {
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
        guard let selected, selected.unavailable == nil else { return }
        generation += 1
        let token = generation
        selectedFile = file; fileLoaded = false; fileLoading = true; fileError = nil; notice = nil
        do {
            guard case .text(let value) = try await request(selected.host, .read(directory: selected.project.directory, file: file.path)) else { throw ProjectFileError("protocol", "Unexpected project file reply.") }
            guard token == generation else { return }
            selectedFile = value.file; saved = value.text; draft = value.text ?? ""; modifiedAt = value.modifiedAt; fileLoaded = true
            if category == .mcp { deriveMCP() }
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
            notice = "Saved to the project folder. It takes effect in new turns."
            await load(hosts, force: true)
            if case .context(let context) = try? await request(selected.host, .context(directory: selected.project.directory)), token == generation { self.context = context; deriveReadRows() }
            await compareHosts(token: token, text: value.text, file: file, selected: selected)
        } catch { if token == generation { fileError = String(describing: error) } }
        saving = false
    }
}

extension ShepherdViewModel {
    var projectsSources: [ProjectsHost] {
        func known(_ state: ShepherdState, reason: String?) -> [ProjectSummary] {
            var seen = Set<String>()
            return ProjectSettingsStore.directories(in: state).compactMap { directory, name in
                guard seen.insert(directory).inserted else { return nil }
                return ProjectSummary(directory: directory, name: name, displayPath: directory, summary: reason ?? "loading project settings", minimal: true)
            }
        }
        return [ProjectsHost(id: "local", name: "This Mac", known: known(state, reason: nil))] + remoteHosts.connections.map { connection in
            let reason: String? = connection.phase == .connected
                ? connection.supportsProjects ? nil : "Update Shepherd on this host to edit project settings."
                : "Host offline. Reconnect in Settings > Remote to edit its projects."
            return ProjectsHost(id: connection.id.uuidString, name: connection.config.name, endpointID: connection.endpointID, supportsDetails: connection.supportsProjectDetails, unavailable: reason, known: known(connection.state, reason: reason))
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

    func addSettingsProject(path: String, host: ProjectsHost) async throws {
        if host.id == "local" {
            if state.spaces.contains(where: { $0.path == path }) { return }
            try await server.addSpace(Space(name: URL(fileURLWithPath: path).lastPathComponent, path: path), first: true)
            adopt(server.state)
        } else if let hostID = UUID(uuidString: host.id) {
            guard remoteHosts.connections.first(where: { $0.id == hostID })?.endpointID == host.endpointID else {
                throw ProjectFileError("host_changed", "The host address changed. Close the picker and choose the host again.")
            }
            _ = try await remoteHosts.addSpace(hostID: hostID, path: path)
        }
        await projects.load(projectsSources, force: true)
    }
}
