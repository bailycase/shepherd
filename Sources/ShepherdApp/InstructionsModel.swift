import Foundation
import Observation
import SystemConfiguration
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Settings ▸ Instructions on the Mac (DESIGN.md › Instructions): Shepherd's root instructions
/// for pi on this Mac, kept by the server's `InstructionsStore`, and on every remote host, read
/// and saved over `instructions.v1`.
///
/// With Same on every host on, a save writes the file here and then to every host; a host that
/// is offline is owed both files and takes them when it connects again. Off, each machine keeps
/// its own, the page edits one at a time, and a host that differs from This Mac can be copied
/// either way or kept different (remembered, so the same difference is never flagged again).
@MainActor
@Observable
final class InstructionsModel {
    /// A machine the page has a chip for.
    enum Machine: Hashable, Identifiable {
        case local
        case remote(UUID)

        var id: Self { self }
    }

    struct DraftKey: Hashable {
        var machine: Machine
        var file: InstructionFile
    }

    private enum Key {
        static let sameEverywhere = "shepherd.instructions.sameEverywhere"
        static let pendingSync = "shepherd.instructions.pendingSync"
        static let keptDifferent = "shepherd.instructions.keptDifferent"
    }

    // MARK: Persisted

    /// Same on every host: one set of files, written to every host on save.
    var sameEverywhere: Bool {
        didSet {
            guard sameEverywhere != oldValue else { return }
            defaults.set(sameEverywhere, forKey: Key.sameEverywhere)
            if sameEverywhere { machine = .local }
        }
    }
    /// Hosts owed This Mac's files, sent when each connects again.
    private(set) var pendingSync: Set<UUID> {
        didSet { defaults.set(pendingSync.map(\.uuidString).sorted(), forKey: Key.pendingSync) }
    }
    /// Differences kept on purpose: "<host>/<file>" → both sides' fingerprint.
    private(set) var keptDifferent: [String: String] {
        didSet { defaults.set(keptDifferent, forKey: Key.keptDifferent) }
    }

    // MARK: Loaded

    /// This Mac's files, nil until they are read.
    private(set) var local: InstructionsSnapshot?
    private(set) var remote: [UUID: InstructionsHostFiles] = [:]
    /// When each host last took This Mac's files, this launch.
    private(set) var syncedAt: [UUID: Date] = [:]

    // MARK: Page

    var file: InstructionFile = .agents
    /// The machine whose files the page edits (always This Mac with Same on every host on).
    var machine: Machine = .local {
        didSet { if machine != oldValue { showsDiff = true } }
    }
    /// Comparing a host that differs: its diff against This Mac, or its file in the editor.
    var showsDiff = true
    /// The editor's text for a machine's file while it differs from what is saved there.
    private(set) var drafts: [DraftKey: String] = [:]
    private(set) var busy = false
    /// What went wrong with the last save, copy or restore, in words.
    private(set) var problem: String?

    @ObservationIgnored private let store: InstructionsStore
    @ObservationIgnored private let remoteHosts: RemoteHostStore
    @ObservationIgnored private let defaults: UserDefaults

    /// This Mac's name in a host's history ("Synced from Baily's MacBook Pro"): the computer
    /// name from System Settings, read locally (never a network lookup).
    static let machineName: String = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "a Mac"

    init(store: InstructionsStore, remoteHosts: RemoteHostStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.remoteHosts = remoteHosts
        self.defaults = defaults
        sameEverywhere = defaults.object(forKey: Key.sameEverywhere) as? Bool ?? true
        pendingSync = Set((defaults.stringArray(forKey: Key.pendingSync) ?? []).compactMap(UUID.init(uuidString:)))
        keptDifferent = defaults.dictionary(forKey: Key.keptDifferent) as? [String: String] ?? [:]
    }

    // MARK: Reading

    /// Reads This Mac's files and asks every connected host for its own (the page opening).
    func refresh() async {
        await reloadLocal()
        for connection in remoteHosts.connections {
            await fetch(connection.id)
        }
    }

    /// A host connected again: it takes what it is owed, then the page reads it afresh.
    func hostConnected(_ hostID: UUID) {
        Task {
            if local == nil { await reloadLocal() }
            if sameEverywhere, pendingSync.contains(hostID) {
                await push(InstructionFile.allCases, to: hostID)
            } else {
                await fetch(hostID)
            }
        }
    }

