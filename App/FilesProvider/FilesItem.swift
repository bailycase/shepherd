import FileProvider
import Foundation
import ShepherdProtocol
import ShepherdRemote
import UniformTypeIdentifiers

extension FilesLocation {
    init?(_ identifier: NSFileProviderItemIdentifier) {
        if identifier == .rootContainer {
            self = .root
        } else {
            self.init(identifier: identifier.rawValue)
        }
    }

    var itemIdentifier: NSFileProviderItemIdentifier {
        self == .root ? .rootContainer : NSFileProviderItemIdentifier(identifier)
    }

    var hostID: UUID? {
        switch self {
        case .root: nil
        case .host(let host), .thread(let host, _), .entry(let host, _, _): host
        }
    }
}

/// One item of the Shepherd location: a Mac, a thread's folder, or a file or folder in one.
final class FilesItem: NSObject, NSFileProviderItem {
    let location: FilesLocation
    let filename: String
    let contentType: UTType
    let capabilities: NSFileProviderItemCapabilities
    let itemVersion: NSFileProviderItemVersion
    let documentSize: NSNumber?
    let contentModificationDate: Date?

    var itemIdentifier: NSFileProviderItemIdentifier { location.itemIdentifier }
    var parentItemIdentifier: NSFileProviderItemIdentifier { location.parent.itemIdentifier }

    private init(_ location: FilesLocation, name: String, type: UTType, capabilities: NSFileProviderItemCapabilities,
                 content: Data, size: Int64? = nil, modified: Double? = nil) {
        self.location = location
        filename = name
        contentType = type
        self.capabilities = capabilities
        itemVersion = NSFileProviderItemVersion(contentVersion: content, metadataVersion: Data(name.utf8))
        documentSize = size.map { NSNumber(value: $0) }
        contentModificationDate = modified.map(Date.init(timeIntervalSince1970:))
    }

    /// The location itself, or a Mac in it: read only, nothing made in them.
    static func folder(_ location: FilesLocation, name: String) -> FilesItem {
        FilesItem(location, name: name, type: .folder, capabilities: [.allowsReading, .allowsContentEnumerating], content: Data())
    }

    /// A thread's folder: a new file can be made in it on a Mac that takes one (`writable`).
    static func thread(_ location: FilesLocation, name: String, writable: Bool) -> FilesItem {
        FilesItem(location, name: name, type: .folder,
                  capabilities: writable ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems] : [.allowsReading, .allowsContentEnumerating],
                  content: Data())
    }

    /// An entry of a thread's folder. A file is read, and saved in place on a Mac that takes saves (`writable`);
    /// nothing is renamed, moved or deleted from here.
    static func entry(_ location: FilesLocation, _ entry: ThreadFileEntry, writable: Bool) -> FilesItem {
        if entry.isDirectory {
            return FilesItem(location, name: entry.name, type: .folder,
                             capabilities: writable ? [.allowsReading, .allowsContentEnumerating, .allowsAddingSubItems]
                                                    : [.allowsReading, .allowsContentEnumerating],
                             content: Data(), modified: entry.modified)
        }
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return FilesItem(location, name: entry.name, type: type, capabilities: writable ? [.allowsReading, .allowsWriting] : [.allowsReading],
                         content: entry.filesVersion, size: entry.size, modified: entry.modified)
    }
}

/// A folder's children as a Mac listed them. `complete` is false when the Mac stopped at its listing limit
/// (`ThreadFilesLimits`): what is missing from it may still be there.
struct FilesChildren {
    var items: [FilesItem]
    var complete = true
}

/// What the location holds, read from the Macs each time.
enum FilesCatalog {
    static func children(of location: FilesLocation) async throws -> FilesChildren {
        let source = FilesSource.shared
        switch location {
        case .root:
            let hosts = await source.hosts()
            return FilesChildren(items: zip(hosts, FilesNames.unique(hosts.map(\.record.name))).map { .folder(.host($0.record.id), name: $1) })
        case .host(let host):
            let writable = try await source.writable(host)
            return FilesChildren(items: try await source.threads(host).map {
                .thread(.thread(host: host, agent: $0.agent), name: $0.name, writable: writable)
            })
        case .thread(let host, let agent), .entry(let host, let agent, _):
            let listing = try await source.list(host, agent, location.folderPath ?? "")
            let writable = try await source.writable(host)
            return FilesChildren(items: listing.entries.compactMap { entry in location.child(entry.name).map { FilesItem.entry($0, entry, writable: writable) } },
                                 complete: !listing.truncated)
        }
    }

    static func item(_ location: FilesLocation) async throws -> FilesItem {
        if location == .root { return .folder(.root, name: "Shepherd") }
        let siblings = try await children(of: location.parent)
        guard let item = siblings.items.first(where: { $0.location == location }) else {
            guard siblings.complete else { throw FilesSource.failure("This folder has more files than Shepherd lists.") }
            throw NSFileProviderError(.noSuchItem)
        }
        return item
    }
}
