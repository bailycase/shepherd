import Darwin
import Foundation

/// A hook as Settings' editor holds it before it is written.
public struct HookDraft: Equatable, Sendable {
    public var event: String
    /// Empty for none.
    public var matcher: String
    public var handler: HookHandler
    public init(event: String, matcher: String = "", handler: HookHandler) {
        self.event = event; self.matcher = matcher; self.handler = handler
    }
}

/// Adds, changes and removes one handler in a Shepherd, Claude Code or Codex JSON hooks file
/// (never Codex's `config.toml`). Every other key and entry stays as it was; the file is written
/// whole, pretty-printed with a two-space indent, by temp file and rename (through a symbolic
/// link to the file it names). A hook written here runs at once; one edited while off stays off.
public struct HookFileWriter: Sendable {
    public struct Failure: Error, Equatable, CustomStringConvertible, Sendable {
        public let description: String
    }

    public let settings: HookSettingsStore
    public init(settings: HookSettingsStore) { self.settings = settings }

    /// Adds `draft` to `path` (creating the file and its folders): into the event's first group
    /// with the same matcher, else a new group at the end. Returns the new hook's hash.
    @discardableResult
    public func add(_ draft: HookDraft, to path: String) throws -> String {
        var root = try document(path)
        try Self.insert(draft, into: &root)
        return try save(root, path: path, written: draft, replacing: nil)
    }

    /// Replaces `entry` with `draft`: in place when the event and matcher are the same, else moved
    /// as `add` places it. Throws when the file no longer holds `entry` as it was read. Returns the new hash.
    @discardableResult
    public func update(_ entry: HookEntry, to draft: HookDraft) throws -> String {
        var root = try document(entry.file)
        try Self.verify(entry, in: root)
        if draft.event == entry.event && draft.matcher == entry.matcher {
            var groups = root["hooks"]![entry.event]!.arrayValue!
            var handlers = groups[entry.groupIndex]["hooks"]!.arrayValue!
            handlers[entry.handlerIndex] = draft.handler.raw
            groups[entry.groupIndex]["hooks"] = .array(handlers)
            root["hooks"]![entry.event] = .array(groups)
            return try save(root, path: entry.file, written: draft, replacing: entry)
        }
        Self.remove(entry, from: &root)
        try Self.insert(draft, into: &root)
        return try save(root, path: entry.file, written: draft, replacing: entry)
    }

    /// Removes `entry` (and its group, when it was the last handler there) and forgets its off switch.
    public func delete(_ entry: HookEntry) throws {
        var root = try document(entry.file)
        try Self.verify(entry, in: root)
        Self.remove(entry, from: &root)
        _ = try save(root, path: entry.file, written: nil, replacing: entry)
    }

    // MARK: Editing the document

    private func document(_ path: String) throws -> HookJSON {
        guard !path.hasSuffix(".toml") else { throw Failure(description: "Codex's config.toml is read-only in Shepherd. Edit it in an editor.") }
        guard FileManager.default.fileExists(atPath: path) else { return .object([HookJSON.Member]()) }
        let root: HookJSON
        do { root = try HookCatalog.document(at: path, isTOML: false) }
        catch { throw Failure(description: "Couldn't read \(path): \(error). Fix the file before changing its hooks.") }
        guard root.objectValue != nil, root["hooks"].map({ $0.objectValue != nil }) ?? true else {
            throw Failure(description: "\(path) doesn't have the hooks file shape. Fix the file before changing its hooks.")
        }
        return root
    }

    private static func verify(_ entry: HookEntry, in root: HookJSON) throws {
        let current = (try? HookCatalog.entries(of: root, file: entry.file, scope: entry.scope, format: entry.format, editable: true)) ?? []
        guard current.contains(where: { $0.slot == entry.slot && $0.hash == entry.hash }) else {
            throw Failure(description: "This hook changed in its file since Shepherd read it. Reload and try again.")
        }
    }

    @discardableResult
    private static func insert(_ draft: HookDraft, into root: inout HookJSON) throws -> (Int, Int) {
        guard draft.handler.raw.objectValue != nil else { throw Failure(description: "A hook handler must be a JSON object.") }
        var hooks = root["hooks"] ?? .object([HookJSON.Member]())
        guard var groups = (hooks[draft.event] ?? .array([])).arrayValue else {
            throw Failure(description: "“hooks.\(draft.event)” isn't a list. Fix the file before adding a hook.")
        }
        let group: Int
        if let index = groups.firstIndex(where: { ($0["matcher"]?.stringValue ?? "") == draft.matcher && $0["hooks"]?.arrayValue != nil }) {
            group = index
        } else {
            var created = HookJSON.object([HookJSON.Member]())
            if !draft.matcher.isEmpty { created["matcher"] = .string(draft.matcher) }
            created["hooks"] = .array([])
            groups.append(created)
            group = groups.count - 1
        }
        var handlers = groups[group]["hooks"]!.arrayValue!
        handlers.append(draft.handler.raw)
        groups[group]["hooks"] = .array(handlers)
        hooks[draft.event] = .array(groups)
        root["hooks"] = hooks
        return (group, handlers.count - 1)
    }

    /// Removes the handler; an emptied group goes too, and an emptied event.
    private static func remove(_ entry: HookEntry, from root: inout HookJSON) {
        var groups = root["hooks"]![entry.event]!.arrayValue!
        var handlers = groups[entry.groupIndex]["hooks"]!.arrayValue!
        handlers.remove(at: entry.handlerIndex)
        if handlers.isEmpty { groups.remove(at: entry.groupIndex) } else { groups[entry.groupIndex]["hooks"] = .array(handlers) }
        root["hooks"]![entry.event] = groups.isEmpty ? nil : .array(groups)
    }

    // MARK: Saving

    private func save(_ root: HookJSON, path: String, written draft: HookDraft?, replacing old: HookEntry?) throws -> String {
        let target = PiHome.canonical(path)
        try FileManager.default.createDirectory(atPath: (target as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        var info = stat()
        let mode = lstat(target, &info) == 0 ? info.st_mode & 0o7777 : 0o644
        try PiHome.write(Data(root.pretty.utf8), to: URL(fileURLWithPath: target), mode: mode)

        let hash = draft.map { HookCanonical.hash(file: path, event: $0.event, matcher: $0.matcher, canonical: $0.handler.raw.canonical) } ?? ""
        // Only an off switch carries over: an edit keeps a hook that was off, off; a removed one is forgotten.
        guard let old, settings.read().off.contains(old.hash) else { return hash }
        let remaining = Set(((try? HookCatalog.entries(of: root, file: path, scope: .mac, format: .shepherd, editable: true)) ?? []).map(\.hash))
        try settings.change { settings in
            if !remaining.contains(old.hash) { settings.off.removeAll { $0 == old.hash } }
            if draft != nil, !settings.off.contains(hash) { settings.off.append(hash) }
        }
        return hash
    }
}
