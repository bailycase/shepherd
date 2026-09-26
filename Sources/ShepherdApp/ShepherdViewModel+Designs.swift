import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// The Design tool (Settings ▸ Experiments ▸ Design tool): the Designs page, New design, and
// opening a design. A design's screen is its agent's layout (`DesignLayoutView`): the canvas
// beside the agent's chat, mounted and hidden like any agent's, so switching designs is a
// visibility flip. The design, not its agent, is the Recents row.

extension ShepherdViewModel {
    // MARK: Lookups

    var designToolEnabled: Bool { settings.designToolEnabled }

    func design(_ id: DesignID?) -> Design? {
        guard let id else { return nil }
        return state.designs.first { $0.id == id }
    }

    /// The design an agent draws, while that design exists.
    func design(drawnBy agent: Agent?) -> Design? {
        design(agent?.designID)
    }

    /// The design on screen: its agent's layout is the one shown.
    var shownDesign: Design? {
        guard shownDestination == nil, selectedRemoteAgent == nil else { return nil }
        return design(drawnBy: selectedAgent)
    }

    /// The project a design's chip names: its system, else its project.
    func designSystemName(_ design: Design) -> String {
        design.systemNamespace ?? state.spaces.first { $0.id == design.spaceID }?.name ?? "design"
    }

    // MARK: Pages

    /// The Designs page as its view draws it, derived again only when what it reads changed.
    var designsPage: DesignsPageModel {
        let now = Date()
        let firstBoards = designRendering.thumbnails.entries.mapValues {
            DesignsPageModel.FirstBoard(size: $0.size, version: $0.version)
        }
        let inputs = DesignsPageInputs(designs: state.designs, spaces: state.spaces, firstBoards: firstBoards,
                                       filter: designsPageFilter, selection: designsPageSelection,
                                       minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = designsPageCache, cached.inputs == inputs { return cached.model }
        let model = DesignsPageModel.make(designs: inputs.designs, spaces: inputs.spaces, firstBoards: inputs.firstBoards,
                                          filter: inputs.filter, selection: inputs.selection, now: now)
        designsPageCache = (inputs, model)
        return model
    }

    /// Changes whenever a design's boards may have changed: the page reads their first boards
    /// again then.
    var designThumbnailSignature: [String] {
        state.designs.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)" }
    }

    /// Reads each design's first board for its card.
    func loadDesignThumbnails() async {
        for design in state.designs {
            guard let snapshot = try? await server.designSnapshot(design.id) else { continue }
            designRendering.thumbnails.update(design.id, snapshot: snapshot)
        }
    }

    /// New design (the page's button, "Start a design"): the brief, ready to type into.
    func openNewDesign() {
        newDesign.prepare(for: self)
        openDestination(.newDesign)
        newDesign.focusRequest += 1
    }

    // MARK: Opening a design

    /// A design's row or card: its canvas and its agent's chat. A design whose agent is gone
    /// starts a fresh one.
    func openDesign(_ id: DesignID) {
        guard let design = design(id) else { return }
        designsPageSelection = id
        // Its agent, or one that draws it before the design records it (a start whose
        // `setDesignAgent` hasn't reached this state yet).
        let agent = state.agents.first { $0.id == design.agentID } ?? state.agents.first { $0.designID == id }
        if let agent {
            selectAgent(agent.id)
            return
        }
        guard !startingDesignAgents.contains(id) else { return }
        startingDesignAgents.insert(id)
        Task {
            defer { startingDesignAgents.remove(id) }
            do {
                _ = try await startDesignAgent(design, brief: nil, images: [])
            } catch {
                remoteActionError = "Couldn't open \(design.name): \(error)"
            }
        }
    }

    /// Starts the agent that draws `design` in its project, with the default model, and selects
    /// it. `brief` is its opening message.
    @discardableResult
    func startDesignAgent(_ design: Design, brief: String?, images: [NativeImage]) async throws -> AgentID {
        guard let space = state.spaces.first(where: { $0.id == design.spaceID }) else {
            throw AgentStartFailure(message: "That project is gone.")
        }
        let defaults = settings.agentDefaults
        var config = NewAgentConfig(spaceID: space.id, workingDirectory: space.path, model: defaults.model,
                                    thinking: defaults.thinking, initialPrompt: brief)
        config.initialImages = images
        config.initialName = design.name
        config.designID = design.id
        let agentID = try await startAgent(config, focusWindow: false)
        try await server.setDesignAgent(design.id, agentID: agentID)
        return agentID
    }

    /// New design's Send: makes the design in the chosen project, starts its agent with the
    /// brief as its first message, and opens the canvas.
    @discardableResult
    func createDesign(brief: String, images: [NativeImage], in spaceID: SpaceID) async throws -> DesignID {
        let design = Design(name: Self.provisionalName(for: brief), spaceID: spaceID, createdAt: SessionServer.nowMilliseconds())
        _ = try await server.createDesign(design)
        adopt(server.state)
        // A design whose agent failed to start still opens later, and starts one then.
        try await startDesignAgent(design, brief: brief, images: images)
        return design.id
    }