    /// This Mac's files changed outside the editor (a remote client's save, a suggestion added
    /// or taken back): the page shows them at once, a draft keeps a line added at the end, and
    /// with Same on every host on every host takes the change.
    func localChanged(_ snapshot: InstructionsSnapshot) {
        let old = local
        local = snapshot
        guard let old else { return }
        let changed = InstructionFile.allCases.filter { old[$0] != snapshot[$0] }
        guard !changed.isEmpty else { return }
        for file in changed {
            let key = DraftKey(machine: .local, file: file)
            guard let draft = drafts[key] else { continue }
            let rebased = InstructionsText.rebased(draft, from: old[file], to: snapshot[file])
            drafts[key] = rebased == snapshot[file] ? nil : rebased
        }
        if sameEverywhere { Task { await pushToAll() } }
    }

    /// What a host's files are, as far as the page knows now.
    func files(of hostID: UUID) -> InstructionsHostFiles {
        guard let connection = remoteHosts.connections.first(where: { $0.id == hostID }),
              connection.phase == .connected else { return .offline }
        guard connection.supportsInstructions else { return .unsupported }
        return remote[hostID] ?? .checking
    }

    /// The saved text of a machine's file, nil while it is unknown.
    func saved(_ file: InstructionFile, on machine: Machine) -> String? {
        switch machine {
        case .local: local?[file]
        case .remote(let hostID): files(of: hostID).snapshot?[file]
        }
    }

    /// What the editor shows: the draft, else the saved text.
    func text(_ file: InstructionFile, on machine: Machine) -> String {
        drafts[DraftKey(machine: machine, file: file)] ?? saved(file, on: machine) ?? ""
    }

    func setText(_ text: String, file: InstructionFile, on machine: Machine) {
        let key = DraftKey(machine: machine, file: file)
        let draft: String? = text == saved(file, on: machine) ? nil : text
        if drafts[key] != draft { drafts[key] = draft }
    }

    func isEdited(_ file: InstructionFile, on machine: Machine) -> Bool {
        drafts[DraftKey(machine: machine, file: file)] != nil
    }

    /// Where a machine keeps a file, for the editor's header; nil while it is unknown.
    func path(of file: InstructionFile, on machine: Machine) -> String? {
        snapshot(of: machine)?.path(of: file)
    }

    /// Per host: the chosen host while its copy of the open file differs from This Mac's (and
    /// wasn't kept different). The editor compares the two, and Resolve offers the ways out.
    var comparing: UUID? {
        guard !sameEverywhere, case .remote(let hostID) = machine, let lines = differingLines(hostID, file: file),
              lines > 0, !isKeptDifferent(hostID, file: file) else { return nil }
        return hostID
    }

    /// Asks a host for its files again (after it couldn't answer).
    func reload(_ hostID: UUID) async {
        remote[hostID] = .checking
        await fetch(hostID)
    }

    // MARK: Hosts

    /// Every configured remote host, in the sidebar's order.
    var hosts: [(id: UUID, name: String)] {
        remoteHosts.connections.map { (id: $0.id, name: $0.config.name) }
    }

    func name(of machine: Machine) -> String {
        switch machine {
        case .local: "This Mac"
        case .remote(let hostID): remoteHosts.connections.first { $0.id == hostID }?.config.name ?? "host"
        }
    }

    /// The machines a save with Same on every host on writes to: This Mac and every host that
    /// can take instructions, online or owed them.
    var saveTargets: Int {
        1 + remoteHosts.connections.filter { files(of: $0.id) != .unsupported }.count
    }

    func chip(for machine: Machine, now: Date = Date()) -> InstructionsChip {
        switch machine {
        case .local:
            let synced = remoteHosts.connections.allSatisfy { connection in
                switch files(of: connection.id) {
                case .unsupported: true
                case .loaded(let snapshot): InstructionFile.allCases.allSatisfy { local?[$0] == snapshot[$0] }
                default: !pendingSync.contains(connection.id)
                }
            }
            return InstructionsPresentation.localChip(sameEverywhere: sameEverywhere, allSynced: synced)
        case .remote(let hostID):
            return InstructionsPresentation.hostChip(
                files(of: hostID), local: local, file: file, sameEverywhere: sameEverywhere,
                pending: pendingSync.contains(hostID), keptDifferent: isKeptDifferent(hostID, file: file),
                syncedAt: syncedAt[hostID], now: now
            )
        }
    }

    /// How many lines of `file` a host's copy differs from This Mac's by; nil while unknown.
    func differingLines(_ hostID: UUID, file: InstructionFile) -> Int? {
        guard let local, let theirs = files(of: hostID).snapshot else { return nil }
        return InstructionsText.differingLineCount(local[file], theirs[file])
    }

