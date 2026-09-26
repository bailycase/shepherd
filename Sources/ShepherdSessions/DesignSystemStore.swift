import Foundation
import ShepherdCore
import ShepherdProtocol

/// Why a design system could not be read, written, installed or synced. `code` is the stable
/// spelling for replies.
public enum DesignSystemError: Error, Hashable, Sendable, CustomStringConvertible {
    case invalidNamespace(String)
    case noSuchSystem(String)
    /// Built into Shepherd (Night Watch): read and installed, never written or synced.
    case readOnly(String)
    /// Another design's agent built it: only that agent writes it.
    case notYours(String)
    case invalidTokens([String])
    case noTokens(String)
    case invalidFile(String)
    case invalidSource(String)
    case tooManyFiles
    case tooLarge(String)
    case tooManySystems
    case stale(base: UInt64, current: UInt64)
    /// Nothing to re-sync: the system names no stylesheets, or its project is gone.
    case noSources(String)
    /// A design's `ds/<namespace>/` holds a system installed from elsewhere (claude.ai): it is
    /// kept as it is.
    case namespaceTaken(String)
    /// `design-systems/<namespace>` is a link or a file, never followed.
    case notAFolder(String)
    case io(String)

    public var code: String {
        switch self {
        case .invalidNamespace: return "invalid_namespace"
        case .noSuchSystem: return "no_such_system"
        case .readOnly: return "read_only_system"
        case .notYours: return "not_your_system"
        case .invalidTokens: return "invalid_tokens"
        case .noTokens: return "no_tokens"
        case .invalidFile: return "invalid_file"
        case .invalidSource: return "invalid_source"
        case .tooManyFiles: return "too_many_files"
        case .tooLarge: return "too_large"
        case .tooManySystems: return "too_many_systems"
        case .stale: return "stale_revision"
        case .noSources: return "no_sources"
        case .namespaceTaken: return "namespace_taken"
        case .notAFolder: return "not_a_folder"
        case .io: return "io_failed"
        }
    }

    public var description: String {
        switch self {
        case .invalidNamespace(let name): return "\"\(name.prefix(80))\" can't name a design system: [a-z0-9][a-z0-9_-]{0,63}"
        case .noSuchSystem(let name): return "no design system \(name)"
        case .readOnly(let name): return "\(name) is built into Shepherd: install it, but never write or sync it"
        case .notYours(let name): return "\(name) was built by another design's agent; write a system of your own under another namespace"
        case .invalidTokens(let problems): return "tokens.json: " + problems.prefix(12).joined(separator: "; ")
        case .noTokens(let name): return "\(name) needs its tokens.json"
        case .invalidFile(let path): return "\"\(path.prefix(120))\" can't be a file of a design system: a relative path of json, css, js, md, html, svg or txt, never system.json or tokens.json (pass tokens)"
        case .invalidSource(let path): return "\"\(path.prefix(120))\" is not a stylesheet of the project (.css, .scss or .less, relative to it)"
        case .tooManyFiles: return "a design system holds at most \(DesignSystemFile.maxFiles) files"
        case .tooLarge(let what): return "\(what) is too large"
        case .tooManySystems: return "this Mac keeps at most \(DesignSystemStore.maxSystems) design systems"
        case .stale(let base, let current):
            return "the design system changed since revision \(base) (it is at \(current)); read it again and redo the change"
        case .noSources(let why): return why
        case .namespaceTaken(let name):
            return "the design's ds/\(name)/ holds a system installed from elsewhere; it is kept as it is, so install under another namespace"
        case .notAFolder(let name):
            return "design-systems/\(name) is not a folder of its own (a link is never followed); write the system under another namespace"
        case .io(let message): return message
        }
    }
}

/// Every design system this host keeps, under the support directory's `design-systems/<ns>/`:
/// `tokens.json`, `tokens.css`, `README.md`, components, and Shepherd's own `system.json`
/// beside them (docs/designs.md › Design systems). Built-in systems (Night Watch) live in
/// memory, handed over by the app.
///
/// Every read and write runs on the store's own serial queue, never the server's. A system is
/// read from a project's stylesheets only when an agent writes it or the user re-syncs it; the
/// project is only ever read. Nothing watches the files.
public final class DesignSystemStore: @unchecked Sendable {
    public let directory: URL
    public static let maxSystems = 100
    /// A stylesheet is read up to this size.
    public static let maxSourceBytes = 1_000_000

