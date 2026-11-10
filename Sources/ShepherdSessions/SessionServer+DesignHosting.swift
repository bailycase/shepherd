import Foundation
import ShepherdCore
import ShepherdProtocol

/// How a design's agent starts for another device's design request (`serveDesigns`): the app's
/// view model starts it as its own Open does, the host with no app as a client's new thread.
public struct DesignHosting {
    /// Starts `design`'s agent with `brief` as its first message, on New design's choices, with
    /// nothing selected.
    public var startAgent: @MainActor (Design, String?, RemoteDesignCreate.Options) async throws -> AgentID
    /// A design was made or imported here, before its agent starts.
    public var changed: @MainActor () async -> Void

    public init(startAgent: @escaping @MainActor (Design, String?, RemoteDesignCreate.Options) async throws -> AgentID,
                changed: @escaping @MainActor () async -> Void = {}) {
        self.startAgent = startAgent
        self.changed = changed
    }
}

/// The words a design's agent starts from.
public enum DesignBrief {
    /// A system build's.
    public static let systemBuild = "Build a design system from this space: read its tokens file, its component templates and a "
        + "few pages (read only), write the system with system_write, and tell me what doesn't match."

    /// An imported design's (ImportDone: it reads everything and changes nothing until asked).
    public static func imported(file: String) -> String {
        "This design was imported from Claude Design (\(file)), with its pages, notes and layout as they were. Read its boards, "
            + "notes and design system, run design_check, and tell me in a few sentences what you found (anything off-system "
            + "included). Change nothing until I ask, and end by asking what to work on first."
    }
}

