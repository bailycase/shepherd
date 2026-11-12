import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol

// MARK: Slice 2b-ii: MCP servers, hooks, subagents and spaces

/// `mcpServer:<name>`: one server's entry in the shared `~/.config/mcp/mcp.json`, the object as the
/// file holds it (Shepherd's `shepherd` fields included). The file is shared with other tools and hand
/// edited, so a unit is one server: a write goes through `MCPConfigFile.update`, which keeps every other
/// key and entry, and a hand edit of the file is read back as ops. The servers' secrets are not here:
/// a `${keychain:…}` reference travels as a reference, and the credentials are slice 2c's. pi's own
/// `mcp.json` is derived from this file when an agent launches (`MCPPiConfig`), as it always was.
final class FleetMCPSource: FleetUnitSource {
    private let file: MCPConfigFile
    private let written: () -> Void
    private var present: [String] = []

    /// `written`: told after a synced server is written, so Settings follows.
    init(file: MCPConfigFile, written: @escaping () -> Void = {}) {
        self.file = file
        self.written = written
    }

    static let kind = "mcpServer:"
    var units: [String] { present }
    func owns(_ unit: String) -> Bool { unit.hasPrefix(Self.kind) }
    func storesBlob(_ unit: String) -> Bool { false }
    var watchedFiles: [URL] { [file.url] }

    /// A file that doesn't parse reads as no servers, which would delete every one: wait until it does.
    var isReady: Bool {
        if case .document = file.read() { return true }
        return false
    }

    func read() -> [String: Data] {
        guard case .document(let document) = file.read() else { return [:] }
        var values: [String: Data] = [:]
        for entry in document.servers {
            let unit = Self.kind + entry.name
            guard FleetUnit.isValid(unit) else { continue }
            values[unit] = Data(MCPJSON.write(.object(entry.json)).utf8)
        }
        present = Array(values.keys)
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard unit.hasPrefix(Self.kind) else { return }
        let name = String(unit.dropFirst(Self.kind.count))
        var entry: MCPServerEntry?
        if let value {
            guard case .success(.object(let json)) = MCPJSON.parse(value) else {
                throw FleetUnitRefused(description: "\(unit) isn't a server entry")
            }
            entry = MCPServerEntry(name: name, json: json)
        }
        do {
            try file.update { document in
                if let entry { document.upsert(entry) } else { document.remove(name) }
            }
        } catch MCPConfigError.invalid {
            // Never over a file that doesn't parse: it is tried again when it does (`isReady`).
            return
        }
        written()
    }
}

/// `hook:<id>`: one hook of Shepherd's own hooks file on this Mac (`~/.shepherd/hooks.json`), its
/// value the event, matcher, handler and whether it is on. The id is a hash of what the hook does,
/// not of where it is, so the same hook has one id on every Mac. Written through `HookFileWriter` and
/// `HookSettingsStore`, the writers Settings ▸ Hooks uses. Claude Code's and Codex's files belong to
/// those tools and a space's hooks are repo files: neither syncs. `setting:hooks.readers` is the
/// Sources switches (whether those two tools' files are read).
final class FleetHooksSource: FleetUnitSource {
    private let catalog: () -> HookCatalog
    private let written: () -> Void
    private var present: [String] = []

    static let kind = "hook:"
    static let readers = FleetUnit.setting("hooks.readers")

    init(catalog: @escaping () -> HookCatalog, written: @escaping () -> Void = {}) {
        self.catalog = catalog
        self.written = written
    }

    var units: [String] { present + [Self.readers] }
    func owns(_ unit: String) -> Bool { unit.hasPrefix(Self.kind) }
    func storesBlob(_ unit: String) -> Bool { false }
    private var sharedPath: String { catalog().home + "/.shepherd/hooks.json" }
    var watchedFiles: [URL] { [URL(fileURLWithPath: sharedPath), catalog().settingsStore.url] }

    /// A hooks file that doesn't read would look like no hooks, and delete them all: wait until it does.
    var isReady: Bool {
        let path = sharedPath
        guard let source = catalog().load().sources.first(where: { $0.path == path }) else { return false }
        switch source.state {
        case .loaded, .notFound: return true
        case .readerOff, .unreadable: return false
        }
    }

