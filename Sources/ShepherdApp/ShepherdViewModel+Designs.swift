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

    /// The system a design's chip names; nil while it is drawn in none. A design belongs to no
    /// project, so nothing else stands in.
    func designSystemName(_ design: Design) -> String? {
        design.systemNamespace
    }

    /// The folder a design's agent works in: a system build's project, else the design's own
    /// folder under the support directory (it has no repository). An agent that already draws
    /// it keeps the folder it was started in (an older design's project).
    func designWorkingFolder(_ design: Design) -> URL? {
        if let agentID = design.agentID, let agent = state.agents.first(where: { $0.id == agentID }),
           let cwd = state.tabs.first(where: { $0.id == agent.tabID })?.layout.firstLeaf.cwd {
            return URL(fileURLWithPath: (cwd as NSString).expandingTildeInPath, isDirectory: true)
        }
        if design.buildsSystem {
            return design.sourceSpaceID.flatMap { id in state.spaces.first { $0.id == id } }
                .map { URL(fileURLWithPath: ($0.path as NSString).expandingTildeInPath, isDirectory: true) }
        }
        return designStore.folder(for: design.id)
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
        let building = Set(systems.map(\.namespace).filter(systemIsBuilding))
        let inputs = DesignsPageInputs(designs: state.designs, spaces: state.spaces, firstBoards: firstBoards,
                                       filter: designsPageFilter, selection: designsPageSelection, systems: systems,
                                       swatches: swatches, hosts: remoteDesignSections, importing: designImporting, building: building,
                                       comments: designCommentCounts, minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = designsPageCache, cached.inputs == inputs { return cached.model }
        var model = DesignsPageModel.make(designs: inputs.designs, spaces: inputs.spaces, firstBoards: inputs.firstBoards,
                                          filter: inputs.filter, selection: inputs.selection, now: now,
                                          systems: inputs.systems, swatches: inputs.swatches, importing: inputs.importing,
                                          building: inputs.building, comments: inputs.comments)
        model.hosts = inputs.hosts
        designsPageCache = (inputs, model)
        return model
    }

    /// Changes whenever a design's boards may have changed: the page reads their first boards
    /// again then.
    var designThumbnailSignature: [String] {
        state.designs.filter { !$0.buildsSystem }.map { "\($0.id.rawValue)/\($0.lastActiveAt)/\($0.boardCount ?? -1)" }
    }

    /// Only visible consumers request snapshots; catalog changes refresh that demand, not every design.
    func loadDesignThumbnails() async {
        for id in designRendering.thumbnails.demandedIDs {
            guard !Task.isCancelled, let design = design(id), !design.buildsSystem,
                  let snapshot = try? await ownerDesignSnapshot(id), self.design(id) != nil else { continue }
            designRendering.thumbnails.update(id, snapshot: snapshot)
        }
    }

    /// Each design's open comments, for its card ("2 comments"). Read as the Designs page opens
    /// and as designs change.
    // ponytail: a comment added while the page is open shows on the next change or visit; push
    // counts with `designCommentsChanged` if that matters.
    func loadDesignCommentCounts() async {
        var counts: [DesignID: Int] = [:]
        for design in state.designs where !design.buildsSystem {
            guard !Task.isCancelled else { return }
            guard let file = try? await ownerDesignComments(design.id) else { continue }
            let open = file.comments.count { $0.resolvedAt == nil }
            if open > 0 { counts[design.id] = open }
        }
        if counts != designCommentCounts { designCommentCounts = counts }
    }

    func designThumbnailVisibility(_ target: DesignTarget, visible: Bool) {
        switch target {
        case .local(let id):
            designRendering.thumbnails.demand(id, visible: visible)
            if visible {
                Task {
                    guard let snapshot = try? await ownerDesignSnapshot(id), design(id) != nil else { return }
                    designRendering.thumbnails.update(id, snapshot: snapshot)
                }
            }
        case .remote(let ref):
            remoteDesignRendering(ref.hostID)?.thumbnails.demand(ref.designID, visible: visible)
        }
    }

    /// New design (the page's button, "Start a design"): the brief, ready to type into. `system` is the design
    /// system the page it was pressed on is showing: the draft draws in it rather than in the default, which is the
    /// system built from a project when there is one. Nil keeps what the draft had picked.
    func openNewDesign(system: String? = nil) {
        newDesign.prepare(for: self)
        if let system { newDesign.choose(system: system) }
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
                // The background host starts it, as a paired Mac's (`openRemoteDesign`).
                guard case .agent(let agentID) = try await Self.remoteDesign(localDesigns, .ensureAgent(designID: id)) else {
                    throw RemoteDesignReply.unexpected
                }
                // ponytail: polls for the host's push, as `createDesign` does.
                for _ in 0..<100 where self.agent(id: agentID) == nil { try await Task.sleep(for: .milliseconds(20)) }
                selectAgent(agentID)
            } catch {
                remoteActionError = "Couldn't open \(design.name): \(error)"
            }
        }
    }

    /// New design's Send: makes the design (in no project), installs the chosen design system in
    /// it, starts its agent with the brief as its first message, on the model and level chosen
    /// (nil: Settings' defaults), and opens the canvas.
    @discardableResult
    func createDesign(brief: String, images: [NativeImage], system: String? = nil, model: String? = nil,
                      thinking: ThinkingLevel? = nil) async throws -> DesignID {
        // The background host makes it, its agent with these choices.
        guard case .created(let designID, let agentID) = try await Self.remoteDesign(localDesigns, .create(RemoteDesignCreate(
            brief: brief, systemNamespace: system, options: .init(model: model, thinking: thinking, images: images)))) else {
            throw RemoteDesignReply.unexpected
        }
        // ponytail: polls for the host's push, as `startHostedAgent` does.
        for _ in 0..<100 where !state.designs.contains(where: { $0.id == designID }) { try await Task.sleep(for: .milliseconds(20)) }
        if let agentID { selectAgent(agentID) } else { openDesign(designID) }
        return designID
    }

    /// The connected hosts New design can make a design on: those serving designs.
    var newDesignHosts: [RemoteHostStore.Connection] {
        remoteHosts.allConnections.filter { $0.phase == .connected && $0.supportsDesigns }
    }

    func newDesignHost(_ id: UUID) -> RemoteHostStore.Connection? {
        newDesignHosts.first { $0.id == id }
    }

    /// New design's Send with a host chosen: the host makes it as its own New design does
    /// (`create`), and its canvas opens here once the host has its agent.
    func createDesign(onHost hostID: UUID, brief: String, system: String?) async throws {
        guard let connection = newDesignHost(hostID) else {
            throw RemoteHostClientError.rejected(code: "offline", message: "the host isn't connected")
        }
        guard case .created(let designID, let agentID) = try await Self.remoteDesign(
            connection.designs, .create(RemoteDesignCreate(brief: brief, systemNamespace: system))) else {
            throw RemoteDesignReply.unexpected
        }
        Task { await connection.designs.refresh() }
        if let agentID {
            selectRemoteAgent(hostID: hostID, agentID: agentID)
        } else {
            openRemoteDesign(RemoteDesignRef(hostID: hostID, designID: designID))
        }
    }

    // MARK: Screens

    /// The canvas state of `id`, made the first time it is shown.
    func designScreen(_ id: DesignID) -> DesignScreenModel {
        if let screen = designScreens[id] { return screen }
        // No host yet: a canvas whose reads fail until it connects, not kept.
        guard let host = localHost else { return localHostDesignScreen(id, library: localDesigns, keep: false) }
        return localHostDesignScreen(id, library: host.designs)
    }

    /// The background host's designs; with no host yet, a library that answers nothing.
    var localDesigns: RemoteDesignLibrary {
        localHost?.designs ?? RemoteDesignLibrary(hostID: UUID(), cache: remoteHosts.designCache)
    }
    /// The canvas of one of the background host's designs, as this app's own: its files read from
    /// the host's folder on this Mac (`designFolder`), its changes and comments through the host,
    /// and messages to its agent through the app's own thread.
    private func localHostDesignScreen(_ id: DesignID, library: RemoteDesignLibrary, keep: Bool = true) -> DesignScreenModel {
        let source = library.source(id)
        let tweak = Self.remoteDesignTweak(library, id)
        let actions = remoteDesignCanvasActions(library, agent: design(id)?.agentID.map { RemoteAgentRef(hostID: library.hostID, agentID: $0) },
                                                ask: { [weak self] agentID, text, record in
            guard let self, self.state.agents.contains(where: { $0.id == agentID }) else { return false }
            await self.threadStores.store(for: agentID).send(text: text, designContext: record)
            return true
        })
        let screen = DesignScreenModel(designID: id, host: designRendering.host(for: id),
                                       snapshot: { _ in try await source.sync().snapshot },
                                       source: { _, path in try await source.source(path) },
                                       comments: remoteDesignCommentActions(library), tweak: tweak, actions: actions)
        if let design = design(id), let system = designSystemName(design) { screen.tweak?.systemName = system }
        screen.referenceActions = designReferenceCanvasActions()
        if keep { designScreens[id] = screen }
        return screen
    }

    /// A design's snapshot and comments from the background host that keeps it.
    func ownerDesignSnapshot(_ id: DesignID) async throws -> DesignSnapshot {
        guard hostDesign(id) != nil, let host = localHost else { throw BackgroundHostClient.HostStarting() }
        return try await host.designs.source(id).sync().snapshot
    }

    func ownerDesignComments(_ id: DesignID) async throws -> DesignComments {
        guard hostDesign(id) != nil, let host = localHost else { throw BackgroundHostClient.HostStarting() }
        guard case .comments(let comments) = try await Self.remoteDesign(host.designs, .comments(designID: id)) else {
            throw RemoteDesignReply.unexpected
        }
        return comments
    }

    /// The designs whose revisions are pushed: the background host's.
    private func watchDesigns() {
        localHost?.designs.watch(visibleDesigns)
    }
    /// A design's layout came on screen or left it: only designs on screen take live views and
    /// get their revisions pushed.
    func designVisibility(_ id: DesignID, visible: Bool) {
        designScreen(id).setActive(visible)
        let changed = visible ? visibleDesigns.insert(id).inserted : visibleDesigns.remove(id) != nil
        if changed { watchDesigns() }
    }

    /// The host pushed a design's new revision: its canvas pulls what changed.
    func designRevised(_ id: DesignID) {
        referencesDesignsChanged()
        guard let screen = designScreens[id] else { return }
        Task { await screen.refresh() }
    }

    /// Designs that are gone give up their canvases and renderers.
    func pruneDesigns() {
        let live = Set(state.designs.map(\.id))
        for id in Set(designScreens.keys).subtracting(live) { designScreens.removeValue(forKey: id) }
        if !visibleDesigns.isSubset(of: live) {
            visibleDesigns.formIntersection(live)
            watchDesigns()
        }
        if let selection = designsPageSelection, !live.contains(selection) { designsPageSelection = nil }
        madeDesignRendering?.prune(keeping: live)
        referencesDesignsChanged()
    }
}

