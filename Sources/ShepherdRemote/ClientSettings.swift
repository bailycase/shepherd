import Foundation
import Observation
import ShepherdCore
import ShepherdProtocol

// Settings on the iPhone and the iPad: a host's settings (Defaults, Worktrees, Extensions), its
// root instructions, and its suggested instructions, read and changed over the remote protocol.
// The models here hold what the screens draw and every rule they follow, so the screens only
// draw; they take the hosts as the app knows them now (`SettingsHost`).

/// What a client's Settings reads and changes a host through: its `RemoteHostClient`, or a
/// stand-in in tests.
public protocol SettingsClient: SkillsClient {
    func hostSettings(_ request: RemoteHostSettingsRequest) async throws -> HostSettings
    func instructions(_ request: RemoteInstructionsRequest) async throws -> InstructionsSnapshot
    func suggestions(_ request: RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot
    /// The host's MCP servers, subagent profiles and providers (`hostInventory.v1`).
    func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult
    /// Changes them (`hostConfig.v1`).
    func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult
    /// The host's model catalog, for its model menus.
    func listModels() async throws -> ModelListing
}

extension SettingsClient {
    /// A stand-in that has no inventory.
    public func hostInventory(_ request: RemoteHostInventoryRequest) async throws -> RemoteHostInventoryResult {
        throw RemoteHostClientError.rejected(code: "update_required", message: "This host has no inventory to share.")
    }

    public func hostConfig(_ request: RemoteHostConfigRequest) async throws -> RemoteHostConfigResult {
        throw RemoteHostClientError.rejected(code: "update_required", message: "This host's configuration can't be changed from here.")
    }

    public func listModels() async throws -> ModelListing { ModelListing(models: [], defaultModel: nil) }
}

extension RemoteHostClient: SettingsClient {}

/// A host as a client's Settings sees it now.
public struct SettingsHost: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// nil while it isn't connected.
    public let client: (any SettingsClient)?
    public let capabilities: Set<String>

    public init(id: UUID, name: String, client: (any SettingsClient)?, capabilities: Set<String>) {
        self.id = id
        self.name = name
        self.client = client
        self.capabilities = capabilities
    }

    public var isConnected: Bool { client != nil }

    /// Connected, and serving `capability`.
    public func serves(_ capability: String) -> Bool {
        client != nil && capabilities.contains(capability)
    }
}

/// A host's answer as words for the screen: its own reason, else that it didn't answer.
public func settingsProblem(_ error: Error) -> String {
    if case RemoteHostClientError.rejected(_, let message) = error { return message }
    return "The host didn't answer. Try again once it's connected."
}

// MARK: Host settings

/// Each host's settings (Settings ▸ Defaults, Worktrees, Extensions). A change shows at once and
/// goes to the host; a host that refuses it puts its own settings back.
@MainActor
@Observable
public final class ClientHostSettings {
    public enum State: Equatable, Sendable {
        case offline
        /// Its Shepherd predates `hostSettings.v1`.
        case unsupported
        case loading
        case loaded(HostSettings)
        case failed(String)
    }

    private var loaded: [UUID: State] = [:]
    /// Each host's model catalog, once read (`loadModels`).
    private var catalogs: [UUID: [String]] = [:]
    /// Each host's models that take images, read with its catalog (all of them when the host
    /// does not say).
    private var imageCatalogs: [UUID: [String]] = [:]
    @ObservationIgnored private var forgotten: Set<UUID> = []

    public func forget(host: UUID) {
        forgotten.insert(host)
        loaded[host] = nil
        catalogs[host] = nil
        imageCatalogs[host] = nil
    }

    /// The models a host's model menus offer, with `current` kept even when the catalog lacks it.
    public func models(of host: SettingsHost, current: String? = nil) -> [String] {
        let models = catalogs[host.id] ?? []
        guard let current, !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }

    /// The models a host's image reading menu offers: the ones its catalog does not call
    /// text-only, with `current` kept even when it is not among them.
    public func imageModels(of host: SettingsHost, current: String? = nil) -> [String] {
        let models = imageCatalogs[host.id] ?? catalogs[host.id] ?? []
        guard let current, !current.isEmpty, !models.contains(current) else { return models }
        return [current] + models
    }

    /// Reads a host's model catalog (asking its pi), once per call.
    public func loadModels(_ host: SettingsHost) async {
        guard !forgotten.contains(host.id), let client = host.client,
              let listing = try? await client.listModels(), !forgotten.contains(host.id) else { return }
        catalogs[host.id] = listing.models
        imageCatalogs[host.id] = listing.imageCapableModels
    }
    /// The last change a host refused, in words.
    public private(set) var problem: String?