/// Another device's New design, Open, Import and "Build one from a repo", answered as this Mac's
/// own are, with nothing selected or opened here.
extension SessionServer {
    /// Serves design requests from here on. Once per server, by the app or the host.
    @MainActor
    public func serveDesigns(_ hosting: DesignHosting) {
        onRemoteCreateDesign = { [weak self] request, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do { completion(.success(try await self.createRequestedDesign(request, hosting: hosting))) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        onRemoteEnsureDesignAgent = { [weak self] id, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do { completion(.success(try await self.ensureRequestedDesignAgent(id, hosting: hosting))) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
        onRemoteImportDesign = { [weak self] url, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteDesignImportFailure("import_failed", "host is shutting down"))) }
                do { completion(.success(try await self.importRequestedDesign(from: url, hosting: hosting))) }
                catch { completion(.failure(error as? RemoteDesignImportFailure ?? RemoteDesignImportFailure("import_failed", "\(error)"))) }
            }
        }
        onLocalFinishImport = { [weak self] preview, name, skipping, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do {
                    let design = try await self.finishDesignImport(preview, name: name, skippingUnreadable: skipping)
                    await hosting.changed()
                    let agent = try? await hosting.startAgent(design, DesignBrief.imported(file: preview.file), .init())
                    completion(.success(RemoteDesignCreated(designID: design.id, agentID: agent)))
                } catch {
                    await self.cancelDesignImport(preview.id)
                    completion(.failure(error))
                }
            }
        }
        onRemoteBuildDesignSystem = { [weak self] spaceID, completion in
            Task { @MainActor in
                guard let self else { return completion(.failure(RemoteCreateAgentError("host is shutting down"))) }
                do { completion(.success(try await self.buildRequestedDesignSystem(spaceID, hosting: hosting))) }
                catch { completion(.failure(RemoteCreateAgentError(String(describing: error)))) }
            }
        }
    }

    /// A design's agent started by the host with no app: in the reserved designs space, working
    /// in the design's own folder (a system build: in the project it reads), on the host's defaults.
    @MainActor
    public func startDesignAgent(_ design: Design, brief: String?, options: RemoteDesignCreate.Options = .init(),
                                 hosting: ThreadHosting) async throws -> AgentID {
        let folder: String
        if design.buildsSystem {
            guard let space = design.sourceSpaceID.flatMap({ id in state.spaces.first { $0.id == id } }) else {
                throw AgentStartFailure(message: "That space is gone.")
            }
            folder = space.path
        } else {
            guard let own = designs.folder(for: design.id) else { throw AgentStartFailure(message: "That design has no folder.") }
            folder = own.path
        }
        let defaults = hosting.defaults()
        var config = NewAgentConfig(spaceID: try await designsSpaceID(), workingDirectory: folder, model: options.model ?? defaults.model,
                                    thinking: options.thinking ?? defaults.thinking, initialPrompt: brief)
        config.initialImages = options.images
        config.initialName = design.name
        config.designID = design.id
        let agentID = try await startNewAgent(config, launch: hosting.launch(), defaultServiceTier: defaults.serviceTier, mcp: hosting.mcp)
        try await setDesignAgent(design.id, agentID: agentID)
        return agentID
    }

    /// New design (`RemoteDesignRequest.create`): the design, with its system installed before
    /// any agent starts. An agent that fails to start is started when the design is next opened,
    /// so the design is answered either way.
    @MainActor
    func createRequestedDesign(_ request: RemoteDesignCreate, hosting: DesignHosting) async throws -> RemoteDesignCreated {
        let design = Design(name: NewAgentConfig.provisionalName(for: request.brief), createdAt: Self.nowMilliseconds())
        _ = try await createDesign(design)
        if let system = request.systemNamespace { _ = try await installDesignSystem(design.id, namespace: system) }
        await hosting.changed()
        let agent = try? await hosting.startAgent(design, request.brief, request.options ?? .init())
        return RemoteDesignCreated(designID: design.id, agentID: agent)
    }

    /// Open on a design whose agent is gone (`RemoteDesignRequest.ensureAgent`): a fresh one. One
    /// start at a time.
    @MainActor
    func ensureRequestedDesignAgent(_ id: DesignID, hosting: DesignHosting) async throws -> AgentID {
        guard let design = state.designs.first(where: { $0.id == id }), !design.buildsSystem else { throw SessionServerError.noSuchDesign(id) }
        if let agent = state.agents.first(where: { $0.id == design.agentID }) ?? state.agents.first(where: { $0.designID == id }) {
            return agent.id
        }
        guard startingDesignAgents.insert(id).inserted else { throw AgentStartFailure(message: "Its agent is starting. Try again in a moment.") }
        defer { startingDesignAgents.remove(id) }
        return try await hosting.startAgent(design, nil, .init())
    }

    /// An uploaded ZIP (`RemoteDesignRequest.importFinish`), imported as Import does. Without
    /// anyone here to ask, it decides as conservatively as it can: boards that can't be read
    /// refuse it (nothing is imported), and a project already in Designs comes in as a copy under
    /// the next name.
    @MainActor
    func importRequestedDesign(from url: URL, hosting: DesignHosting) async throws -> RemoteDesignCreated {
        let preview: DesignImportPreview
        do {
            preview = try await prepareDesignImport(from: url)
        } catch let failure as DesignImportFailure {
            throw RemoteDesignImportFailure("import_failed", failure.message)
        }
        do {
            guard preview.unreadable.isEmpty else {
                let count = preview.unreadable.count
                throw RemoteDesignImportFailure("import_unreadable", "\(count == 1 ? "1 board" : "\(count) boards") of it can't be read, "
                    + "so nothing was imported. Import it on the host to choose what to do.")
            }
            let again = state.designs.contains { $0.importedFrom.map(preview.origin.isSameProject) == true }
            let name = again ? DesignNaming.importName(preview.title, taken: state.designs.map(\.name)) : nil
            let design = try await finishDesignImport(preview, name: name)
            await hosting.changed()
            let agent = try? await hosting.startAgent(design, DesignBrief.imported(file: preview.file), .init())
            return RemoteDesignCreated(designID: design.id, agentID: agent)
        } catch {
            await cancelDesignImport(preview.id)
            if let failure = error as? RemoteDesignImportFailure { throw failure }
            if let failure = error as? DesignImportFailure { throw RemoteDesignImportFailure("import_failed", failure.message) }
            let text = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            throw RemoteDesignImportFailure("import_failed", text.hasSuffix(".") ? String(text.dropLast()) : text)
        }
    }

    /// "Build one from a repo" (`RemoteDesignRequest.buildSystem`). A space with a build already
    /// answers that one (and its agent, started if it is gone).
    @MainActor
    func buildRequestedDesignSystem(_ spaceID: SpaceID, hosting: DesignHosting) async throws -> RemoteDesignCreated {
        guard let space = state.spaces.first(where: { $0.id == spaceID }) else { throw AgentStartFailure(message: "That space is gone.") }
        if let existing = state.designs.first(where: { $0.buildsSystem && $0.sourceSpaceID == spaceID }) {
            let agent = state.agents.first { $0.id == existing.agentID } ?? state.agents.first { $0.designID == existing.id }
            if let agent { return RemoteDesignCreated(designID: existing.id, agentID: agent.id) }
            return RemoteDesignCreated(designID: existing.id, agentID: try? await hosting.startAgent(existing, nil, .init()))
        }
        guard startingSystemBuilds.insert(spaceID).inserted else { throw AgentStartFailure(message: "Its build is starting. Try again in a moment.") }
        defer { startingSystemBuilds.remove(spaceID) }
        let design = Design(name: space.name, createdAt: Self.nowMilliseconds(), buildsSystem: true, sourceSpaceID: space.id)
        _ = try await createDesign(design)
        await hosting.changed()
        let agent = try? await hosting.startAgent(design, DesignBrief.systemBuild, .init())
        return RemoteDesignCreated(designID: design.id, agentID: agent)
    }
}
