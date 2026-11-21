import Foundation
import Observation
import ShepherdProtocol

/// A draft and its exact host baseline. Nil (missing) is distinct from an existing empty file.
public struct SpaceFileDraft: Equatable, Sendable {
    public fileprivate(set) var saved: ProjectFileText
    public var text: String
    public fileprivate(set) var conflict = false
    public var isEdited: Bool { text != (saved.text ?? "") }

    fileprivate init(_ saved: ProjectFileText) {
        self.saved = saved
        text = saved.text ?? ""
    }
}

/// Settings on one space on one host. Project file operations always name an inventoried file;
/// the host remains the authority on paths, contents and whether a write is still current.
@MainActor @Observable
public final class ClientSpaceConfiguration {
    public enum Inherited: Hashable, Sendable {
        case mcp, skill, prompt, `extension`

        fileprivate var key: WritableKeyPath<SpaceInheritanceExclusions, [String]> {
            switch self {
            case .mcp: \.mcp
            case .skill: \.skills
            case .prompt: \.prompts
            case .extension: \.extensions
            }
        }
    }

    public struct Server: Equatable, Identifiable, Sendable {
        public var file: String
        public var name: String
        public var endpoint: String?
        public var usesOAuth: Bool
        public var id: [String] { [file, name] }
    }

    public let directory: String
    public private(set) var files: [ProjectFile.Category: [ProjectFile]]?
    public private(set) var resources: [ProjectResource.Kind: [ProjectResource]] = [:]
    public private(set) var inheritedResources: [ProjectResource.Kind: [ProjectResource]] = [:]
    public private(set) var context: ProjectContext?
    public private(set) var drafts: [String: SpaceFileDraft] = [:]
    public private(set) var servers: [Server] = []
    public private(set) var inheritedServers: [Server] = []
    public private(set) var signedIn: [String: [String]] = [:]
    public private(set) var problem: String?
    public private(set) var busy = false

    private var capabilities: Set<String>
    @ObservationIgnored private let send: @MainActor (RemoteProjectsRequest) async throws -> RemoteProjectsResult

    public init(directory: String, capabilities: Set<String>, send: @escaping @MainActor (RemoteProjectsRequest) async throws -> RemoteProjectsResult) {
        self.directory = directory
        self.capabilities = capabilities
        self.send = send
    }

    private func supports(_ capability: Capability) -> Bool { capabilities.contains(capability.rawValue) }
    public var canEdit: Bool { supports(.projectsV2) }
    public var canManageResources: Bool { canEdit && supports(.projectResources) }
    public var canUseMCP: Bool { canEdit && supports(.projectMCP) }
    public func canSetInheritance(_ kind: Inherited) -> Bool {
        guard canManageResources, supports(.projectInheritance), context?.inheritsFrom != nil, let excluded = context?.excluded else { return false }
        // The host drops new fields on older peers. Do not erase another client's exclusions.
        return supports(.projectInheritedResources)
            || (kind != .prompt && kind != .extension && excluded.prompts.isEmpty && excluded.extensions.isEmpty)
    }

    public func updateCapabilities(_ capabilities: Set<String>) { self.capabilities = capabilities }

    public func inherits(_ kind: Inherited, _ name: String) -> Bool {
        context?.excluded?[keyPath: kind.key].contains(name) != true
    }

    public func setText(_ text: String, file: String) { drafts[file]?.text = text }

    public func load() async {
        guard canEdit else { return }
        await perform {
            try await loadFiles()
            if let file = files?[.instructions]?.first, drafts[file.path] == nil {
                drafts[file.path] = SpaceFileDraft(try await read(file.path))
            }
            if supports(.projectDetails) {
                guard case .context(let value) = try await send(.context(directory: directory)) else { throw unexpected }
                context = value
            } else {
                context = nil
            }
        }
    }

    public func open(_ file: String, discard: Bool = false) async {
        guard canEdit, contains(file), discard || drafts[file] == nil else { return }
        await perform { drafts[file] = SpaceFileDraft(try await read(file)) }
    }

