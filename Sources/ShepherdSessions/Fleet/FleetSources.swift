import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// `instruction:AGENTS.md` and `instruction:APPEND_SYSTEM.md`: Shepherd's root instructions,
/// written through `InstructionsStore` so each synced copy lands in its history ("Synced from
/// Mac mini") like any other save.
final class FleetInstructionsSource: FleetUnitSource {
    private let store: InstructionsStore
    /// Told after a synced copy is written, so Settings and the clients showing the files follow.
    private let written: () -> Void
    let units = InstructionFile.allCases.map(FleetUnit.instruction)

    init(_ store: InstructionsStore, written: @escaping () -> Void = {}) {
        self.store = store
        self.written = written
    }

    private func file(_ unit: String) -> InstructionFile? {
        FleetUnit.name(of: unit).flatMap(InstructionFile.init(rawValue:))
    }

    func storesBlob(_ unit: String) -> Bool { true }
    var watchedFiles: [URL] { InstructionFile.allCases.map { store.directory.appendingPathComponent($0.fileName) } }

    func read() -> [String: Data] {
        Dictionary(uniqueKeysWithValues: InstructionFile.allCases.map { (FleetUnit.instruction($0), Data(store.content($0).utf8)) })
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        !String(decoding: value, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard let file = file(unit) else { return }
        try store.save(file, content: value.map { String(decoding: $0, as: UTF8.self) } ?? "", origin: origin, sync: true)
        written()
    }
}

/// `setting:pi.<key>`: the keys of pi's own `settings.json` that are a person's preferences. pi
/// writes this file too, and Shepherd writes its own keys in it (`shellCommandPrefix`, the
/// resource lists, compaction overrides), so a unit is one top level key, applied under pi's
/// lock with every other key left as it is, and pi's rewrites are read back as ops.
final class FleetPiSettingsSource: FleetUnitSource {
    /// What syncs. Left out on purpose: what Shepherd manages (`shellCommandPrefix`, `skills`,
    /// `extensions`, `packages`, `cacheWarming`, `compaction`) and what is about this Mac (`shellPath`,
    /// `externalEditor`, `sessionDir`, `httpProxy`, `npmCommand`, `terminal`).
    static let keys = [
        "defaultProvider", "defaultModel", "defaultThinkingLevel", "modelThinkingLevels", "thinkingBudgets", "enabledModels",
        "hideThinkingBlock", "showCacheMissNotices", "steeringMode", "followUpMode", "theme", "quietStartup", "transport",
        "retry", "images", "markdown",
    ]

    private let file: PiSettingsFile
    let units = keys.map { FleetUnit.setting("pi." + $0) }

    init(settings: URL) {
        // A write waits briefly for pi's lock; one that can't try again at the next change.
        file = PiSettingsFile(url: settings, patience: 1)
    }

    private func key(_ unit: String) -> String? {
        guard let name = FleetUnit.name(of: unit), name.hasPrefix("pi.") else { return nil }
        let key = String(name.dropFirst(3))
        return Self.keys.contains(key) ? key : nil
    }

    func storesBlob(_ unit: String) -> Bool { false }
    var watchedFiles: [URL] { [file.url] }

    func read() -> [String: Data] {
        guard let data = try? Data(contentsOf: file.url), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
        var values: [String: Data] = [:]
        for key in Self.keys {
            guard let value = object[key], let json = Self.canonical(value) else { continue }
            values[FleetUnit.setting("pi." + key)] = json
        }
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard let key = key(unit) else { return }
        let parsed = try value.map { try JSONSerialization.jsonObject(with: $0, options: .fragmentsAllowed) }
        _ = try file.update { settings in
            if let parsed { settings[key] = parsed } else { settings.removeValue(forKey: key) }
            return []
        }
    }

    /// One JSON text for a value, the same on every Mac (sorted keys).
    static func canonical(_ value: Any) -> Data? {
        try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes])
    }
}

