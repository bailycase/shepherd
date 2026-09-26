import Foundation
import AppKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdUI

/// Where a new thread runs: a project (a space) on This Mac (`host` nil) or on a host.
struct NewThreadPlace: Hashable {
    var host: UUID?
    var space: SpaceID
}

/// The New thread page's workplace chip and its menu, as plain values (NavNewThread): every
/// host's projects (its spaces, nested ones flattened), "Add folder…" on each, and the chip's
/// "project · host". Pure.
enum NewThreadPlaces {
    struct Host: Equatable {
        /// Nil for This Mac.
        var id: UUID?
        var name: String
        var spaces: [Space]
    }

    static let thisMac = "This Mac"

    /// This Mac's projects, then each connected host's, the chosen one checked.
    static func sections(_ hosts: [Host], chosen: NewThreadPlace?) -> [NWPlaceSection] {
        hosts.map { host in
            NWPlaceSection(id: sectionID(host.id), title: host.name, options: host.spaces.map { space in
                NWPlaceOption(id: optionID(NewThreadPlace(host: host.id, space: space.id)), section: sectionID(host.id),
                              title: space.name, detail: NewThreadRules.abbreviatedPath(space.path),
                              isCurrent: chosen == NewThreadPlace(host: host.id, space: space.id))
            })
        }
    }

    /// The chip's words: the project and its host ("shepherd", "This Mac").
    static func chip(_ hosts: [Host], chosen: NewThreadPlace?) -> (project: String, host: String) {
        guard let chosen, let host = hosts.first(where: { $0.id == chosen.host }),
              let space = host.spaces.first(where: { $0.id == chosen.space }) else {
            return ("Choose a project", hosts.first?.name ?? thisMac)
        }
        return (space.name, host.name)
    }

    /// The project a page opens on: the one chosen while it still exists, else the space of the
    /// thread last on screen, else This Mac's first, else the first host's first.
    static func fallback(_ hosts: [Host], chosen: NewThreadPlace?, recent: NewThreadPlace?) -> NewThreadPlace? {
        func exists(_ place: NewThreadPlace?) -> NewThreadPlace? {
            guard let place, hosts.contains(where: { $0.id == place.host && $0.spaces.contains { $0.id == place.space } }) else { return nil }
            return place
        }
        if let chosen = exists(chosen) { return chosen }
        if let recent = exists(recent) { return recent }
        for host in hosts {
            if let space = host.spaces.first { return NewThreadPlace(host: host.id, space: space.id) }
        }
        return nil
    }

    static func sectionID(_ host: UUID?) -> String { host?.uuidString ?? "local" }

    static func optionID(_ place: NewThreadPlace) -> String { "\(sectionID(place.host))/\(place.space.rawValue)" }

    /// The place an option stands for.
    static func place(_ option: NWPlaceOption) -> NewThreadPlace? {
        let parts = option.id.split(separator: "/", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        let host = parts[0] == "local" ? nil : UUID(uuidString: parts[0])
        if parts[0] != "local", host == nil { return nil }
        return NewThreadPlace(host: host, space: SpaceID(rawValue: parts[1]))
    }

    /// The host an "Add folder…" row adds to.
    static func host(of section: NWPlaceSection) -> UUID? {
        section.id == "local" ? nil : UUID(uuidString: section.id)
    }

    /// Why the attached images cannot go with a new thread there, or nil: a host from before
    /// `createAgentImagesCapability` would drop them, and one send takes only so much. `host` is
    /// nil for This Mac.
    static func imagesRefusal(_ images: [NativeImage], host: (name: String, takesImages: Bool)?) -> String? {
        guard !images.isEmpty else { return nil }
        if let host, !host.takesImages { return "Update Shepherd on \(host.name) to start a thread with images." }
        guard NativeImage.fitOneSend(images) else {
            return "The images come to over \(NativeImage.maxBytesPerSend / 1024 / 1024) MiB together. Remove one to send."
        }
        return nil
    }
}

/// The New thread page's draft (NavNewThread): what to do, with which images, where, with which
/// model and level, and whether in a new worktree. Owned by the view model, so it survives the
/// page going away.
@MainActor @Observable
final class NewThreadState {
    var prompt = ""
    /// Go to pi with the opening prompt, as a thread's composer sends them.
    var attachments = ComposerAttachments()
    private(set) var place: NewThreadPlace?
    var worktree = false
    /// The model and level the thread starts with; a blank model is the target's default.
    private(set) var model = ""
    private(set) var thinking: ThinkingLevel = .medium
    /// The target's catalog, for the model picker and the levels its model takes.
    private(set) var listing: ModelListing?
    private(set) var catalog: ModelCatalog?
    /// A host's defaults are loading.
    private(set) var loadingDefaults = false
    private(set) var starting = false
    var error: String?
    /// Bumped to give the field the keyboard (⌘N, the destination).
    var focusRequest = 0
    @ObservationIgnored private var edited = (model: false, thinking: false)
    @ObservationIgnored private var defaultsRequest = UUID()
    @ObservationIgnored private var defaultsHost: UUID??

