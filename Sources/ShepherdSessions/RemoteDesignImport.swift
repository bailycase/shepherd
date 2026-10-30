import Foundation
import ShepherdCore
import ShepherdProtocol

/// Why another device's import didn't land: a stable code (`import_unreadable`: boards the host
/// can't read, nothing imported) and words for the client.
public struct RemoteDesignImportFailure: Error, Sendable {
    public let code: String
    public let message: String

    public init(_ code: String, _ message: String) {
        self.code = code
        self.message = message
    }
}

/// One ZIP another device is uploading to import (`design.import.v1`): written in order into a
/// private file under the host's support folder, in a folder of its own so the import reads its
/// real name. It goes when the connection does, or when the import is cancelled or lands.
final class RemoteDesignImportUpload {
    let id = UUID()
    let url: URL
    private let folder: URL
    private let handle: FileHandle
    let size: Int
    private(set) var received = 0

    init(root: URL, name: String, size: Int) throws {
        guard (1...RemoteProtocol.designImportMaxBytes).contains(size), name.lowercased().hasSuffix(".zip"), name.utf8.count <= 200,
              name == (name as NSString).lastPathComponent, !name.hasPrefix("."),
              !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw RemoteDesignImportFailure("invalid_import", "An import takes one .zip of at most \(RemoteProtocol.designImportMaxBytes / 1024 / 1024) MB.")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        // Uploads a crash left behind go after a day.
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in (try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let modified = try? entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
        folder = root.appendingPathComponent(id.uuidString, isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        url = folder.appendingPathComponent(name)
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else {
            try? fm.removeItem(at: folder)
            throw RemoteDesignImportFailure("import_failed", "The host couldn't keep the upload.")
        }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        self.size = size
    }

    /// The next piece, at the offset received so far.
    func append(_ data: Data, at offset: Int) throws {
        guard offset == received, !data.isEmpty, data.count <= RemoteProtocol.designChunkBytes, data.count <= size - received else {
            throw RemoteDesignImportFailure("invalid_offset", "That piece doesn't follow what the host has (\(received) of \(size) bytes).")
        }
        try handle.write(contentsOf: data)
        received += data.count
    }

    var isComplete: Bool { received == size }

    deinit {
        try? handle.close()
        try? FileManager.default.removeItem(at: folder)
    }
}
