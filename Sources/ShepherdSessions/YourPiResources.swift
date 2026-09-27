import Darwin
import Foundation

/// A kind of file the user's pi reads that Shepherd copies into its own home: after the copy,
/// Shepherd's pi reads each only there (docs/pi-home.md › Imports).
public enum YourPiResourceKind: String, Codable, CaseIterable, Sendable {
    /// The global context file pi picks (`AGENTS.override.md`, `AGENTS.md`, … `CLAUDE.md`), and
    /// `SYSTEM.md` and `APPEND_SYSTEM.md`.
    case instructions
    case skills
    case prompts
    case themes
    /// Code: copied, and switched off until the user opts each one in.
    case extensions
}

/// One thing of the user's pi, copied or to be copied into Shepherd's home: what pi calls it,
/// where it came from, and where its copy lives.
public struct YourPiCopy: Codable, Equatable, Hashable, Sendable, Identifiable {
    public var kind: YourPiResourceKind
    /// What pi calls it: the file's name for instructions ("AGENTS.md"), the skill's folder, the
    /// prompt's or theme's file name without its extension, the extension's file, folder or package.
    public var name: String
    /// Where it came from, as the user's pi names it: a path, or a package's source.
    public var source: String
    /// Its copy, relative to Shepherd's home ("skills/pdf", "your-extensions/npm/node_modules/x").
    public var destination: String
    /// An extension's files pi loads, relative to `destination` ("" is `destination` itself).
    public var entries: [String]?

    public init(kind: YourPiResourceKind, name: String, source: String, destination: String, entries: [String]? = nil) {
        self.kind = kind
        self.name = name
        self.source = source
        self.destination = destination
        self.entries = entries
    }

    public var id: String { destination }
}

/// Where Shepherd keeps the user's extensions in its home: a folder pi never discovers on its
/// own (its own is `extensions/`), so a copy loads only once it is switched on, by its absolute
/// path in the home's settings.json `extensions`.
public enum YourPiExtensionsFolder {
    public static let name = "your-extensions"
}

/// What the user's pi reads, found as pi finds it, and copied as plain files (`YourPiTree`).
/// Nothing here runs pi's code or writes the user's folders.
enum YourPiResources {
    /// One thing found, and where its copy goes.
    struct Found: Equatable {
        var copy: YourPiCopy
        /// The file or folder to copy (a link followed).
        var source: URL
        /// A single-file skill (`name.md`), copied as `<destination>/SKILL.md` so every skill in
        /// Shepherd's home is a folder.
        var singleFileSkill = false
        /// Folders copied beside it: an npm package's dependencies, hoisted beside it by npm.
        var companions: [Companion] = []
        /// How much of it may be copied.
        var limits: YourPiTree.Limits
    }

    struct Companion: Equatable {
        var source: URL
        var destination: String
    }

    /// What was found of one kind, in pi's order, and what was passed over (one sentence each).
    struct Listing: Equatable {
        var found: [Found] = []
        var skipped: [String] = []
    }

    // MARK: Finding them

    /// Everything of `kind` in the user's pi at `agentDirectory`, whose settings are `settings`;
    /// `userHome` is their home folder (`~`, and `~/.agents/skills`).
    static func find(_ kind: YourPiResourceKind, agentDirectory: URL, settings: [String: Any]?, userHome: String) -> Listing {
        switch kind {
        case .instructions: instructions(in: agentDirectory)
        case .skills: skills(agentDirectory: agentDirectory, settings: settings, userHome: userHome)
        case .prompts: files(.prompts, suffix: ".md", agentDirectory: agentDirectory, settings: settings, userHome: userHome)
        case .themes: files(.themes, suffix: ".json", agentDirectory: agentDirectory, settings: settings, userHome: userHome)
        case .extensions: extensions(agentDirectory: agentDirectory, settings: settings, userHome: userHome)
        }
    }