    /// A system Shepherd ships: its record and its files by path, read-only.
    public struct BuiltIn: Sendable, Hashable {
        public var info: DesignSystemInfo
        public var files: [String: Data]

        public init(info: DesignSystemInfo, files: [String: Data]) {
            self.info = info
            self.files = files
        }
    }

    private let queue = DispatchQueue(label: "shepherd.design-systems", qos: .userInitiated)
    /// Queue-confined.
    private var builtIns: [String: BuiltIn] = [:]

    public init(directory: URL) {
        self.directory = directory
    }

    /// Adds (or replaces) a built-in system. A folder of the same name on disk is hidden by it.
    public func register(_ builtIn: BuiltIn) {
        queue.async { self.builtIns[builtIn.info.namespace] = builtIn }
    }

    /// A system's folder: a folder of its own directly inside `design-systems/`, or not there
    /// yet. Nil for a namespace off the grammar, or for a name that is a link (followed, it
    /// would read or write outside the store).
    public func folder(for namespace: String) -> URL? {
        guard DesignPath.isSystemNamespace(namespace) else { return nil }
        let folder = directory.appendingPathComponent(namespace, isDirectory: true)
        if let type = (try? FileManager.default.attributesOfItem(atPath: folder.path))?[.type] as? FileAttributeType,
           type != .typeDirectory {
            return nil
        }
        return folder
    }

    /// `folder(for:)`, or why there is none.
    private func ownFolder(_ namespace: String) throws -> URL {
        guard DesignPath.isSystemNamespace(namespace) else { throw DesignSystemError.invalidNamespace(namespace) }
        guard let folder = folder(for: namespace) else { throw DesignSystemError.notAFolder(namespace) }
        return folder
    }

    // MARK: Reads

    /// Every system: the built-ins first, then the folders on disk by namespace.
    public func list() async -> [DesignSystemSummary] {
        (try? await run {
            let builtIn = self.builtIns.values.sorted { $0.info.namespace < $1.info.namespace }.map(Self.summary)
            let names = ((try? FileManager.default.contentsOfDirectory(atPath: self.directory.path)) ?? [])
                .filter { self.folder(for: $0) != nil && self.builtIns[$0] == nil }
                .sorted()
            let onDisk = names.compactMap { try? self.summaryOnQueue($0) }
            return builtIn + onDisk
        }) ?? []
    }

    public func read(_ namespace: String) async throws -> DesignSystemRead {
        try await run {
            let (summary, files) = try self.loadOnQueue(namespace)
            let tokens = files[DesignSystemFile.tokens].flatMap { try? DesignSystemTokens.decode($0) }
            let readme = files[DesignSystemFile.readme].map { data -> String in
                String(decoding: data.prefix(DesignSystemRead.maxReadmeBytes), as: UTF8.self)
            }
            return DesignSystemRead(summary: summary, tokens: tokens, readme: readme, files: files.keys.sorted())
        }
    }

    /// A system's summary and every file of it, for an install.
    func contents(_ namespace: String) async throws -> (summary: DesignSystemSummary, files: [String: Data]) {
        try await run { try self.loadOnQueue(namespace) }
    }

    // MARK: Writes (SessionServer only)

    /// Writes a system's tokens and files for `owner`'s agent, reading its `sources` from
    /// `sourceRoot` (the owner's project) to check they are there. A new system becomes the
    /// owner's; an existing one must be.
    func write(_ write: DesignSystemWrite, owner: DesignID, spaceID: SpaceID?, sourceRoot: URL?,
               at now: Double) async throws -> (summary: DesignSystemSummary, changed: Bool, notes: [String]) {
        try await run { try self.writeOnQueue(write, owner: owner, spaceID: spaceID, sourceRoot: sourceRoot, at: now) }
    }