    public init() {}

    public func state(of host: SettingsHost) -> State {
        guard !forgotten.contains(host.id), host.isConnected else { return .offline }
        guard host.capabilities.contains(RemoteProtocol.hostSettingsCapability) else { return .unsupported }
        return loaded[host.id] ?? .loading
    }

    public func settings(of host: SettingsHost) -> HostSettings? {
        if case .loaded(let settings) = state(of: host) { return settings }
        return nil
    }

    /// Reads a host's settings afresh.
    public func refresh(_ host: SettingsHost) async {
        guard !forgotten.contains(host.id), let client = host.client, host.capabilities.contains(RemoteProtocol.hostSettingsCapability) else { return }
        if loaded[host.id] == nil { loaded[host.id] = .loading }
        do {
            let settings = try await client.hostSettings(.fetch)
            guard !forgotten.contains(host.id) else { return }
            loaded[host.id] = .loaded(settings)
        } catch {
            guard !forgotten.contains(host.id) else { return }
            loaded[host.id] = .failed(settingsProblem(error))
        }
    }

    public func refresh(_ hosts: [SettingsHost]) async {
        for host in hosts { await refresh(host) }
    }

    /// Shows `change` at once, then sends it to the host.
    public func change(_ change: HostSettingChange, on host: SettingsHost) async {
        guard let client = host.client, show(change, on: host) else { return }
        await send(change, through: client, to: host)
    }

    /// Shows `change` at once and sends it without waiting for the host: a control's setter, so
    /// a switch never springs back while the host answers. Returns the send, nil when nothing
    /// was sent.
    @discardableResult
    public func post(_ change: HostSettingChange, on host: SettingsHost) -> Task<Void, Never>? {
        guard let client = host.client, show(change, on: host) else { return nil }
        return Task { await send(change, through: client, to: host) }
    }

    public func dismissProblem() {
        problem = nil
    }

    private func show(_ change: HostSettingChange, on host: SettingsHost) -> Bool {
        // An older host refuses a change it doesn't know: it is never sent there.
        if let needed = change.capability, !host.serves(needed) { return false }
        guard !forgotten.contains(host.id), case .loaded(var settings)? = loaded[host.id] else { return false }
        settings.apply(change)
        loaded[host.id] = .loaded(settings)
        problem = nil
        return true
    }

    private func send(_ change: HostSettingChange, through client: any SettingsClient, to host: SettingsHost) async {
        guard !forgotten.contains(host.id) else { return }
        do {
            let settings = try await client.hostSettings(.change(change))
            guard !forgotten.contains(host.id) else { return }
            loaded[host.id] = .loaded(settings)
        } catch {
            guard !forgotten.contains(host.id) else { return }
            problem = settingsProblem(error)
            await refresh(host)
        }
    }
}

// MARK: Instructions

/// Settings ▸ Instructions on a client: the root instructions every Mac in the fleet shares. The
/// page edits one copy, read from the first connected host that serves it; a save writes it there
/// and the fleet carries it to every other Mac on its own (`fleet.sync.v1`). Nothing here knows
/// about the other hosts: no scope, no chips, no owed writes.
@MainActor
@Observable
public final class ClientInstructions {
    public private(set) var busy = false
    /// What went wrong with the last save, in words.
    public private(set) var problem: String?

    private var files: [UUID: InstructionsHostFiles] = [:]
    private var drafts: [InstructionFile: String] = [:]
    @ObservationIgnored private var editRevisions: [InstructionFile: Int] = [:]
    @ObservationIgnored private var forgotten: Set<UUID> = []
    /// This device in a host's history ("Synced from iPhone").
    @ObservationIgnored private let origin: String

    public init(origin: String) {
        self.origin = origin
    }

    public func forget(host: UUID) {
        forgotten.insert(host)
        files[host] = nil
    }

    // MARK: Reading

    public func files(of host: SettingsHost) -> InstructionsHostFiles {
        guard !forgotten.contains(host.id), host.isConnected else { return .offline }
        guard host.capabilities.contains(RemoteProtocol.instructionsCapability) else { return .unsupported }
        return files[host.id] ?? .checking
    }

    /// The host whose files the page edits: the first whose files are read.
    public func edited(in hosts: [SettingsHost]) -> SettingsHost? {
        hosts.first { files(of: $0).snapshot != nil }
    }