// MARK: New design

/// The New design page's draft (DZStart): the brief, its images, the model and level its agent
/// starts with, and the design system it is drawn in. A design belongs to no project. Owned by
/// the view model, so it survives the page going away.
@MainActor @Observable
final class NewDesignState {
    var brief = ""
    var attachments = ComposerAttachments()
    /// Dropped or pasted images still being resized and read off the main actor.
    private(set) var preparingImages = 0
    /// How dropped images are resized and read; a test holds it to see a send wait.
    @ObservationIgnored var prepareImages: ([NSItemProvider]) async -> [(URL, ImageFile?)] = { providers in
        // A PDF (From a screenshot) goes as its first page.
        await ImageFile.read(await AppImageDrop.resolve(providers).map { PageCapture.imageFile($0) })
    }
    /// Why Send waits for the images being read; nil when none are.
    var imagesPending: String? { preparingImages > 0 ? "Adding images…" : nil }
    /// The model and level the design agent starts with (This Mac's defaults until picked); a
    /// blank model is pi's default. They stay with the design's pi session after that.
    private(set) var model = ""
    private(set) var thinking: ThinkingLevel = .medium
    /// This Mac's catalog, for the model picker and the levels its model takes.
    private(set) var listing: ModelListing?
    private(set) var catalog: ModelCatalog?
    @ObservationIgnored private var edited = (model: false, thinking: false)
    @ObservationIgnored private var loadingDefaults = false
    /// The design system picked from the card's menu; nil draws in the default
    /// (`defaultSystem`).
    private(set) var system: String?
    /// The connected host the design is made on (`RemoteDesignRequest.create`); nil: This Mac.
    private(set) var host: UUID?
    /// A ZIP going to the host to import, and the share of it sent.
    private(set) var uploading: Double?
    private(set) var starting = false
    var error: String?
    /// Bumped to give the field the keyboard.
    var focusRequest = 0

