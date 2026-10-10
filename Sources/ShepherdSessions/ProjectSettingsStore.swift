import Foundation
import Darwin
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import AppKit
import CoreFoundation

/// Projects keeps its directory history outside workspace state. All IO stays on this worker,
/// never the server queue. The file API is restricted to project configuration, including on TCP.
public final class ProjectSettingsStore: @unchecked Sendable {
    public static let fileLimit = 64 * 1024
    public static let pageSize = 64
    private let queue = DispatchQueue(label: "shepherd.project-settings", qos: .userInitiated)
    private let historyURL: URL
    private let mcp: ProjectMCPService?
    private let home: URL
    private let sessions: URL
    private let systems: URL?
    private let globalDirectories: @Sendable () -> [URL]
    private let openEditor: @MainActor @Sendable (URL) async throws -> Void
    private var history: [Entry] = []
    private var loaded = false
    private var importedSessions = false
    private var pendingConfigMigration: [String] = []
    private var configMigrationError: String?
    private var migrationURL: URL { historyURL.deletingLastPathComponent().appendingPathComponent("project-config-migration.json") }

    /// Freeze the pre-cutover cohort once. New projects never become migration candidates on
    /// a later restart. Each owning host runs this before launching its restored agents.
    public func migrateExistingProjectConfiguration(in state: ShepherdState) {
        queue.async { [self] in
            do {
                try load()
                if FileManager.default.fileExists(atPath: migrationURL.path) {
                    let handle = try FileHandle(forReadingFrom: migrationURL)
                    defer { try? handle.close() }
                    var info = stat()
                    guard fstat(handle.fileDescriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
                          info.st_size <= 4 * 1024 * 1024 else { throw ProjectFileError("config_migration", "Project configuration migration history is too large.") }
                    let data = try handle.read(upToCount: 4 * 1024 * 1024 + 1) ?? Data()
                    guard data.count <= 4 * 1024 * 1024 else { throw ProjectFileError("config_migration", "Project configuration migration history is too large.") }
                    pendingConfigMigration = try JSONDecoder().decode([String].self, from: data)
                } else {
                    try rememberEntries(Self.directories(in: state))
                    try importSessions()
                    pendingConfigMigration = history.map(\.directory)
                    guard pendingConfigMigration.count <= 20_000 else { throw ProjectFileError("config_migration", "Too many projects to migrate configuration safely.") }
                    try saveConfigMigration()
                }
                guard pendingConfigMigration.count <= 20_000 else { throw ProjectFileError("config_migration", "Too many projects to migrate configuration safely.") }
            } catch {
                configMigrationError = "Project configuration migration could not be initialized. Check the host's project history and retry after restarting Shepherd."
                ShepherdLog.warning("Project configuration migration could not be initialized: \(error)")
            }
        }
    }

    /// Shared launch boundary, including remote RPC launches. Parent configurations must also
    /// be ready before their MCP servers are inherited by a subproject.
    public func prepareProjectConfiguration(for cwd: String) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                continuation.resume(with: Result {
                    if let configMigrationError { throw ProjectFileError("config_migration", configMigrationError) }
                    let path = absolute(cwd)
                    let deadline = Date().addingTimeInterval(30)
                    for directory in pendingConfigMigration where path == directory || path.hasPrefix(directory + "/") {
                        guard Date() < deadline else { throw ProjectFileError("config_migration", "Project configuration migration reached its time limit. Retry to continue.") }
                        try migrateConfiguration(directory)
                    }
                })
            }
        }
    }

    private func saveConfigMigration() throws {
        try FileManager.default.createDirectory(at: migrationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(pendingConfigMigration)
        guard pendingConfigMigration.count <= 20_000, data.count <= 4 * 1024 * 1024 else {
            throw ProjectFileError("config_migration", "Project configuration migration history exceeds its safety limit.")
        }
        try data.write(to: migrationURL, options: .atomic)
    }

    private func migrateConfiguration(_ directory: String) throws {
        guard pendingConfigMigration.contains(directory) else { return }
        do {
            let support = absolute(historyURL.deletingLastPathComponent().path)
            if directory != support, !directory.hasPrefix(support + "/") {
                try ProjectConfigMigration.copy(in: validatedRoot(directory))
            }
        } catch let error as ProjectFileError where error.code == "global_settings" {
            // Global Pi, app support and the user's home are never project migrations.
        }
        let before = pendingConfigMigration
        pendingConfigMigration.removeAll { $0 == directory }
        do { try saveConfigMigration() }
        catch { pendingConfigMigration = before; throw error }
    }
    private struct Entry: Codable { var directory: String; var name: String }

    public init(historyURL: URL, home: URL, sessions: URL, systems: URL? = nil,
                globalDirectories: @escaping @Sendable () -> [URL] = { [] },
                openEditor: (@MainActor @Sendable (URL) async throws -> Void)? = nil, pi: PiSetup? = nil) {
        self.mcp = pi.map { ProjectMCPService(pi: $0) }
        self.openEditor = openEditor ?? ProjectSettingsStore.openEditor
        self.historyURL = historyURL; self.home = home; self.sessions = sessions; self.systems = systems
        self.globalDirectories = globalDirectories
    }

    /// Called before and after workspace mutations so deletion cannot erase a directory.
    public func remember(_ state: ShepherdState) {
        queue.async { [self] in
            do { try load(); try rememberEntries(Self.directories(in: state)) }
            catch { ShepherdLog.warning("Project history could not be saved: \(error)") }
        }
    }

    public func cancelMCP(owner: UUID) async { await mcp?.cancel(owner: owner) }
    public func stopMCP() async { await mcp?.cancelAll() }

    public func request(_ request: RemoteProjectsRequest, state: ShepherdState, owner: UUID? = nil) async throws -> RemoteProjectsResult {
        if case .mcp(let directory, let file, let action) = request {
            guard file == ".shepherd/mcp.json" || file == ".mcp.json", let mcp else {
                throw ProjectFileError("unsupported", "Project MCP sign-in is unavailable on this host.")
            }
            switch action {
            case .poll, .complete, .cancel:
                // File edits/deletion must not prevent cancelling a run that already owns this path.
                return .mcp(try await mcp.request(directory: directory, file: file, text: "", action: action, owner: owner))
            default: break
            }
            let canonicalDirectory = PiHome.canonical(directory)
            let value = try await self.request(.read(directory: directory, file: file), state: state)
            guard case .text(let text) = value else { throw ProjectFileError("protocol", "Unexpected project file reply.") }
            let contents: String
            if let saved = text.text { contents = saved }
            else if action == .credentials || action == .approveProject { contents = "{}" }
            else { throw ProjectFileError("missing", "Save the server before signing in.") }
            return .mcp(try await mcp.request(directory: directory, file: file, text: contents, action: action, owner: owner, canonicalDirectory: canonicalDirectory))
        }
        if case .open(let directory, let file) = request {
            let value = try await self.request(.read(directory: directory, file: file), state: state)
            guard case .text(let text) = value, text.file.exists else { throw ProjectFileError("missing", "Save the file before opening it in an editor.") }
            let reference: URL = try await withCheckedThrowingContinuation { continuation in
                queue.async { [self] in continuation.resume(with: Result { try editorReference(root: root(directory), file: file) }) }
            }
            try await openEditor(reference)
            return .opened
        }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                continuation.resume(with: Result {
                    try load()
                    try rememberEntries(Self.directories(in: state))
                    switch request {
                    case .list(let offset):
                        try importSessions()
                        guard offset >= 0, offset <= history.count else { throw ProjectFileError("invalid", "Invalid project page.") }
                        let end = min(history.count, offset + Self.pageSize)
                        let designs = designSystemDirectories(state)
                        let folders = parentCandidates()
                        let parents = ProjectNesting.parents(in: state.spaces)
                        let spaces = Dictionary(uniqueKeysWithValues: state.spaces.map { ($0.id, $0) })
                        return .listing(ProjectListing(projects: history[offset..<end].map { entry in
                            var project = summary(entry, designSystem: designs.contains(entry.directory))
                            project.projectID = state.spaces.first { absolute($0.path) == entry.directory }?.id
                            let folderParent = ProjectNesting.parent(of: entry.directory, among: folders)
                            project.parent = project.projectID.map { id in parents[id].flatMap { spaces[$0].map { absolute($0.path) } } } ?? folderParent
                            project.mcpServers = sharedMCP(entry.directory)
                            // Organization never grants config or MCP inheritance across unrelated folders.
                            if let parent = folderParent {
                                project.inheritedMCP = sharedMCP(parent).filter { !project.mcpServers.contains($0) }
                                if !project.inheritedMCP.isEmpty {
                                    project.inheritedFromName = history.first { $0.directory == parent }?.name ?? URL(fileURLWithPath: parent).lastPathComponent
                                }
                            }
                            return project
                        },
                                                       nextOffset: end < history.count ? end : nil))
                    case .files(let directory):
                        return .files(try inventory(root: root(directory)))
                    case .context(let directory):
                        return .context(try context(root: root(directory)))
                    case .mcp:
                        preconditionFailure("MCP is handled after file validation above.")
                    case .open:
                        preconditionFailure("Open is handled after allowlist validation above.")
                    case .read(let directory, let file):
                        let root = try root(directory)
                        let item = try allowed(file, root: root)
                        return .text(ProjectFileText(file: item, text: try read(root: root, file: file), modifiedAt: modified(root: root, file: file)))
                    case .save(let directory, let file, let text, let expected):
                        let root = try root(directory)
                        _ = try allowed(file, root: root)
                        guard text.utf8.count <= Self.fileLimit else { throw ProjectFileError("too_large", "Project files can be at most 64 KiB.") }
                        if file.hasSuffix(".json") {
                            guard (try? YourPiFiles.object(Data(text.utf8), file: file)) != nil else {
                                throw ProjectFileError("invalid_json", "Enter a JSON object. The file has not been changed.")
                            }
                        }
                        guard try read(root: root, file: file) == expected else {
                            throw ProjectFileError("conflict", "This file changed elsewhere. Select the file again and choose Discard to load it before saving.")
                        }
                        try replace(root: root, file: file, text: text, expected: expected)
                        return .text(ProjectFileText(file: try allowed(file, root: root), text: text, modifiedAt: modified(root: root, file: file)))
                    }
                })
            }
        }
    }

    /// The project `cwd` is a subproject of, for an agent starting there: the outermost project
    /// folder that holds it (`ProjectNesting`), or nil. Its `.shepherd/mcp.json` servers are shared with
    /// the agent (`shepherd-mcp-parent.ts`). Reads the history on this store's worker, never the
    /// caller's queue.
    public func parentProject(of cwd: String, state: ShepherdState) async -> String? {
        await withCheckedContinuation { continuation in
            queue.async { [self] in
                try? load()
                try? rememberEntries(Self.directories(in: state))
                continuation.resume(returning: ProjectNesting.parent(of: absolute(cwd), among: parentCandidates()))
            }
        }
    }

    /// Every project folder that can be a parent: never the home folder (its `.pi` is the user's
    /// own pi) and never the root.
    private func parentCandidates() -> [String] {
        let home = absolute(home.path)
        return history.map(\.directory).filter { $0 != home && $0 != "/" }
    }

    /// The servers a project's own `.shepherd/mcp.json` names, sorted: what it shares with its subprojects.
    private func sharedMCP(_ directory: String) -> [String] {
        guard let root = try? validatedRoot(directory), let text = try? read(root: root, file: ".shepherd/mcp.json"),
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let servers = object["mcpServers"] as? [String: Any] else { return [] }
        return servers.keys.sorted()
    }

    /// Primary agent cwd only, never a terminal tab. Names do not merge distinct directories.
    public static func directories(in state: ShepherdState) -> [(String, String)] {
        let spaces = Dictionary(state.spaces.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let tabs = Dictionary(state.tabs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var entries = state.spaces.filter { !$0.hidden }.map { ($0.path, $0.name) }
        for agent in state.agents where agent.designID == nil {
            guard let tab = tabs[agent.tabID], let pane = agent.paneID.flatMap({ tab.layout.leaf(withID: $0) })
                    ?? tab.layout.leaves.first(where: { $0.agentID == agent.id }) else { continue }
            let space = spaces[agent.spaceID]
            let name = space?.path == pane.cwd ? space!.name : (pane.cwd as NSString).lastPathComponent
            entries.append((pane.cwd, name))
        }
        return entries
    }

    private func load() throws {
        guard !loaded else { return }
        if FileManager.default.fileExists(atPath: historyURL.path) {
            do { history = try JSONDecoder().decode([Entry].self, from: Data(contentsOf: historyURL)) }
            catch { throw ProjectFileError("history", "Project history could not be read; it was left unchanged.") }
        }
        loaded = true
    }

    private func absolute(_ path: String) -> String {
        let path = path == "~" ? home.path : path.hasPrefix("~/") ? home.appendingPathComponent(String(path.dropFirst(2))).path : path
        return URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func rememberEntries(_ entries: [(String, String)], updateExisting: Bool = true) throws {
        var seen = Set<String>()
        var changed = false
        let original = history
        for (path, name) in entries where !path.isEmpty && path.utf8.count <= 4096 {
            let path = absolute(path)
            guard seen.insert(path).inserted else { continue }
            if let index = history.firstIndex(where: { $0.directory == path }) {
                if updateExisting, history[index].name != name { history[index].name = name; changed = true }
            } else {
                history.append(Entry(directory: path, name: name)); changed = true
            }
        }
        if changed {
            do {
                try FileManager.default.createDirectory(at: historyURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder().encode(history).write(to: historyURL, options: .atomic)
            } catch { history = original; throw error }
        }
    }

    /// Older deleted agents still have session headers. Read the header only, never conversation
    /// text. The bounded scan runs for the initial cutover cohort or the user's first list request.
    private func importSessions() throws {
        guard !importedSessions else { return }
        let fm = FileManager.default
        guard let walk = fm.enumerator(at: sessions, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            importedSessions = true; return
        }
        var entries: [(String, String)] = []
        let deadline = Date().addingTimeInterval(5)
        var count = 0
        for case let url as URL in walk {
            count += 1
            guard count <= 20_000, Date() < deadline else { break }
            guard url.pathExtension == "jsonl", let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.read(upToCount: 4096),
                  let line = data.split(separator: 10).first,
                  let object = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any],
                  object["type"] as? String == "session", let cwd = object["cwd"] as? String,
                  cwd.hasPrefix("/"), !cwd.hasPrefix(historyURL.deletingLastPathComponent().path + "/") else { continue }
            entries.append((cwd, (cwd as NSString).lastPathComponent))
        }
        try rememberEntries(entries, updateExisting: false)
        importedSessions = true
    }

    private func root(_ directory: String) throws -> URL {
        if let configMigrationError { throw ProjectFileError("config_migration", configMigrationError) }
        try migrateConfiguration(directory)
        return try validatedRoot(directory)
    }

    private func validatedRoot(_ directory: String) throws -> URL {
        guard history.contains(where: { $0.directory == directory }) else { throw ProjectFileError("unknown_project", "This directory is not a known project.") }
        let url = URL(fileURLWithPath: directory)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue,
              url.resolvingSymlinksInPath().path == directory else { throw ProjectFileError("missing", "The project directory is no longer available.") }
        let homePath = home.resolvingSymlinksInPath().path
        let managed = historyURL.deletingLastPathComponent().resolvingSymlinksInPath().path
        let protectedRoots = YourPiLocator.supportFolders(including: home.appendingPathComponent("Library/Application Support/Shepherd"))
            + [home.appendingPathComponent(".pi"), home.appendingPathComponent(".shepherd"), home.appendingPathComponent(".agents"),
                              home.appendingPathComponent(".config")]
            + ["instructions", "pi", "skills", "designs", "design-systems"].map {
                URL(fileURLWithPath: managed).appendingPathComponent($0)
            } + globalDirectories() + [systems].compactMap { $0 }
        let protected = protectedRoots.flatMap { root in
            [root.standardizedFileURL.path, root.resolvingSymlinksInPath().path]
        }
        guard directory != "/", directory != homePath, directory != managed, !protected.contains(where: { directory == $0 || directory.hasPrefix($0 + "/") }) else {
            throw ProjectFileError("global_settings", "This directory holds global settings. Open the host's Settings page instead.")
        }
        return url
    }

    private func inventory(root: URL) throws -> [ProjectFile] {
        var files = [ProjectFile(path: "AGENTS.md", category: .instructions, exists: false),
                     ProjectFile(path: "AGENTS.override.md", category: .instructions, exists: false),
                     ProjectFile(path: ".shepherd/APPEND_SYSTEM.md", category: .instructions, exists: false),
                     ProjectFile(path: ".shepherd/SYSTEM.md", category: .instructions, exists: false),
                     ProjectFile(path: ".shepherd/settings.json", category: .pi, exists: false),
                     ProjectFile(path: ".shepherd/mcp.json", category: .mcp, exists: false),
                     ProjectFile(path: ".mcp.json", category: .mcp, exists: false)]
        let fm = FileManager.default
        for base in [".shepherd/skills", ".agents/skills"] {
            let folder = root.appendingPathComponent(base)
            guard folder.resolvingSymlinksInPath().path == folder.path else { continue }
            for name in (try? fm.contentsOfDirectory(atPath: folder.path))?.sorted().prefix(256) ?? [] where name != "." && name != ".." {
                let path = base + "/" + name + "/SKILL.md"
                if fm.fileExists(atPath: root.appendingPathComponent(path).path) { files.append(ProjectFile(path: path, category: .skills, exists: true)) }
            }
        }
        let extensions = root.appendingPathComponent(".shepherd/extensions")
        if extensions.resolvingSymlinksInPath().path == extensions.path {
            for name in (try? fm.contentsOfDirectory(atPath: extensions.path))?.sorted().prefix(256) ?? [] {
                guard ["ts", "js", "mjs", "cjs"].contains((name as NSString).pathExtension) else { continue }
                files.append(ProjectFile(path: ".shepherd/extensions/" + name, category: .extensions, exists: true))
            }
        }
        return files.map { file in
            var file = file
            let url = root.appendingPathComponent(file.path)
            file.exists = fm.fileExists(atPath: url.path)
            return file
        }
    }

    private func editorReference(root: URL, file: String) throws -> URL {
        try withParent(root: root, file: file) { parent, name in
            let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw ProjectFileError("invalid_file", "Cannot open this file safely.") }
            defer { close(fd) }
            var identity = stat(); guard fstat(fd, &identity) == 0 else { throw ProjectFileError("invalid_file", "Cannot identify this file safely.") }
            let path = root.appendingPathComponent(file).path
            guard let url = CFURLCreateWithFileSystemPath(nil, path as CFString, .cfurlposixPathStyle, false),
                  let reference = CFURLCreateFileReferenceURL(nil, url, nil)?.takeRetainedValue(),
                  let resolved = CFURLCreateFilePathURL(nil, reference, nil)?.takeRetainedValue(),
                  let resolvedPath = CFURLCopyFileSystemPath(resolved, .cfurlposixPathStyle) else {
                throw ProjectFileError("invalid_file", "The file moved before it could be opened.")
            }
            var observed = stat()
            guard lstat(resolvedPath as String, &observed) == 0,
                  identity.st_dev == observed.st_dev, identity.st_ino == observed.st_ino,
                  let referenceURL = URL(string: CFURLGetString(reference)! as String) else {
                throw ProjectFileError("invalid_file", "The file changed before it could be opened.")
            }
            // Keep the inode reference for the editor, rather than a replaceable pathname.
            return referenceURL
        }
    }

    @MainActor private static func openEditor(_ url: URL) async throws {
        let workspace = NSWorkspace.shared
        if let editor = workspace.urlForApplication(withBundleIdentifier: "com.apple.dt.Xcode")
            ?? workspace.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") {
            _ = try await workspace.open([url], withApplicationAt: editor, configuration: NSWorkspace.OpenConfiguration())
        } else { throw ProjectFileError("editor", "No text editor is available on this host.") }
    }

    private func modified(root: URL, file: String) -> Double? {
        (try? root.appendingPathComponent(file).resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970
    }

    private func context(root: URL) throws -> ProjectContext {
        let fm = FileManager.default
        var contexts: [ProjectContext.File] = []
        let globals = globalDirectories() + [home.appendingPathComponent(".pi/agent"), historyURL.deletingLastPathComponent().appendingPathComponent("instructions")]
        for directory in globals {
            if let file = YourPiFiles.contextFile(in: directory), !contexts.contains(where: { $0.path == file.path }) {
                let display = file.path.hasPrefix(home.path + "/") ? "~" + file.path.dropFirst(home.path.count) : file.path
                contexts.append(ProjectContext.File(path: file.path, displayPath: String(display), isGlobal: true))
            }
        }
        var folder = root
        for _ in 0..<128 {
            if let file = YourPiFiles.contextFile(in: folder) {
                let path = file.path
                let display = path.hasPrefix(home.path + "/") ? "~" + path.dropFirst(home.path.count) : path
                contexts.append(ProjectContext.File(path: path, displayPath: String(display)))
            }
            let parent = folder.deletingLastPathComponent()
            if parent.path == folder.path { break }
            folder = parent
        }
        let files = try inventory(root: root)
        var resources = files.filter { $0.category == .skills || $0.category == .extensions }.count
        if let text = try read(root: root, file: ".shepherd/settings.json"),
           let settings = try? YourPiFiles.object(Data(text.utf8), file: ".shepherd/settings.json") {
            resources += (settings["extensions"] as? [Any])?.count ?? 0
            resources += (settings["packages"] as? [Any])?.count ?? 0
        }
        var servers = Set<String>()
        for file in files where file.category == .mcp && file.exists {
            if let text = try? read(root: root, file: file.path), let settings = try? YourPiFiles.object(Data(text.utf8), file: file.path),
               let names = settings["mcpServers"] as? [String: Any] { servers.formUnion(names.keys) }
        }
        return ProjectContext(files: contexts, resources: resources, mcpServers: servers.count)
    }

    private func allowed(_ file: String, root: URL) throws -> ProjectFile {
        guard let item = try inventory(root: root).first(where: { $0.path == file }) else {
            throw ProjectFileError("invalid_file", "Only project instruction and .shepherd configuration files can be edited.")
        }
        return item
    }

    private func designSystemDirectories(_ state: ShepherdState) -> Set<String> {
        guard let systems, let folders = try? FileManager.default.contentsOfDirectory(at: systems, includingPropertiesForKeys: nil) else { return [] }
        var paths = Set<String>()
        for folder in folders {
            let file = folder.appendingPathComponent(DesignSystemFile.info)
            guard let size = (try? file.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size <= Self.fileLimit,
                  let data = try? Data(contentsOf: file), let info = try? JSONDecoder().decode(DesignSystemInfo.self, from: data),
                  let id = info.spaceID, let space = state.spaces.first(where: { $0.id == id }) else { continue }
            paths.insert(absolute(space.path))
        }
        return paths
    }

    private func summary(_ entry: Entry, designSystem: Bool) -> ProjectSummary {
        let path = entry.directory == home.path ? "~" : entry.directory.hasPrefix(home.path + "/") ? "~" + entry.directory.dropFirst(home.path.count) : entry.directory
        do {
            let root = try validatedRoot(entry.directory), files = try inventory(root: root)
            var parts = files.filter { $0.category == .instructions && $0.exists }.map { URL(fileURLWithPath: $0.path).lastPathComponent }
            let skills = files.filter { $0.category == .skills }.count
            if skills > 0 { parts.append("\(skills) \(skills == 1 ? "skill" : "skills")") }
            var extensions = files.filter { $0.category == .extensions }.count
            if let text = try? read(root: root, file: ".shepherd/settings.json"), let object = try? YourPiFiles.object(Data(text.utf8), file: ".shepherd/settings.json") {
                extensions += (object["extensions"] as? [Any])?.count ?? 0
                extensions += (object["packages"] as? [Any])?.count ?? 0
                if !Set(object.keys).subtracting(["extensions", "packages"]).isEmpty { parts.append("pi settings") }
            } else if files.contains(where: { $0.path == ".shepherd/settings.json" && $0.exists }) { parts.append("pi settings") }
            if extensions > 0 { parts.append("\(extensions) \(extensions == 1 ? "extension" : "extensions")") }
            var mcpNames = Set<String>()
            for file in files where file.category == .mcp && file.exists {
                if let text = try? read(root: root, file: file.path), let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                   let servers = object["mcpServers"] as? [String: Any] { mcpNames.formUnion(servers.keys) }
            }
            if !mcpNames.isEmpty { parts.append("\(mcpNames.count) MCP \(mcpNames.count == 1 ? "server" : "servers")") }
            if designSystem { parts.append("design system") }
            let minimal = parts.isEmpty || parts == ["AGENTS.md"]
            return ProjectSummary(directory: entry.directory, name: entry.name, displayPath: String(path),
                                  summary: parts.isEmpty ? "no project settings" : parts == ["AGENTS.md"] ? "AGENTS.md only" : parts.joined(separator: " · "), minimal: minimal)
        } catch {
            return ProjectSummary(directory: entry.directory, name: entry.name, displayPath: String(path), summary: "directory unavailable", minimal: true,
                                  error: "The project directory is no longer available.")
        }
    }

    /// Walk using directory descriptors and O_NOFOLLOW: symlink swaps cannot redirect an editor
    /// to auth, another project or the user's global configuration. Missing .shepherd is created on Save.
    private func withParent<T>(root: URL, file: String, create: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
        // Foundation maps /private/tmp back to /tmp. POSIX realpath keeps the physical path
        // so this no-follow walk accepts macOS' standard aliases without following replacements.
        guard let resolved = realpath(root.path, nil) else { throw ProjectFileError("unavailable", "Could not open the project directory.") }
        defer { free(resolved) }
        let physical = String(cString: resolved)
        guard URL(fileURLWithPath: physical).resolvingSymlinksInPath().path == root.path else {
            throw ProjectFileError("unsafe_path", "The project directory changed before it could be opened.")
        }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectFileError("unavailable", "Could not open the project directory.") }
        defer { Darwin.close(fd) }
        for name in physical.split(separator: "/").map(String.init) {
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ProjectFileError("unsafe_path", "Project configuration cannot follow symbolic links.") }
            Darwin.close(fd); fd = next
        }
        let components = file.split(separator: "/").map(String.init)
        for name in components.dropLast() {
            if create, mkdirat(fd, name, 0o755) != 0, errno != EEXIST { throw ProjectFileError("write_failed", "Could not create the project configuration folder.") }
            let next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else {
                if errno == ENOENT { throw ProjectFileError("not_found", "The project file does not exist.") }
                throw ProjectFileError("unsafe_path", "Project configuration cannot follow symbolic links.")
            }
            Darwin.close(fd); fd = next
        }
        return try body(fd, components.last!)
    }

    private func read(root: URL, file: String) throws -> String? {
        do {
            return try withParent(root: root, file: file) { parent, name in
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                if fd < 0, errno == ENOENT { return nil }
                guard fd >= 0 else { throw ProjectFileError("unsafe_path", "Project configuration cannot follow symbolic links.") }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                var info = stat()
                guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw ProjectFileError("invalid_file", "Choose a regular project file.") }
                guard info.st_size <= Self.fileLimit else { throw ProjectFileError("too_large", "Project files can be at most 64 KiB.") }
                let data = try handle.read(upToCount: Self.fileLimit + 1) ?? Data()
                guard data.count <= Self.fileLimit, let text = String(data: data, encoding: .utf8) else { throw ProjectFileError("invalid_file", "Choose a UTF-8 project file of at most 64 KiB.") }
                return text
            }
        } catch let error as ProjectFileError where error.code == "not_found" { return nil }
    }

    private func replace(root: URL, file: String, text: String, expected: String?) throws {
        try withParent(root: root, file: file, create: true) { parent, name in
            let temporary = ".shepherd-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw ProjectFileError("write_failed", "Could not save the project file.") }
            defer { Darwin.close(fd); unlinkat(parent, temporary, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: Data(text.utf8))
            try handle.synchronize()
            let existing = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            var current: String?
            if existing >= 0 {
                let readHandle = FileHandle(fileDescriptor: existing, closeOnDealloc: true)
                defer { try? readHandle.close() }
                var info = stat()
                guard fstat(existing, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw ProjectFileError("unsafe", "Only regular project files can be saved.") }
                let data = try readHandle.read(upToCount: Self.fileLimit + 1) ?? Data()
                guard info.st_size <= Self.fileLimit, data.count <= Self.fileLimit,
                      let value = String(data: data, encoding: .utf8) else { throw ProjectFileError("invalid_file", "The project file changed to an unreadable file.") }
                current = value
                guard fchmod(fd, info.st_mode & 0o777) == 0 else { throw ProjectFileError("write_failed", "Could not preserve the project file's permissions.") }
            } else if errno != ENOENT { throw ProjectFileError("unsafe", "Could not safely read the project file before replacing it.") }
            guard current == expected else { throw ProjectFileError("conflict", "This file changed elsewhere. Select the file again and choose Discard to load it before saving.") }
            guard renameat(parent, temporary, parent, name) == 0 else { throw ProjectFileError("write_failed", "Could not replace the project file.") }
        }
    }
}
