import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

// Design systems in the app (DZSystem, NavDesigns): the catalog read from the server, a system's
// page, and "Build one from a repo". A system an agent builds from a repository belongs to a
// design made for it (`Design.buildsSystem`): its page is that design agent's layout, with the
// agent's report in its chat, so opening it is a visibility flip like any design. Every other
// system (Night Watch, one a canvas's agent wrote) opens as the Design systems page, without a
// chat. The repository is only read.

extension ShepherdViewModel {
    /// The words a system build's agent starts from.
    static let systemBuildBrief = "Build a design system from this project: read its tokens file, its component templates and a "
        + "few pages (read only), write the system with system_write, and tell me what doesn't match."

    var designSystemReader: DesignSystemReader {
        let server = server
        return DesignSystemReader(summaries: { await server.designSystemSummaries() },
                                  system: { try await server.designSystem($0) },
                                  resync: { try await server.resyncDesignSystem($0) })
    }

    /// Reads the systems again.
    func loadDesignSystems() async {
        await designSystems.load(designSystemReader)
    }

    /// The server says a system changed: its page and cards read it again.
    func designSystemsChanged() {
        guard designToolEnabled || designSystems.loaded else { return }
        Task { await loadDesignSystems() }
    }

    // MARK: Opening

    /// A system's page: a build's agent layout, else the Design systems page.
    func openDesignSystem(_ namespace: String) {
        guard designToolEnabled else { return }
        if let owner = designSystems.summary(namespace)?.info.ownerDesignID, let build = design(owner), build.buildsSystem {
            openSystemBuild(build.id)
            return
        }
        lastDesignSystem = .system(namespace)
        if shownDesignSystem != namespace { shownDesignSystem = namespace }
        openDestination(.designSystem)
    }

    /// A build's page: its agent's layout (a fresh agent when it is gone).
    func openSystemBuild(_ id: DesignID) {
        lastDesignSystem = .build(id)
        // Its sidebar row is More ▸ Design systems, as Hosts is.
        if !moreOpen { moreOpen = true }
        openDesign(id)
    }

    /// More ▸ Design systems: the system page opened last, else the first system built here, else
    /// the first listed (Night Watch).
    func openDesignSystems() {
        guard designToolEnabled else { return }
        switch lastDesignSystem {
        case .build(let id)? where design(id) != nil:
            openSystemBuild(id)
            return
        case .system(let namespace)? where designSystems.summary(namespace) != nil:
            openDesignSystem(namespace)
            return
        default:
            break
        }
        if let first = designSystems.summaries.first(where: { !$0.builtIn }) ?? designSystems.summaries.first {
            openDesignSystem(first.namespace)
        } else {
            openDestination(.designSystem)
            Task { await loadDesignSystems() }
        }
    }

    /// The system the Design systems page draws: the one opened, else the first listed.
    var designSystemShown: String? {
        if let shown = shownDesignSystem, designSystems.summary(shown) != nil { return shown }
        return designSystems.summaries.first(where: { !$0.builtIn })?.namespace ?? designSystems.summaries.first?.namespace
    }

    /// A system's colors on a card or chip.
    func designSystemSwatches(_ namespace: String?, count: Int) -> [DesignSystemPresentation.Swatch] {
        guard let namespace else { return [] }
        return DesignSystemPresentation.swatches(designSystems.tokens(namespace), count: count)
    }

    // MARK: Building one

    /// "Build one from a repo": a design whose agent builds a system from the project `spaceID`
    /// (its source, read only), opened on its page. A project with a build already opens that one.
    func buildDesignSystem(in spaceID: SpaceID) {
        guard designToolEnabled, let space = state.spaces.first(where: { $0.id == spaceID }) else { return }
        if let existing = state.designs.first(where: { $0.buildsSystem && $0.sourceSpaceID == spaceID }) {
            openSystemBuild(existing.id)
            return
        }
        guard !startingSystemBuilds.contains(spaceID) else { return }
        startingSystemBuilds.insert(spaceID)
        Task {
            defer { startingSystemBuilds.remove(spaceID) }
            do {
                let design = Design(name: space.name, createdAt: SessionServer.nowMilliseconds(), buildsSystem: true,
                                    sourceSpaceID: space.id)
                _ = try await server.createDesign(design)
                adopt(server.state)
                lastDesignSystem = .build(design.id)
                // A build whose agent failed to start still opens later, and starts one then.
                try await startDesignAgent(design, brief: Self.systemBuildBrief, images: [])
            } catch {
                remoteActionError = "Couldn't build a design system from \(space.name): \(error)"
            }
        }
    }

    /// Re-sync: the system's stylesheets read again from its project.
    func resyncDesignSystem(_ namespace: String) {
        let reader = designSystemReader
        Task {
            do {
                try await designSystems.resync(namespace, reader)
            } catch {
                remoteActionError = "Couldn't re-sync \(namespace): \(Self.systemFailure(error))"
            }
        }
    }

    static func systemFailure(_ error: Error) -> String {
        if let error = error as? DesignSystemError { return error.description }
        return (error as? LocalizedError)?.errorDescription ?? "\(error)"
    }

    // MARK: The page

    /// A system's page as its view draws it, derived again only when what it reads changed.
    func designSystemPage(_ target: DesignSystemTarget) -> DesignSystemPageModel {
        let now = Date()
        let build: Design?
        let summary: DesignSystemSummary?
        switch target {
        case .system(let namespace):
            build = nil
            summary = designSystems.summary(namespace)
        case .build(let id):
            build = design(id)
            summary = designSystems.system(builtBy: id)
        }
        let namespace = summary?.namespace
        let inputs = DesignSystemPageInputs(
            summary: summary, read: namespace.flatMap { designSystems.reads[$0] }, build: build, spaces: state.spaces,
            designs: namespace.map { ns in state.designs.filter { $0.systemNamespace == ns } } ?? [],
            syncing: namespace.map { designSystems.syncing.contains($0) } ?? false,
            minute: Int(now.timeIntervalSince1970 / 60))
        if let cached = designSystemPageCache[target], cached.inputs == inputs { return cached.model }
        let model = DesignSystemPageModel.make(summary: inputs.summary, read: inputs.read, build: inputs.build, spaces: inputs.spaces,
                                               designs: inputs.designs, syncing: inputs.syncing, now: now)
        designSystemPageCache[target] = (inputs, model)
        return model
    }

    /// Draws a system's component specimens from its files, when its revision moved.
    func loadDesignSpecimens(_ namespace: String) async {
        guard let summary = designSystems.summary(namespace), designSystems.reads[namespace] != nil else { return }
        let revision = "\(summary.info.revision)/\(summary.builtIn)"
        let specimens = designRendering.specimens
        guard !specimens.has(namespace, revision: revision) else { return }
        guard let files = try? await server.designSystemContents(namespace) else { return }
        let tokens = designSystems.tokens(namespace)
        let background = DesignSystemPresentation.background(tokens)?.light
        specimens.update(namespace, revision: revision, files: files,
                         boards: DesignSpecimenBoard.boards(tokens, files: files, background: background))
    }
}
