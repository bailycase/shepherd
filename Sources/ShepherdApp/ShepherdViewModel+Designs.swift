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
        let systems = designSystems.summaries
        let swatches = Dictionary(systems.map { ($0.namespace, designSystemSwatches($0.namespace, count: 4)) },
                                  uniquingKeysWith: { first, _ in first })
        let inputs = DesignsPageInputs(designs: state.designs, spaces: state.spaces, firstBoards: firstBoards,
                                       filter: designsPageFilter, selection: designsPageSelection, systems: systems,
                                       swatches: swatches, hosts: remoteDesignSections, minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = designsPageCache, cached.inputs == inputs { return cached.model }
        var model = DesignsPageModel.make(designs: inputs.designs, spaces: inputs.spaces, firstBoards: inputs.firstBoards,
                                          filter: inputs.filter, selection: inputs.selection, now: now,
                                          systems: inputs.systems, swatches: inputs.swatches)
        model.hosts = inputs.hosts
        designsPageCache = (inputs, model)
        return model
    }

    /// Changes whenever a design's boards may have changed: the page reads their first boards
    /// again then.
    var designThumbnailSignature: [String] {
        state.designs.filter { !$0.buildsSystem }.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)" }
    }

    /// Reads each design's first board for its card.
    func loadDesignThumbnails() async {
        for design in state.designs where !design.buildsSystem {
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

    /// New design's Send: makes the design in the chosen project, installs the chosen design
    /// system in it, starts its agent with the brief as its first message, and opens the canvas.
    @discardableResult
    func createDesign(brief: String, images: [NativeImage], in spaceID: SpaceID, system: String? = nil) async throws -> DesignID {
        let design = Design(name: Self.provisionalName(for: brief), spaceID: spaceID, createdAt: SessionServer.nowMilliseconds())
        _ = try await server.createDesign(design)
        // Installed before the agent starts, so its first turn reads it among the design's systems.
        if let system { _ = try await server.installDesignSystem(design.id, namespace: system) }
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
                                       source: { try await server.designBoard($0, path: $1).source },
                                       comments: designCommentActions(), tweak: tweak, actions: designCanvasActions())
        if let design = design(id) { screen.tweak?.systemName = designSystemName(design) }
        designScreens[id] = screen
        return screen
    }

    /// The canvas's own changes through the server (Duplicate, a board moved), and its messages to
    /// the design agent (Variations, another direction), which carry a view record as data.
    private func designCanvasActions() -> DesignCanvasActions {
        let server = server
        return DesignCanvasActions(
            snapshot: { try await server.designSnapshot($0) },
            duplicate: { try await server.duplicateDesignBoard($0, path: $1, baseRevision: $2) },
            updateIndex: { try await server.updateDesignIndex($0, patch: $1, baseRevision: $2) },
            ask: { [weak self] id, text, record in
                guard let self, let agentID = self.design(id)?.agentID, self.state.agents.contains(where: { $0.id == agentID }) else {
                    return false
                }
                await self.threadStores.store(for: agentID).send(text: text, designContext: record)
                return true
            },
            report: { [weak self] in self?.remoteActionError = $0 })
    }

    /// The canvas's comment changes through the server. A change based on comments that moved on
    /// meanwhile is refused as stale: it reads them again and goes once more.
    private func designCommentActions() -> DesignCommentActions {
        let server = server
        func again<T>(_ designID: DesignID, _ base: UInt64?, _ body: (UInt64?) async throws -> T) async throws -> T {
            do {
                return try await body(base)
            } catch DesignStoreError.stale {
                return try await body(try await server.designComments(designID).revision)
            }
        }
        return DesignCommentActions(
            list: { try await server.designComments($0) },
            add: { id, draft, base in
                let outcome = try await again(id, base) { try await server.addDesignComment(id, draft: draft, baseRevision: $0) }
                return (outcome.comment, outcome.undelivered)
            },
            reply: { id, comment, text, base in
                let outcome = try await again(id, base) { try await server.replyToDesignComment(id, commentID: comment, text: text, baseRevision: $0) }
                return (outcome.comment, outcome.undelivered)
            },
            resolve: { id, comment, base in
                try await again(id, base) { try await server.resolveDesignComment(id, commentID: comment, baseRevision: $0) }
            },
            report: { [weak self] in self?.remoteActionError = $0 })
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
    /// The design system picked from the card's menu; nil draws in the project's own (its system
    /// when one was built from it, else its stylesheets).
    private(set) var system: String?
    /// Each project's tokens file as last found (DZStart's "found in web/static/tokens.css"); a
    /// project read and found without one maps to nil.
    private(set) var tokensFiles: [SpaceID: String?] = [:]
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
        guard space != id || system != nil else { return }
        space = id
        system = nil
        error = nil
    }

    /// Draws the design in `namespace` (a system from the card's menu), in the project chosen.
    func choose(system namespace: String) {
        guard system != namespace else { return }
        system = namespace
        error = nil
    }

    /// Looks for the chosen project's tokens file once, read-only.
    func detect(_ vm: ShepherdViewModel) async {
        guard let space, tokensFiles[space] == nil,
              let folder = vm.state.spaces.first(where: { $0.id == space }).map({ URL(fileURLWithPath: $0.path, isDirectory: true) })
        else { return }
        let found = await DesignSystemDetection.find(folder)
        tokensFiles[space] = .some(found)
    }

    /// The system Send installs: the one picked, else the one built from the project.
    func systemToInstall(_ vm: ShepherdViewModel) -> String? {
        if let system { return vm.designSystems.summary(system) != nil ? system : nil }
        guard let space else { return nil }
        return Self.projectSystem(space, in: vm.designSystems.summaries)?.namespace
    }

    /// The system built from a project: the most recently changed of those read from it.
    static func projectSystem(_ space: SpaceID, in systems: [DesignSystemSummary]) -> DesignSystemSummary? {
        systems.filter { !$0.builtIn && $0.info.spaceID == space }.max { $0.info.updatedAt < $1.info.updatedAt }
    }

    /// The card under "Design system & starting point" (DZStart): a system picked from the menu;
    /// else the one built from the project; else the project, "found in" its tokens file when it
    /// has one, else at its folder.
    static func card(project: Space, system: DesignSystemSummary?, picked: Bool, tokensFile: String?,
                     spaces: [Space]) -> (title: String, line: String, note: String) {
        if let system {
            let info = system.info
            let owner = system.builtIn ? "shepherd" : info.spaceID.flatMap { id in spaces.first { $0.id == id }?.name } ?? project.name
            let note: String
            if system.builtIn {
                note = "built into Shepherd"
            } else if let source = info.sources.first ?? (picked ? nil : tokensFile) {
                note = "found in \(source)"
            } else {
                note = NewThreadRules.abbreviatedPath(project.path)
            }
            return (info.namespace, "design system · \(owner)", note)
        }
        if let tokensFile {
            return (project.name, "design system · \(project.name)", "found in \(tokensFile)")
        }
        return (project.name, "design system · \(project.name)", NewThreadRules.abbreviatedPath(project.path))
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
        let system = systemToInstall(vm)
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                try await vm.createDesign(brief: text, images: images, in: space, system: system)
                brief = ""
                attachments.removeAll()
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
