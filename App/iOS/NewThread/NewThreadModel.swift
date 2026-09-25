import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// One New thread form while it is on screen: the prompt, where it runs (host, repo, worktree),
/// model and thinking, images, and Start. The rules are `NewThreadRules` (ShepherdRemote),
/// which mirror the Mac's New Agent sheet; this store asks the host and keeps the answers.
/// Rows are derived once per host change, never in a view's body.
@MainActor
@Observable
final class NewThreadModel {
    /// The form on screen, for the screenshot fixtures' `prepare`.
    @ObservationIgnored static weak var active: NewThreadModel?

    /// What a chip or row opened: on iPhone, Where it runs holds repo, host and worktree
    /// together; on iPad each is its own popover.
    enum Panel: Hashable {
        case workspace, repo, host, worktree, model
    }

    var panel: Panel?
    /// The part of Where it runs to show first: `.worktree` when the worktree line opened it.
    var workspaceAnchor: Panel?
    var prompt = ""
    private(set) var hostID: UUID?
    private(set) var spaceID: SpaceID?
    private(set) var defaults = NewThreadDefaults()
    private(set) var modelOptions: [String] = []
    private(set) var modelQuery = ""
    private(set) var modelMatches: [String] = []
    private(set) var worktreeWanted = true
    private(set) var branch = ""
    private(set) var base = NewThreadBase()
    private(set) var attachments: [NewThreadAttachment] = []
    var errorText: String?
    private(set) var starting = false
    private(set) var hostRows: [NewThreadHostRow] = []
    private(set) var repoRows: [NewThreadRepoRow] = []
    private(set) var inputs: [NewThreadHostInput] = []
    /// The folder browser pushed from Add repo.
    var folders: NewThreadFolderBrowser?

    @ObservationIgnored private let hosts: MobileHosts
    @ObservationIgnored private let threads: ThreadStores
    @ObservationIgnored private let navigator: MobileNavigator
    @ObservationIgnored private let preferredHost: UUID?
    @ObservationIgnored private let context: AgentRef?
    @ObservationIgnored private var began = false
    /// Each host's connection, so defaults that failed load again only on a new one.
    @ObservationIgnored private var sessions: [UUID: UUID] = [:]
    @ObservationIgnored private var defaultsSession: UUID?
    /// A repo just added, until the host's state push brings it.
    @ObservationIgnored private var pendingSpace: SpaceID?

    init(hosts: MobileHosts, threads: ThreadStores, navigator: MobileNavigator, preferredHost: UUID?, context: AgentRef?) {
        self.hosts = hosts
        self.threads = threads
        self.navigator = navigator
        self.preferredHost = preferredHost
        self.context = context
    }

    // MARK: Derived

    var host: NewThreadHostInput? { inputs.first { $0.id == hostID } }
    var space: Space? { host?.spaces.first { $0.id == spaceID } }
    var usesWorktree: Bool { draft.usesWorktree }

    var draft: NewThreadDraft {
        NewThreadDraft(prompt: prompt, host: host, space: space, defaults: defaults, worktree: worktreeWanted, branch: branch,
                       base: base, attachments: attachments.count, starting: starting)
    }

    var blocker: NewThreadBlocker? { NewThreadRules.blocker(draft) }

    // MARK: Lifetime

    /// Starts following the hosts and picks where the thread runs.
    func begin() {
        guard !began else { return }
        began = true
        Self.active = self
        track()
        chooseInitialTarget()
    }

