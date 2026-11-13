import Foundation
import Observation
import ShepherdProtocol

// Settings ▸ Skills on the Mac, the iPhone and the iPad: the agent skills every Mac in the fleet
// shares, read and changed over `skills.v1` (the Mac's own through its store). The page edits one
// host's copy, the first connected one; the fleet carries a change to every other Mac on its own
// (`fleet.sync.v1`), so nothing here knows about the other hosts. The model holds what the pages
// draw and every rule they follow, so the pages only draw; they pass the hosts as the app knows
// them now (`SkillsHost`).

/// What Settings ▸ Skills reads and changes a host's skills through: its `RemoteHostClient`, the
/// Mac's own store, or a stand-in in tests.
public protocol SkillsClient: AnyObject, Sendable {
    func skills(_ request: RemoteSkillsRequest) async throws -> RemoteSkillsResult
}

extension RemoteHostClient: SkillsClient {}

/// A host as Settings ▸ Skills sees it now.
public struct SkillsHost: Identifiable, Sendable {
    public let id: UUID
    public let name: String
    /// nil while it isn't connected.
    public let client: (any SkillsClient)?
    /// Whether it serves `skills.v1`; a host that is offline is taken to.
    public let serves: Bool

    public init(id: UUID, name: String, client: (any SkillsClient)?, serves: Bool) {
        self.id = id
        self.name = name
        self.client = client
        self.serves = serves
    }

    /// A remote host from Settings' own list.
    public init(_ host: SettingsHost) {
        self.init(id: host.id, name: host.name, client: host.client,
                  serves: host.client == nil || host.capabilities.contains(RemoteProtocol.skillsCapability))
    }

    public var isConnected: Bool { client != nil }
}

/// A host's skills as far as the page knows now.
public enum HostSkills: Equatable, Sendable {
    case offline
    /// Its Shepherd predates `skills.v1`.
    case unsupported
    case loading
    case loaded(SkillsSnapshot)
    case failed(String)

    public var snapshot: SkillsSnapshot? {
        if case .loaded(let snapshot) = self { return snapshot }
        return nil
    }
}

/// One installed skill as the list draws it.
public struct SkillRow: Identifiable, Equatable, Sendable {
    public var skill: InstalledSkill
    /// An update is being installed ("Updating").
    public var isUpdating: Bool
    /// The SKILL.md this host's pi uses instead (with `~`), when a skill of the same name
    /// from pi's own setup comes first: the agent never sees this one.
    public var shadowedBy: String?

    public init(skill: InstalledSkill, isUpdating: Bool = false, shadowedBy: String? = nil) {
        self.skill = skill
        self.isUpdating = isUpdating
        self.shadowedBy = shadowedBy
    }

    public var id: String { skill.name }
    public var name: String { skill.name }
}

/// A skill pi loads from outside Shepherd's folder, as the list draws it: read-only.
public struct PiSkillRow: Identifiable, Equatable, Sendable {
    public var skill: PiSkill

    public init(skill: PiSkill) {
        self.skill = skill
    }

    public var id: String { skill.path }
    public var name: String { skill.name }
}

/// One of the list's read-only groups: the skills from the user's own pi setup (pi's agent
/// directory and its settings' paths), or from pi packages.
public struct PiSkillGroup: Identifiable, Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable {
        case setup, packages
    }

    public var kind: Kind
    public var rows: [PiSkillRow]

    public init(kind: Kind, rows: [PiSkillRow]) {
        self.kind = kind
        self.rows = rows
    }

    public var id: Kind { kind }
}

/// An install on its way, for the sheet or screen that follows it.
public struct SkillInstall: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case installing
        case installed
        case failed(String)
    }

    public var state: State

    public var isRunning: Bool { state == .installing }
    public var failure: String? {
        if case .failed(let reason) = state { return reason }
        return nil
    }
}

/// Where a skill on skills.sh stands: Install, installing, installed, or installed with a newer
/// commit waiting.
public enum SkillResultState: Equatable, Sendable {
    case install
    case installing
    case installed
    case update

    @MainActor
    public init(_ skill: DirectorySkill, model: ClientSkills, hosts: [SkillsHost]) {
        if let install = model.installs[skill.id], install.isRunning {
            self = .installing
        } else if let row = model.row(skill.slug, in: hosts) {
            self = row.skill.update == nil ? .installed : .update
        } else {
            self = .install
        }
    }
}

/// Settings ▸ Skills' model. Skills are the fleet's: the page reads and changes one copy, on the
/// first connected host, and the fleet carries every change to the other Macs by itself.
@MainActor
@Observable
public final class ClientSkills {
    /// A removal the toast can take back.
    public struct Removal: Equatable, Sendable {
        public var name: String
    }

    public enum Filter: String, CaseIterable, Sendable {
        case all, on, updates
    }