    /// Reads every connected host's files.
    public func refresh(_ hosts: [SettingsHost]) async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        for host in hosts where host.serves(RemoteProtocol.instructionsCapability) {
            await fetch(host)
        }
    }

    public func saved(_ file: InstructionFile, in hosts: [SettingsHost]) -> String? {
        edited(in: hosts).flatMap { files(of: $0).snapshot?[file] }
    }

    /// What the editor shows: the draft, else what is saved.
    public func text(_ file: InstructionFile, in hosts: [SettingsHost]) -> String {
        drafts[file] ?? saved(file, in: hosts) ?? ""
    }

    public func setText(_ text: String, file: InstructionFile, in hosts: [SettingsHost]) {
        guard edited(in: hosts) != nil else { return }
        editRevisions[file, default: 0] += 1
        // While a write waits, even returning to the old saved text is a newer edit.
        let draft: String? = !busy && text == saved(file, in: hosts) ? nil : text
        if drafts[file] != draft { drafts[file] = draft }
    }

    public func isEdited(_ file: InstructionFile) -> Bool {
        drafts[file] != nil
    }

    public func revert(_ file: InstructionFile, in hosts: [SettingsHost]) {
        editRevisions[file, default: 0] += 1
        drafts[file] = busy ? saved(file, in: hosts) : nil
    }

    /// The saved versions of `file`, newest first.
    public func history(_ file: InstructionFile, in hosts: [SettingsHost]) -> [InstructionHistoryEntry] {
        edited(in: hosts).flatMap { files(of: $0).snapshot?.history.filter { $0.file == file } } ?? []
    }

    // MARK: Saving

    /// Saves the draft of `file` to the host the page edits; the fleet takes it from there.
    public func save(_ file: InstructionFile, in hosts: [SettingsHost]) async {
        guard let text = drafts[file], let edited = edited(in: hosts), !busy else { return }
        let revision = editRevisions[file, default: 0]
        busy = true
        problem = nil
        defer { busy = false }
        do {
            files[edited.id] = .loaded(try await request(.save(file: file, content: text, origin: origin, sync: false), on: edited))
            if editRevisions[file, default: 0] == revision { drafts[file] = nil }
        } catch {
            if !forgotten.contains(edited.id) { problem = settingsProblem(error) }
        }
    }

    /// Puts a saved version back, dropping the file's draft.
    public func restore(_ entry: InstructionHistoryEntry, in hosts: [SettingsHost]) async {
        guard let edited = edited(in: hosts), !busy else { return }
        let revision = editRevisions[entry.file, default: 0]
        busy = true
        problem = nil
        defer { busy = false }
        do {
            files[edited.id] = .loaded(try await request(.restore(revisionID: entry.id, origin: origin), on: edited))
            if editRevisions[entry.file, default: 0] == revision { drafts[entry.file] = nil }
        } catch {
            if !forgotten.contains(edited.id) { problem = settingsProblem(error) }
        }
    }

    public func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private func fetch(_ host: SettingsHost) async {
        guard !forgotten.contains(host.id), host.client != nil else { return }
        if files[host.id] == nil { files[host.id] = .checking }
        do {
            files[host.id] = .loaded(try await request(.fetch, on: host))
        } catch {
            guard !forgotten.contains(host.id) else { return }
            files[host.id] = .failed(settingsProblem(error))
        }
    }

    private func request(_ request: RemoteInstructionsRequest, on host: SettingsHost) async throws -> InstructionsSnapshot {
        guard !forgotten.contains(host.id) else { throw CancellationError() }
        guard let client = host.client else { throw RemoteHostClientError.disconnected }
        let snapshot = try await client.instructions(request)
        guard !forgotten.contains(host.id) else { throw CancellationError() }
        return snapshot
    }
}

// MARK: Suggestions

/// Settings ▸ Experiments ▸ Suggested instructions on a client: one experiment across every host.
/// Turning it on or changing what it learns from goes to every connected host; the lines waiting
/// are every host's, newest first.
@MainActor
@Observable
public final class ClientSuggestions {
    /// A line waiting on one host.
    public struct Waiting: Identifiable, Equatable, Sendable {
        public var host: UUID
        public var hostName: String
        public var suggestion: InstructionSuggestion
        public var id: UUID { suggestion.id }
    }

    private var snapshots: [UUID: SuggestionsSnapshot] = [:]
    @ObservationIgnored private var forgotten: Set<UUID> = []

    public func forget(host: UUID) {
        forgotten.insert(host)
        snapshots[host] = nil
    }
    public private(set) var busy = false
    /// The last change a host refused, in words.
    public private(set) var problem: String?

    public init() {}