    /// Every host a thread can start on: This Mac, and each connected host.
    static func hosts(_ vm: ShepherdViewModel) -> [NewThreadPlaces.Host] {
        [NewThreadPlaces.Host(id: nil, name: NewThreadPlaces.thisMac, spaces: vm.visibleSpaces)]
            + vm.remoteHosts.connections.filter { $0.phase == .connected }.map {
                NewThreadPlaces.Host(id: $0.id, name: $0.config.name, spaces: $0.state.spaces.filter { !$0.hidden })
            }
    }

    /// The page is opening: keep the chosen project while it exists, else pick one, and load
    /// the target's defaults.
    func prepare(for vm: ShepherdViewModel) {
        let recent: NewThreadPlace? = if let remote = vm.selectedRemoteAgent, let agent = vm.remoteAgent(remote) {
            NewThreadPlace(host: remote.hostID, space: agent.spaceID)
        } else {
            vm.selectedSpaceID.map { NewThreadPlace(host: nil, space: $0) }
        }
        let next = NewThreadPlaces.fallback(Self.hosts(vm), chosen: place, recent: recent)
        if next != place { place = next }
        loadDefaults(vm)
    }

    /// A project from the chip's menu.
    func choose(host: UUID?, space: SpaceID, vm: ShepherdViewModel) {
        let next = NewThreadPlace(host: host, space: space)
        guard next != place else { return }
        place = next
        error = nil
        if host != nil, vm.remoteHosts.connections.first(where: { $0.id == host })?.supportsWorktreeCreation != true { worktree = false }
        loadDefaults(vm)
    }

    /// Dropped or pasted images, resized on the way in as the thread's composer does.
    func attach(_ providers: [NSItemProvider]) {
        attachments.clearError()
        Task {
            let urls = await AppImageDrop.resolve(providers)
            attachments.add(urls: urls)
        }
    }

    /// Images from the file importer.
    func attach(urls: [URL]) {
        attach(urls.map { NSItemProvider(contentsOf: $0) ?? NSItemProvider() })
    }

    /// Why the attached images cannot go where the thread would start, or nil.
    func imagesRefusal(_ vm: ShepherdViewModel) -> String? {
        let host: (name: String, takesImages: Bool)? = place?.host.flatMap { id in
            vm.remoteHosts.connections.first { $0.id == id }.map { ($0.config.name, $0.supportsCreateAgentImages) }
        }
        return NewThreadPlaces.imagesRefusal(attachments.images, host: host)
    }