    /// The last change a host refused, in words.
    public private(set) var problem: String?
    /// The removal Undo takes back.
    public private(set) var removal: Removal?
    /// Installs from Browse and Add from repo, by the key the sheet gave them.
    public private(set) var installs: [String: SkillInstall] = [:]

    private var loaded: [UUID: HostSkills] = [:]
    private var updating: Set<String> = []

    @ObservationIgnored private var forgotten: Set<UUID> = []
    @ObservationIgnored private var installAttempts: [String: UUID] = [:]

    public init() {}

    /// Explicit Forget, not a disconnect: drop what was read from this host.
    public func forget(host: UUID) {
        forgotten.insert(host)
        loaded[host] = nil
    }

    // MARK: Reading

    public func state(of host: SkillsHost) -> HostSkills {
        guard !forgotten.contains(host.id), host.isConnected else { return .offline }
        guard host.serves else { return .unsupported }
        return loaded[host.id] ?? .loading
    }

    /// The host the page edits: the first that is connected and serves skills.
    public func edited(in hosts: [SkillsHost]) -> SkillsHost? {
        hosts.first { !forgotten.contains($0.id) && $0.isConnected && $0.serves }
    }

    /// The edited host once its skills are read: what the list shows.
    public func reference(in hosts: [SkillsHost]) -> SkillsHost? {
        edited(in: hosts).flatMap { state(of: $0).snapshot != nil ? $0 : nil }
    }

    /// Every skill the edited host has, by name.
    public func rows(in hosts: [SkillsHost]) -> [SkillRow] {
        let shadowed = pi(in: hosts)?.skills.shadowedInstalled ?? [:]
        return (reference(in: hosts).flatMap { state(of: $0).snapshot }?.skills ?? []).sorted { $0.name < $1.name }.map {
            SkillRow(skill: $0, isUpdating: updating.contains($0.name), shadowedBy: $0.isOn ? shadowed[$0.name] : nil)
        }
    }

    /// The skills the edited host's pi loads from outside its skills folder, and that host; nil
    /// while none is read, or when the host predates reporting them. They are that host's own:
    /// the fleet never carries them.
    public func pi(in hosts: [SkillsHost]) -> (host: SkillsHost, skills: PiSkills)? {
        guard let host = reference(in: hosts), let pi = state(of: host).snapshot?.pi else { return nil }
        return (host, pi)
    }

    /// The read-only groups a filter and a search keep: the host's pi setup, then its pi
    /// packages; an empty group is left out. They never have updates, and On keeps the skills the
    /// agent uses (not one a skill of the same name shadows).
    public func piGroups(in hosts: [SkillsHost], filter: Filter = .all, query: String = "") -> [PiSkillGroup] {
        guard filter != .updates, let pi = pi(in: hosts) else { return [] }
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        let kept = pi.skills.skills.filter { skill in
            guard filter != .on || skill.isUsed else { return false }
            return words.isEmpty || skill.name.lowercased().contains(words) || skill.summary.lowercased().contains(words)
                || (skill.package ?? "").lowercased().contains(words)
        }
        return PiSkillGroup.Kind.allCases.compactMap { kind in
            let rows = kept.filter { ($0.origin == .package) == (kind == .packages) }.map(PiSkillRow.init)
            return rows.isEmpty ? nil : PiSkillGroup(kind: kind, rows: rows)
        }
    }

    /// The rows a filter and a search keep (the search matches names and descriptions).
    public func rows(in hosts: [SkillsHost], filter: Filter, query: String = "") -> [SkillRow] {
        let words = query.trimmingCharacters(in: .whitespaces).lowercased()
        return rows(in: hosts).filter { row in
            switch filter {
            case .all: break
            case .on: guard row.skill.isOn else { return false }
            case .updates: guard row.skill.update != nil else { return false }
            }
            return words.isEmpty || row.name.lowercased().contains(words) || row.skill.summary.lowercased().contains(words)
        }
    }

    /// How many rows each filter keeps ("All 8", "On 7", "Updates 2"), pi's own skills included.
    public func count(_ filter: Filter, in hosts: [SkillsHost]) -> Int {
        rows(in: hosts, filter: filter).count + piGroups(in: hosts, filter: filter).reduce(0) { $0 + $1.rows.count }
    }

    public func row(_ name: String, in hosts: [SkillsHost]) -> SkillRow? {
        rows(in: hosts).first { $0.name == name }
    }