    /// Reads the system's stylesheets again from `root` and updates the tokens that came from
    /// them (`DesignSystemTokens.resynced`).
    func resync(_ namespace: String, root: URL, at now: Double) async throws -> DesignSystemSyncResult {
        try await run {
            guard self.builtIns[namespace] == nil else { throw DesignSystemError.readOnly(namespace) }
            let folder = try self.ownFolder(namespace)
            var info = try self.infoOnQueue(namespace)
            guard !info.sources.isEmpty else {
                throw DesignSystemError.noSources("\(namespace) names no stylesheets to read again")
            }
            let tokensURL = folder.appendingPathComponent(DesignSystemFile.tokens)
            guard let data = try? Data(contentsOf: tokensURL) else { throw DesignSystemError.noTokens(namespace) }
            let tokens: DesignSystemTokens
            do { tokens = try DesignSystemTokens.decode(data) } catch {
                throw DesignSystemError.invalidTokens([String(describing: error)])
            }
            var declarations: [String: [DesignCSSDeclaration]?] = [:]
            for source in info.sources { declarations[source] = Self.readSource(source, root: root) }
            let (next, changes) = tokens.resynced(from: declarations)
            if !changes.isEmpty {
                let encoded: Data
                do { encoded = try next.encoded() } catch { throw DesignSystemError.io("could not encode tokens.json") }
                try Self.writeFile(encoded, to: tokensURL)
                let stylesheet = folder.appendingPathComponent(DesignSystemFile.stylesheet)
                if Self.isGenerated(try? Data(contentsOf: stylesheet)) {
                    try Self.writeFile(Data(next.css().utf8), to: stylesheet)
                }
                info.revision += 1
                info.updatedAt = now
            }
            info.syncedAt = now
            try self.saveInfo(info)
            return DesignSystemSyncResult(summary: try self.summaryOnQueue(namespace), changes: changes)
        }
    }

    // MARK: Queue

