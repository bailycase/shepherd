import Darwin
import Foundation

/// Who this host is in a fleet: a random id written once to `<support>/fleet/identity.json` and
/// never changed (a Mac that is wiped gets a new one and pairs again).
struct FleetIdentity: Codable, Equatable, Sendable {
    var hostID: UUID
    /// Epoch milliseconds.
    var createdAt: Double

    static let fileName = "identity.json"

    /// The identity saved in `directory`, made and saved on first use. An unreadable file is
    /// replaced only when it is missing: a damaged identity is an error, never a silent new Mac.
    static func loadOrCreate(in directory: URL, now: Date = Date()) throws -> FleetIdentity {
        let url = directory.appendingPathComponent(fileName)
        if let data = try? Data(contentsOf: url) {
            return try JSONDecoder().decode(FleetIdentity.self, from: data)
        }
        let identity = FleetIdentity(hostID: UUID(), createdAt: (now.timeIntervalSince1970 * 1000).rounded())
        try FleetFiles.write(try JSONEncoder().encode(identity), to: url)
        return identity
    }
}

/// The fleet folder's files are private to this user: the folder 0700 and each file 0600, like
/// the remote token.
enum FleetFiles {
    static func write(_ data: Data, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else { throw CocoaError(.fileWriteNoPermission) }
        try data.write(to: url, options: .atomic)
        guard chmod(url.path, 0o600) == 0 else { throw CocoaError(.fileWriteNoPermission) }
    }
}