    /// The id of a hook: the same on every Mac, whatever its home folder.
    static func id(event: String, matcher: String, handler: HookJSON) -> String {
        HookCanonical.hash(file: "", event: event, matcher: matcher, canonical: handler.canonical)
    }

    private func ownEntries(_ snapshot: HookCatalogSnapshot) -> [HookEntry] {
        let path = sharedPath
        return snapshot.entries.filter { $0.scope == .mac && $0.format == .shepherd && $0.file == path }
    }

    func read() -> [String: Data] {
        let snapshot = catalog().load()
        var values: [String: Data] = [:]
        for entry in ownEntries(snapshot) {
            let id = Self.id(event: entry.event, matcher: entry.matcher, handler: entry.handler.raw)
            let value = HookJSON.object(["event": .string(entry.event), "handler": entry.handler.raw, "matcher": .string(entry.matcher), "on": .bool(entry.on)])
            values[Self.kind + id] = Data(value.canonical.utf8)
        }
        present = Array(values.keys)
        let readers = snapshot.settings.readers
        values[Self.readers] = Data(HookJSON.object(["claude": .bool(readers.claude), "codex": .bool(readers.codex)]).canonical.utf8)
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool {
        guard unit == Self.readers else { return true }
        // Both on is what no choice means.
        return String(decoding: value, as: UTF8.self) != HookJSON.object(["claude": .bool(true), "codex": .bool(true)]).canonical
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        let catalog = catalog()
        if unit == Self.readers {
            guard let value, let json = try? HookJSON.parse(String(decoding: value, as: UTF8.self)),
                  let claude = json["claude"]?.boolValue, let codex = json["codex"]?.boolValue else { return }
            try catalog.settingsStore.change { $0.readers = HookSettings.Readers(claude: claude, codex: codex) }
            written()
            return
        }
        guard unit.hasPrefix(Self.kind) else { return }
        let id = String(unit.dropFirst(Self.kind.count))
        let existing = ownEntries(catalog.load()).first { Self.id(event: $0.event, matcher: $0.matcher, handler: $0.handler.raw) == id }
        let writer = HookFileWriter(settings: catalog.settingsStore)
        do {
            if let value {
                guard let json = try? HookJSON.parse(String(decoding: value, as: UTF8.self)), let event = json["event"]?.stringValue, !event.isEmpty,
                      let handler = json["handler"], handler.objectValue != nil else {
                    throw FleetUnitRefused(description: "\(unit) isn't a hook")
                }
                let on = json["on"]?.boolValue ?? true
                if let existing {
                    if existing.on != on { try catalog.settingsStore.setOn(existing.hash, on) }
                } else {
                    let hash = try writer.add(HookDraft(event: event, matcher: json["matcher"]?.stringValue ?? "", handler: HookHandler(raw: handler)), to: sharedPath)
                    if !on { try catalog.settingsStore.setOn(hash, false) }
                }
            } else if let existing {
                try writer.delete(existing)
            }
        } catch let failure as HookFileWriter.Failure {
            throw FleetUnitRefused(description: failure.description)
        }
        written()
    }
}

/// `subagent:<file>`: a subagent profile's Markdown in pi's `agents/` folder, as the file holds it.
/// Written through `SubagentDefinitionsStore.save`, which checks the profile loads (and has a name no
/// other profile has) before it touches the folder; a profile this Mac's pi refuses stays as it was.
final class FleetSubagentsSource: FleetUnitSource {
    private let store: SubagentDefinitionsStore
    private let written: () -> Void
    private var present: [String] = []
    private var listed: [SubagentDefinitionsStore.File]?

    static let kind = "subagent:"

    init(store: SubagentDefinitionsStore, written: @escaping () -> Void = {}) {
        self.store = store
        self.written = written
    }

    var units: [String] { present }
    func owns(_ unit: String) -> Bool { unit.hasPrefix(Self.kind) }
    func storesBlob(_ unit: String) -> Bool { true }
    var watchedFiles: [URL] { [store.directory] }

