import Darwin
import Foundation
import CryptoKit
import CoreFoundation

/// Files owned by this Mac's isolated pi home. Parsing uses the runtime's canonical module on
/// bundled Node, without starting pi, loading profile extensions or contacting a provider.
public final class SubagentDefinitionsStore: @unchecked Sendable {
    public struct Definition: Codable, Equatable, Identifiable, Sendable {
        public var file: String
        public var name: String
        public var description: String?
        public var tools: [String]?
        public var context: String?
        public var error: String?
        public var disabled: Bool?
        public var fingerprint: String?
        public var id: String { file }
        public var isDefault: Bool { ["scout.md", "reviewer.md", "planner.md", "worker.md"].contains(file) }
        public var diagnostic: String? { error.map { $0 + ". The profile did not load." } ?? (disabled == true ? "This subagent is disabled." : nil) }
        public var capability: String {
            let readOnly = tools.map { $0.allSatisfy { ["read", "grep", "find", "ls", "shepherd_parent_message"].contains($0) } } ?? false
            return (readOnly ? "read-only" : "can edit") + (context == "fork" ? " · fork" : "")
        }
    }
    public struct File: Equatable, Sendable {
        public var file: String
        public var text: String
        public var fingerprint: String
    }
    public struct Failure: Error, CustomStringConvertible {
        public let description: String
        fileprivate let fingerprint: String?
        init(_ text: String, fingerprint: String? = nil) { description = text; self.fingerprint = fingerprint }
    }

    public let directory: URL
    private let pi: PiSetup
    private let parserSource: String
    private let lock = NSLock()
    private static let limit = 128 * 1024
    private static let marker = ".shepherd-defaults-v1"

    public init(pi: PiSetup, parserSource: String) {
        self.pi = pi
        self.parserSource = parserSource
        directory = pi.home.appendingPathComponent("agents", isDirectory: true)
    }

    public static func acceptsFilename(_ file: String) -> Bool {
        let parts = file.split(separator: "/", omittingEmptySubsequences: false)
        return file.utf8.count <= 240 && file.hasSuffix(".md") && !file.hasSuffix(".chain.md") && !parts.isEmpty && parts.count <= 17 && parts.allSatisfy {
            !$0.isEmpty && !$0.hasPrefix(".") && !$0.contains("\0") && !$0.contains(":")
        } && !parts.dropLast().contains { ["skills", "node_modules"].contains(String($0)) }
    }

    public func snapshot() throws -> [Definition] {
        try lock.withLock { try seed(); return try readSnapshot() }
    }

