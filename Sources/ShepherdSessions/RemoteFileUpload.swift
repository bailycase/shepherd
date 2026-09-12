import Foundation
import Darwin
import ShepherdCore
import ShepherdProtocol

/// One connection owns one bounded upload. Partial files disappear on disconnect.
final class RemoteFileUpload {
    let id = UUID()
    let sessionID: SessionID
    private let url: URL
    private let handle: FileHandle
    private let size: Int
    private var received = 0
    private var completed = false

    init(directory: URL, sessionID: SessionID, name: String, size: Int) throws {
        guard (0...RemoteProtocol.uploadMaxBytes).contains(size),
              !name.isEmpty, name.utf8.count <= 200,
              name == (name as NSString).lastPathComponent,
              name != ".", name != "..", !name.contains("\0"), !name.contains("\n"), !name.contains("\r") else {
            throw RemoteCreateAgentError("Upload requires a filename and a file no larger than 32 MiB")
        }
        self.sessionID = sessionID
        self.size = size
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let directoryInfo = try directory.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey])
        guard directoryInfo.isDirectory == true, directoryInfo.isSymbolicLink != true else {
            throw RemoteCreateAgentError("Upload directory is not a private directory")
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let cutoff = Date().addingTimeInterval(-86_400)
        for entry in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.contentModificationDateKey]) {
            if let modified = try entry.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, modified < cutoff {
                try? fm.removeItem(at: entry)
            }
        }
        url = directory.appendingPathComponent("\(id.uuidString)-\(name)")
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RemoteCreateAgentError("Cannot create private upload file") }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    func append(_ data: Data) throws {
        guard !completed, !data.isEmpty, data.count <= RemoteProtocol.uploadChunkBytes,
              data.count <= size - received else { throw RemoteCreateAgentError("Upload chunk exceeds declared size or chunk limit") }
        try handle.write(contentsOf: data)
        received += data.count
    }

    func finish() throws -> String {
        guard received == size, !completed else { throw RemoteCreateAgentError("Upload is incomplete") }
        try handle.close()
        completed = true
        return url.path
    }

    deinit {
        try? handle.close()
        if !completed { try? FileManager.default.removeItem(at: url) }
    }
}
