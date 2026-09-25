import Foundation
import Observation
import ShepherdProtocol

// Settings ▸ Skills on the Mac, the iPhone and the iPad: every host's agent skills, read and
// changed over `skills.v1` (the Mac's own through its store). The model holds what the pages draw
// and every rule they follow, so the pages only draw; they pass the hosts as the app knows them
// now (`SkillsHost`).

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

/// One installed skill as the list draws it: the skill as the first host that has it holds it.
public struct SkillRow: Identifiable, Equatable, Sendable {
    public var skill: InstalledSkill
    /// An update or a change is on its way to the hosts ("Updating").
    public var isUpdating: Bool

    public init(skill: InstalledSkill, isUpdating: Bool = false) {
        self.skill = skill
        self.isUpdating = isUpdating
    }

    public var id: String { skill.name }
    public var name: String { skill.name }
}

/// Where one host is with a skill (the detail's Hosts).
public struct SkillCopy: Identifiable, Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case installed
        case updating
        case checking
        /// Online without it.
        case missing
        /// Offline, with a change waiting for it.
        case owed
        case offline
        case unsupported
    }

    public var id: UUID
    public var name: String
    public var state: State

    public init(id: UUID, name: String, state: State) {
        self.id = id
        self.name = name
        self.state = state
    }
}

/// An install on its way to each host, one host at a time ("Installing · 1 of 3 hosts").
public struct SkillInstall: Equatable, Sendable {
    public struct Step: Identifiable, Equatable, Sendable {
        public enum State: Equatable, Sendable {
            case waiting
            case copying
            case installed
            /// Offline: it installs when the host is back.
            case owed
            case failed(String)
        }

        public var id: UUID
        public var name: String
        public var state: State
    }

    public var steps: [Step]
    public var cancelled = false
    /// What each host is sent, so Cancel can take back what an offline host is owed.
    var request: RemoteSkillsRequest?

    public var installed: Int { steps.filter { $0.state == .installed }.count }
    public var isRunning: Bool { !cancelled && steps.contains { $0.state == .waiting || $0.state == .copying } }
    public var failure: String? {
        for step in steps { if case .failed(let reason) = step.state { return reason } }
        return nil
    }
}

/// Settings ▸ Skills' model. Skills are global: with Same skills on every host on (the default,
/// kept per device), every change goes to every host, one that is offline is owed it and takes it
/// when it's back, and the list shows the first host's skills with where each host is. Off, the
/// page changes the first host alone.
@MainActor
@Observable
public final class ClientSkills {
    private enum Key {
        static let sameEverywhere = "shepherd.skills.sameEverywhere"
        static let owed = "shepherd.skills.owed"
    }

    /// A removal the toast can take back.
    public struct Removal: Equatable, Sendable {
        public var name: String
        public var hosts: [UUID]
    }

    public enum Filter: String, CaseIterable, Sendable {
        case all, on, updates
    }

    public var sameEverywhere: Bool {
        didSet { if sameEverywhere != oldValue { defaults.set(sameEverywhere, forKey: Key.sameEverywhere) } }
    }
    /// The last change a host refused, in words.
    public private(set) var problem: String?
    /// The removal Undo takes back.
    public private(set) var removal: Removal?
    /// Installs from Browse and Add from repo, by the key the sheet gave them.
    public private(set) var installs: [String: SkillInstall] = [:]