    private func readSnapshot(adding file: String? = nil) throws -> [Definition] {
            var files: [[String: String]] = [], folders = Set<String>()
            func scan(_ folder: URL, relative: String, depth: Int) throws {
                folders.insert(relative)
                guard folders.count <= 512 else { throw Failure("At most 512 subagent folders can be scanned.") }
                guard depth <= 16 else { throw Failure("Subagent folders can nest at most 16 levels.") }
                for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    let name = url.lastPathComponent
                    if name.hasPrefix(".") || ["skills", "node_modules"].contains(name) { continue }
                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                    if values.isDirectory == true && values.isSymbolicLink != true { try scan(url, relative: relative + name + "/", depth: depth + 1); continue }
                    guard name.hasSuffix(".md"), !name.hasSuffix(".chain.md") else { continue }
                    guard files.count < 512 else { throw Failure("At most 512 subagent files can load.") }
                    let file = relative + name
                    do {
                        let text = try read(file)
                        files.append(["file": file, "text": text ?? "", "fingerprint": fingerprint(text ?? "")])
                    } catch {
                        var row = ["file": file, "error": String(describing: error)]
                        row["fingerprint"] = (error as? Failure)?.fingerprint
                        files.append(row)
                    }
                }
            }
            // Opening the folder no-follow before enumeration also rejects a substituted root.
            try withParent("placeholder.md") { _ , _ in }
            try scan(directory, relative: "", depth: 0)
            if let file {
                var path = ""
                for part in file.split(separator: "/").dropLast() { path += part + "/"; folders.insert(path) }
                guard folders.count <= 512 else { throw Failure("At most 512 subagent folders can be scanned. Choose an existing folder.") }
            }
            return try parse(files).definitions
    }

    public func open(_ file: String) throws -> File {
        try lock.withLock {
            guard let text = try read(file) else { throw Failure("This subagent file no longer exists. Go back to reload the list.") }
            return File(file: file, text: text, fingerprint: fingerprint(text))
        }
    }

    public func editorURL(_ file: String) throws -> URL {
        try lock.withLock {
            try withParent(file) { parent, name in
                let fd = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
                guard fd >= 0 else { throw Failure("Cannot open this subagent file safely.") }
                defer { Darwin.close(fd) }
                var identity = stat()
                guard fstat(fd, &identity) == 0, identity.st_mode & S_IFMT == S_IFREG else { throw Failure("Choose a regular subagent file.") }
                let path = directory.appendingPathComponent(file).path
                guard let url = CFURLCreateWithFileSystemPath(nil, path as CFString, .cfurlposixPathStyle, false),
                      let reference = CFURLCreateFileReferenceURL(nil, url, nil)?.takeRetainedValue(),
                      let resolved = CFURLCreateFilePathURL(nil, reference, nil)?.takeRetainedValue(),
                      let resolvedPath = CFURLCopyFileSystemPath(resolved, .cfurlposixPathStyle) else { throw Failure("The file moved before it could be opened.") }
                var observed = stat()
                guard lstat(resolvedPath as String, &observed) == 0,
                      identity.st_dev == observed.st_dev, identity.st_ino == observed.st_ino,
                      let result = URL(string: CFURLGetString(reference)! as String) else { throw Failure("The file changed before it could be opened.") }
                return result
            }
        }
    }

    @discardableResult
    public func save(_ file: String, text: String, expected: String?) throws -> File {
        try lock.withLock {
            guard Self.acceptsFilename(file) else { throw Failure("Choose a Markdown filename inside Shepherd's subagent folder.") }
            guard text.utf8.count <= Self.limit else { throw Failure("Subagent files can be at most 128 KiB.") }
            guard let definition = try parse([["file": file, "text": text]]).definitions.first else { throw Failure("Could not validate the subagent file.") }
            if let error = definition.error { throw Failure(error + ". The file was not saved.") }
            try seed()
            let current = try readSnapshot(adding: file)
            guard current.count < 512 || current.contains(where: { $0.file == file }) else { throw Failure("At most 512 subagent files can load. Remove a file before creating another.") }
            guard !current.contains(where: { $0.file != file && $0.name == definition.name }) else { throw Failure("Duplicate subagent name: \(definition.name). The file was not saved.") }
            try replace(file, text: text, expected: expected)
            return File(file: file, text: text, fingerprint: fingerprint(text))
        }
    }

    public func delete(_ file: String, expected: String) throws {
        try lock.withLock {
            try withParent(file) { fd, name in
                guard let text = try read(file), fingerprint(text) == expected else { throw Failure("This file changed elsewhere. Reopen it before deleting.") }
                guard unlinkat(fd, name, 0) == 0 else { throw Failure("Could not delete the subagent file.") }
            }
        }
    }

    /// Restore only shipped files. Preflight every snapshot before touching any of them.
    public func restore(expected: [String: String]) throws {
        try lock.withLock {
            let defaults = try parse([]).defaults
            let current = try readSnapshot()
            let custom = current.filter { defaults[$0.file] == nil }
            guard custom.count + defaults.count <= 512 else { throw Failure("Restoring defaults would exceed 512 subagent files. Remove custom files first.") }
            let names = Set(defaults.keys.map { String($0.dropLast(3)) })
            guard !custom.contains(where: { names.contains($0.name) }) else { throw Failure("A custom file uses a default subagent's name. Rename it before restoring defaults.") }
            for file in defaults.keys {
                let current = try currentFingerprint(file)
                guard current == expected[file] else { throw Failure("A default file changed elsewhere. Reload the list before restoring.") }
            }
            for (file, text) in defaults.sorted(by: { $0.key < $1.key }) {
                try replace(file, text: text, expected: expected[file])
            }
        }
    }

    private func seed() throws {
        try FileManager.default.createDirectory(at: pi.home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try withParent("placeholder.md", create: true) { _, _ in }
        guard try read(Self.marker, internalName: true) == nil else { return }
        for (file, text) in try parse([]).defaults where try !exists(file) {
            do { try replace(file, text: text, expected: nil) }
            catch { if try !exists(file) { throw error } }
        }
        do { try replace(Self.marker, text: "1\n", expected: nil, internalName: true) }
        catch { if try read(Self.marker, internalName: true) == nil { throw error } }
    }

    private struct Parsed: Decodable {
        var definitions: [Definition]
        var defaults: [String: String]
    }
    private func parse(_ files: [[String: String]]) throws -> Parsed {
        guard let package = pi.engine.packageDirectory else { throw Failure("Subagent editing needs the pi engine bundled with Shepherd.") }
        let module = pi.home.appendingPathComponent("shepherd-children-config.ts")
        try PiHome.write(Data(parserSource.utf8), to: module, mode: 0o600)
        let input = try JSONSerialization.data(withJSONObject: ["package": package, "module": module.path, "directory": directory.path, "files": files])
        let script = #"""
        import fs from 'node:fs'; import path from 'node:path'; import {createRequire} from 'node:module';
        const q = JSON.parse(fs.readFileSync(0, 'utf8'));
        const require = createRequire(path.join(q.package, 'package.json'));
        const {createJiti} = require('jiti');
        const bundled = path.join(q.package, 'dist/bundle/index.js');
        const sdk = fs.existsSync(bundled) ? bundled : path.join(q.package, 'dist/index.js');
        const jiti = createJiti(import.meta.url, {moduleCache:false, alias:{'@earendil-works/pi-coding-agent':sdk}});
        const config = await jiti.import(q.module);
        const definitions = q.files.map(({file,text,error,fingerprint}) => {
          let result;
          try { if(error) throw Error(error); result = config.parseChildAgent(text, path.join(q.directory,file)); }
          catch(e) { result = config.childAgentError(text ?? '', path.join(q.directory,file), e); }
          const {name,description,tools,context,error:problem,disabled} = result;
          return {file,fingerprint,name,description,tools,context,error:problem,disabled};
        });
        const counts = new Map(); for(const d of definitions) counts.set(d.name,(counts.get(d.name)||0)+1);
        for(const d of definitions) if(counts.get(d.name)>1) d.error = `Duplicate subagent name: ${d.name}`;
        console.log(JSON.stringify({definitions,defaults:config.childAgentDefaults}));
        """#
        var env = ProcessInfo.processInfo.environment.filter { !$0.key.hasPrefix("NODE_") && !$0.key.hasPrefix("JITI_") && !$0.key.hasPrefix("PI_") }
        env["PI_CODING_AGENT_DIR"] = pi.home.path
        let result = try BoundedCommand.run(PiLaunch.node(pi.engine) + ["--input-type=module", "-e", script], directory: pi.home,
                                            environment: env, input: input, timeout: 10, outputLimit: 8 << 20)
        guard result.status == 0 else { throw Failure("Could not read subagent definitions with Shepherd's bundled parser.") }
        return try JSONDecoder().decode(Parsed.self, from: result.output)
    }

    private func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func withParent<T>(_ file: String, create: Bool = false, internalName: Bool = false, _ body: (Int32, String) throws -> T) throws -> T {
        let components = file.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard internalName && file == Self.marker || Self.acceptsFilename(file) else { throw Failure("Choose a Markdown filename inside Shepherd's subagent folder.") }
        var homeInfo = stat()
        guard lstat(pi.home.path, &homeInfo) == 0, homeInfo.st_mode & S_IFMT == S_IFDIR,
              let resolved = realpath(pi.home.path, nil) else { throw Failure("Could not open Shepherd's pi home without following symbolic links.") }
        defer { free(resolved) }
        var fd = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure("Could not open Shepherd's pi home.") }
        defer { Darwin.close(fd) }
        let folders = String(cString: resolved).split(separator: "/").map(String.init) + ["agents"] + components.dropLast()
        for folder in folders {
            if create, mkdirat(fd, folder, 0o700) != 0, errno != EEXIST { throw Failure("Could not create the subagent folder.") }
            let next = openat(fd, folder, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw Failure("Subagent folders cannot follow symbolic links or missing directories.") }
            Darwin.close(fd); fd = next
        }
        return try body(fd, components.last!)
    }

    private func exists(_ file: String) throws -> Bool {
        try withParent(file) { parent, name in
            var info = stat()
            if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 { return true }
            guard errno == ENOENT else { throw Failure("Could not check the subagent file.") }
            return false
        }
    }

    private func identityFingerprint(_ info: stat) -> String {
        "file:\(info.st_dev):\(info.st_ino):\(info.st_size):\(info.st_mtimespec.tv_sec):\(info.st_mtimespec.tv_nsec):\(info.st_ctimespec.tv_sec):\(info.st_ctimespec.tv_nsec)"
    }

    private func currentFingerprint(_ file: String, internalName: Bool = false) throws -> String? {
        do { return try read(file, internalName: internalName).map(fingerprint) }
        catch let failure as Failure where failure.fingerprint != nil { return failure.fingerprint }
    }

    private func read(_ file: String, internalName: Bool = false) throws -> String? {
        try withParent(file, internalName: internalName) { fd, name in
            let opened = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if opened < 0 && errno == ENOENT { return nil }
            guard opened >= 0 else { throw Failure("Subagent files cannot follow symbolic links.") }
            let handle = FileHandle(fileDescriptor: opened, closeOnDealloc: true)
            defer { try? handle.close() }
            var info = stat()
            guard fstat(opened, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { throw Failure("Choose a regular UTF-8 subagent file of at most 128 KiB.") }
            guard info.st_size <= Self.limit else { throw Failure("Choose a UTF-8 subagent file of at most 128 KiB.", fingerprint: identityFingerprint(info)) }
            let data = try handle.read(upToCount: Self.limit + 1) ?? Data()
            guard data.count <= Self.limit, let text = String(data: data, encoding: .utf8) else { throw Failure("Choose a UTF-8 subagent file of at most 128 KiB.", fingerprint: identityFingerprint(info)) }
            return text
        }
    }

    private func replace(_ file: String, text: String, expected: String?, internalName: Bool = false) throws {
        try withParent(file, create: true, internalName: internalName) { parent, name in
            let temporary = ".shepherd-" + UUID().uuidString
            let fd = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw Failure("Could not save the subagent file.") }
            defer { Darwin.close(fd); unlinkat(parent, temporary, 0) }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
            try handle.write(contentsOf: Data(text.utf8)); try handle.synchronize()
            let current = try currentFingerprint(file, internalName: internalName)
            guard current == expected else { throw Failure("This file changed elsewhere. Reopen it before saving. Your draft was kept.") }
            // Exclusive creation prevents a New draft overwriting a concurrently created file.
            if expected == nil {
                guard linkat(parent, temporary, parent, name, 0) == 0 else { throw Failure("That filename already exists. Choose a different filename.") }
            } else {
                guard renameat(parent, temporary, parent, name) == 0 else { throw Failure("Could not replace the subagent file.") }
            }
        }
    }
}
