import CryptoKit
import Foundation

/// The text Files last had of each file, under the version Files knows it by: what a save is compared against on the Mac.
/// The Mac's save lands only while its file still holds this text (`RemoteAgentQuery.fileWrite`), so an agent's edit
/// made at any moment after Files took the file in is never written over. One per file, replaced as Files takes in a newer
/// one, at most `ThreadFilesLimits.readBytes` each.
actor FilesBases {
    static let shared = FilesBases()

    private struct Base: Codable {
        var version: Data
        var text: String
    }

    private let folder: URL?

    init() {
        folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("files-bases", isDirectory: true)
        try? folder.map { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
    }

    private func url(_ identifier: String) -> URL? {
        let name = SHA256.hash(data: Data(identifier.utf8)).map { String(format: "%02x", $0) }.joined()
        return folder?.appendingPathComponent(name)
    }

    func store(_ identifier: String, version: Data, text: String) {
        guard let url = url(identifier), let data = try? JSONEncoder().encode(Base(version: version, text: text)) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    /// The text Files had of the file at `version`, or nil when the extension doesn't hold that one.
    func text(_ identifier: String, version: Data) -> String? {
        guard let url = url(identifier), let data = try? Data(contentsOf: url),
              let base = try? JSONDecoder().decode(Base.self, from: data), base.version == version else { return nil }
        return base.text
    }
}
