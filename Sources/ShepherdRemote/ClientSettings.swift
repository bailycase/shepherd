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
func settingsProblem(_ error: Error) -> String {
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
    /// The last change a host refused, in words.
    public private(set) var problem: String?

    public init() {}

    public func state(of host: SettingsHost) -> State {
        guard host.isConnected else { return .offline }
        guard host.capabilities.contains(RemoteProtocol.hostSettingsCapability) else { return .unsupported }
        return loaded[host.id] ?? .loading
    }

    public func settings(of host: SettingsHost) -> HostSettings? {
        if case .loaded(let settings) = state(of: host) { return settings }
        return nil
    }

    /// Reads a host's settings afresh.
    public func refresh(_ host: SettingsHost) async {
        guard let client = host.client, host.capabilities.contains(RemoteProtocol.hostSettingsCapability) else { return }
        if loaded[host.id] == nil { loaded[host.id] = .loading }
        do {
            loaded[host.id] = .loaded(try await client.hostSettings(.fetch))
        } catch {
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
        guard case .loaded(var settings)? = loaded[host.id] else { return false }
        settings.apply(change)
        loaded[host.id] = .loaded(settings)
        problem = nil
        return true
    }

    private func send(_ change: HostSettingChange, through client: any SettingsClient, to host: SettingsHost) async {
        do {
            loaded[host.id] = .loaded(try await client.hostSettings(.change(change)))
        } catch {
            problem = settingsProblem(error)
            await refresh(host)
        }
    }
}

// MARK: Instructions

/// Settings ▸ Instructions on a client: the root instructions on every host. With Same on every
/// host on (the default, kept per device), the page edits one set of files, read from the first
/// host that answers, and a save writes them to every host; a host offline then is owed them and
/// takes them the next time the page reads it. Off, the page edits one host at a time.
@MainActor
@Observable
public final class ClientInstructions {
    private enum Key {
        static let sameEverywhere = "shepherd.ios.instructions.sameEverywhere"
        static let pending = "shepherd.ios.instructions.pendingSync"
    }

    /// A draft of one file: on every host (`host` nil, with Same on every host on) or on one.
    public struct DraftKey: Hashable, Sendable {
        public var host: UUID?
        public var file: InstructionFile
    }

    public var sameEverywhere: Bool {
        didSet { if sameEverywhere != oldValue { defaults.set(sameEverywhere, forKey: Key.sameEverywhere) } }
    }
    /// Per host, the host being edited; the reference when nil or gone.
    public var chosenHost: UUID?
    public private(set) var busy = false
    /// What went wrong with the last save, in words.
    public private(set) var problem: String?

    private var files: [UUID: InstructionsHostFiles] = [:]
    private var drafts: [DraftKey: String] = [:]
    private var syncedAt: [UUID: Date] = [:]
    private var pending: Set<UUID> {
        didSet { defaults.set(pending.map(\.uuidString).sorted(), forKey: Key.pending) }
    }

    @ObservationIgnored private let defaults: UserDefaults
    /// This device in a host's history ("Synced from iPhone").
    @ObservationIgnored private let origin: String

    public init(defaults: UserDefaults = .standard, origin: String) {
        self.defaults = defaults
        self.origin = origin
        sameEverywhere = defaults.object(forKey: Key.sameEverywhere) as? Bool ?? true
        pending = Set((defaults.stringArray(forKey: Key.pending) ?? []).compactMap(UUID.init(uuidString:)))
    }

    // MARK: Reading

    public func files(of host: SettingsHost) -> InstructionsHostFiles {
        guard host.isConnected else { return .offline }
        guard host.capabilities.contains(RemoteProtocol.instructionsCapability) else { return .unsupported }
        return files[host.id] ?? .checking
    }

    /// The first host whose files are read: with Same on every host on, what the page edits and
    /// every other host is compared with.
    public func reference(in hosts: [SettingsHost]) -> SettingsHost? {
        hosts.first { files(of: $0).snapshot != nil }
    }

    /// The host whose files the page edits.
    public func edited(in hosts: [SettingsHost]) -> SettingsHost? {
        if !sameEverywhere, let chosen = hosts.first(where: { $0.id == chosenHost }) { return chosen }
        return reference(in: hosts)
    }

    /// Reads every connected host's files, then gives a host that is owed them its copy.
    public func refresh(_ hosts: [SettingsHost]) async {
        for host in hosts where host.serves(RemoteProtocol.instructionsCapability) {
            await fetch(host)
        }
        guard sameEverywhere, let reference = reference(in: hosts), let snapshot = files(of: reference).snapshot else { return }
        for host in hosts where pending.contains(host.id) && host.id != reference.id && host.serves(RemoteProtocol.instructionsCapability) {
            await write(snapshot, to: host)
        }
    }

    public func saved(_ file: InstructionFile, in hosts: [SettingsHost]) -> String? {
        edited(in: hosts).flatMap { files(of: $0).snapshot?[file] }
    }

    /// What the editor shows: the draft, else what is saved.
    public func text(_ file: InstructionFile, in hosts: [SettingsHost]) -> String {
        drafts[draftKey(file, in: hosts)] ?? saved(file, in: hosts) ?? ""
    }

    public func setText(_ text: String, file: InstructionFile, in hosts: [SettingsHost]) {
        let key = draftKey(file, in: hosts)
        let draft: String? = text == saved(file, in: hosts) ? nil : text
        if drafts[key] != draft { drafts[key] = draft }
    }

    public func isEdited(_ file: InstructionFile, in hosts: [SettingsHost]) -> Bool {
        drafts[draftKey(file, in: hosts)] != nil
    }

    public func revert(_ file: InstructionFile, in hosts: [SettingsHost]) {
        drafts[draftKey(file, in: hosts)] = nil
    }

    /// A host's chip: with Same on every host on how it compares with the reference ("synced",
    /// "differs · 2 lines", "offline · will sync"); per host, how `file` does.
    public func chip(for host: SettingsHost, file: InstructionFile, in hosts: [SettingsHost], now: Date = Date()) -> InstructionsChip {
        InstructionsPresentation.hostChip(files(of: host), local: reference(in: hosts).flatMap { files(of: $0).snapshot },
                                          file: file, sameEverywhere: sameEverywhere, pending: pending.contains(host.id),
                                          keptDifferent: false, syncedAt: syncedAt[host.id], now: now)
    }

    /// "Save to 3 hosts", "Save", "Save to build-01".
    public func saveTitle(in hosts: [SettingsHost]) -> String {
        if sameEverywhere {
            let targets = hosts.filter { files(of: $0) != .unsupported }.count
            return targets > 1 ? "Save to \(targets) hosts" : "Save"
        }
        return edited(in: hosts).map { "Save to \($0.name)" } ?? "Save"
    }

    /// Where a save goes, under the editor's file name: "every host", or the host edited.
    public func scope(in hosts: [SettingsHost]) -> String {
        sameEverywhere ? "every host" : edited(in: hosts)?.name ?? "no host"
    }

    /// With Same on every host on, the connected hosts whose files differ from the reference's.
    public func differing(in hosts: [SettingsHost]) -> [SettingsHost] {
        guard sameEverywhere, let reference = reference(in: hosts), let snapshot = files(of: reference).snapshot else { return [] }
        return hosts.filter { host in
            guard let other = files(of: host).snapshot else { return false }
            return InstructionFile.allCases.contains { other[$0] != snapshot[$0] }
        }
    }

    /// With Same on every host on, each host's state in one line ("Studio, build-01 synced ·
    /// horizon when it's back"); per host, nil.
    public func syncLine(in hosts: [SettingsHost]) -> String? {
        guard sameEverywhere, let reference = reference(in: hosts), let snapshot = files(of: reference).snapshot else { return nil }
        var synced: [String] = [], differing: [String] = [], waiting: [String] = []
        for host in hosts {
            switch files(of: host) {
            case .loaded(let other):
                if InstructionFile.allCases.allSatisfy({ other[$0] == snapshot[$0] }) { synced.append(host.name) } else { differing.append(host.name) }
            case .offline where pending.contains(host.id):
                waiting.append(host.name)
            default:
                break
            }
        }
        return InstructionsPresentation.syncLine(synced: synced, differing: differing, waiting: waiting)
    }

    /// The edited host's saved versions of `file`, newest first.
    public func history(_ file: InstructionFile, in hosts: [SettingsHost]) -> [InstructionHistoryEntry] {
        edited(in: hosts).flatMap { files(of: $0).snapshot?.history.filter { $0.file == file } } ?? []
    }

    // MARK: Saving

    /// Saves the draft of `file`: with Same on every host on, to every host (one offline is owed
    /// it); per host, to the host being edited.
    public func save(_ file: InstructionFile, in hosts: [SettingsHost]) async {
        let key = draftKey(file, in: hosts)
        guard let text = drafts[key], let edited = edited(in: hosts), !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await save(file, content: text, to: edited, sync: false)
            drafts[key] = nil
            await spread(from: edited, in: hosts)
        } catch {
            problem = settingsProblem(error)
        }
    }

    /// Puts a saved version back on the edited host, dropping the file's draft; with Same on every
    /// host on, every other host then takes the files too.
    public func restore(_ entry: InstructionHistoryEntry, in hosts: [SettingsHost]) async {
        guard let edited = edited(in: hosts), !busy else { return }
        let key = draftKey(entry.file, in: hosts)
        busy = true
        problem = nil
        defer { busy = false }
        do {
            guard let client = edited.client else { throw RemoteHostClientError.disconnected }
            files[edited.id] = .loaded(try await client.instructions(.restore(revisionID: entry.id, origin: origin)))
            drafts[key] = nil
            await spread(from: edited, in: hosts)
        } catch {
            problem = settingsProblem(error)
        }
    }

    /// With Same on every host on, gives every host whose files differ the reference's.
    public func syncNow(in hosts: [SettingsHost]) async {
        guard let reference = reference(in: hosts), let snapshot = files(of: reference).snapshot, !busy else { return }
        busy = true
        problem = nil
        defer { busy = false }
        for host in differing(in: hosts) where host.id != reference.id {
            await write(snapshot, to: host)
        }
    }

    public func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private func draftKey(_ file: InstructionFile, in hosts: [SettingsHost]) -> DraftKey {
        DraftKey(host: sameEverywhere ? nil : edited(in: hosts)?.id, file: file)
    }

    private func fetch(_ host: SettingsHost) async {
        guard let client = host.client else { return }
        if files[host.id] == nil { files[host.id] = .checking }
        do {
            files[host.id] = .loaded(try await client.instructions(.fetch))
        } catch {
            files[host.id] = .failed(settingsProblem(error))
        }
    }

    /// With Same on every host on, writes `edited`'s files to every other host.
    private func spread(from edited: SettingsHost, in hosts: [SettingsHost]) async {
        guard sameEverywhere, let snapshot = files(of: edited).snapshot else { return }
        for host in hosts where host.id != edited.id {
            await write(snapshot, to: host)
        }
    }

    private func save(_ file: InstructionFile, content: String, to host: SettingsHost, sync: Bool) async throws {
        guard let client = host.client else { throw RemoteHostClientError.disconnected }
        files[host.id] = .loaded(try await client.instructions(.save(file: file, content: content, origin: origin, sync: sync)))
    }

    /// Writes both of `snapshot`'s files to a host; one that can't take them now is owed them,
    /// unless its Shepherd will never take them.
    private func write(_ snapshot: InstructionsSnapshot, to host: SettingsHost) async {
        guard host.capabilities.contains(RemoteProtocol.instructionsCapability) || !host.isConnected else { return }
        guard host.isConnected else {
            pending.insert(host.id)
            return
        }
        do {
            for file in InstructionFile.allCases where files(of: host).snapshot?[file] != snapshot[file] {
                try await save(file, content: snapshot[file], to: host, sync: true)
            }
            syncedAt[host.id] = Date()
            pending.remove(host.id)
        } catch {
            pending.insert(host.id)
            problem = "Couldn't write to \(host.name): \(settingsProblem(error))"
        }
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
    public private(set) var busy = false
    /// The last change a host refused, in words.
    public private(set) var problem: String?

    public init() {}

    /// Reads every connected host's suggestions.
    public func refresh(_ hosts: [SettingsHost]) async {
        for host in hosts {
            guard let client = host.client, host.capabilities.contains(RemoteProtocol.suggestionsCapability) else {
                snapshots[host.id] = nil
                continue
            }
            if let snapshot = try? await client.suggestions(.fetch) { snapshots[host.id] = snapshot }
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
            guard let client = host.client else { continue }
            do {
                snapshots[host.id] = try await client.suggestions(request)
            } catch {
                problem = settingsProblem(error)
            }
        }
    }
}