/// `setting:host.<key>`: the host settings that are the same on every Mac (`FleetHostSetting`).
/// The values live in the app's preferences, which the app owns: the app tells the host what they
/// are (`update`), and a synced value is applied by the app's own setting code (`apply`), so the
/// switch, the pi files and the running agents follow exactly as if it was changed on this Mac.
final class FleetHostSettingsSource: FleetUnitSource {
    private var settings: HostSettings?
    private let apply: @Sendable (HostSettingChange) -> Void
    /// The settings and the weights this Mac holds; the weights of other Macs the store decided come through `owns`.
    var units: [String] {
        FleetHostSetting.allCases.map(\.unit) + (settings.map { Array(FleetWeightSetting.values(in: $0).keys) } ?? [])
    }
    func owns(_ unit: String) -> Bool { FleetWeightSetting.hostID(unit: unit) != nil }

    init(apply: @escaping @Sendable (HostSettingChange) -> Void) { self.apply = apply }

    /// The settings as the app has them now; nil is no report yet.
    func update(_ settings: HostSettings) { self.settings = settings }

    var isReady: Bool { settings != nil }
    var writesAsynchronously: Bool { true }

    func storesBlob(_ unit: String) -> Bool { false }

    func read() -> [String: Data] {
        guard let settings else { return [:] }
        return FleetHostSetting.values(in: settings).merging(FleetWeightSetting.values(in: settings)) { $1 }.mapValues { Data($0.utf8) }
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        guard let settings else { return false }
        // A weight set to Normal is what no choice means.
        if FleetWeightSetting.hostID(unit: unit) != nil { return String(decoding: value, as: UTF8.self) != "\"\(FleetSendWeight.normal.rawValue)\"" }
        guard let setting = FleetHostSetting.named(unit: unit) else { return false }
        return !setting.isDefault(in: settings)
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        if let id = FleetWeightSetting.hostID(unit: unit) {
            // A deletion is back to the default.
            let json = value.map { String(decoding: $0, as: UTF8.self) } ?? "\"\(FleetSendWeight.normal.rawValue)\""
            guard let change = FleetWeightSetting.change(hostID: id, fromJSON: json) else {
                throw FleetUnitRefused(description: "\(unit) holds a value this version doesn't know")
            }
            return apply(change)
        }
        guard let value else { return }
        guard let setting = FleetHostSetting.named(unit: unit),
              let change = setting.change(fromJSON: String(decoding: value, as: UTF8.self)) else {
            throw FleetUnitRefused(description: "\(unit) holds a value this version doesn't know")
        }
        apply(change)
    }
}

/// What a tree of files is, as one hash: the sorted `path:hash` lines. A unit that describes a tree
/// (a skill's state, an extension's meta) carries it, and a Mac applies the unit only once its own
/// files hash to the same thing.
enum FleetTreeDigest {
    static func of(_ hashes: [String: String]) -> String {
        FleetSyncProtocol.hash(Data(hashes.sorted { $0.key < $1.key }.map { "\($0.key):\($0.value)" }.joined(separator: "\n").utf8))
    }

    /// Whether any file of the tree has a winner in the fleet that isn't what is on disk yet: a sync is
    /// still writing it. `winners` is unit to hash ("-" a deletion), `local` the same for this Mac's files.
    static func isMidSync(winners: [String: String], local: [String: String]) -> Bool {
        winners.contains { (local[$0.key] ?? "-") != $0.value }
    }
}

/// `skill:<name>/<path>` (each file in a skill, a blob) and `skillstate:<name>` (a skill's state:
/// on or off, the repository it came from, a digest of its files), for every skill Shepherd keeps,
/// on or off; and `setting:skills.autoUpdate`. Read and written through `SkillsStore`, so a synced
/// skill lands where an installed one does (`<pi home>/skills`, or `<support>/skills/off` while it is
/// off) and a removal keeps its Undo. The skills pi loads from elsewhere are the user's own and never travel.
///
/// A skill arrives whole: its files are written into the folder of skills that are off, which pi never
/// reads, and the state moves the folder into place only once the files on disk hash to the state's
/// digest. The state sorts after the files, so it reaches a Mac after them. A skill that is already
/// there is updated in place, file by file; its files are read when it is used, not when pi starts.
final class FleetSkillsSource: FleetUnitSource {
    private let store: SkillsStore
    private let hasher = FleetFileHasher()
    private var fleetValue: (String) -> Data? = { _ in nil }
    private var fleetWinners: (String) -> [String: String] = { _ in [:] }
    /// Told after a synced write, so Settings and the clients showing the skills follow.
    private let written: () -> Void
    /// Skills too big to sync, named once in the log.
    private var oversized: Set<String> = []