    /// Reads every connected host's suggestions.
    public func refresh(_ hosts: [SettingsHost]) async {
        for host in hosts where !forgotten.contains(host.id) {
            guard let client = host.client, host.capabilities.contains(RemoteProtocol.suggestionsCapability) else {
                snapshots[host.id] = nil
                continue
            }
            if let snapshot = try? await client.suggestions(.fetch), !forgotten.contains(host.id) { snapshots[host.id] = snapshot }
        }
    }

    /// The hosts that serve suggestions now.
    public func hosts(_ hosts: [SettingsHost]) -> [SettingsHost] {
        hosts.filter { $0.serves(RemoteProtocol.suggestionsCapability) && snapshots[$0.id] != nil }
    }

    /// The experiment's settings as the page draws them: the first such host's.
    public func settings(_ hosts: [SettingsHost]) -> SuggestedInstructionsSettings? {
        self.hosts(hosts).first.flatMap { snapshots[$0.id]?.settings }
    }

    /// On anywhere.
    public func isOn(_ hosts: [SettingsHost]) -> Bool {
        self.hosts(hosts).contains { snapshots[$0.id]?.settings.enabled == true }
    }

    /// Every host's waiting lines, newest first.
    public func waiting(_ hosts: [SettingsHost]) -> [Waiting] {
        self.hosts(hosts).flatMap { host in
            (snapshots[host.id]?.waiting ?? []).map { Waiting(host: host.id, hostName: host.name, suggestion: $0) }
        }
        .sorted { $0.suggestion.suggestedAt > $1.suggestion.suggestedAt }
    }

    public func waiting(_ id: UUID, in hosts: [SettingsHost]) -> Waiting? {
        waiting(hosts).first { $0.id == id }
    }

    /// Changes the experiment on every host that serves it, showing it at once.
    public func configure(_ hosts: [SettingsHost], _ change: (inout SuggestedInstructionsSettings) -> Void) async {
        await run(show(hosts, change))
    }

    /// Changes the experiment on every host that serves it, showing it at once and sending it
    /// without waiting: a control's setter. Returns the sends.
    @discardableResult
    public func post(_ hosts: [SettingsHost], _ change: (inout SuggestedInstructionsSettings) -> Void) -> Task<Void, Never> {
        let requests = show(hosts, change)
        return Task { await run(requests) }
    }

    /// Adds a waiting line to its file on its host (`line` edited first, `file` retargeted).
    public func add(_ waiting: Waiting, line: String? = nil, file: InstructionFile? = nil, in hosts: [SettingsHost]) async {
        if let line, let problem = InstructionsText.suggestionProblem(line) {
            self.problem = problem
            return
        }
        guard let host = hosts.first(where: { $0.id == waiting.host }) else { return }
        await run([(host, .add(id: waiting.id, line: line, file: file))])
    }

    /// Adds every waiting line on every host.
    public func addAll(_ hosts: [SettingsHost]) async {
        let targets = self.hosts(hosts).filter { !(snapshots[$0.id]?.waiting.isEmpty ?? true) }
        await run(targets.map { ($0, RemoteSuggestionsRequest.addAll) })
    }

    public func dismiss(_ waiting: Waiting, in hosts: [SettingsHost]) async {
        guard let host = hosts.first(where: { $0.id == waiting.host }) else { return }
        await run([(host, .dismiss(id: waiting.id))])
    }

    public func dismissProblem() {
        problem = nil
    }

    /// Shows a change on every host that serves the experiment (off drops what waits), and
    /// returns the requests that make it.
    private func show(_ hosts: [SettingsHost], _ change: (inout SuggestedInstructionsSettings) -> Void)
        -> [(SettingsHost, RemoteSuggestionsRequest)] {
        self.hosts(hosts).compactMap { host -> (SettingsHost, RemoteSuggestionsRequest)? in
            guard var snapshot = snapshots[host.id] else { return nil }
            change(&snapshot.settings)
            if !snapshot.settings.enabled { snapshot.waiting = [] }
            snapshots[host.id] = snapshot
            return (host, .configure(snapshot.settings))
        }
    }

    private func run(_ requests: [(SettingsHost, RemoteSuggestionsRequest)]) async {
        busy = true
        problem = nil
        defer { busy = false }
        for (host, request) in requests {
            guard !forgotten.contains(host.id), let client = host.client else { continue }
            do {
                let snapshot = try await client.suggestions(request)
                guard !forgotten.contains(host.id) else { continue }
                snapshots[host.id] = snapshot
            } catch {
                guard !forgotten.contains(host.id) else { continue }
                problem = settingsProblem(error)
            }
        }
    }
}