    private func track() {
        let next = withObservationTracking {
            (hosts.hosts.map { host in
                NewThreadHostInput(id: host.id, name: host.name, phase: host.phase, capabilities: host.capabilities, state: host.state)
            }, Dictionary(hosts.hosts.compactMap { host in host.session.map { (host.id, $0) } }, uniquingKeysWith: { first, _ in first }))
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.track() }
        }
        sessions = next.1
        guard next.0 != inputs else { return }
        inputs = next.0
        hostsChanged()
    }

    private func hostsChanged() {
        rebuildRows()
        guard let host else {
            chooseInitialTarget()
            return
        }
        if let pendingSpace, host.spaces.contains(where: { $0.id == pendingSpace }) { self.pendingSpace = nil }
        if space == nil, pendingSpace == nil || pendingSpace != spaceID, let first = host.spaces.first {
            spaceID = first.id
            rebuildRows()
        }
        // A host that comes back (or a repo that arrives) gets its defaults once per connection.
        if host.phase.isConnected, !defaults.ready, !defaults.loading, space != nil, sessions[host.id] != defaultsSession {
            loadDefaults()
        }
        refreshBase()
    }

    private func rebuildRows() {
        let hostRows = NewThreadRows.hosts(inputs, selected: hostID)
        if hostRows != self.hostRows { self.hostRows = hostRows }
        let repoRows = NewThreadRows.repos(inputs, host: hostID, space: spaceID)
        if repoRows != self.repoRows { self.repoRows = repoRows }
    }

    /// The host asked for, else the thread on screen's, else the first connected host with a
    /// repo. With nothing connected, an offline host is still chosen so the form says why.
    private func chooseInitialTarget() {
        guard hostID == nil, !inputs.isEmpty else { return }
        let connected = inputs.filter(\.phase.isConnected)
        let wanted = [preferredHost, context?.host].compactMap { $0 }
        let pick = wanted.first { id in connected.contains { $0.id == id } }
            ?? connected.first { !$0.spaces.isEmpty }?.id
            ?? connected.first?.id
            ?? wanted.first { id in inputs.contains { $0.id == id } }
            ?? inputs.first?.id
        guard let pick else { return }
        hostID = pick
        let contextSpace = context?.host == pick ? hosts.agent(context!)?.spaceID : nil
        let spaces = inputs.first { $0.id == pick }?.spaces ?? []
        spaceID = spaces.first { $0.id == contextSpace }?.id ?? spaces.first?.id
        rebuildRows()
        loadDefaults()
        refreshBase()
    }

    // MARK: Choosing

    func choose(host id: UUID) {
        guard id != hostID, hostRows.first(where: { $0.id == id })?.selectable == true else { return }
        hostID = id
        if space == nil { spaceID = host?.spaces.first?.id }
        errorText = nil
        rebuildRows()
        loadDefaults()
        refreshBase()
    }

    func choose(repo id: NewThreadRepoRow.ID) {
        if id.host != hostID {
            hostID = id.host
            spaceID = id.space
            errorText = nil
            rebuildRows()
            loadDefaults()
        } else {
            spaceID = id.space
            rebuildRows()
            if !defaults.ready && !defaults.loading { loadDefaults() }
        }
        refreshBase()
    }

    func setWorktree(_ on: Bool) {
        worktreeWanted = on
        refreshBase()
    }

    func setBranch(_ value: String) { branch = value }

    func setBase(_ value: String) { base.base = value }

    func setFetchFirst(_ on: Bool) {
        base.fetchFirst = on
        resolveBase(fetch: on)
    }

    func setModel(_ id: String) {
        defaults.edit(model: id)
    }

    func setThinking(_ level: ThinkingLevel) {
        defaults.edit(thinking: level)
    }

    func setModelQuery(_ query: String) {
        modelQuery = query
        rankModels()
    }

    private func rankModels() {
        let matches = NewThreadRules.rankModels(modelQuery, in: modelOptions)
        if matches != modelMatches { modelMatches = matches }
    }

    func retry(host id: UUID) { hosts.retry(id) }

    // MARK: The host's answers

    /// The host's model and thinking for a new thread (`creationOptions`), then its catalog.
    func loadDefaults() {
        guard let hostID else { return }
        let requestID = defaults.begin(hostID: hostID)
        defaultsSession = sessions[hostID]
        // A new attempt replaces the last one's error; what still blocks Start says so itself.
        errorText = nil
        modelOptions = []
        rankModels()
        guard let client = hosts.host(hostID)?.connectedClient, let spaceID else {
            defaults.fail(requestID: requestID)
            return
        }
        Task {
            do {
                let options = try await client.creationOptions(spaceID: spaceID, cwd: nil, fetchFirst: nil)
                guard defaults.requestID == requestID, self.hostID == hostID else { return }
                defaults.apply(requestID: requestID, model: options.model, thinking: options.thinking)
                // A catalog failure leaves the editable defaults usable.
                if let listing = try? await client.listModels(), defaults.requestID == requestID {
                    modelOptions = listing.models
                    rankModels()
                }
            } catch {
                guard defaults.requestID == requestID else { return }
                defaults.fail(requestID: requestID)
                errorText = Self.message(error)
            }
        }
    }

    /// Resolves the worktree's base for the current target when it is not resolved for it yet.
    private func refreshBase() {
        guard draft.usesWorktree, let target = draft.baseTarget else { return }
        if branch.isEmpty { branch = NewThreadRules.generatedBranch() }
        if base.target != target { resolveBase(fetch: nil) }
    }

    /// Asks the host for the base it would branch from (after a fetch when `fetch` is true).
    func resolveBase(fetch: Bool?) {
        guard draft.usesWorktree, let target = draft.baseTarget else { return }
        let requestID = base.begin(target)
        errorText = nil
        guard let client = hosts.host(target.host)?.connectedClient else {
            base.fail(requestID: requestID)
            return
        }
        Task {
            do {
                let options = try await client.creationOptions(spaceID: target.space, cwd: target.cwd, fetchFirst: fetch)
                base.apply(requestID: requestID, options: options)
            } catch {
                guard base.requestID == requestID else { return }
                base.fail(requestID: requestID)
                errorText = Self.message(error)
            }
        }
    }

    // MARK: Attachments

    func add(_ attachment: NewThreadAttachment) {
        guard attachments.count < NativeImage.maxPerSend else { return }
        attachments.append(attachment)
    }

    func remove(attachment id: UUID) {
        attachments.removeAll { $0.id == id }
    }

    // MARK: Start

    /// Creates the agent as the Mac does, then opens its thread. Images go with the first send,
    /// since createAgent takes none.
    func start() {
        guard let creation = NewThreadRules.creation(draft), let hostID, let client = hosts.host(hostID)?.connectedClient else { return }
        starting = true
        errorText = nil
        let images = attachments.map(\.image)
        Task {
            do {
                let agentID = try await client.createAgent(
                    spaceID: creation.spaceID, cwd: creation.cwd, model: creation.model, thinking: creation.thinking,
                    initialPrompt: creation.initialPrompt, worktreeBranch: creation.worktreeBranch,
                    worktreeBase: creation.worktreeBase, worktreeFetchFirst: creation.worktreeFetchFirst)
                let ref = AgentRef(host: hostID, agent: agentID)
                if let text = creation.firstSend { sendFirst(text, images: images, to: ref) }
                navigator.dismissPresented()
                navigator.open(.thread(ref))
            } catch {
                errorText = Self.message(error)
                starting = false
            }
        }
    }

    /// Puts the prompt in the new thread's composer and sends it with the images once the
    /// thread's screen runs its store; the send itself waits for pi to start.
    private func sendFirst(_ text: String, images: [NativeImage], to ref: AgentRef) {
        let store = threads.store(for: ref)
        store.draft = text
        Task {
            let deadline = ContinuousClock.now + .seconds(30)
            while !store.isLive, ContinuousClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard store.isLive, store.draft == text else { return }
            await store.send(images: images)
        }
    }

    // MARK: Repos

    func browseFolders() {
        guard let host, host.phase.isConnected, let client = hosts.host(host.id)?.connectedClient else { return }
        folders = NewThreadFolderBrowser(hostName: host.name, client: client)
    }

    /// Adds `path` as a space on the host and chooses it. The space arrives with the host's
    /// next state push.
    func addRepo(_ path: String) async -> Bool {
        guard let hostID, let client = hosts.host(hostID)?.connectedClient else { return false }
        do {
            let id = try await client.addSpace(path: path)
            guard self.hostID == hostID else { return true }
            if host?.spaces.contains(where: { $0.id == id }) != true { pendingSpace = id }
            spaceID = id
            rebuildRows()
            if !defaults.ready && !defaults.loading { loadDefaults() }
            refreshBase()
            return true
        } catch {
            folders?.errorText = Self.message(error)
            return false
        }
    }

    static func message(_ error: Error) -> String {
        if case RemoteHostClientError.rejected(_, let message) = error { return message }
        return String(describing: error)
    }
}