    /// The page is opening: a system picked earlier that is gone reads as none picked, and the
    /// model and level follow Settings unless picked here.
    func prepare(for vm: ShepherdViewModel) {
        if let host, vm.newDesignHost(host) == nil { self.host = nil }
        if host == nil, let system, !vm.designSystems.summaries.isEmpty, vm.designSystems.summary(system) == nil { self.system = nil }
        loadDefaults(vm)
    }

    func setModel(_ id: String) {
        model = id
        edited.model = true
    }

    func setThinking(_ level: ThinkingLevel) {
        thinking = level
        edited.thinking = true
    }

    /// The levels the chosen model takes before its pi starts; empty when it takes none.
    func thinkingLevels() -> [ThinkingLevel] {
        ThinkingLevel.offered(model: model, listing: listing, hostTakesAllLevels: true)
    }

    /// This Mac's model and level (Settings, else pi's default model) and its catalog, the
    /// catalog read once.
    private func loadDefaults(_ vm: ShepherdViewModel) {
        if !edited.model { model = vm.settings.defaultModel(piHome: vm.pi.home) ?? "" }
        if !edited.thinking { thinking = vm.settings.defaultThinking }
        guard listing == nil, !loadingDefaults else { return }
        loadingDefaults = true
        let pi = vm.pi
        Task {
            defer { loadingDefaults = false }
            let listing = await vm.modelListing()
            let catalog = await ModelCatalog.loadLocal(from: pi.catalog)
            self.listing = listing
            self.catalog = catalog
        }
    }