    /// The global context file pi would pick, then `SYSTEM.md` and `APPEND_SYSTEM.md`.
    static func instructions(in agentDirectory: URL) -> Listing {
        var listing = Listing()
        var files: [URL] = []
        if let context = YourPiFiles.contextFile(in: agentDirectory) { files.append(context) }
        for name in ["SYSTEM.md", "APPEND_SYSTEM.md"] {
            let url = agentDirectory.appendingPathComponent(name)
            if isFile(url.path) { files.append(url) }
        }
        for file in files {
            let name = file.lastPathComponent
            listing.found.append(Found(copy: YourPiCopy(kind: .instructions, name: name, source: file.path, destination: name),
                                       source: file, limits: YourPiTree.fileLimits))
        }
        return listing
    }

    /// Skills, in pi's order: their pi's `skills/`, the `skills` paths in its settings, the skills
    /// of the packages it lists, then `~/.agents/skills` (which Shepherd's pi no longer reads).
    /// A skill whose folder name is taken by one before it is passed over, as pi passes over the
    /// later of two skills of one name.
    static func skills(agentDirectory: URL, settings: [String: Any]?, userHome: String) -> Listing {
        var roots: [(URL, agents: Bool)] = [(agentDirectory.appendingPathComponent("skills", isDirectory: true), false)]
        let entries = settingsEntries("skills", settings: settings, agentDirectory: agentDirectory, userHome: userHome)
        roots += entries.paths.map { ($0, false) }
        for package in packages(settings: settings, agentDirectory: agentDirectory, userHome: userHome) {
            if let directory = package.directory {
                roots += packageResources(.skills, in: directory).map { ($0, false) }
            }
        }
        roots.append((URL(fileURLWithPath: userHome, isDirectory: true).appendingPathComponent(".agents/skills", isDirectory: true), true))

        var listing = Listing()
        var taken: [String: String] = [:]
        for (root, agents) in roots {
            for skill in skillsIn(root, agentsMode: agents) where !entries.filters.excludes(skill.url, name: skill.name) {
                let folder = safeName(skill.name)
                guard !folder.isEmpty else { continue }
                if let first = taken[folder] {
                    listing.skipped.append("The skill \(folder) from \(skill.url.path) wasn't copied: \(first) has the same name.")
                    continue
                }
                taken[folder] = skill.url.path
                listing.found.append(Found(copy: YourPiCopy(kind: .skills, name: folder, source: skill.url.path, destination: "skills/\(folder)"),
                                           source: skill.url, singleFileSkill: skill.singleFile, limits: YourPiTree.skillLimits))
            }
        }
        return listing
    }

    /// Prompt templates (`.md`) or themes (`.json`): their pi's own folder's top level, the paths
    /// in its settings (a folder's files at any depth, as pi reads them), then the packages'.
    static func files(_ kind: YourPiResourceKind, suffix: String, agentDirectory: URL, settings: [String: Any]?, userHome: String) -> Listing {
        let key = kind.rawValue
        var candidates: [URL] = topLevelFiles(agentDirectory.appendingPathComponent(key, isDirectory: true), suffix: suffix)
        let entries = settingsEntries(key, settings: settings, agentDirectory: agentDirectory, userHome: userHome)
        for path in entries.paths {
            candidates += isFile(path.path) ? (path.path.hasSuffix(suffix) ? [path] : []) : filesBelow(path, suffix: suffix)
        }
        for package in packages(settings: settings, agentDirectory: agentDirectory, userHome: userHome) {
            guard let directory = package.directory else { continue }
            for path in packageResources(kind, in: directory) {
                candidates += isFile(path.path) ? [path] : filesBelow(path, suffix: suffix)
            }
        }
        var listing = Listing()
        var taken: [String: String] = [:]
        let noun = kind == .prompts ? "prompt" : "theme"
        for file in candidates where !entries.filters.excludes(file, name: file.deletingPathExtension().lastPathComponent) {
            let name = file.lastPathComponent
            if let first = taken[name] {
                if first != file.path { listing.skipped.append("The \(noun) \(name) from \(file.path) wasn't copied: \(first) has the same name.") }
                continue
            }
            taken[name] = file.path
            listing.found.append(Found(copy: YourPiCopy(kind: kind, name: file.deletingPathExtension().lastPathComponent, source: file.path,
                                                        destination: "\(key)/\(name)"),
                                       source: file, limits: YourPiTree.fileLimits))
        }
        return listing
    }