    /// When the host last looked for updates.
    public func checkedAt(in hosts: [SkillsHost]) -> Double? {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.checkedAt }
    }

    /// Update automatically, as the host has it.
    public func autoUpdate(in hosts: [SkillsHost]) -> Bool {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.autoUpdate } ?? false
    }

    /// Every skill the host's agent loads, in pi's order: the installed ones that are on (less any
    /// a skill from pi's setup shadows), then pi's own. Each is a name, a description, its SKILL.md
    /// and how it's used.
    public func loadedSkills(in hosts: [SkillsHost]) -> [(name: String, summary: String, location: String, invocation: SkillInvocation)] {
        guard let snapshot = reference(in: hosts).flatMap({ state(of: $0).snapshot }) else { return [] }
        let shadowed = snapshot.pi?.shadowedInstalled ?? [:]
        let installed = snapshot.skills.filter { $0.isOn && shadowed[$0.name] == nil }.map {
            (name: $0.name, summary: $0.summary, location: "\(snapshot.directory)/\($0.name)/SKILL.md", invocation: $0.invocation)
        }
        let outside = (snapshot.pi?.skills ?? []).filter(\.isUsed).map {
            (name: $0.name, summary: $0.summary, location: $0.path, invocation: $0.invocation)
        }
        return installed + outside
    }

    /// What every automatic skill the host's agent loads costs in every prompt, pi's own included.
    public func promptTokens(in hosts: [SkillsHost]) -> Int {
        SkillsText.promptTokens(loadedSkills(in: hosts).filter { $0.invocation == .automatic }.map { ($0.name, $0.summary, $0.location) })
    }

    /// Where the host keeps its skills ("~/.agents/skills").
    public func directory(in hosts: [SkillsHost]) -> String {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.directory } ?? "~/.agents/skills"
    }

    // MARK: Hosts

    /// Reads the edited host's skills afresh.
    public func refresh(_ hosts: [SkillsHost]) async {
        if let host = edited(in: hosts) { await fetch(host) }
    }

    /// A host connected again: the page reads it afresh.
    public func hostConnected(_ host: SkillsHost) async {
        guard host.isConnected, host.serves else { return }
        await fetch(host)
    }

    /// A host's skills changed without this page (another device, the fleet, the host's own check).
    public func hostChanged(_ id: UUID, _ snapshot: SkillsSnapshot) {
        guard !forgotten.contains(id) else { return }
        loaded[id] = .loaded(snapshot)
    }

    public func dismissProblem() {
        problem = nil
    }

    // MARK: Changes

    /// Turns a skill on or off, showing it at once.
    @discardableResult
    public func setOn(_ name: String, _ on: Bool, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.setOn(name: name, on: on), in: hosts) { snapshot in
            if let index = snapshot.skills.firstIndex(where: { $0.name == name }) { snapshot.skills[index].isOn = on }
        }
    }

    /// How the agent may use a skill.
    @discardableResult
    public func setInvocation(_ name: String, _ invocation: SkillInvocation, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.setInvocation(name: name, invocation: invocation), in: hosts) { snapshot in
            if let index = snapshot.skills.firstIndex(where: { $0.name == name }) { snapshot.skills[index].invocation = invocation }
        }
    }

    /// Takes a skill off the fleet; Undo puts it back.
    @discardableResult
    public func remove(_ name: String, in hosts: [SkillsHost]) -> Task<Void, Never> {
        removal = Removal(name: name)
        return post(.remove(name: name), in: hosts) { snapshot in
            snapshot.skills.removeAll { $0.name == name }
        }
    }

    /// Puts back the skill just removed.
    @discardableResult
    public func undoRemoval(in hosts: [SkillsHost]) -> Task<Void, Never>? {
        guard let removal else { return nil }
        self.removal = nil
        return post(.restore(name: removal.name), in: hosts, showing: nil)
    }

    public func dismissRemoval() {
        removal = nil
    }

    /// Installs a skill's newer commit; the row says Updating meanwhile.
    public func update(_ name: String, in hosts: [SkillsHost]) async {
        guard let current = row(name, in: hosts), let source = current.skill.source, let update = current.skill.update,
              !updating.contains(name) else { return }
        updating.insert(name)
        defer { updating.remove(name) }
        await send(.install(repo: source.repo, paths: [source.path], commit: update.commit, invocation: nil), in: hosts)
    }

    /// Update N: every skill with a newer commit.
    public func updateAll(in hosts: [SkillsHost]) async {
        for row in rows(in: hosts) where row.skill.update != nil {
            await update(row.name, in: hosts)
        }
    }

    /// Update automatically.
    @discardableResult
    public func setAutoUpdate(_ on: Bool, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.configure(autoUpdate: on), in: hosts) { $0.autoUpdate = on }
    }

    /// Asks the host to look for newer commits now.
    public func checkUpdates(in hosts: [SkillsHost]) async {
        await send(.checkUpdates, in: hosts)
    }

    // MARK: Installing

    /// A repository's skills, looked up on the edited host (Add from repo).
    public func lookUp(_ repo: String, in hosts: [SkillsHost]) async throws -> RepoSkills {
        guard let host = edited(in: hosts) else {
            throw RemoteHostClientError.rejected(code: "offline", message: "No host is connected to look it up.")
        }
        guard case .repo(let found) = try await request(.lookUp(repo: repo), on: host) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "The host didn't answer with the repository.")
        }
        return found
    }

    /// Installs skills from a repository; `key` names the install for the sheet that follows it.
    public func install(_ key: String, repo: String, paths: [String], commit: String?, invocation: SkillInvocation?,
                        in hosts: [SkillsHost]) async {
        await run(key, .install(repo: repo, paths: paths, commit: commit, invocation: invocation), in: hosts)
    }

    /// Installs a folder copied from this device.
    public func installFiles(_ key: String, name: String, files: [SkillFile], invocation: SkillInvocation,
                             in hosts: [SkillsHost]) async {
        await run(key, .installFiles(name: name, files: files, invocation: invocation), in: hosts)
    }

    private func run(_ key: String, _ request: RemoteSkillsRequest, in hosts: [SkillsHost]) async {
        guard let host = edited(in: hosts) else { return }
        let attempt = UUID()
        installAttempts[key] = attempt
        installs[key] = SkillInstall(state: .installing)
        do {
            if case .skills(let snapshot) = try await self.request(request, on: host) { loaded[host.id] = .loaded(snapshot) }
            guard installAttempts[key] == attempt else { return }
            installs[key] = SkillInstall(state: .installed)
        } catch {
            guard installAttempts[key] == attempt, !forgotten.contains(host.id) else { return }
            installs[key] = SkillInstall(state: .failed(settingsProblem(error)))
        }
    }

    /// Installs a skill from skills.sh: its repository is looked up to find the skill's folder,
    /// then installed like one from Add from repo.
    public func install(_ key: String, source: String, skill: String, invocation: SkillInvocation?, in hosts: [SkillsHost]) async {
        guard edited(in: hosts) != nil else { return }
        let attempt = UUID()
        installAttempts[key] = attempt
        installs[key] = SkillInstall(state: .installing)
        do {
            let found = try await lookUp(source, in: hosts)
            guard installAttempts[key] == attempt, !Task.isCancelled else { return }
            guard let match = found.skills.first(where: { $0.name == skill })
                ?? found.skills.first(where: { $0.path.split(separator: "/").last.map(String.init) == skill }) else {
                throw RemoteHostClientError.rejected(code: "no_such_skill", message: "\(source) has no skill named \(skill).")
            }
            await install(key, repo: found.repo, paths: [match.path], commit: found.commit, invocation: invocation, in: hosts)
        } catch {
            guard installAttempts[key] == attempt, !Task.isCancelled else { return }
            installs[key] = SkillInstall(state: .failed(settingsProblem(error)))
        }
    }

    public func dismissInstall(_ key: String) {
        installAttempts[key] = nil
        installs[key] = nil
    }

    // MARK: Private

    private func post(_ request: RemoteSkillsRequest, in hosts: [SkillsHost],
                      showing change: ((inout SkillsSnapshot) -> Void)?) -> Task<Void, Never> {
        problem = nil
        if let change, let host = edited(in: hosts), case .loaded(var snapshot)? = loaded[host.id] {
            change(&snapshot)
            loaded[host.id] = .loaded(snapshot)
        }
        return Task { await send(request, in: hosts) }
    }

    private func post(_ request: RemoteSkillsRequest, in hosts: [SkillsHost], showing change: @escaping (inout SkillsSnapshot) -> Void) -> Task<Void, Never> {
        post(request, in: hosts, showing: Optional(change))
    }

    /// Sends `request` to the edited host: it answers with its skills.
    private func send(_ request: RemoteSkillsRequest, in hosts: [SkillsHost]) async {
        guard let host = edited(in: hosts) else { return }
        do {
            if case .skills(let snapshot) = try await self.request(request, on: host) { loaded[host.id] = .loaded(snapshot) }
        } catch {
            guard !forgotten.contains(host.id) else { return }
            problem = settingsProblem(error)
            await fetch(host)
        }
    }

    private func fetch(_ host: SkillsHost) async {
        guard !forgotten.contains(host.id), host.client != nil, host.serves else { return }
        if loaded[host.id] == nil { loaded[host.id] = .loading }
        do {
            if case .skills(let snapshot) = try await request(.fetch, on: host) { loaded[host.id] = .loaded(snapshot) }
        } catch {
            guard !forgotten.contains(host.id) else { return }
            loaded[host.id] = .failed(settingsProblem(error))
        }
    }

    private func request(_ request: RemoteSkillsRequest, on host: SkillsHost) async throws -> RemoteSkillsResult {
        guard !forgotten.contains(host.id), let client = host.client else { throw CancellationError() }
        let result = try await client.skills(request)
        guard !forgotten.contains(host.id) else { throw CancellationError() }
        return result
    }
}