    func isKeptDifferent(_ hostID: UUID, file: InstructionFile) -> Bool {
        guard let local, let theirs = files(of: hostID).snapshot else { return false }
        return keptDifferent[Self.keptKey(hostID, file)] == InstructionsPresentation.fingerprint(host: theirs[file], local: local[file])
    }

    // MARK: Side column

    /// The open file's saves on a machine, newest first.
    func history(on machine: Machine) -> [InstructionHistoryEntry] {
        snapshot(of: machine)?.history.filter { $0.file == file } ?? []
    }

    /// A save's summary as this Mac reads it: its own name in a host's history is "This Mac".
    func summary(of entry: InstructionHistoryEntry) -> String {
        entry.summary == "Synced from \(Self.machineName)" ? "Synced from This Mac" : entry.summary
    }

    /// Where a machine keeps its files ("~/Library/Application Support/Shepherd/instructions"),
    /// as it last said.
    func directory(of machine: Machine) -> String? {
        switch machine {
        case .local: local?.directory
        case .remote(let hostID): remote[hostID]?.snapshot?.directory
        }
    }

    /// A machine's row in Files on each host.
    func row(for machine: Machine, now: Date = Date()) -> InstructionsHostRow {
        switch machine {
        case .local:
            return local.map { InstructionsPresentation.localRow($0, now: now) } ?? InstructionsHostRow(detail: "checking…")
        case .remote(let hostID):
            return InstructionsPresentation.hostRow(
                files(of: hostID), lastKnown: remote[hostID]?.snapshot, local: local, file: file,
                keptDifferent: isKeptDifferent(hostID, file: file),
                lastConnected: remoteHosts.connections.first { $0.id == hostID }?.lastConnected, now: now
            )
        }
    }

    /// The file that isn't open: how This Mac's copy compares with every host's, in one line.
    var otherFileLine: String? {
        guard let local, let other = InstructionFile.allCases.first(where: { $0 != file }) else { return nil }
        return InstructionsPresentation.otherFileLine(
            local: local[other],
            hosts: remoteHosts.connections.map { (name: $0.config.name, text: files(of: $0.id).snapshot?[other]) })
    }

    private func snapshot(of machine: Machine) -> InstructionsSnapshot? {
        switch machine {
        case .local: local
        case .remote(let hostID): files(of: hostID).snapshot
        }
    }

    // MARK: Saving

    /// "Save to 3 hosts", "Save", or "Save to build-01".
    var saveTitle: String {
        if sameEverywhere {
            let targets = saveTargets
            return targets > 1 ? "Save to \(targets) hosts" : "Save"
        }
        if case .remote = machine { return "Save to \(name(of: machine))" }
        return "Save"
    }

    var canSave: Bool { !busy && isEdited(file, on: machine) }

    /// Saves the open file on the machine being edited; with Same on every host on, on every host.
    func save() async {
        let key = DraftKey(machine: machine, file: file)
        guard let text = drafts[key], !busy else { return }
        await run {
            switch key.machine {
            case .local:
                try await self.saveLocal(key.file, content: text, origin: nil, sync: false)
                self.drafts[key] = nil
                if self.sameEverywhere { await self.pushToAll() }
            case .remote(let hostID):
                let snapshot = try await self.remoteHosts.instructions(
                    hostID: hostID, request: .save(file: key.file, content: text, origin: Self.machineName, sync: false))
                self.remote[hostID] = .loaded(snapshot)
                self.drafts[key] = nil
            }
        }
    }

    /// Drops the open file's unsaved changes.
    func revert() {
        drafts[DraftKey(machine: machine, file: file)] = nil
    }

    /// Per host: This Mac's copy of the open file onto the chosen host.
    func copyThisMacs(to hostID: UUID) async {
        await run { await self.push([self.file], to: hostID, owed: false) }
    }

    /// Per host: the chosen host's copy of the open file onto This Mac and every other host.
    func copyToAllHosts(from hostID: UUID) async {
        guard let theirs = files(of: hostID).snapshot?[file] else { return }
        let file = file
        await run {
            try await self.saveLocal(file, content: theirs, origin: self.name(of: .remote(hostID)), sync: true)
            self.drafts[DraftKey(machine: .local, file: file)] = nil
            for connection in self.remoteHosts.connections where connection.id != hostID {
                await self.push([file], to: connection.id, owed: false)
            }
        }
    }