    /// Makes the design on a connected host that serves designs, or nil on This Mac. Its systems
    /// are the host's, so a system picked here goes.
    func choose(host id: UUID?) {
        guard host != id else { return }
        host = id
        system = nil
        error = nil
    }

    /// The systems the design can be drawn in: This Mac's, or the chosen host's.
    func systems(_ vm: ShepherdViewModel) -> [DesignSystemSummary] {
        guard let host else { return vm.designSystems.summaries }
        return vm.newDesignHost(host)?.designs.listing?.systems ?? []
    }

    /// Draws the design in `namespace` (a system from the card's menu).
    func choose(system namespace: String) {
        guard system != namespace else { return }
        system = namespace
        error = nil
    }

    /// The system Send installs and the card shows: the one picked, else the default.
    func systemToInstall(_ vm: ShepherdViewModel) -> String? {
        chosenSystem(in: systems(vm))?.namespace
    }

    func chosenSystem(in systems: [DesignSystemSummary]) -> DesignSystemSummary? {
        if let system, let picked = systems.first(where: { $0.namespace == system }) { return picked }
        return Self.defaultSystem(in: systems)
    }

    /// The system a new design starts in: the most recently changed one built here, else the
    /// first registered built-in, if a caller explicitly supplied one. The app bundles none.
    static func defaultSystem(in systems: [DesignSystemSummary]) -> DesignSystemSummary? {
        systems.filter { !$0.builtIn }.max { $0.info.updatedAt < $1.info.updatedAt } ?? systems.first(where: \.builtIn)
    }

    /// The card under "Design system & starting point" (DZStart): the system the design is
    /// drawn in, naming the project it was read from as information ("design system ·
    /// dashboard-web"), "found in" its first stylesheet there. None yet (the catalog still
    /// loading): a blank canvas.
    static func card(system: DesignSystemSummary?, spaces: [Space]) -> (title: String, line: String, note: String) {
        guard let system else { return ("No design system", "starting point · a blank canvas", "pick one from the menu") }
        let info = system.info
        if system.builtIn { return (info.namespace, "design system · shepherd", "built into Shepherd") }
        let repo = info.spaceID.flatMap { id in spaces.first { $0.id == id }?.name }
        let line = repo.map { "design system · \($0)" } ?? "design system"
        let note = info.sources.first.map { "found in \($0)" } ?? "made in Shepherd"
        return (info.namespace, line, note)
    }