    /// Extensions: the files and folders in their pi's `extensions/`, the `extensions` paths in
    /// its settings, and the packages its settings list, copied into `your-extensions/`. An npm
    /// package brings the dependencies npm hoisted beside it, so it loads from its copy as it did.
    static func extensions(agentDirectory: URL, settings: [String: Any]?, userHome: String) -> Listing {
        var listing = Listing()
        var seen: Set<String> = []
        let root = YourPiExtensionsFolder.name
        func add(_ name: String, source: URL, label: String, destination: String, entries: [String], companions: [Companion] = []) {
            guard seen.insert(destination).inserted else { return }
            listing.found.append(Found(copy: YourPiCopy(kind: .extensions, name: name, source: label, destination: destination, entries: entries),
                                       source: source, companions: companions, limits: YourPiTree.extensionLimits))
        }
        let folder = agentDirectory.appendingPathComponent("extensions", isDirectory: true)
        for name in children(folder) {
            let url = folder.appendingPathComponent(name)
            if isFile(url.path) {
                guard name.hasSuffix(".ts") || name.hasSuffix(".js") else { continue }
                add((name as NSString).deletingPathExtension, source: url, label: url.path, destination: "\(root)/files/\(safeName(name))", entries: [""])
            } else if let entries = extensionEntries(url), !entries.isEmpty {
                add(name, source: url, label: url.path, destination: "\(root)/files/\(safeName(name))", entries: entries)
            }
        }
        let paths = settingsEntries("extensions", settings: settings, agentDirectory: agentDirectory, userHome: userHome)
        for url in paths.paths {
            let name = url.lastPathComponent
            if isFile(url.path) {
                add((name as NSString).deletingPathExtension, source: url, label: url.path, destination: "\(root)/paths/\(safeName(name))", entries: [""])
            } else if let entries = extensionEntries(url, discovering: true), !entries.isEmpty {
                add(name, source: url, label: url.path, destination: "\(root)/paths/\(safeName(name))", entries: entries)
            } else if !FileManager.default.fileExists(atPath: url.path) {
                listing.skipped.append("The extension \(url.path) wasn't copied: it isn't there.")
            }
        }
        for package in packages(settings: settings, agentDirectory: agentDirectory, userHome: userHome) {
            guard let directory = package.directory else {
                listing.skipped.append("The package \(package.label) wasn't copied: your pi hasn't installed it.")
                continue
            }
            let entries = packageExtensionEntries(directory)
            guard !entries.isEmpty else { continue }
            add(package.name, source: directory, label: package.label, destination: "\(root)/\(package.destination)", entries: entries,
                companions: package.npmRoot.map { dependencies(of: directory, npmRoot: $0, destinationRoot: "\(root)/npm/node_modules") } ?? [])
        }
        return listing
    }

    // MARK: Settings entries

    /// A settings list's plain paths (absolute; `~` is the user's home; relative to their pi's
    /// folder, as pi resolves a user entry) and its filters. Glob entries are left out: pi
    /// expands them against the whole tree, which a copy doesn't mirror.
    static func settingsEntries(_ key: String, settings: [String: Any]?, agentDirectory: URL, userHome: String)
        -> (paths: [URL], filters: Filters) {
        var paths: [URL] = []
        var filters = Filters()
        for case let raw as String in settings?[key] as? [Any] ?? [] {
            let entry = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let first = entry.first else { continue }
            switch first {
            case "!": filters.excluded.append(String(entry.dropFirst()))
            case "-": filters.removed.insert(absolute(String(entry.dropFirst()), agentDirectory: agentDirectory, home: userHome))
            case "+": filters.added.insert(absolute(String(entry.dropFirst()), agentDirectory: agentDirectory, home: userHome))
            default:
                // pi reads only local paths here; a glob it expands against the whole tree.
                if entry.contains("*") || entry.contains("?") || entry.contains("://") { continue }
                paths.append(URL(fileURLWithPath: absolute(entry, agentDirectory: agentDirectory, home: userHome)))
            }
        }
        return (paths, filters)
    }

    /// pi's `!pattern`, `-path` and `+path` filters, as near as plain matching gets: a pattern
    /// matches a name or a path (`*` crossing folders), an exact path the file or its folder.
    struct Filters: Equatable {
        var excluded: [String] = []
        var removed: Set<String> = []
        var added: Set<String> = []