    /// A folder this Mac hasn't made yet holds no profiles; one that can't be listed isn't read as empty.
    var isReady: Bool {
        guard FileManager.default.fileExists(atPath: store.directory.path) else {
            listed = []
            return true
        }
        listed = try? store.files()
        return listed != nil
    }

    func read() -> [String: Data] {
        let files = listed ?? []
        var values: [String: Data] = [:]
        for file in files where SubagentDefinitionsStore.acceptsFilename(file.file) && FleetUnit.isValid(Self.kind + file.file) {
            values[Self.kind + file.file] = Data(file.text.utf8)
        }
        present = Array(values.keys)
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { !value.isEmpty }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard unit.hasPrefix(Self.kind) else { return }
        let file = String(unit.dropFirst(Self.kind.count))
        guard SubagentDefinitionsStore.acceptsFilename(file) else { throw FleetUnitRefused(description: "\(unit) isn't a subagent file name") }
        let existing = FileManager.default.fileExists(atPath: store.directory.path) ? try store.files().first { $0.file == file } : nil
        do {
            if let value {
                guard let text = String(data: value, encoding: .utf8) else { throw FleetUnitRefused(description: "\(unit) isn't text") }
                try store.save(file, text: text, expected: existing?.fingerprint)
            } else if let existing {
                try store.delete(file, expected: existing.fingerprint)
            }
        } catch let failure as SubagentDefinitionsStore.Failure {
            throw FleetUnitRefused(description: failure.description)
        }
        written()
    }
}

/// Where each synced space's folder is on this Mac (`fleet/space-paths.json`, never synced): a
/// space is the same everywhere, but its folder is wherever this Mac keeps the repo.
struct FleetSpacePaths {
    private let url: URL
    private(set) var paths: [SpaceID: String]

    init(directory: URL) {
        url = directory.appendingPathComponent("space-paths.json")
        let raw = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([String: String].self, from: $0) } ?? [:]
        paths = Dictionary(uniqueKeysWithValues: raw.map { (SpaceID(rawValue: $0.key), $0.value) })
    }

    /// Records where `space` is here (a person located it, or it was already a space here). Returns whether anything changed.
    @discardableResult
    mutating func bind(_ space: SpaceID, to path: String) -> Bool {
        guard paths[space] != path else { return false }
        paths[space] = path
        save()
        return true
    }

    mutating func forget(_ space: SpaceID) {
        guard paths.removeValue(forKey: space) != nil else { return }
        save()
    }

    private func save() {
        let raw = Dictionary(uniqueKeysWithValues: paths.map { ($0.key.rawValue, $0.value) })
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(raw) { FleetStore.write(data, to: url) }
    }
}

/// `space:<spaceID>`: a project's name, repo, base branch, place in the tree and whether it is
/// hidden from the sidebar, the same on every Mac. Not its folder: a Mac that has no folder for a
/// synced space keeps it unbound (nothing is added to its state) until a folder is bound
/// (`FleetSpacePaths`), and a bound space takes the synced fields as they change. A space another Mac
/// removed goes from this one too, unless a thread here lives in it. Reserved spaces (designs,
/// automations, standalone threads, project coordinators) are this Mac's own and never sync.
final class FleetSpacesSource: FleetUnitSource {
    /// What the host lets the source do with its state: all on the server queue.
    struct Host {
        var spaces: () -> [Space]
        var hasThreads: (SpaceID) -> Bool
        /// Applies `change` to the spaces through the server's own state mutation.
        var mutate: (@escaping (inout [Space]) -> Void) throws -> Void
    }

    private let host: Host
    private let written: () -> Void
    private var bindings: FleetSpacePaths
    private var present: [String] = []

    static let kind = "space:"

    init(host: Host, directory: URL, written: @escaping () -> Void = {}) {
        self.host = host
        self.written = written
        bindings = FleetSpacePaths(directory: directory)
    }

    /// Where a space is on this Mac, for the unit's binding.
    func bind(_ space: SpaceID, to path: String) {
        if bindings.bind(space, to: path) { written() }
    }

    var units: [String] { present }
    func owns(_ unit: String) -> Bool { unit.hasPrefix(Self.kind) }
    func storesBlob(_ unit: String) -> Bool { false }