    static let autoUpdate = FleetUnit.setting("skills.autoUpdate")
    let units = [FleetSkillsSource.autoUpdate]

    init(_ store: SkillsStore, written: @escaping () -> Void = {}) {
        self.store = store
        self.written = written
    }

    func owns(_ unit: String) -> Bool { unit == Self.autoUpdate || FleetUnit.skillParts(of: unit) != nil }
    func attach(fleetValue: @escaping (String) -> Data?) { self.fleetValue = fleetValue }
    func attach(fleetWinners: @escaping (String) -> [String: String]) { self.fleetWinners = fleetWinners }

    /// A skill's state is a few words, so it travels inline; its files by hash.
    func storesBlob(_ unit: String) -> Bool { FleetUnit.skillParts(of: unit)?.path != nil }
    var watchedFiles: [URL] { [store.syncedRecords] }
    var watchedTrees: [URL] { store.syncedFolders }

    struct State: Codable, Equatable {
        var on: Bool
        var source: SkillSource?
        /// Of the skill's files (`FleetTreeDigest`); nil from a Mac that doesn't send one.
        var digest: String?
    }

    static func json(_ state: State) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(state)) ?? Data()
    }

    /// A skill's files on disk: path to hash. nil when it is over the limits.
    private func files(of skill: SkillsStore.Synced) -> [String: String]? {
        guard let files = FleetFileTree.files(under: skill.folder.resolvingSymlinksInPath().path,
                                               skipping: { FleetFileTree.isNoise($0) || $0 == "node_modules" },
                                               limits: FleetFileTree.skillLimits) else { return nil }
        var hashes: [String: String] = [:]
        for file in files {
            let unit = FleetUnit.skillFile(skill.name, file.relative)
            guard FleetUnit.isValid(unit), file.size <= FleetSyncProtocol.maxBlobBytes, let hash = hasher.hash(file) else { continue }
            hashes[file.relative] = hash
        }
        return hashes
    }

    func fingerprints() -> [String: String] {
        var result: [String: String] = [:]
        for skill in store.syncedSkills() {
            guard let hashes = files(of: skill) else {
                if oversized.insert(skill.name).inserted {
                    ShepherdLog.info("fleet: the skill \(skill.name) is too big to sync, so it stays on this Mac")
                }
                continue
            }
            oversized.remove(skill.name)
            var local: [String: String] = [:]
            for (path, hash) in hashes {
                let unit = FleetUnit.skillFile(skill.name, path)
                result[unit] = hash
                local[unit] = hash
            }
            let state = FleetUnit.skill(skill.name)
            // Files the fleet has decided but this Mac hasn't written yet: the state is the fleet's, not an edit.
            if FleetTreeDigest.isMidSync(winners: fleetWinners("skill:\(skill.name)/"), local: local),
               let theirs = fleetValue(state) {
                result[state] = FleetSyncProtocol.hash(theirs)
            } else {
                result[state] = FleetSyncProtocol.hash(Self.json(State(on: skill.isOn, source: skill.source, digest: FleetTreeDigest.of(hashes))))
            }
        }
        // Files of a skill whose SKILL.md hasn't arrived yet are still files here: not reading them would look like deleting them.
        for (unit, winner) in fleetWinners("skill:") where result[unit] == nil && winner != "-" {
            guard let parts = FleetUnit.skillParts(of: unit), let path = parts.path, let url = store.syncedFile(parts.name, path),
                  let file = FleetFileTree.files(under: url.path, limits: FleetFileTree.skillLimits)?.first, let hash = hasher.hash(file) else { continue }
            result[unit] = hash
        }
        result[Self.autoUpdate] = FleetSyncProtocol.hash(Self.autoUpdateJSON(store.snapshot().autoUpdate))
        return result
    }

    func read() -> [String: Data] {
        var values: [String: Data] = [:]
        for unit in fingerprints().keys { values[unit] = value(of: unit) }
        return values
    }

    func value(of unit: String) -> Data? {
        if unit == Self.autoUpdate { return Self.autoUpdateJSON(store.snapshot().autoUpdate) }
        guard let (name, path) = FleetUnit.skillParts(of: unit) else { return nil }
        guard let path else {
            guard let skill = store.syncedSkills().first(where: { $0.name == name }), let hashes = files(of: skill) else { return nil }
            return Self.json(State(on: skill.isOn, source: skill.source, digest: FleetTreeDigest.of(hashes)))
        }
        guard let url = store.syncedFile(name, path) else { return nil }
        return try? Data(contentsOf: url)
    }

    private static func autoUpdateJSON(_ on: Bool) -> Data { Data((on ? "true" : "false").utf8) }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        unit == Self.autoUpdate ? String(decoding: value, as: UTF8.self) == "true" : true
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        defer { written() }
        if unit == Self.autoUpdate {
            guard let value, let on = try? JSONDecoder().decode(Bool.self, from: value) else { return }
            try store.configure(autoUpdate: on)
            return
        }
        guard let (name, path) = FleetUnit.skillParts(of: unit) else { return }
        if let path {
            // The fleet removing the skill moves the whole folder to Removed (where Undo is) when its state
            // is applied: its files are not taken one by one.
            if value == nil, fleetWinners(FleetUnit.skill(name))[FleetUnit.skill(name)] == "-" { return }
            // A skill that isn't here yet is written where pi doesn't read, and moved into place whole.
            try store.writeSynced(name, path: path, data: value, on: false)
            if value != nil, let state = fleetValue(FleetUnit.skill(name)).flatMap({ try? JSONDecoder().decode(State.self, from: $0) }) {
                _ = try settle(name, state)
            }
            return
        }
        guard let value else {
            // Gone from the fleet: it goes to Removed, where Undo can put it back.
            do { try store.remove(name) } catch SkillsStore.StoreError.noSuchSkill {}
            return
        }
        guard let state = try? JSONDecoder().decode(State.self, from: value) else {
            throw FleetUnitRefused(description: "\(unit) holds a state this version doesn't know")
        }
        // Its files make it, and then this is applied: a skill that isn't whole yet waits for them.
        guard try settle(name, state) else { throw FleetUnitWaiting(description: "\(name)'s files aren't all here yet") }
    }

    /// Puts a skill as its state says (on or off, from where) once its files are all here. False while they aren't.
    private func settle(_ name: String, _ state: State) throws -> Bool {
        if let digest = state.digest, let skill = store.syncedSkills().first(where: { $0.name == name }) {
            let hashes = files(of: skill)
            // Off and wanted on: it moves in only when whole. One already on is updated where it is.
            if !skill.isOn, state.on, hashes.map(FleetTreeDigest.of) != digest { return false }
        }
        return try store.applySynced(name, on: state.on, source: state.source)
    }
}