    // MARK: Screens

    /// The canvas state of `id`, made the first time it is shown.
    func designScreen(_ id: DesignID) -> DesignScreenModel {
        if let screen = designScreens[id] { return screen }
        let server = server
        let project = design(id).flatMap { design in state.spaces.first { $0.id == design.spaceID } }.map { URL(fileURLWithPath: $0.path) }
        let tweak = DesignTweakIO(
            snapshot: { try await server.designSnapshot(id) },
            board: { try await server.designBoard(id, path: $0) },
            writeBoards: { try await server.writeDesignBoards(id, sources: $0, baseRevision: $1) },
            updateIndex: { try await server.updateDesignIndex(id, patch: $0, baseRevision: $1) },
            restore: { try await server.restoreDesignVersions(id, $0, ifCurrent: $1) },
            projectTokens: { await DesignProjectTokens.read(project) })
        let screen = DesignScreenModel(designID: id, host: designRendering.host(for: id),
                                       snapshot: { try await server.designSnapshot($0) },
                                       source: { try await server.designBoard($0, path: $1).source }, tweak: tweak)
        if let design = design(id) { screen.tweak?.systemName = designSystemName(design) }
        designScreens[id] = screen
        return screen
    }

    /// A design's layout came on screen or left it: only designs on screen take live views and
    /// get their revisions pushed.
    func designVisibility(_ id: DesignID, visible: Bool) {
        designScreen(id).setActive(visible)
        let changed = visible ? visibleDesigns.insert(id).inserted : visibleDesigns.remove(id) != nil
        if changed { server.watchDesignRevisions(of: visibleDesigns) }
    }

    /// The host pushed a design's new revision: its canvas pulls what changed.
    func designRevised(_ id: DesignID) {
        guard let screen = designScreens[id] else { return }
        Task { await screen.refresh() }
    }

    /// Designs that are gone give up their canvases and renderers.
    func pruneDesigns() {
        let live = Set(state.designs.map(\.id))
        for id in Set(designScreens.keys).subtracting(live) { designScreens.removeValue(forKey: id) }
        if !visibleDesigns.isSubset(of: live) {
            visibleDesigns.formIntersection(live)
            server.watchDesignRevisions(of: visibleDesigns)
        }
        if let selection = designsPageSelection, !live.contains(selection) { designsPageSelection = nil }
        madeDesignRendering?.prune(keeping: live)
    }
}

// MARK: New design

/// The New design page's draft (DZStart): the brief, its images, and the project it is drawn
/// in. Owned by the view model, so it survives the page going away.
@MainActor @Observable
final class NewDesignState {
    var brief = ""
    var attachments = ComposerAttachments()
    /// The project the design belongs to: its agent works in its folder.
    private(set) var space: SpaceID?
    private(set) var starting = false
    var error: String?
    /// Bumped to give the field the keyboard.
    var focusRequest = 0

    /// The page is opening: keep the chosen project while it exists, else the selected space,
    /// else the most recently used one (decision 10).
    func prepare(for vm: ShepherdViewModel) {
        let spaces = vm.visibleSpaces
        if let space, spaces.contains(where: { $0.id == space }) { return }
        let recent = vm.state.agents.filter { agent in spaces.contains { $0.id == agent.spaceID } }
            .max { ($0.lastActiveAt ?? -1) < ($1.lastActiveAt ?? -1) }?.spaceID
        let selected = vm.selectedSpaceID.flatMap { id in spaces.contains { $0.id == id } ? id : nil }
        space = selected ?? recent ?? spaces.first?.id
    }

    func choose(_ id: SpaceID) {
        guard space != id else { return }
        space = id
        error = nil
    }

    /// Dropped or pasted images, resized on the way in.
    func attach(_ providers: [NSItemProvider]) {
        attachments.clearError()
        Task {
            let urls = await AppImageDrop.resolve(providers)
            attachments.add(urls: urls)
        }
    }

    func attach(urls: [URL]) {
        attach(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
    }

    /// What the line under the card says: a failed start, or an image left out.
    var notice: String? {
        error ?? attachments.error ?? NewThreadPlaces.imagesRefusal(attachments.images, host: nil)
    }

    /// Why Send is unavailable; nil when it can send.
    func blocker(_ vm: ShepherdViewModel) -> String? {
        if starting { return "Starting…" }
        guard let space, vm.state.spaces.contains(where: { $0.id == space }) else { return "Add a project to start a design." }
        if brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the design first." }
        return NewThreadPlaces.imagesRefusal(attachments.images, host: nil)
    }

    /// Send: makes the design, starts its agent with the brief, and opens the canvas. The draft
    /// clears once the design exists.
    func send(_ vm: ShepherdViewModel) {
        guard blocker(vm) == nil, let space else { NSSound.beep(); return }
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.images
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                try await vm.createDesign(brief: text, images: images, in: space)
                brief = ""
                attachments.removeAll()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