    private func writeOnQueue(_ write: DesignSystemWrite, owner: DesignID, spaceID: SpaceID?, sourceRoot: URL?,
                              at now: Double) throws -> (summary: DesignSystemSummary, changed: Bool, notes: [String]) {
        let namespace = write.namespace
        guard DesignPath.isSystemNamespace(namespace) else { throw DesignSystemError.invalidNamespace(namespace) }
        guard builtIns[namespace] == nil else { throw DesignSystemError.readOnly(namespace) }
        let folder = try ownFolder(namespace)
        let manager = FileManager.default
        let exists = manager.fileExists(atPath: folder.path)
        var info: DesignSystemInfo
        if exists {
            info = try infoOnQueue(namespace)
            guard info.ownerDesignID == owner else { throw DesignSystemError.notYours(namespace) }
        } else {
            let count = ((try? manager.contentsOfDirectory(atPath: directory.path)) ?? []).filter(DesignPath.isSystemNamespace).count
            guard count < Self.maxSystems else { throw DesignSystemError.tooManySystems }
            info = DesignSystemInfo(namespace: namespace, title: namespace, createdAt: now, ownerDesignID: owner)
        }
        if let base = write.baseRevision, base != info.revision {
            throw DesignSystemError.stale(base: base, current: info.revision)
        }
        var notes: [String] = []

        // What goes where: tokens.json first, then the other files, then a generated stylesheet.
        var writes: [String: Data] = [:]
        var removals: Set<String> = []
        var tokens: DesignSystemTokens?
        if let json = write.tokens {
            let decoded: DesignSystemTokens
            do { decoded = try DesignSystemTokens(json: json) } catch {
                throw DesignSystemError.invalidTokens([String(describing: error)])
            }
            var problems = decoded.problems()
            if let own = decoded.namespace, own != namespace { problems.append("its namespace is \(own), not \(namespace)") }
            guard problems.isEmpty else { throw DesignSystemError.invalidTokens(problems) }
            tokens = decoded
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
            writes[DesignSystemFile.tokens] = try encoder.encode(json)
        } else if !exists || !manager.fileExists(atPath: folder.appendingPathComponent(DesignSystemFile.tokens).path) {
            throw DesignSystemError.noTokens(namespace)
        }
        for (path, value) in (write.files ?? [:]).sorted(by: { $0.key < $1.key }) {
            guard DesignSystemFile.isPath(path), path != DesignSystemFile.tokens else { throw DesignSystemError.invalidFile(path) }
            switch value {
            case .null: removals.insert(path)
            case .string(let text): writes[path] = Data(text.utf8)
            default: throw DesignSystemError.invalidFile(path)
            }
        }
        for (path, data) in writes where data.count > DesignSystemFile.maxFileBytes {
            throw DesignSystemError.tooLarge(path)
        }
        let stylesheet = folder.appendingPathComponent(DesignSystemFile.stylesheet)
        if let tokens, writes[DesignSystemFile.stylesheet] == nil, !removals.contains(DesignSystemFile.stylesheet) {
            let current = try? Data(contentsOf: stylesheet)
            if current == nil || Self.isGenerated(current) {
                writes[DesignSystemFile.stylesheet] = Data(tokens.css().utf8)
            } else {
                notes.append("tokens.css is the one you wrote, so it was left as it is; keep it in step with tokens.json")
            }
        }

        // The folder after the write stays within its limits.
        var existing = exists ? filesOnQueue(folder) : [:]
        for path in removals { existing[path] = nil }
        for (path, data) in writes { existing[path] = data }
        guard existing.count <= DesignSystemFile.maxFiles else { throw DesignSystemError.tooManyFiles }
        guard existing.values.reduce(0, { $0 + $1.count }) <= DesignSystemFile.maxTotalBytes else {
            throw DesignSystemError.tooLarge("the system")
        }

        // Sources are read from the project, never written: a missing one is said, not refused.
        var sources = info.sources
        var synced = false
        if let listed = write.sources {
            for source in listed where !DesignSystemFile.isSourcePath(source) { throw DesignSystemError.invalidSource(source) }
            var seen = Set<String>()
            sources = listed.filter { seen.insert($0).inserted }
            if let sourceRoot {
                for source in sources where Self.readSource(source, root: sourceRoot) == nil {
                    notes.append("\(source) is not a stylesheet in the project; Re-sync skips it until it is there")
                }
                synced = true
            }
        }

        // Write only what differs.
        var changed = false
        if !exists {
            do { try manager.createDirectory(at: folder, withIntermediateDirectories: true) } catch {
                throw DesignSystemError.io("could not create \(namespace): \(error.localizedDescription)")
            }
        }
        for (path, data) in writes.sorted(by: { $0.key < $1.key }) {
            let url = folder.appendingPathComponent(path)
            guard (try? Data(contentsOf: url)) != data else { continue }
            guard Self.isInside(Self.deepestExisting(url.deletingLastPathComponent()), folder) else {
                throw DesignSystemError.invalidFile(path)
            }
            do { try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) } catch {
                throw DesignSystemError.io("could not write \(path): \(error.localizedDescription)")
            }
            try Self.writeFile(data, to: url)
            changed = true
        }
        for path in removals.sorted() {
            let url = folder.appendingPathComponent(path)
            guard manager.fileExists(atPath: url.path), Self.isInside(url.deletingLastPathComponent(), folder) else { continue }
            try? manager.removeItem(at: url)
            changed = true
        }
        let title = write.title?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            ?? tokens?.name?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? info.title
        let described = info.title != String(title.prefix(120)) || info.sources != sources || (spaceID != nil && info.spaceID != spaceID)
        info.title = String(title.prefix(120))
        info.sources = sources
        if let spaceID { info.spaceID = spaceID }
        if changed || described || !exists {
            info.revision += 1
            info.updatedAt = now
        }
        if synced { info.syncedAt = now }
        if changed || described || synced || !exists { try saveInfo(info) }
        return (try summaryOnQueue(namespace), changed || described || !exists, notes)
    }

    private func loadOnQueue(_ namespace: String) throws -> (DesignSystemSummary, [String: Data]) {
        if let builtIn = builtIns[namespace] { return (Self.summary(builtIn), builtIn.files) }
        let folder = try ownFolder(namespace)
        let summary = try summaryOnQueue(namespace)
        return (summary, filesOnQueue(folder))
    }

    private func summaryOnQueue(_ namespace: String) throws -> DesignSystemSummary {
        if let builtIn = builtIns[namespace] { return Self.summary(builtIn) }
        let folder = try ownFolder(namespace)
        let info = try infoOnQueue(namespace)
        let tokens = (try? Data(contentsOf: folder.appendingPathComponent(DesignSystemFile.tokens))).map { try? DesignSystemTokens.decode($0) }
        return DesignSystemSummary(info: info, counts: tokens??.counts ?? DesignSystemCounts(), unreadable: tokens??.counts == nil)
    }

    private static func summary(_ builtIn: BuiltIn) -> DesignSystemSummary {
        let tokens = builtIn.files[DesignSystemFile.tokens].flatMap { try? DesignSystemTokens.decode($0) }
        return DesignSystemSummary(info: builtIn.info, builtIn: true, counts: tokens?.counts ?? DesignSystemCounts(),
                                   unreadable: tokens == nil)
    }

    /// system.json; a folder without one (made by hand) reads as nobody's.
    private func infoOnQueue(_ namespace: String) throws -> DesignSystemInfo {
        let folder = try ownFolder(namespace)
        guard FileManager.default.fileExists(atPath: folder.path) else { throw DesignSystemError.noSuchSystem(namespace) }
        let url = folder.appendingPathComponent(DesignSystemFile.info)
        guard let data = try? Data(contentsOf: url), let info = try? JSONDecoder().decode(DesignSystemInfo.self, from: data),
              info.namespace == namespace else {
            return DesignSystemInfo(namespace: namespace, title: namespace, createdAt: 0)
        }
        return info
    }

    private func saveInfo(_ info: DesignSystemInfo) throws {
        let folder = try ownFolder(info.namespace)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data: Data
        do { data = try encoder.encode(info) } catch { throw DesignSystemError.io("could not encode system.json") }
        try Self.writeFile(data, to: folder.appendingPathComponent(DesignSystemFile.info))
    }

    /// Every file of a system's folder by path: regular files inside it (links are not
    /// followed), by the file grammar, `system.json` left out.
    private func filesOnQueue(_ folder: URL) -> [String: Data] {
        var files: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path + "/"
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey]
        let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles])
        while let url = walker?.nextObject() as? URL, files.count <= DesignSystemFile.maxFiles {
            let resolved = url.resolvingSymlinksInPath().path
            guard resolved.hasPrefix(root) else { continue }
            let relative = String(resolved.dropFirst(root.count))
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true, values?.isSymbolicLink != true, DesignSystemFile.isPath(relative),
                  let data = try? Data(contentsOf: url) else { continue }
            files[relative] = data
        }
        return files
    }

    /// A stylesheet's custom properties, read from inside `root` only (links resolved first); nil
    /// when it isn't there or can't be read.
    static func readSource(_ source: String, root: URL) -> [DesignCSSDeclaration]? {
        guard DesignSystemFile.isSourcePath(source) else { return nil }
        let url = root.appendingPathComponent(source)
        guard isInside(url, root),
              let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true, (values.fileSize ?? 0) <= maxSourceBytes,
              let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        return DesignSystemCSS.declarations(text, file: source)
    }

    static func isGenerated(_ data: Data?) -> Bool {
        guard let data else { return false }
        return String(decoding: data.prefix(80), as: UTF8.self).hasPrefix(DesignSystemTokens.generatedMarker)
    }

    private static func writeFile(_ data: Data, to url: URL) throws {
        do { try data.write(to: url, options: .atomic) } catch {
            throw DesignSystemError.io("could not write \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Whether `url`, with its links resolved, is `folder` or inside it.
    static func isInside(_ url: URL, _ folder: URL) -> Bool {
        (url.resolvingSymlinksInPath().path + "/").hasPrefix(folder.resolvingSymlinksInPath().path + "/")
    }

    private static func deepestExisting(_ folder: URL) -> URL {
        var url = folder
        while !FileManager.default.fileExists(atPath: url.path), url.pathComponents.count > 1 {
            url = url.deletingLastPathComponent()
        }
        return url
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