/// `extension:<path>` (a file under the home's `your-extensions/`) and `extmeta:<id>` (what one
/// extension is: its name, the files pi loads, whether it is switched on, a digest of its files).
/// Every Mac holds the extensions as content in its own `your-extensions/` and loads them from there,
/// by that Mac's absolute path in settings.json: the store holds no machine path, and an extension
/// copied from a path on another Mac loads on this one from its copy.
///
/// An extension arrives whole or not at all: it is listed in settings.json (and so loaded by pi) only
/// once the files on disk hash to the meta's digest, and an extension that is already on is taken out
/// of settings.json while a sync rewrites its files and put back when they are whole. The meta sorts
/// after the files, so it reaches a Mac after them.
///
/// An extension someone is working on (a copy whose source is a folder on this Mac, as "your pi"
/// listed it) is linked: the folder is watched, each save is mirrored into the copy, and the copy's
/// change is an op like any other. The folder stays the live source here; the other Macs hold the
/// copy. Credentials an extension needs belong in pi's `auth.json`, which slice 2c syncs; nothing
/// here reads a Keychain.
final class FleetExtensionsSource: FleetUnitSource {
    private let imports: YourPiImport
    private let root: URL
    private let hasher = FleetFileHasher()
    private var fleetValue: (String) -> Data? = { _ in nil }
    private var fleetWinners: (String) -> [String: String] = { _ in [:] }
    private let written: () -> Void
    /// A copy's signature (its files' paths, sizes and times) as last mirrored from its folder.
    private var mirrored: [String: String] = [:]
    private var oversized: Set<String> = []
    let units: [String] = []