    private var loaded: [UUID: HostSkills] = [:]
    private var updating: Set<String> = []
    private var sending: [UUID: Set<String>] = [:]
    /// Changes waiting for hosts that were offline, in order.
    private var owed: [UUID: [RemoteSkillsRequest]] {
        didSet { saveOwed() }
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sameEverywhere = defaults.object(forKey: Key.sameEverywhere) as? Bool ?? true
        if let data = defaults.data(forKey: Key.owed),
           let decoded = try? JSONDecoder().decode([String: [RemoteSkillsRequest]].self, from: data) {
            owed = Dictionary(uniqueKeysWithValues: decoded.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } })
        } else {
            owed = [:]
        }
    }

    // MARK: Reading

    public func state(of host: SkillsHost) -> HostSkills {
        guard host.isConnected else { return .offline }
        guard host.serves else { return .unsupported }
        return loaded[host.id] ?? .loading
    }

    /// The first host whose skills are read: what the list shows and every host is compared with.
    public func reference(in hosts: [SkillsHost]) -> SkillsHost? {
        hosts.first { state(of: $0).snapshot != nil }
    }

    /// The hosts a change goes to: every host, or with Same skills on every host off the first.
    public func targets(in hosts: [SkillsHost]) -> [SkillsHost] {
        if sameEverywhere { return hosts }
        return (reference(in: hosts) ?? hosts.first).map { [$0] } ?? []
    }

    /// Every skill on any host, by name, as the first host that has it holds it.
    public func rows(in hosts: [SkillsHost]) -> [SkillRow] {
        var skills: [String: InstalledSkill] = [:]
        for host in hosts {
            for skill in state(of: host).snapshot?.skills ?? [] where skills[skill.name] == nil {
                skills[skill.name] = skill
            }
        }
        return skills.values.sorted { $0.name < $1.name }.map { SkillRow(skill: $0, isUpdating: updating.contains($0.name)) }
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

    /// How many rows each filter keeps ("All 8", "On 7", "Updates 2").
    public func count(_ filter: Filter, in hosts: [SkillsHost]) -> Int {
        rows(in: hosts, filter: filter).count
    }

    public func row(_ name: String, in hosts: [SkillsHost]) -> SkillRow? {
        rows(in: hosts).first { $0.name == name }
    }

    /// Where each host is with a skill.
    public func copies(of name: String, in hosts: [SkillsHost]) -> [SkillCopy] {
        hosts.map { host in
            let state: SkillCopy.State
            switch self.state(of: host) {
            case .offline: state = owes(host.id, name) ? .owed : .offline
            case .unsupported: state = .unsupported
            case .loading, .failed: state = .checking
            case .loaded(let snapshot):
                if sending[host.id]?.contains(name) == true {
                    state = .updating
                } else {
                    state = snapshot.skill(name) == nil ? .missing : .installed
                }
            }
            return SkillCopy(id: host.id, name: host.name, state: state)
        }
    }

    /// When the first host last looked for updates.
    public func checkedAt(in hosts: [SkillsHost]) -> Double? {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.checkedAt }
    }

    /// Update automatically, as the first host has it.
    public func autoUpdate(in hosts: [SkillsHost]) -> Bool {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.autoUpdate } ?? false
    }

    /// What the first host's automatic skills cost in every prompt.
    public func promptTokens(in hosts: [SkillsHost]) -> Int {
        guard let snapshot = reference(in: hosts).flatMap({ state(of: $0).snapshot }) else { return 0 }
        return SkillsText.promptTokens(snapshot.skills, directory: snapshot.directory)
    }

    /// Where the first host keeps its skills ("~/.agents/skills").
    public func directory(in hosts: [SkillsHost]) -> String {
        reference(in: hosts).flatMap { state(of: $0).snapshot?.directory } ?? "~/.agents/skills"
    }

    /// Whether any host has a change waiting for it.
    public func owes(_ host: UUID) -> Bool {
        !(owed[host] ?? []).isEmpty
    }

    // MARK: Hosts

    /// Reads every connected host's skills, giving a host that is owed changes them first.
    public func refresh(_ hosts: [SkillsHost]) async {
        for host in hosts where host.isConnected && host.serves {
            await catchUp(host)
            await fetch(host)
        }
    }

    /// A host connected again: it takes what it is owed, then the page reads it afresh.
    public func hostConnected(_ host: SkillsHost) async {
        guard host.isConnected, host.serves else { return }
        await catchUp(host)
        await fetch(host)
    }

    /// A host's skills changed without this page (another device, the host's own check).
    public func hostChanged(_ id: UUID, _ snapshot: SkillsSnapshot) {
        loaded[id] = .loaded(snapshot)
    }

    public func dismissProblem() {
        problem = nil
    }

    // MARK: Changes

    /// Turns a skill on or off on every target host, showing it at once.
    @discardableResult
    public func setOn(_ name: String, _ on: Bool, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.setOn(name: name, on: on), name: name, to: holders(of: name, in: hosts)) { snapshot in
            if let index = snapshot.skills.firstIndex(where: { $0.name == name }) { snapshot.skills[index].isOn = on }
        }
    }

    /// How the agent may use a skill, on every target host.
    @discardableResult
    public func setInvocation(_ name: String, _ invocation: SkillInvocation, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.setInvocation(name: name, invocation: invocation), name: name, to: holders(of: name, in: hosts)) { snapshot in
            if let index = snapshot.skills.firstIndex(where: { $0.name == name }) { snapshot.skills[index].invocation = invocation }
        }
    }

    /// Takes a skill off every target host; Undo puts it back.
    @discardableResult
    public func remove(_ name: String, in hosts: [SkillsHost]) -> Task<Void, Never> {
        let targets = holders(of: name, in: hosts)
        removal = Removal(name: name, hosts: targets.map(\.id))
        return post(.remove(name: name), name: name, to: targets) { snapshot in
            snapshot.skills.removeAll { $0.name == name }
        }
    }

    /// Puts back the skill just removed, on the hosts it came off.
    @discardableResult
    public func undoRemoval(in hosts: [SkillsHost]) -> Task<Void, Never>? {
        guard let removal else { return nil }
        self.removal = nil
        let targets = hosts.filter { removal.hosts.contains($0.id) }
        return post(.restore(name: removal.name), name: removal.name, to: targets, showing: nil)
    }

    public func dismissRemoval() {
        removal = nil
    }

    /// Installs a skill's newer commit on every target host; the row says Updating meanwhile.
    public func update(_ name: String, in hosts: [SkillsHost]) async {
        guard let current = row(name, in: hosts), let source = current.skill.source, let update = current.skill.update,
              !updating.contains(name) else { return }
        updating.insert(name)
        defer { updating.remove(name) }
        await send(.install(repo: source.repo, paths: [source.path], commit: update.commit, invocation: nil), name: name,
                   to: targets(in: hosts))
    }

    /// Update N: every skill with a newer commit.
    public func updateAll(in hosts: [SkillsHost]) async {
        for row in rows(in: hosts) where row.skill.update != nil {
            await update(row.name, in: hosts)
        }
    }

    /// Update automatically, on every target host.
    @discardableResult
    public func setAutoUpdate(_ on: Bool, in hosts: [SkillsHost]) -> Task<Void, Never> {
        post(.configure(autoUpdate: on), name: nil, to: targets(in: hosts)) { $0.autoUpdate = on }
    }

    /// Asks each connected host to look for newer commits now.
    public func checkUpdates(in hosts: [SkillsHost]) async {
        await send(.checkUpdates, name: nil, to: targets(in: hosts).filter(\.isConnected))
    }

    // MARK: Installing

    /// A repository's skills, looked up on the first connected host (Add from repo).
    public func lookUp(_ repo: String, in hosts: [SkillsHost]) async throws -> RepoSkills {
        guard let host = targets(in: hosts).first(where: { $0.isConnected && $0.serves }) ?? hosts.first(where: { $0.isConnected && $0.serves }),
              let client = host.client else {
            throw RemoteHostClientError.rejected(code: "offline", message: "No host is connected to look it up.")
        }
        guard case .repo(let found) = try await client.skills(.lookUp(repo: repo)) else {
            throw RemoteHostClientError.rejected(code: "protocol", message: "The host didn't answer with the repository.")
        }
        return found
    }

    /// Installs skills from a repository on every target host, one host at a time; `key` names
    /// the install for the sheet that follows it.
    public func install(_ key: String, repo: String, paths: [String], commit: String?, invocation: SkillInvocation?,
                        in hosts: [SkillsHost]) async {
        await run(key, .install(repo: repo, paths: paths, commit: commit, invocation: invocation), in: hosts)
    }

    /// Installs a folder copied from this device on every target host, one host at a time.
    public func installFiles(_ key: String, name: String, files: [SkillFile], invocation: SkillInvocation,
                             in hosts: [SkillsHost]) async {
        await run(key, .installFiles(name: name, files: files, invocation: invocation), in: hosts)
    }

    private func run(_ key: String, _ request: RemoteSkillsRequest, in hosts: [SkillsHost]) async {
        let destinations = targets(in: hosts)
        installs[key] = SkillInstall(steps: destinations.map { host in
            SkillInstall.Step(id: host.id, name: host.name, state: host.isConnected ? .waiting : .owed)
        }, request: request)
        for host in destinations {
            guard installs[key]?.cancelled == false else { break }
            guard let client = host.client else {
                owe(request, to: host.id)
                continue
            }
            guard host.serves else {
                step(key, host.id, .failed("Update Shepherd on \(host.name) to install skills there."))
                continue
            }
            step(key, host.id, .copying)
            do {
                if case .skills(let snapshot) = try await client.skills(request) { loaded[host.id] = .loaded(snapshot) }
                step(key, host.id, .installed)
            } catch {
                step(key, host.id, .failed(settingsProblem(error)))
            }
        }
    }

    /// Installs a skill from skills.sh: its repository is looked up on a host to find the
    /// skill's folder, then installed like one from Add from repo.
    public func install(_ key: String, source: String, skill: String, invocation: SkillInvocation?, in hosts: [SkillsHost]) async {
        installs[key] = SkillInstall(steps: targets(in: hosts).map { SkillInstall.Step(id: $0.id, name: $0.name, state: .waiting) })
        do {
            let found = try await lookUp(source, in: hosts)
            guard let match = found.skills.first(where: { $0.name == skill })
                ?? found.skills.first(where: { $0.path.split(separator: "/").last.map(String.init) == skill }) else {
                throw RemoteHostClientError.rejected(code: "no_such_skill", message: "\(source) has no skill named \(skill).")
            }
            await install(key, repo: found.repo, paths: [match.path], commit: found.commit, invocation: invocation, in: hosts)
        } catch {
            let reason = settingsProblem(error)
            installs[key]?.steps = (installs[key]?.steps ?? []).map { SkillInstall.Step(id: $0.id, name: $0.name, state: .failed(reason)) }
        }
    }

    /// Stops an install before the hosts it hasn't reached; what those hosts are owed is dropped.
    public func cancelInstall(_ key: String) {
        guard var install = installs[key] else { return }
        install.cancelled = true
        for index in install.steps.indices where install.steps[index].state == .owed || install.steps[index].state == .waiting {
            if let request = install.request, let last = owed[install.steps[index].id]?.lastIndex(of: request) {
                owed[install.steps[index].id]?.remove(at: last)
            }
            install.steps[index].state = .failed("Cancelled")
        }
        installs[key] = install
    }

    public func dismissInstall(_ key: String) {
        installs[key] = nil
    }

    // MARK: Private

    /// The target hosts that have the skill, or are offline (and may).
    private func holders(of name: String, in hosts: [SkillsHost]) -> [SkillsHost] {
        targets(in: hosts).filter { host in
            switch state(of: host) {
            case .loaded(let snapshot): snapshot.skill(name) != nil
            case .offline: true
            default: false
            }
        }
    }

    private func post(_ request: RemoteSkillsRequest, name: String?, to targets: [SkillsHost],
                      showing change: ((inout SkillsSnapshot) -> Void)?) -> Task<Void, Never> {
        problem = nil
        if let change {
            for host in targets {
                guard case .loaded(var snapshot)? = loaded[host.id], host.isConnected else { continue }
                change(&snapshot)
                loaded[host.id] = .loaded(snapshot)
            }
        }
        return Task { await send(request, name: name, to: targets) }
    }

    /// Sends `request` to each host: a connected one answers with its skills, an offline one is
    /// owed it (except a check, which it does itself).
    private func send(_ request: RemoteSkillsRequest, name: String?, to targets: [SkillsHost]) async {
        for host in targets {
            guard let client = host.client else {
                if request != .checkUpdates { owe(request, to: host.id) }
                continue
            }
            guard host.serves else { continue }
            if let name { sending[host.id, default: []].insert(name) }
            do {
                if case .skills(let snapshot) = try await client.skills(request) { loaded[host.id] = .loaded(snapshot) }
            } catch {
                problem = targets.count > 1 ? "\(host.name): \(settingsProblem(error))" : settingsProblem(error)
                await fetch(host)
            }
            if let name { sending[host.id]?.remove(name) }
        }
    }

    private func fetch(_ host: SkillsHost) async {
        guard let client = host.client, host.serves else { return }
        if loaded[host.id] == nil { loaded[host.id] = .loading }
        do {
            if case .skills(let snapshot) = try await client.skills(.fetch) { loaded[host.id] = .loaded(snapshot) }
        } catch {
            loaded[host.id] = .failed(settingsProblem(error))
        }
    }

    /// Sends a host what it was owed while it was away, in order; a change it can no longer take
    /// (a skill it no longer has) is dropped.
    private func catchUp(_ host: SkillsHost) async {
        guard let client = host.client, let requests = owed[host.id], !requests.isEmpty else { return }
        owed[host.id] = nil
        for request in requests {
            if case .skills(let snapshot)? = try? await client.skills(request) { loaded[host.id] = .loaded(snapshot) }
        }
    }

    /// Adds a change a host is owed, dropping any earlier one it replaces.
    private func owe(_ request: RemoteSkillsRequest, to host: UUID) {
        var requests = owed[host] ?? []
        switch request {
        case .setOn(let name, _):
            requests.removeAll { if case .setOn(name, _) = $0 { return true } else { return false } }
        case .setInvocation(let name, _):
            requests.removeAll { if case .setInvocation(name, _) = $0 { return true } else { return false } }
        case .configure:
            requests.removeAll { if case .configure = $0 { return true } else { return false } }
        case .remove(let name):
            requests.removeAll { owed in
                switch owed {
                case .setOn(name, _), .setInvocation(name, _), .restore(name): true
                default: false
                }
            }
        case .restore(let name):
            // Undoing a removal the host never took: the two cancel out.
            if let last = requests.lastIndex(of: .remove(name: name)) {
                requests.remove(at: last)
                owed[host] = requests
                return
            }
        default:
            break
        }
        requests.append(request)
        owed[host] = requests
    }

    private func owes(_ host: UUID, _ name: String) -> Bool {
        (owed[host] ?? []).contains { request in
            switch request {
            case .setOn(name, _), .setInvocation(name, _), .remove(name), .restore(name): true
            case .install: true
            default: false
            }
        }
    }

    private func step(_ key: String, _ host: UUID, _ state: SkillInstall.Step.State) {
        guard var install = installs[key], let index = install.steps.firstIndex(where: { $0.id == host }) else { return }
        install.steps[index].state = state
        installs[key] = install
    }

    private func saveOwed() {
        let stored = Dictionary(uniqueKeysWithValues: owed.map { ($0.key.uuidString, $0.value) })
        if let data = try? JSONEncoder().encode(stored) { defaults.set(data, forKey: Key.owed) }
    }
}