    static func syncs(_ space: Space) -> Bool {
        !space.hidden && !space.holdsDesigns && !space.holdsProjects && !space.holdsThreads
    }

    private static func unit(_ id: SpaceID) -> String { kind + id.rawValue }

    func read() -> [String: Data] {
        var values: [String: Data] = [:]
        for space in host.spaces() where Self.syncs(space) {
            bindings.bind(space.id, to: space.path)
            var object: [String: Any] = ["name": space.name]
            if let key = space.repoKey { object["repoKey"] = key }
            if let base = space.worktreeBase { object["worktreeBase"] = base }
            if let parent = space.parentID { object["parentID"] = parent.rawValue }
            if space.parentIsExplicit { object["parentIsExplicit"] = true }
            if space.sidebarHidden { object["sidebarHidden"] = true }
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]) else { continue }
            values[Self.unit(space.id)] = data
        }
        present = Array(values.keys)
        return values
    }

    func isSeedable(_ unit: String, _ value: Data) -> Bool { true }

    /// The git config of each space's checkout, so a changed origin (its `repoKey`) is noticed when it happens.
    var watchedFilesOnly: [URL] { FleetRepoKeys.watchedFiles(of: host.spaces().filter(Self.syncs)) }

    private struct Fields {
        var name: String
        var repoKey: String?
        var worktreeBase: String?
        var parentID: SpaceID?
        var parentIsExplicit: Bool
        var sidebarHidden: Bool
    }

    private static func fields(_ data: Data) -> Fields? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], let name = object["name"] as? String, !name.isEmpty else { return nil }
        return Fields(name: name, repoKey: object["repoKey"] as? String, worktreeBase: object["worktreeBase"] as? String,
                      parentID: (object["parentID"] as? String).map { SpaceID(rawValue: $0) },
                      parentIsExplicit: object["parentIsExplicit"] as? Bool ?? false, sidebarHidden: object["sidebarHidden"] as? Bool ?? false)
    }

    func write(_ unit: String, _ value: Data?, origin: String) throws {
        guard unit.hasPrefix(Self.kind) else { return }
        let id = SpaceID(rawValue: String(unit.dropFirst(Self.kind.count)))
        let local = host.spaces().first { $0.id == id }
        guard let value else {
            // Another Mac removed it. Removing a space takes its threads with it, so one with threads here stays.
            guard let local, Self.syncs(local) else { return }
            if host.hasThreads(id) { throw FleetUnitRefused(description: "\(local.name) has threads on this Mac", quiet: true) }
            try host.mutate { spaces in
                spaces.removeAll { $0.id == id }
                for index in spaces.indices where spaces[index].parentID == id {
                    spaces[index].parentID = nil
                    spaces[index].parentIsExplicit = true
                }
            }
            bindings.forget(id)
            written()
            return
        }
        guard let fields = Self.fields(value) else { throw FleetUnitRefused(description: "\(unit) isn't a space") }
        if local != nil {
            try host.mutate { spaces in
                guard let index = spaces.firstIndex(where: { $0.id == id }) else { return }
                spaces[index].name = fields.name
                spaces[index].repoKey = fields.repoKey ?? spaces[index].repoKey
                spaces[index].worktreeBase = fields.worktreeBase
                spaces[index].parentID = fields.parentID
                spaces[index].parentIsExplicit = fields.parentIsExplicit
                spaces[index].sidebarHidden = fields.sidebarHidden
            }
            written()
            return
        }
        // Not here yet: it is added once a folder is bound to it, and only if the folder is there.
        var isDirectory: ObjCBool = false
        guard let path = bindings.paths[id], FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw FleetUnitRefused(description: "\(fields.name) has no folder on this Mac", quiet: true)
        }
        try host.mutate { spaces in
            guard !spaces.contains(where: { $0.id == id }) else { return }
            spaces.append(Space(id: id, name: fields.name, path: path, sidebarHidden: fields.sidebarHidden, parentID: fields.parentID,
                                parentIsExplicit: fields.parentIsExplicit, worktreeBase: fields.worktreeBase, repoKey: fields.repoKey))
        }
        written()
    }
}