    init(_ imports: YourPiImport, written: @escaping () -> Void = {}) {
        self.imports = imports
        self.written = written
        root = imports.home.directory.appendingPathComponent(YourPiExtensionsFolder.name, isDirectory: true)
    }

    func owns(_ unit: String) -> Bool { ["extension", "extmeta"].contains(FleetUnit.kind(of: unit) ?? "") }
    func attach(fleetValue: @escaping (String) -> Data?) { self.fleetValue = fleetValue }
    func attach(fleetWinners: @escaping (String) -> [String: String]) { self.fleetWinners = fleetWinners }
    func storesBlob(_ unit: String) -> Bool { FleetUnit.kind(of: unit) == "extension" }

    var watchedFiles: [URL] { [imports.stateURL] }
    var watchedTrees: [URL] { [root] + links().map(\.source) }

    struct Meta: Codable, Equatable {
        var name: String
        var entries: [String]?
        var on: Bool
        /// Of the extension's files (`FleetTreeDigest`); nil from a Mac that doesn't send one.
        var digest: String?
    }

    static func json(_ meta: Meta) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(meta)) ?? Data()
    }

    private static let prefix = YourPiExtensionsFolder.name + "/"

    /// An extension's id: its copy's place under `your-extensions/`.
    private static func id(of copy: YourPiCopy) -> String? {
        guard copy.destination.hasPrefix(prefix) else { return nil }
        let id = String(copy.destination.dropFirst(prefix.count))
        return FleetFileTree.isSafe(id) ? id : nil
    }

    /// The unit of a file of extension `group`: the group itself for a lone file, else the path inside it.
    private static func unit(_ group: String, _ relative: String) -> String {
        FleetUnit.extensionFile(relative.isEmpty ? group : group + "/" + relative)
    }

    // MARK: Linked folders

    /// The copies whose source is a folder or file on this Mac that isn't in the home: what a person works on.
    private func links() -> [(id: String, source: URL)] {
        imports.syncedExtensions().compactMap { entry -> (String, URL)? in
            guard let id = Self.id(of: entry.copy), entry.copy.source.hasPrefix("/"),
                  !entry.copy.source.hasPrefix(imports.home.directory.path + "/"),
                  FileManager.default.fileExists(atPath: entry.copy.source) else { return nil }
            return (id, URL(fileURLWithPath: entry.copy.source))
        }
    }

    /// Makes each copy match its folder when the folder changed: files that are new or newer are
    /// copied, files the folder no longer has are removed. One that is over the limits stays as it was copied.
    /// Then puts back an extension a sync held out once its files are whole.
    func prepare() {
        for link in links() {
            guard let files = FleetFileTree.files(under: link.source.path, followingFileLinks: true, limits: FleetFileTree.extensionLimits) else { continue }
            let signature = FleetSyncProtocol.hash(Data(files.map { "\($0.relative):\($0.size):\($0.modified)" }.joined(separator: "\n").utf8))
            guard mirrored[link.id] != signature else { continue }
            mirrored[link.id] = signature
            mirror(files, of: link.source, into: root.appendingPathComponent(link.id))
        }
        for destination in imports.heldExtensions() { releaseIfWhole(destination) }
    }

    private func mirror(_ files: [FleetFileTree.File], of source: URL, into copy: URL) {
        let single = files.count == 1 && files[0].relative.isEmpty
        let (folder, names) = single ? (copy.deletingLastPathComponent(), [copy.lastPathComponent]) : (copy, files.map(\.relative))
        for (file, relative) in zip(files, names) {
            var info = stat()
            let target = single ? copy : copy.appendingPathComponent(relative)
            if lstat(target.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, Int(info.st_size) == file.size,
               Int64(info.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(info.st_mtimespec.tv_nsec) >= file.modified { continue }
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: file.path)) else { continue }
            try? FleetFileTree.write(data, to: relative, under: folder)
        }
        guard !single, let there = FleetFileTree.files(under: copy.path, limits: FleetFileTree.extensionLimits) else { return }
        let kept = Set(files.map(\.relative))
        for stale in there where !kept.contains(stale.relative) { try? FleetFileTree.remove(stale.relative, under: copy) }
    }

    // MARK: Reading

    /// An extension's files on disk: path to hash ("" for a lone file). nil when it is over the limits.
    private func files(ofGroup group: String) -> [String: String]? {
        guard let files = FleetFileTree.files(under: root.appendingPathComponent(group).path, limits: FleetFileTree.extensionLimits) else { return nil }
        var hashes: [String: String] = [:]
        for file in files {
            guard FleetUnit.isValid(Self.unit(group, file.relative)), file.size <= FleetSyncProtocol.maxBlobBytes,
                  let hash = hasher.hash(file) else { continue }
            hashes[file.relative] = hash
        }
        return hashes
    }

    /// The fleet's winners for an extension's files, for `FleetTreeDigest.isMidSync`.
    private func winners(ofGroup group: String) -> [String: String] {
        var result = fleetWinners(FleetUnit.extensionFile(group + "/"))
        if let lone = fleetWinners(FleetUnit.extensionFile(group))[FleetUnit.extensionFile(group)] { result[FleetUnit.extensionFile(group)] = lone }
        return result
    }

    func fingerprints() -> [String: String] {
        var result: [String: String] = [:]
        var paths: Set<String> = []
        let copies = imports.syncedExtensions().compactMap { entry in Self.id(of: entry.copy).map { ($0, entry) } }
        var groups = copies.map(\.0)
        // The packages an npm extension needs, hoisted beside it.
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("npm").path) { groups.append("npm") }
        var skipped: Set<String> = []
        var digests: [String: String] = [:]
        var midSync: Set<String> = []
        for group in Set(groups).sorted() {
            guard let hashes = files(ofGroup: group) else {
                if oversized.insert(group).inserted {
                    ShepherdLog.info("fleet: the extension \(group) is too big to sync, so it stays on this Mac")
                }
                skipped.insert(group)
                continue
            }
            oversized.remove(group)
            var local: [String: String] = [:]
            for (relative, hash) in hashes {
                let unit = Self.unit(group, relative)
                result[unit] = hash
                local[unit] = hash
            }
            digests[group] = FleetTreeDigest.of(hashes)
            if FleetTreeDigest.isMidSync(winners: winners(ofGroup: group), local: local) { midSync.insert(group) }
        }
        // Files of an extension that isn't a copy here yet (its meta comes last) are still files here: not reading them would look like deleting them.
        for (unit, winner) in fleetWinners(FleetUnit.extensionFile("")) where result[unit] == nil && winner != "-" {
            guard let name = FleetUnit.name(of: unit), FleetFileTree.isSafe(name),
                  let file = FleetFileTree.files(under: root.appendingPathComponent(name).path, limits: FleetFileTree.extensionLimits)?.first,
                  file.relative.isEmpty, let hash = hasher.hash(file) else { continue }
            result[unit] = hash
        }
        let held = imports.heldExtensions()
        for (id, entry) in copies where !skipped.contains(id) {
            let meta = FleetUnit.extensionMeta(id)
            // Files the fleet has decided but this Mac hasn't finished writing: the meta is the fleet's, not an edit.
            if midSync.contains(id) || held.contains(entry.copy.destination), let theirs = fleetValue(meta) {
                result[meta] = FleetSyncProtocol.hash(theirs)
            } else {
                result[meta] = FleetSyncProtocol.hash(Self.json(Self.meta(entry.copy, on: entry.on, digest: digests[id])))
            }
        }
        return result
    }

    private static func meta(_ copy: YourPiCopy, on: Bool, digest: String?) -> Meta { Meta(name: copy.name, entries: copy.entries, on: on, digest: digest) }

    func read() -> [String: Data] {
        var values: [String: Data] = [:]
        for unit in fingerprints().keys { values[unit] = value(of: unit) }
        return values
    }

    func value(of unit: String) -> Data? {
        guard let name = FleetUnit.name(of: unit) else { return nil }
        if FleetUnit.kind(of: unit) == "extmeta" {
            guard let entry = imports.syncedExtensions().first(where: { Self.id(of: $0.copy) == name }), let hashes = files(ofGroup: name) else { return nil }
            return Self.json(Self.meta(entry.copy, on: entry.on, digest: FleetTreeDigest.of(hashes)))
        }
        guard FleetFileTree.isSafe(name) else { return nil }
        return try? Data(contentsOf: root.appendingPathComponent(name))
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    // MARK: Writing

    /// The extension a file belongs to, by its copy's place.
    private func destination(ofFile path: String) -> String? {
        imports.syncedExtensions().compactMap { Self.id(of: $0.copy) }.first { path == $0 || path.hasPrefix($0 + "/") }.map { Self.prefix + $0 }
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        defer { written() }
        guard let name = FleetUnit.name(of: unit) else { return }
        if FleetUnit.kind(of: unit) == "extension" {
            // One that is on stops being loaded until its files are whole again.
            if let destination = destination(ofFile: name) { try imports.holdSyncedExtension(destination: destination) }
            if let value { try FleetFileTree.write(value, to: name, under: root) } else { try FleetFileTree.remove(name, under: root) }
            if let destination = destination(ofFile: name) { releaseIfWhole(destination) }
            return
        }
        guard FleetFileTree.isSafe(name) else { throw FleetUnitRefused(description: "\(unit) isn't a place under your-extensions") }
        let destination = Self.prefix + name
        guard let value else {
            try imports.removeSyncedExtension(destination: destination)
            return
        }
        guard let meta = try? JSONDecoder().decode(Meta.self, from: value) else {
            throw FleetUnitRefused(description: "\(unit) holds an extension this version doesn't know")
        }
        // The files it loads come with it: until they are all here, and match, it waits and is not listed.
        guard isWhole(group: name, meta: meta) else { throw FleetUnitWaiting(description: "\(name)'s files aren't all here yet") }
        try imports.applySyncedExtension(destination: destination, name: meta.name, entries: meta.entries, on: meta.on)
    }

    /// Every file the fleet has decided for the extension is here, and the files hash to the meta's digest.
    private func isWhole(group: String, meta: Meta) -> Bool {
        guard let hashes = files(ofGroup: group) else { return false }
        var local: [String: String] = [:]
        for (relative, hash) in hashes { local[Self.unit(group, relative)] = hash }
        if FleetTreeDigest.isMidSync(winners: winners(ofGroup: group), local: local) { return false }
        let loaded = (meta.entries ?? [""]).allSatisfy { entry in
            FleetFileTree.isSafe(entry.isEmpty ? "x" : entry)
                && FileManager.default.fileExists(atPath: (entry.isEmpty ? root.appendingPathComponent(group) : root.appendingPathComponent(group).appendingPathComponent(entry)).path)
        }
        return loaded && meta.digest.map { $0 == FleetTreeDigest.of(hashes) } != false
    }

    /// Lists a held extension again once its files are whole, as the fleet's meta for it says.
    private func releaseIfWhole(_ destination: String) {
        guard imports.heldExtensions().contains(destination), destination.hasPrefix(Self.prefix) else { return }
        let group = String(destination.dropFirst(Self.prefix.count))
        guard let theirs = fleetValue(FleetUnit.extensionMeta(group)), let meta = try? JSONDecoder().decode(Meta.self, from: theirs),
              isWhole(group: group, meta: meta) else { return }
        do {
            try imports.applySyncedExtension(destination: destination, name: meta.name, entries: meta.entries, on: meta.on)
        } catch {
            ShepherdLog.warning("fleet: couldn't list \(group) again: \(error)")
        }
    }
}
