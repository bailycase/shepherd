import Darwin
import Foundation
import ShepherdCore

/// Which tiers a model offers on this host: `ServiceTierSupport`, plus the one thing it can't know
/// by itself, who owns a model CLIProxyAPI serves (`owned_by` in the connection file Settings
/// keeps in Shepherd's pi home). The file is read when it changes, never on every snapshot, and
/// only for that provider's models.
final class ServiceTierOffers: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var cached: (stamp: [Double], owners: [String: String])?

    init(home: PiHome) {
        file = home.directory.appendingPathComponent(CLIProxyAPIStore.fileName)
    }

    func tiers(for model: ServiceTierModel) -> [ServiceTier] {
        var model = model
        if model.provider == CLIProxyAPIStore.provider { model.ownedBy = owner(of: model.id) }
        return ServiceTierSupport.tiers(for: model)
    }

    private func owner(of id: String) -> String? {
        var info = stat()
        guard stat(file.path, &info) == 0 else { return nil }
        let stamp = [Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1e9, Double(info.st_size)]
        return lock.withLock {
            if cached?.stamp != stamp {
                cached = (stamp, Self.owners(in: file))
            }
            return cached?.owners[id]
        }
    }

    /// `id` to `owned_by` for every model in the connection file; its key is never decoded.
    static func owners(in file: URL) -> [String: String] {
        struct Listing: Decodable {
            struct Entry: Decodable { var id: String; var owned_by: String? }
            var models: [Entry]
        }
        guard let data = try? Data(contentsOf: file), let listing = try? JSONDecoder().decode(Listing.self, from: data) else { return [:] }
        var owners: [String: String] = [:]
        for entry in listing.models {
            if let owner = entry.owned_by { owners[entry.id] = owner }
        }
        return owners
    }
}