        func excludes(_ url: URL, name: String) -> Bool {
            let path = url.standardizedFileURL.path
            let folder = url.deletingLastPathComponent().standardizedFileURL.path
            let isSkill = url.lastPathComponent == "SKILL.md"
            let candidates = [name, url.lastPathComponent, path] + (isSkill ? [folder] : [])
            let exact = [path] + (isSkill ? [folder] : [])
            if exact.contains(where: removed.contains) { return true }
            if exact.contains(where: added.contains) { return false }
            return excluded.contains { pattern in candidates.contains { fnmatch(pattern.replacingOccurrences(of: "**", with: "*"), $0, 0) == 0 } }
        }
    }

    static func absolute(_ path: String, agentDirectory: URL, home: String) -> String {
        YourPiFiles.absolute(path.trimmingCharacters(in: .whitespaces), agentDirectory: agentDirectory, home: home)
    }

    // MARK: Packages

    /// A package the user's pi lists in its settings, and where their pi installed it.
    struct Package: Equatable {
        /// How pi names it ("@acme/tools", "owner/repo", a folder's name).
        var name: String
        /// Its source as their settings give it, without any user or password in a URL.
        var label: String
        var directory: URL?
        /// Its copy's folder under `your-extensions/`.
        var destination: String
        /// The `node_modules` npm installed it in, for its hoisted dependencies.
        var npmRoot: URL?
    }

