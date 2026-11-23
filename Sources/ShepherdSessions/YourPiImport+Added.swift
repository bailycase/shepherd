import Darwin
import Foundation

/// Extensions the person adds in Shepherd itself (Settings ▸ Models ▸ Extensions), from a file, a
/// folder or a Git repository, beside those copied from their own pi. Each is copied into
/// `your-extensions/added/` and switched on, so it loads like any copied extension: by its absolute
/// path in the home's settings.json `extensions`, synced across a fleet, and left out of launches
/// with pi's reason when it fails to load. A provider one registers shows up in Sign-in.
extension YourPiImport {
    /// Where an added extension's copy lives, relative to the home.
    public static let addedFolder = YourPiExtensionsFolder.name + "/added"

    /// Whether the copy at `destination` was added in Shepherd rather than copied from the user's pi.
    public static func isAdded(_ destination: String) -> Bool {
        destination.hasPrefix(addedFolder + "/")
    }

    /// Adds the extension at `source`: a `.ts`/`.js` file, or a folder pi loads (a package.json
    /// `pi.extensions`, an `index.ts`/`index.js`, an `extensions/` folder, or top-level `.ts`/`.js`
    /// files). Adding the same source again replaces its copy. Returns the copy, switched on.
    @discardableResult
    public func addExtension(from source: URL) throws -> YourPiCopy {
        try add(source.standardizedFileURL, label: source.standardizedFileURL.path, name: nil)
    }

