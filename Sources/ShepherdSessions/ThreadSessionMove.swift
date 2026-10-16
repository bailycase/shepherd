import Foundation
import ShepherdProtocol

/// A staged copy keeps the original conversation recoverable until workspace persistence succeeds.
struct ThreadSessionMove: Sendable {
    let source: URL
    let destination: URL

    /// Read-only checks run before stopping pi, then again after its final writes drain.
    static func preflight(sessionID: String, from: String, to: String, root: URL, allowMissing: Bool = false) throws -> Self? {
        let fm = FileManager.default
        let sourceDirectory = root.appendingPathComponent(PiSessionFolder.name(forCwd: from), isDirectory: true)
        let destinationDirectory = root.appendingPathComponent(PiSessionFolder.name(forCwd: to), isDirectory: true)
        let canonicalRoot = PiHome.canonical(root.path)
        for directory in [sourceDirectory, destinationDirectory] {
            guard PiHome.isInside(PiHome.canonical(directory.path), canonicalRoot) else {
                throw ProjectFileError("unsafe_session", "The conversation directory resolves outside Shepherd's session storage.")
            }
        }
        if sourceDirectory == destinationDirectory {
            guard PiSessionFolder.realPath(from) == PiSessionFolder.realPath(to) else {
                throw ProjectFileError("session_conflict", "These folders map to the same session directory. Nothing was moved.")
            }
            return nil
        }
        let suffix = "_\(sessionID).jsonl"
        func matches(_ directory: URL) throws -> [URL] {
            guard fm.fileExists(atPath: directory.path) else { return [] }
            return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasSuffix(suffix) }
        }
        let sources = try matches(sourceDirectory)
        guard sources.count <= 1 else { throw ProjectFileError("ambiguous_session", "More than one conversation file matches this thread.") }
        guard try matches(destinationDirectory).isEmpty else {
            throw ProjectFileError("session_conflict", "The destination already contains this conversation. Nothing was replaced.")
        }
        guard let source = sources.first else {
            if allowMissing { return nil } // A thread that never started may have no session file.
            throw ProjectFileError("missing_session", "The original conversation could not be found. Nothing was moved.")
        }
        var info = stat()
        guard lstat(source.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw ProjectFileError("unsafe_session", "The conversation must be a regular, unlinked file.")
        }
        return Self(source: source, destination: destinationDirectory.appendingPathComponent(source.lastPathComponent))
    }

    static func prepare(sessionID: String, from: String, to: String, root: URL, allowMissing: Bool = false) throws -> Self? {
        guard let move = try preflight(sessionID: sessionID, from: from, to: to, root: root, allowMissing: allowMissing) else { return nil }
        let fm = FileManager.default
        let source = move.source
        let destinationDirectory = move.destination.deletingLastPathComponent()
        let fd = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw ProjectFileError("unsafe_session", "The original conversation cannot be safely opened.") }
        let input = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? input.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw ProjectFileError("unsafe_session", "The conversation must be a regular, unlinked file.")
        }
        var header = Data()
        var tail = Data()
        while true {
            guard let chunk = try input.read(upToCount: 64 * 1024), !chunk.isEmpty else {
                throw ProjectFileError("invalid_session", "The conversation header is incomplete.")
            }
            if let newline = chunk.firstIndex(of: 10) {
                header.append(chunk[..<newline])
                tail = chunk[newline...]
                break
            }
            header.append(chunk)
            guard header.count <= 1024 * 1024 else { throw ProjectFileError("invalid_session", "The conversation header is too large.") }
        }
        guard var object = try JSONSerialization.jsonObject(with: header) as? [String: Any],
              object["type"] as? String == "session", object["id"] as? String == sessionID else {
            throw ProjectFileError("invalid_session", "The conversation header does not match this thread.")
        }
        object["cwd"] = PiSessionFolder.realPath(to)
        try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
        let destination = move.destination
        let staged = destinationDirectory.appendingPathComponent(".move-\(UUID().uuidString)")
        guard fm.createFile(atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw ProjectFileError("session_write", "Could not stage the conversation.")
        }
        defer { try? fm.removeItem(at: staged) }
        let output = try FileHandle(forWritingTo: staged)
        do {
            try output.write(contentsOf: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            try output.write(contentsOf: tail)
            let deadline = ContinuousClock.now + .seconds(30)
            while let chunk = try input.read(upToCount: 256 * 1024), !chunk.isEmpty {
                guard ContinuousClock.now < deadline else { throw ProjectFileError("move_timeout", "Copying the conversation timed out. The original is unchanged.") }
                try output.write(contentsOf: chunk)
            }
            try output.synchronize()
            try output.close()
            try fm.moveItem(at: staged, to: destination)
            return move
        } catch {
            try? output.close()
            throw error
        }
    }

    func rollback() throws { try FileManager.default.removeItem(at: destination) }
    func finish() throws { try FileManager.default.removeItem(at: source) }
}