    /// The packages in the user's settings: `npm:` ones from their pi's `npm/node_modules`, git
    /// ones from its `git/<host>/<path>`, and local folders where they are.
    static func packages(settings: [String: Any]?, agentDirectory: URL, userHome: String) -> [Package] {
        var packages: [Package] = []
        for entry in settings?["packages"] as? [Any] ?? [] {
            let raw = ((entry as? String) ?? ((entry as? [String: Any])?["source"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !raw.isEmpty else { continue }
            let label = YourPiFiles.withoutCredentials(raw)
            if raw.hasPrefix("npm:") {
                var spec = String(raw.dropFirst(4))
                if let at = spec.dropFirst().lastIndex(of: "@") { spec = String(spec[..<at]) }
                let root = agentDirectory.appendingPathComponent("npm/node_modules", isDirectory: true)
                let directory = root.appendingPathComponent(spec, isDirectory: true)
                packages.append(Package(name: spec, label: label, directory: isDirectory(directory.path) ? directory : nil,
                                        destination: "npm/node_modules/\(safePath(spec))", npmRoot: root))
            } else if let repository = gitRepository(raw) {
                let directory = agentDirectory.appendingPathComponent("git/\(repository)", isDirectory: true)
                packages.append(Package(name: repository.split(separator: "/").suffix(2).joined(separator: "/"), label: label,
                                        directory: isDirectory(directory.path) ? directory : nil, destination: "git/\(safePath(repository))"))
            } else if raw.contains("://") || raw.hasPrefix("git:") {
                // A source pi can't have installed under git/: nothing to copy.
                packages.append(Package(name: label, label: label, directory: nil, destination: ""))
            } else {
                let path = absolute(raw, agentDirectory: agentDirectory, home: userHome)
                packages.append(Package(name: (path as NSString).lastPathComponent, label: path,
                                        directory: isDirectory(path) ? URL(fileURLWithPath: path, isDirectory: true) : nil,
                                        destination: "packages/\(safeName((path as NSString).lastPathComponent))"))
            }
        }
        return packages
    }

    /// `host/owner/repo` for a git source pi installs under `git/` (`git:github.com/o/r@v1`,
    /// `https://github.com/o/r.git`, `git@github.com:o/r`); nil for anything else.
    static func gitRepository(_ source: String) -> String? {
        var rest: String
        if source.hasPrefix("git:") {
            rest = String(source.dropFirst(4))
        } else if let scheme = source.range(of: "://"), ["https", "http", "ssh", "git"].contains(String(source[..<scheme.lowerBound])) {
            rest = String(source[scheme.upperBound...])
            if let at = rest.firstIndex(of: "@"), let slash = rest.firstIndex(of: "/"), at < slash { rest = String(rest[rest.index(after: at)...]) }
        } else if source.hasPrefix("git@") {
            rest = String(source.dropFirst(4)).replacingOccurrences(of: ":", with: "/")
        } else {
            return nil
        }
        if let at = rest.lastIndex(of: "@"), let slash = rest.lastIndex(of: "/"), at > slash { rest = String(rest[..<at]) }
        if rest.hasSuffix(".git") { rest.removeLast(4) }
        let parts = rest.split(separator: "/").map(String.init).filter { !$0.isEmpty && $0 != "." && $0 != ".." }
        return parts.count >= 3 ? parts.joined(separator: "/") : nil
    }

    /// A package's own resources of `kind`: its package.json's `pi.<kind>` paths, else its
    /// `<kind>/` folder.
    static func packageResources(_ kind: YourPiResourceKind, in directory: URL) -> [URL] {
        if let manifest = piManifest(directory), let paths = manifest[kind.rawValue] as? [Any] {
            return paths.compactMap { $0 as? String }.map { directory.appendingPathComponent($0).standardizedFileURL }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
        }
        let convention = directory.appendingPathComponent(kind.rawValue, isDirectory: true)
        return isDirectory(convention.path) ? [convention] : []
    }

    /// The files pi loads from a package: its manifest's `pi.extensions`, else its `index.ts` or
    /// `index.js`, else what its `extensions/` folder holds. Relative to the package.
    static func packageExtensionEntries(_ directory: URL) -> [String] {
        if let entries = extensionEntries(directory), !entries.isEmpty { return entries }
        let convention = directory.appendingPathComponent("extensions", isDirectory: true)
        guard isDirectory(convention.path) else { return [] }
        return (extensionEntries(convention, discovering: true) ?? []).map { $0.isEmpty ? "extensions" : "extensions/\($0)" }
    }

    /// The files pi loads from an extension folder, relative to it: its package.json's
    /// `pi.extensions`, else `index.ts`, else `index.js`. With `discovering`, a folder with none
    /// of those gives its top-level `.ts`/`.js` files and its subfolders that have one (as pi
    /// reads a folder named in settings). Nil when it has none.
    static func extensionEntries(_ directory: URL, discovering: Bool = false) -> [String]? {
        if let manifest = piManifest(directory), let paths = manifest["extensions"] as? [Any] {
            // An entry that leads out of the package ("../x", "a/../../x") would load a file
            // beside the copy, or outside Shepherd's home: it is left out.
            let root = directory.standardizedFileURL.path
            let entries = paths.compactMap { $0 as? String }.filter { !$0.isEmpty }
                .map { (($0 as NSString).standardizingPath as String) }
                .filter { entry in
                    let resolved = directory.appendingPathComponent(entry).standardizedFileURL.path
                    return PiHome.isInside(resolved, root) && resolved != root && FileManager.default.fileExists(atPath: resolved)
                }
                .map { String(directory.appendingPathComponent($0).standardizedFileURL.path.dropFirst(root.count + 1)) }
            var seen: Set<String> = []
            let unique = entries.filter { seen.insert($0).inserted }
            if !unique.isEmpty { return unique }
        }
        for index in ["index.ts", "index.js"] where isFile(directory.appendingPathComponent(index).path) { return [index] }
        guard discovering else { return nil }
        var entries: [String] = []
        for name in children(directory) {
            let url = directory.appendingPathComponent(name)
            if isFile(url.path) {
                if name.hasSuffix(".ts") || name.hasSuffix(".js") { entries.append(name) }
            } else if let inner = extensionEntries(url) {
                entries += inner.map { "\(name)/\($0)" }
            }
        }
        return entries.isEmpty ? nil : entries
    }

    static func piManifest(_ directory: URL) -> [String: Any]? {
        guard let data = try? YourPiFiles.read(directory.appendingPathComponent("package.json")),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["pi"] as? [String: Any]
    }

    /// The dependencies npm hoisted beside `package` into `npmRoot`, and theirs, each once: those
    /// in the package's own `node_modules` come with it. Where a copy goes mirrors `npmRoot`.
    static func dependencies(of package: URL, npmRoot: URL, destinationRoot: String) -> [Companion] {
        var found: [Companion] = []
        var seen: Set<String> = []
        var queue = [package]
        while !queue.isEmpty {
            let current = queue.removeFirst()
            guard let data = try? YourPiFiles.read(current.appendingPathComponent("package.json")),
                  let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }
            var names: [String] = []
            for key in ["dependencies", "optionalDependencies", "peerDependencies"] {
                names += ((manifest[key] as? [String: Any]) ?? [:]).keys.sorted()
            }
            for name in names where !name.isEmpty && !name.contains("..") && !providedByPi(name) {
                // Node looks in the package's own node_modules first, then up the tree.
                if isDirectory(current.appendingPathComponent("node_modules/\(name)").path) { continue }
                let hoisted = npmRoot.appendingPathComponent(name, isDirectory: true)
                guard isDirectory(hoisted.path), seen.insert(name).inserted,
                      hoisted.standardizedFileURL != package.standardizedFileURL else { continue }
                found.append(Companion(source: hoisted, destination: "\(destinationRoot)/\(safePath(name))"))
                queue.append(hoisted)
            }
        }
        return found
    }

    /// Packages pi hands every extension itself (pi: core/extensions/loader.js, its aliases), so
    /// a copy of theirs would never load: an extension's peer dependency on pi is left behind,
    /// with everything npm installed for it.
    static func providedByPi(_ name: String) -> Bool {
        ["@earendil-works/pi-", "@mariozechner/pi-"].contains { name.hasPrefix($0) }
            || ["typebox", "@sinclair/typebox"].contains(name)
    }

    // MARK: Skills in a folder

    /// The skills under `root`, as pi finds them: `root` itself when it holds a SKILL.md (or is
    /// one `.md` file); else, in pi's own folders, each top-level `.md` file (never in
    /// `~/.agents/skills`), and each folder below holding a SKILL.md, which isn't searched further.
    static func skillsIn(_ root: URL, agentsMode: Bool) -> [(name: String, url: URL, singleFile: Bool)] {
        if isFile(root.path) {
            guard root.pathExtension == "md" else { return [] }
            return root.lastPathComponent == "SKILL.md"
                ? [(root.deletingLastPathComponent().lastPathComponent, root.deletingLastPathComponent(), false)]
                : [(root.deletingPathExtension().lastPathComponent, root, true)]
        }
        guard isDirectory(root.path) else { return [] }
        if isFile(root.appendingPathComponent("SKILL.md").path) { return [(root.lastPathComponent, root, false)] }
        var found: [(String, URL, Bool)] = []
        if !agentsMode {
            for name in children(root) where name.hasSuffix(".md") && isFile(root.appendingPathComponent(name).path) {
                found.append(((name as NSString).deletingPathExtension, root.appendingPathComponent(name), true))
            }
        }
        var walk = Walk(root)
        func search(_ folder: URL, depth: Int) {
            guard walk.enter(folder) else { return }
            if isFile(folder.appendingPathComponent("SKILL.md").path) { found.append((folder.lastPathComponent, folder, false)); return }
            guard depth < 8 else { return }
            for name in children(folder) where isDirectory(folder.appendingPathComponent(name).path) {
                search(folder.appendingPathComponent(name, isDirectory: true), depth: depth + 1)
            }
        }
        for name in children(root) where isDirectory(root.appendingPathComponent(name).path) {
            search(root.appendingPathComponent(name, isDirectory: true), depth: 1)
        }
        return found
    }

    /// Folders walked below one root: a link back up to the root or above it (a skill linked to
    /// `/` or to the home folder) is never entered, and the walk stops after `budget` folders, so
    /// a link to a big tree can't hold the first launch or read the whole disk. (A link that
    /// loops below the root ends at the depth limit.)
    struct Walk {
        static let budget = 10_000
        private let root: String
        private(set) var entered = 0

        init(_ root: URL) {
            self.root = PiHome.canonical(root.path)
        }

        mutating func enter(_ folder: URL) -> Bool {
            guard entered < Self.budget, !PiHome.isInside(root, PiHome.canonical(folder.path)) else { return false }
            entered += 1
            return true
        }
    }

    // MARK: Files

    static func topLevelFiles(_ folder: URL, suffix: String) -> [URL] {
        children(folder).map { folder.appendingPathComponent($0) }.filter { $0.lastPathComponent.hasSuffix(suffix) && isFile($0.path) }
    }

    /// Files ending in `suffix` below `folder`, at any depth, as pi reads a folder named in its
    /// settings (hidden entries and `node_modules` left out).
    static func filesBelow(_ folder: URL, suffix: String) -> [URL] {
        var walk = Walk(folder)
        var found: [URL] = []
        func search(_ folder: URL, depth: Int) {
            for name in children(folder) {
                let url = folder.appendingPathComponent(name)
                if isDirectory(url.path) {
                    if depth < 8, walk.enter(url) { search(url, depth: depth + 1) }
                } else if name.hasSuffix(suffix), isFile(url.path) {
                    found.append(url)
                }
            }
        }
        search(folder, depth: 1)
        return found
    }

    /// A folder's visible entries, sorted; none when it isn't one.
    static func children(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
            .filter { !$0.hasPrefix(".") && $0 != "node_modules" }.sorted()
    }

    /// A regular file, or a link to one.
    static func isFile(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
    }

    static func isDirectory(_ path: String) -> Bool {
        var info = stat()
        return stat(path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFDIR
    }

    /// One path component as a folder or file name in the home: no separators, never hidden.
    static func safeName(_ name: String) -> String {
        var cleaned = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "\0", with: "")
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        return cleaned
    }

    /// A relative path of safe components (`@scope/name`, `host/owner/repo`).
    static func safePath(_ path: String) -> String {
        path.split(separator: "/").map { safeName(String($0)) }.filter { !$0.isEmpty }.joined(separator: "/")
    }
}

/// Copies a file or a folder of the user's pi into Shepherd's home as plain, private files: a
/// link is followed and its target's bytes copied (a link that leads nowhere, or back up its own
/// folder, is left out), so the copy holds no link to anything of theirs; FIFOs, sockets and
/// devices are never opened, and `.git` folders are left out. A copy lands whole or not at all:
/// it is written beside the home's staging folder, then renamed into place.
enum YourPiTree {
    struct Limits: Equatable, Sendable {
        var bytes: Int
        var files: Int
    }

    /// A skill: its instructions and whatever scripts it carries.
    static let skillLimits = Limits(bytes: 64 << 20, files: 5_000)
    /// One instructions, prompt or theme file.
    static let fileLimits = Limits(bytes: YourPiFiles.maxBytes, files: 1)
    /// An extension, with its `node_modules`.
    static let extensionLimits = Limits(bytes: 512 << 20, files: 100_000)

    struct Result: Equatable {
        var files = 0
        var folders = 0
        var bytes = 0
        /// Paths inside it that were left out (a broken link, a loop, a FIFO), relative.
        var leftOut: [String] = []
    }

    /// Copies `source` to `destination` (replacing what is there once the copy is whole), with
    /// `staging` (inside the home) for the copy under way. A single file is written as
    /// `fileName` inside `destination` when that is set (a single-file skill's `SKILL.md`).
    @discardableResult
    static func copy(_ source: URL, to destination: URL, staging: URL, limits: Limits, fileName: String? = nil) throws -> Result {
        let files = FileManager.default
        try files.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temporary = staging.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: temporary) }
        var result = Result()
        var info = stat()
        guard stat(source.path, &info) == 0 else { throw YourPiFileError("\(source.lastPathComponent) isn't there") }
        if let fileName {
            try files.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o755])
            try copyFile(source.path, to: temporary.appendingPathComponent(fileName).path, limits: limits, result: &result)
        } else if (info.st_mode & S_IFMT) == S_IFDIR {
            try copyFolder(source.path, to: temporary.path, relative: "", ancestors: [Identity(info)], root: PiHome.canonical(source.path),
                           limits: limits, result: &result)
        } else {
            try copyFile(source.path, to: temporary.path, limits: limits, result: &result)
        }
        try files.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try place(temporary, at: destination, staging: staging)
        return result
    }

    /// Moves `new` to `destination`, replacing what is there only once `new` is in place.
    static func place(_ new: URL, at destination: URL, staging: URL) throws {
        let files = FileManager.default
        var info = stat()
        if lstat(destination.path, &info) == 0 {
            let old = staging.appendingPathComponent("old-\(UUID().uuidString)")
            guard rename(destination.path, old.path) == 0 else {
                throw YourPiFileError("Shepherd couldn't replace \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
            }
            defer { try? files.removeItem(at: old) }
            guard rename(new.path, destination.path) == 0 else {
                let reason = String(cString: strerror(errno))
                _ = rename(old.path, destination.path)
                throw YourPiFileError("Shepherd couldn't write \(destination.lastPathComponent): \(reason)")
            }
        } else if rename(new.path, destination.path) != 0 {
            throw YourPiFileError("Shepherd couldn't write \(destination.lastPathComponent): \(String(cString: strerror(errno)))")
        }
    }

    private struct Identity: Hashable {
        let device: Int32
        let inode: UInt64
        init(_ info: stat) {
            device = info.st_dev
            inode = info.st_ino
        }
    }

    private static func copyFolder(_ source: String, to destination: String, relative: String, ancestors: Set<Identity>, root: String,
                                   limits: Limits, result: inout Result) throws {
        result.folders += 1
        // As many folders as files: a tree of empty folders is as big a copy.
        guard result.folders <= limits.files else { throw YourPiFileError("it has more than \(limits.files) folders") }
        guard mkdir(destination, 0o755) == 0 else { throw YourPiFileError("Shepherd couldn't copy \(relative.isEmpty ? "a folder" : relative)") }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: source).sorted() } catch {
            throw YourPiFileError("\((source as NSString).lastPathComponent) couldn't be read")
        }
        for name in names where name != ".git" {
            let path = source + "/" + name
            let inner = relative.isEmpty ? name : relative + "/" + name
            var info = stat()
            // A link is followed; one that leads nowhere is left out.
            guard stat(path, &info) == 0 else { result.leftOut.append(inner); continue }
            switch info.st_mode & S_IFMT {
            case S_IFDIR:
                let identity = Identity(info)
                // A link back up its own folder would copy forever, and one to a folder above the
                // copy (`/`, the home folder) would copy the disk.
                var link = stat()
                guard !ancestors.contains(identity),
                      !(lstat(path, &link) == 0 && (link.st_mode & S_IFMT) == S_IFLNK && PiHome.isInside(root, PiHome.canonical(path))) else {
                    result.leftOut.append(inner)
                    continue
                }
                try copyFolder(path, to: destination + "/" + name, relative: inner, ancestors: ancestors.union([identity]), root: root,
                               limits: limits, result: &result)
            case S_IFREG:
                try copyFile(path, to: destination + "/" + name, limits: limits, result: &result)
            default:
                result.leftOut.append(inner)
            }
        }
    }

    /// Copies one file's bytes, opened without blocking and checked on its descriptor, with the
    /// execute bit kept and nothing else of its mode.
    private static func copyFile(_ source: String, to destination: String, limits: Limits, result: inout Result) throws {
        let name = (source as NSString).lastPathComponent
        let input = open(source, O_RDONLY | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw YourPiFileError("\(name) couldn't be read") }
        defer { close(input) }
        var info = stat()
        guard fstat(input, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw YourPiFileError("\(name) isn't a file") }
        result.files += 1
        guard result.files <= limits.files else { throw YourPiFileError("it has more than \(limits.files) files") }
        guard result.bytes + Int(info.st_size) <= limits.bytes else { throw YourPiFileError("it's larger than \(limits.bytes >> 20) MB") }
        let mode: mode_t = info.st_mode & 0o111 != 0 ? 0o755 : 0o644
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, mode)
        guard output >= 0 else { throw YourPiFileError("Shepherd couldn't copy \(name)") }
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 256 << 10)
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(input, $0.baseAddress, $0.count) }
            if count < 0 {
                if errno == EINTR { continue }
                throw YourPiFileError("\(name) couldn't be read")
            }
            if count == 0 { break }
            result.bytes += count
            // It grew after the check.
            guard result.bytes <= limits.bytes else { throw YourPiFileError("it's larger than \(limits.bytes >> 20) MB") }
            var written = 0
            while written < count {
                let wrote = buffer.withUnsafeBytes { Darwin.write(output, $0.baseAddress! + written, count - written) }
                if wrote < 0 {
                    if errno == EINTR { continue }
                    throw YourPiFileError("Shepherd couldn't copy \(name)")
                }
                written += wrote
            }
        }
        fchmod(output, mode)
    }
}
