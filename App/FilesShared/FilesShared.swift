import FileProvider
import Foundation
import ShepherdRemote

// What the app shares with its Files extension (`App/FilesProvider`): the Macs it is paired with and how to reach them,
// in the app group. Their tokens stay in the Keychain's shared group (`HostKeychain`). The app is the only writer.

/// A paired Mac as the extension connects to it.
struct FilesSharedHost: Codable, Equatable {
    var record: RemoteHostRecord
    /// The Mac's fleet id when this device reaches it with its fleet token: the extension asks who answers before sending
    /// the token, as the app does (`MobileHosts.connect`).
    var expecting: UUID?
}

enum FilesShared {
    static let group = HostKeychain.accessGroup
    /// The one domain: Files shows it as "Shepherd", holding every paired Mac.
    static let domain = NSFileProviderDomain(identifier: NSFileProviderDomainIdentifier("shepherd"), displayName: "Shepherd")

    private static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("files-hosts.json")
    }

    static func read() -> [FilesSharedHost] {
        guard let url, let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([FilesSharedHost].self, from: data)) ?? []
    }

    static func write(_ hosts: [FilesSharedHost]) {
        guard let url, let data = try? JSONEncoder().encode(hosts) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