    public func save(_ file: String) async {
        guard canEdit, contains(file), let draft = drafts[file], draft.isEdited, !draft.conflict else { return }
        await perform {
            do {
                guard case .text(let saved) = try await send(.save(directory: directory, file: file, text: draft.text, expected: draft.saved.text)),
                      saved.file.path == file else { throw unexpected }
                drafts[file]?.saved = saved
                if let category = files?[saved.file.category], let index = category.firstIndex(where: { $0.path == file }) {
                    files?[saved.file.category]?[index] = saved.file
                }
            } catch RemoteHostClientError.rejected("conflict", _) {
                drafts[file]?.conflict = true
                throw ProjectFileError("conflict", "This file changed on the host. Copy your edits before reloading, then reapply them to the new version.")
            }
        }
    }

    public func setInherited(_ kind: Inherited, _ name: String, on: Bool) async {
        guard canSetInheritance(kind), var excluded = context?.excluded, inherits(kind, name) != on else { return }
        excluded[keyPath: kind.key].removeAll { $0 == name }
        if !on { excluded[keyPath: kind.key].append(name) }
        await perform {
            guard case .context(let updated) = try await send(.inheritance(directory: directory, excluded: excluded)) else { throw unexpected }
            context = updated
        }
    }

    public func loadResources() async {
        guard canManageResources else { return }
        await perform { try await refreshResources() }
    }

    public func installSkills(repo: String, paths: [String], commit: String?) async -> Bool {
        let repo = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canManageResources, !repo.isEmpty, !paths.isEmpty else { return false }
        let installed = await perform {
            guard case .files(let inventory) = try await send(.installSkills(directory: directory, repo: repo, paths: paths, commit: commit)) else { throw unexpected }
            files = Dictionary(grouping: inventory, by: \.category)
        }
        if installed { await loadResources() }
        return installed
    }

    /// Delete only the version the person reviewed, not a fresh read after they confirm.
    public func delete(_ resource: ProjectResource) async -> Bool {
        guard canManageResources, !resource.global, resources[resource.kind]?.contains(resource) == true,
              let draft = drafts[resource.path], let expected = draft.saved.text, !draft.isEdited, !draft.conflict else { return false }
        let deleted = await perform {
            do {
                guard case .text(let result) = try await send(.delete(directory: directory, file: resource.path, expected: expected)),
                      result.file.path == resource.path, !result.file.exists else { throw unexpected }
                drafts[resource.path] = nil
                files?[result.file.category]?.removeAll { $0.path == resource.path }
                resources[resource.kind]?.removeAll { $0.path == resource.path && !$0.global }
            } catch RemoteHostClientError.rejected("conflict", _) {
                drafts[resource.path]?.conflict = true
                throw ProjectFileError("conflict", "This file changed on the host. Reload it before deleting it.")
            }
        }
        if deleted { await loadResources() }
        return deleted
    }

    public func loadMCP() async {
        guard canEdit else { return }
        await perform {
            var local: [Server] = []
            var credentials: [String: [String]] = [:]
            for file in files?[.mcp] ?? [] where file.exists {
                let value = try await read(file.path)
                let found = Self.servers(in: value)
                local += found
                if canUseMCP, found.contains(where: \.usesOAuth) {
                    credentials[file.path] = try await mcp(file.path, .credentials).signedIn
                }
            }
            servers = local
            signedIn = credentials
            var inherited: [String: Server] = [:]
            if let parent = context?.inheritsFrom {
                // Legacy first; .shepherd wins. The shared .mcp.json is not inherited.
                for path in [".pi/mcp.json", ".shepherd/mcp.json"] {
                    for server in Self.servers(in: try await read(path, in: parent)) {
                        inherited[server.name] = server
                    }
                }
            }
            let localNames = Set(local.lazy.filter { $0.file != ".mcp.json" }.map(\.name))
            inheritedServers = inherited.values.filter { !localNames.contains($0.name) }.sorted { $0.name < $1.name }
        }
    }

    public func signIn(_ server: Server, authorize: @MainActor (URL, Duration) async throws -> String) async throws {
        guard canUseMCP, !busy, server.usesOAuth, servers.contains(server), signedIn[server.file]?.contains(server.name) != true,
              drafts[server.file]?.isEdited != true else { return }
        try await ClientSpaceMCPSignIn.run(server: server.name, send: { action in
            do { return try await mcp(server.file, action) }
            catch let error as ProjectFileError where error.code == "offline" { throw RemoteHostClientError.disconnected }
        }, authorize: authorize)
        if signedIn[server.file]?.contains(server.name) != true {
            signedIn[server.file, default: []].append(server.name)
        }
    }