    /// Dropped or pasted images, resized on the way in.
    func attach(_ providers: [NSItemProvider]) {
        attachments.clearError()
        // Send waits while images are being read (`imagesPending`), so a read never lands in a draft sent without it.
        preparingImages += 1
        let prepare = prepareImages
        Task {
            let files = await prepare(providers)
            preparingImages -= 1
            attachments.add(files: files)
        }
    }

    func attach(urls: [URL]) {
        attach(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
    }

    /// The page Capture a page is drawing, by its host; nil when none is.
    private(set) var capturing: String?

    /// Capture a page: the page at `address` drawn off screen and attached to the brief.
    func capture(_ address: String) {
        guard capturing == nil else { return }
        guard let url = PageCapture.address(address) else {
            error = "Enter a web address, like https://staging.acme.dev."
            return
        }
        capturing = url.host() ?? url.absoluteString
        error = nil
        Task {
            defer { capturing = nil }
            do {
                attach(urls: [try await PageCapture.capture(url)])
            } catch {
                self.error = "Couldn't capture \(url.absoluteString): \(ShepherdViewModel.words(error))."
            }
        }
    }

    /// What the line under the card says: a failed start, an upload under way, or an image left out.
    var notice: String? {
        if let uploading { return "Sending the project to the host… \(Int(uploading * 100))%" }
        return error ?? attachments.error ?? NewThreadPlaces.imagesRefusal(attachments.images, host: nil)
    }

    /// Import a project with a host chosen: a Claude Design ZIP, uploaded and imported there
    /// (`design.import.v1`); its canvas opens here.
    func importOnHost(_ url: URL, vm: ShepherdViewModel) {
        guard let host, uploading == nil, let connection = vm.newDesignHost(host) else { return }
        uploading = 0
        error = nil
        Task {
            defer { uploading = nil }
            do {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let (design, agent) = try await connection.designs.importProject(file: url) { [weak self] share in
                    Task { @MainActor in if self?.uploading != nil { self?.uploading = share } }
                }
                if let agent { vm.selectRemoteAgent(hostID: host, agentID: agent) } else { vm.openRemoteDesign(RemoteDesignRef(hostID: host, designID: design)) }
            } catch {
                self.error = "Couldn't import \(url.lastPathComponent): \(ShepherdViewModel.words(error))."
            }
        }
    }

    /// Why Send is unavailable; nil when it can send.
    func blocker(_ vm: ShepherdViewModel) -> String? {
        if starting { return "Starting…" }
        if capturing != nil { return "Capturing the page…" }
        if brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the design first." }
        if let imagesPending { return imagesPending }
        if let big = attachments.oversize { return ComposerAttachments.oversizeMessage(big.name) }
        if let host {
            if vm.newDesignHost(host) == nil { return "That host isn’t connected." }
            if !attachments.images.isEmpty { return "Images go only to a design made on This Mac for now." }
            if RemoteDesignCreate.brief(brief) == nil { return "A brief is at most \(RemoteDesignCreate.maxBriefBytes / 1024) KB." }
        }
        return NewThreadPlaces.imagesRefusal(attachments.images, host: nil)
    }

    /// Send: makes the design, starts its agent with the brief, and opens the canvas. The draft
    /// clears once the design exists.
    func send(_ vm: ShepherdViewModel) {
        guard blocker(vm) == nil else { NSSound.beep(); return }
        let submittedBrief = brief
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        let images = attachments.images
        let submittedImages = attachments.ids
        let system = systemToInstall(vm)
        let chosenModel = model.trimmingCharacters(in: .whitespaces)
        let level = thinking.clamped(to: thinkingLevels())
        starting = true
        error = nil
        let host = host
        Task {
            defer { starting = false }
            do {
                if let host {
                    // The host's New design: its own model and level, its systems.
                    try await vm.createDesign(onHost: host, brief: text, system: system)
                } else {
                    try await vm.createDesign(brief: text, images: images, system: system,
                                              model: chosenModel.isEmpty ? nil : chosenModel, thinking: level)
                }
                // Only what went: words typed and images added while it was being made stay for the next one.
                if brief == submittedBrief { brief = "" }
                for id in submittedImages { attachments.remove(id) }
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