    /// Clones `url` (https, ssh, `git@host:owner/repo`, or file) with the Mac's git and no prompt,
    /// then adds what it holds as `addExtension(from:)` does, without its `.git`. Adding the same URL
    /// again takes its newest commit. Nothing is installed: npm dependencies must come with the code.
    @discardableResult
    public func addExtension(git url: String) throws -> YourPiCopy {
        let url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isGitURL(url) else {
            throw YourPiFileError("That isn't a Git repository URL. Use an https://, ssh:// or git@host:owner/repo address.")
        }
        let staging = home.directory.appendingPathComponent(".shepherd-staging/\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: staging)
            rmdir(staging.deletingLastPathComponent().path)
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let checkout = staging.appendingPathComponent("repository", isDirectory: true)
        do {
            try SkillsGit.run(["clone", "--quiet", "--depth", "1", "--single-branch", "--no-tags", "--", url, checkout.path],
                              in: nil, timeout: SkillsGit.networkTimeout)
        } catch {
            throw YourPiFileError("Shepherd couldn't clone \(YourPiFiles.withoutCredentials(url)): \(error)")
        }
        var name = url.split(whereSeparator: { $0 == "/" || $0 == ":" }).last.map(String.init) ?? "extension"
        if name.hasSuffix(".git") { name.removeLast(4) }
        return try add(checkout, label: YourPiFiles.withoutCredentials(url), name: name)
    }

    /// Removes an extension's copy and its switch, added or copied from the user's pi. New agents
    /// start without it; running ones keep it until `/reload`.
    public func removeExtension(_ destination: String) throws {
        try updateState { state in
            guard state.copies.contains(where: { $0.kind == .extensions && $0.destination == destination }),
                  destination.hasPrefix(YourPiExtensionsFolder.name + "/") else {
                throw YourPiFileError("Shepherd has no copy of that extension.")
            }
            state.copies.removeAll { $0.kind == .extensions && $0.destination == destination }
            state.extensionsOn.removeAll { $0 == destination }
            state.extensionsHeld.removeAll { $0 == destination }
            state.extensionFailures[destination] = nil
            // Out of settings.json before its files go, so no launch reads half of it.
            try applyExtensions(&state)
            let files = home.directory.appendingPathComponent(destination)
            if FileManager.default.fileExists(atPath: files.path) { try FileManager.default.removeItem(at: files) }
        }
        log("removed the extension \(destination)")
    }

    // MARK: Private

    private func add(_ source: URL, label: String, name: String?) throws -> YourPiCopy {
        var info = stat()
        guard stat(source.path, &info) == 0 else { throw YourPiFileError("\(source.lastPathComponent) isn't there.") }
        let folder = (info.st_mode & S_IFMT) == S_IFDIR
        let entries: [String]
        var copyName: String
        if folder {
            entries = YourPiResources.packageExtensionEntries(source).nonEmpty
                ?? YourPiResources.extensionEntries(source, discovering: true) ?? []
            guard !entries.isEmpty else {
                throw YourPiFileError("\(name ?? source.lastPathComponent) has no extension pi can load: no package.json `pi.extensions`, "
                    + "index.ts or index.js, extensions folder, or .ts or .js file.")
            }
            let manifest = (try? YourPiFiles.read(source.appendingPathComponent("package.json"))).flatMap { $0 }
                .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            copyName = (manifest?["name"] as? String) ?? name ?? source.lastPathComponent
            let missing = Self.missingDependencies(source, manifest: manifest)
            guard missing.isEmpty else {
                throw YourPiFileError("\(copyName) needs npm packages Shepherd doesn't install: \(missing.joined(separator: ", ")). "
                    + "Use a build of it that bundles them, or one with its node_modules included.")
            }
        } else {
            guard source.pathExtension == "ts" || source.pathExtension == "js" else {
                throw YourPiFileError("An extension file is a .ts or .js file.")
            }
            entries = [""]
            copyName = source.deletingPathExtension().lastPathComponent
        }
        let folderName = YourPiResources.safePath(copyName).replacingOccurrences(of: "/", with: "-")
        guard !folderName.isEmpty else { throw YourPiFileError("That extension has no usable name.") }
        let destination = "\(Self.addedFolder)/\(folderName)\(folder ? "" : "." + source.pathExtension)"
        if let other = state()?.copies.first(where: { $0.destination == destination }), other.source != label {
            throw YourPiFileError("An extension named \(copyName) is already added, from \(other.source). Remove it first.")
        }
        let copy = YourPiCopy(kind: .extensions, name: copyName, source: label, destination: destination, entries: entries)
        try Self.filesLock.withLock {
            let staging = home.directory.appendingPathComponent(".shepherd-staging/\(UUID().uuidString)", isDirectory: true)
            defer {
                try? FileManager.default.removeItem(at: staging)
                rmdir(staging.deletingLastPathComponent().path)
            }
            do {
                try YourPiTree.copy(source, to: home.directory.appendingPathComponent(destination), staging: staging,
                                    limits: YourPiTree.extensionLimits)
            } catch {
                throw YourPiFileError("\(copyName) wasn't added: \(error).")
            }
        }
        try updateState { state in
            if let index = state.copies.firstIndex(where: { $0.destination == destination }) {
                state.copies[index] = copy
            } else {
                state.copies.append(copy)
            }
            if !state.extensionsOn.contains(destination) { state.extensionsOn.append(destination) }
            state.extensionFailures[destination] = nil
            try applyExtensions(&state)
        }
        log("added the extension \(copyName) from \(label)")
        return copy
    }

    /// The `dependencies` a folder's package.json names that neither pi provides nor its own
    /// `node_modules` holds: what would fail to load, since Shepherd runs no npm.
    static func missingDependencies(_ folder: URL, manifest: [String: Any]?) -> [String] {
        ((manifest?["dependencies"] as? [String: Any]) ?? [:]).keys.sorted().filter { name in
            !YourPiResources.providedByPi(name)
                && !FileManager.default.fileExists(atPath: folder.appendingPathComponent("node_modules/\(name)/package.json").path)
        }
    }

    /// An address git clones over the network or from a local repository, never an option.
    static func isGitURL(_ url: String) -> Bool {
        guard !url.isEmpty, !url.hasPrefix("-"), !url.contains(where: \.isWhitespace) else { return false }
        if let scheme = url.range(of: "://") {
            return ["https", "http", "ssh", "git", "file"].contains(url[..<scheme.lowerBound].lowercased())
        }
        // scp-like: user@host:path
        return url.range(of: #"^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+:[^/].*"#, options: .regularExpression) != nil
    }
}

private extension Array {
    var nonEmpty: Self? { isEmpty ? nil : self }
}