    public func signOut(_ server: Server) async {
        guard canUseMCP, server.usesOAuth, servers.contains(server), signedIn[server.file]?.contains(server.name) == true,
              drafts[server.file]?.isEdited != true else { return }
        await perform {
            var result = try await mcp(server.file, .logout(server: server.name))
            if let id = result.id {
                // Logout also runs in the host's bridge; wait for it before rereading credentials.
                let deadline = ContinuousClock.now + .seconds(300)
                do {
                    while result.phase == .waiting {
                        guard ContinuousClock.now < deadline else { throw ProjectFileError("timeout", "Sign out timed out. Try again.") }
                        try await Task.sleep(for: .milliseconds(250))
                        result = try await mcp(server.file, .poll(id: id))
                    }
                } catch {
                    _ = try? await mcp(server.file, .cancel(id: id))
                    throw error
                }
                _ = try? await mcp(server.file, .cancel(id: id))
            }
            if result.phase == .failed { throw ProjectFileError("mcp", result.message ?? "Couldn't sign out.") }
            guard result.phase == .done else { throw unexpected }
            signedIn[server.file] = try await mcp(server.file, .credentials).signedIn
        }
    }

    private static func servers(in value: ProjectFileText) -> [Server] {
        guard let text = value.text,
              let config = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let entries = config["mcpServers"] as? [String: [String: Any]] else { return [] }
        return entries.keys.sorted().compactMap { name in
            guard let entry = entries[name] else { return nil }
            let url = (entry["url"] as? String).flatMap(URL.init(string:))
            let headers = (entry["headers"] as? [String: Any]) ?? [:]
            let oauth = url?.host != nil && (url?.scheme == "https" || url?.scheme == "http")
                && !headers.keys.contains { $0.lowercased() == "authorization" }
                && name.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
            return Server(file: value.file.path, name: name, endpoint: url?.host ?? (entry["command"] as? String), usesOAuth: oauth)
        }
    }

    private func mcp(_ file: String, _ action: ProjectMCPAction) async throws -> ProjectMCPResult {
        guard case .mcp(let value) = try await send(.mcp(directory: directory, file: file, action: action)) else { throw unexpected }
        return value
    }

    private func contains(_ file: String) -> Bool {
        files?.values.contains { $0.contains { $0.path == file } } == true
            || resources.values.contains { $0.contains { !$0.global && $0.path == file } }
    }

    private func read(_ file: String, in folder: String? = nil) async throws -> ProjectFileText {
        guard case .text(let value) = try await send(.read(directory: folder ?? directory, file: file)), value.file.path == file else { throw unexpected }
        return value
    }

    private func loadFiles() async throws {
        guard case .files(let inventory) = try await send(.files(directory: directory)) else { throw unexpected }
        files = Dictionary(grouping: inventory, by: \.category)
    }

    private func refreshResources() async throws {
        guard case .resources(let list) = try await send(.resources(directory: directory)) else { throw unexpected }
        resources = Dictionary(grouping: list, by: \.kind)
        if let parent = context?.inheritsFrom {
            guard case .resources(let list) = try await send(.resources(directory: parent)) else { throw unexpected }
            let own = resources.mapValues { Set($0.filter { !$0.global }.map(\.name)) }
            inheritedResources = Dictionary(grouping: list.filter {
                !$0.global && $0.kind != .agent && own[$0.kind]?.contains($0.name) != true
                    && ($0.kind == .skill || supports(.projectInheritedResources))
            }, by: \.kind)
        } else {
            inheritedResources = [:]
        }
    }

    private var unexpected: ProjectFileError { ProjectFileError("protocol", "Unexpected space settings reply.") }

    @discardableResult private func perform(_ operation: () async throws -> Void) async -> Bool {
        guard !busy, !Task.isCancelled else { return false }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await operation()
            return true
        } catch is CancellationError {
            return false
        } catch {
            if !Task.isCancelled { problem = (error as? ProjectFileError)?.description ?? settingsProblem(error) }
            return false
        }
    }
}