    /// Per host: keeps the chosen host's copy of the open file as it is; Shepherd stops asking
    /// about this difference.
    func keepDifferent(_ hostID: UUID) {
        guard let local, let theirs = files(of: hostID).snapshot else { return }
        keptDifferent[Self.keptKey(hostID, file)] = InstructionsPresentation.fingerprint(host: theirs[file], local: local[file])
    }

    /// Puts a saved version back on the machine that saved it.
    func restore(_ entry: InstructionHistoryEntry, on machine: Machine) async {
        await run {
            switch machine {
            case .local:
                let snapshot = try await self.detached { try $0.restore(revisionID: entry.id) }
                self.local = snapshot
                self.drafts[DraftKey(machine: .local, file: entry.file)] = nil
                if self.sameEverywhere { await self.pushToAll() }
            case .remote(let hostID):
                let snapshot = try await self.remoteHosts.instructions(
                    hostID: hostID, request: .restore(revisionID: entry.id, origin: Self.machineName))
                self.remote[hostID] = .loaded(snapshot)
                self.drafts[DraftKey(machine: machine, file: entry.file)] = nil
            }
        }
    }

    /// With Same on every host on: the connected hosts whose files differ from This Mac's (saved
    /// there by another client, or kept different before Same on every host was turned on).
    var differingHosts: [UUID] {
        guard let local else { return [] }
        return remoteHosts.connections.map(\.id).filter { hostID in
            guard let theirs = files(of: hostID).snapshot else { return false }
            return InstructionFile.allCases.contains { local[$0] != theirs[$0] }
        }
    }

    /// With Same on every host on: writes This Mac's files to every host that differs.
    func syncDiffering() async {
        let hosts = differingHosts
        await run {
            for hostID in hosts { await self.push(InstructionFile.allCases, to: hostID) }
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private static func keptKey(_ hostID: UUID, _ file: InstructionFile) -> String {
        "\(hostID.uuidString)/\(file.rawValue)"
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await body()
        } catch {
            problem = Self.describe(error)
        }
    }

    /// The store's file work runs off the main actor.
    private func detached(_ work: @escaping @Sendable (InstructionsStore) throws -> InstructionsSnapshot) async throws -> InstructionsSnapshot {
        let store = store
        return try await Task.detached(priority: .userInitiated) { try work(store) }.value
    }

    private func reloadLocal() async {
        local = try? await detached { $0.snapshot() }
    }

    private func saveLocal(_ file: InstructionFile, content: String, origin: String?, sync: Bool) async throws {
        local = try await detached { try $0.save(file, content: content, origin: origin, sync: sync) }
    }

    private func fetch(_ hostID: UUID) async {
        guard let connection = remoteHosts.connections.first(where: { $0.id == hostID }),
              connection.phase == .connected, connection.supportsInstructions else { return }
        if remote[hostID] == nil { remote[hostID] = .checking }
        do {
            remote[hostID] = .loaded(try await remoteHosts.instructions(hostID: hostID))
        } catch {
            remote[hostID] = .failed(Self.describe(error))
        }
    }

    /// Same on every host: both files, so a host that drifted is whole again after any save.
    private func pushToAll() async {
        for connection in remoteHosts.connections {
            await push(InstructionFile.allCases, to: connection.id)
        }
    }

    /// Writes This Mac's copies of `files` to a host (a file it already holds is left alone).
    /// A host that cannot take them now is owed both files (when `owed`), unless its Shepherd
    /// is too old to ever take them.
    private func push(_ files: [InstructionFile], to hostID: UUID, owed: Bool = true) async {
        guard let local else { return }
        switch self.files(of: hostID) {
        case .unsupported:
            return
        case .offline:
            if owed { pendingSync.insert(hostID) }
            return
        default:
            break
        }
        do {
            var snapshot: InstructionsSnapshot?
            for file in files {
                snapshot = try await remoteHosts.instructions(
                    hostID: hostID, request: .save(file: file, content: local[file], origin: Self.machineName, sync: true))
            }
            if let snapshot { remote[hostID] = .loaded(snapshot) }
            syncedAt[hostID] = Date()
            if files.count == InstructionFile.allCases.count { pendingSync.remove(hostID) }
        } catch {
            if owed { pendingSync.insert(hostID) }
            problem = "Couldn't write to \(name(of: .remote(hostID))): \(Self.describe(error))"
        }
    }

    private static func describe(_ error: Error) -> String {
        if let failure = error as? RemoteHostClientError {
            switch failure {
            case .rejected(_, let message): return message
            default: return "The host didn't answer. Try again once it's connected."
            }
        }
        if let failure = error as? InstructionsStore.StoreError { return failure.description }
        return error.localizedDescription
    }
}