    /// What the line under the card says: a failed start, an image left out, or why the images
    /// cannot go.
    func notice(_ vm: ShepherdViewModel) -> String? {
        error ?? attachments.error ?? imagesRefusal(vm)
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
    func thinkingLevels(_ vm: ShepherdViewModel) -> [ThinkingLevel] {
        let all = place?.host.flatMap { id in vm.remoteHosts.connections.first { $0.id == id }?.supportsAllThinkingLevels } ?? true
        return ThinkingLevel.offered(model: model, listing: listing, hostTakesAllLevels: all)
    }

    /// Whether the chosen project can take a new worktree: a git checkout here, or a host that
    /// makes them.
    func offersWorktree(_ vm: ShepherdViewModel) -> Bool {
        guard let place else { return false }
        if let host = place.host {
            return vm.remoteHosts.connections.first { $0.id == host }?.supportsWorktreeCreation == true
        }
        return vm.state.spaces.first { $0.id == place.space }.map(vm.spaceIsRepo) ?? false
    }

    /// Model and level from the target: This Mac's settings, or the host's `creationOptions`,
    /// and the target's catalog. A user's pick survives a reload for the same target.
    private func loadDefaults(_ vm: ShepherdViewModel) {
        let host = place?.host
        if defaultsHost == .some(host), !loadingDefaults, listing != nil { return }
        if defaultsHost != .some(host) { edited = (false, false) }
        defaultsHost = .some(host)
        let request = UUID()
        defaultsRequest = request
        listing = nil
        catalog = nil
        guard let host else {
            loadingDefaults = false
            if !edited.model { model = vm.settings.agentDefaults.model ?? PiConfig.defaultModel(in: vm.server.pi.home) ?? "" }
            if !edited.thinking { thinking = vm.settings.defaultThinking }
            let server = vm.server
            Task {
                let listing = await Task.detached(priority: .userInitiated) { server.modelListing() }.value
                let catalog = await ModelCatalog.loadLocal(from: server.pi.catalog)
                guard defaultsRequest == request else { return }
                self.listing = listing
                self.catalog = catalog
            }
            return
        }
        loadingDefaults = true
        let space = place?.space
        Task {
            do {
                guard let space else { throw RemoteHostClientError.rejected(code: "no_space", message: "Choose a project first") }
                let options = try await vm.remoteHosts.creationOptions(hostID: host, spaceID: space, cwd: nil, fetchFirst: nil)
                guard defaultsRequest == request else { return }
                if !edited.model { model = options.model ?? "" }
                if !edited.thinking { thinking = options.thinking }
                loadingDefaults = false
                if let listing = try? await vm.remoteHosts.listModels(hostID: host), defaultsRequest == request {
                    let all = vm.remoteHosts.connections.first { $0.id == host }?.supportsAllThinkingLevels ?? false
                    self.listing = listing
                    catalog = await ModelCatalog.derive(listing, hostTakesAllLevels: all)
                }
            } catch {
                guard defaultsRequest == request else { return }
                loadingDefaults = false
                self.error = "\(error)"
            }
        }
    }

    /// Why Send is unavailable; nil when it can send.
    func blocker(_ vm: ShepherdViewModel) -> String? {
        if starting { return "Starting…" }
        guard let place else { return "Add a project to start a thread." }
        if let host = place.host {
            guard let connection = vm.remoteHosts.connections.first(where: { $0.id == host }), connection.phase == .connected else {
                return "That host is offline."
            }
            if loadingDefaults { return "Loading \(connection.config.name)'s defaults…" }
        }
        if prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Describe the task first." }
        return imagesRefusal(vm)
    }

    /// Send: creates the agent with the prompt as its opening message, in a new worktree when
    /// asked, and selects it. The draft clears once the agent exists.
    func send(_ vm: ShepherdViewModel) {
        guard blocker(vm) == nil, let place else { NSSound.beep(); return }
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        let chosenModel = model.trimmingCharacters(in: .whitespaces)
        let level = thinking.clamped(to: thinkingLevels(vm))
        let useWorktree = worktree && offersWorktree(vm)
        let images = attachments.images
        starting = true
        error = nil
        Task {
            defer { starting = false }
            do {
                if let host = place.host {
                    guard let space = vm.remoteHosts.connections.first(where: { $0.id == host })?.state.spaces
                        .first(where: { $0.id == place.space }) else { throw AgentStartFailure(message: "That project is gone.") }
                    var base: RemoteCreationOptions?
                    if useWorktree {
                        base = try await vm.remoteHosts.creationOptions(hostID: host, spaceID: space.id, cwd: space.path, fetchFirst: nil)
                    }
                    try await vm.createRemoteAgent(
                        hostID: host, spaceID: space.id, cwd: space.path, model: chosenModel.isEmpty ? nil : chosenModel,
                        thinking: level, initialPrompt: text,
                        worktreeBranch: useWorktree ? NewThreadRules.generatedBranch() : nil,
                        worktreeBase: base?.base, worktreeFetchFirst: base?.fetchFirst, initialImages: images)
                } else {
                    guard let space = vm.state.spaces.first(where: { $0.id == place.space }) else {
                        throw AgentStartFailure(message: "That project is gone.")
                    }
                    var config = NewAgentConfig(spaceID: space.id, workingDirectory: space.path,
                                                model: chosenModel.isEmpty ? nil : chosenModel, thinking: level, initialPrompt: text)
                    config.initialImages = images
                    if useWorktree {
                        let repo = space.path
                        let branch = GitWorktree.generatedBranch()
                        let mode = vm.settings.worktreeBaseMode
                        let fetch = vm.settings.worktreeFetchBeforeCreate
                        let (path, base) = try await Task.detached(priority: .userInitiated) { () -> (String, String) in
                            let resolution = GitWorktree.resolveBase(repo: repo, mode: mode, fetchFirst: fetch)
                            return (try GitWorktree.add(repo: repo, branch: branch, from: resolution.startPoint), resolution.display)
                        }.value
                        config.workingDirectory = path
                        config.worktreeBranch = branch
                        config.worktreeBase = base
                        config.worktreePath = path
                    }
                    try await vm.startAgent(config, focusWindow: false)
                }
                prompt = ""
                attachments.removeAll()
                worktree = false
            } catch RemoteHostClientError.rejected(_, let message) {
                self.error = message
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            }
        }
    }
}
