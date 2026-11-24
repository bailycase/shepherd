import FileProvider
import Foundation
import ShepherdRemote

/// How Files learns that something changed on a Mac. A replicated location hears of changes only through its working set,
/// and a Mac sends no feed of them, so the extension keeps what it last told Files of each folder (child identifier →
/// version) and lists again the folders someone is looking at: one Files shows, or one holding a document an app has
/// open (the system keeps an enumerator open on each). The difference is the change. A pass runs when one opens, every
/// `pollInterval` while any stays open, and when the app comes to the front (`FilesLocationBridge`).
actor FilesWorkingSet {
    static let shared = FilesWorkingSet()

    /// How long a folder is still listed again after its last enumerator closed.
    static let watched: TimeInterval = 15 * 60
    /// The least time between two passes an opened enumerator asks for.
    static let signalSpacing: TimeInterval = 2
    /// How often a pass runs while Files or an app has something of the location open.
    static let pollInterval: Duration = .seconds(30)

    private struct Saved: Codable {
        var anchor = 0
        /// Folder identifier → its children's identifiers → their versions.
        var folders: [String: [String: Data]] = [:]
    }

    private var saved: Saved
    /// Folders with an open enumerator, and how many.
    private var open: [FilesLocation: Int] = [:]
    /// Folders whose last enumerator closed, and when.
    private var closed: [FilesLocation: Date] = [:]
    private var lastSignal = Date.distantPast
    private var poll: Task<Void, Never>?
    private let url: URL?

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        try? folder.map { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        url = folder?.appendingPathComponent("files-working-set.json")
        saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var anchor: NSFileProviderSyncAnchor { Self.anchor(saved.anchor) }

    private static func anchor(_ value: Int) -> NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data(String(value).utf8)) }

    /// Files was just given `items` as the children of `folder`.
    func told(_ folder: FilesLocation, _ children: FilesChildren) {
        saved.folders[folder.identifier] = Self.versions(children.items)
        save()
    }

    /// An enumerator opened on `location` (a folder on screen, or a document an app holds open, which is watched through
    /// its folder): it is listed again on each pass until a while after it closes.
    func opened(_ location: FilesLocation, domain: NSFileProviderDomain) {
        for folder in Set([location, location.parent]) {
            open[folder, default: 0] += 1
            closed[folder] = nil
        }
        let now = Date()
        if now.timeIntervalSince(lastSignal) > Self.signalSpacing {
            lastSignal = now
            Self.signal(domain)
        }
        guard poll == nil else { return }
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.pollInterval)
                guard let self, await self.watching else { break }
                Self.signal(domain)
            }
            await self?.pollEnded()
        }
    }

    func closedEnumerator(_ location: FilesLocation) {
        for folder in Set([location, location.parent]) {
            guard let count = open[folder] else { continue }
            if count > 1 {
                open[folder] = count - 1
            } else {
                open[folder] = nil
                closed[folder] = Date()
            }
        }
    }

    private var watching: Bool { !open.isEmpty }
    private func pollEnded() { poll = nil }

    private static func signal(_ domain: NSFileProviderDomain) {
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Every folder Files was told of, listed again: the working set's full listing, asked for only when Files starts over.
    func all() async -> [FilesItem] {
        var items: [FilesItem] = []
        for identifier in saved.folders.keys {
            guard let folder = FilesLocation(identifier: identifier),
                  let children = try? await FilesCatalog.children(of: folder) else { continue }
            saved.folders[identifier] = Self.versions(children.items)
            items += children.items
        }
        save()
        return items
    }

    /// What changed in the folders someone looks at since `from`, Files' last anchor. Files asks from the anchor it last
    /// took in: an older one means a delivery was lost, so it is told to start over (`all`) rather than miss a change.
    func changes(from: NSFileProviderSyncAnchor) async throws -> (updated: [FilesItem], deleted: [NSFileProviderItemIdentifier]) {
        guard from.rawValue == anchor.rawValue else { throw NSFileProviderError(.syncAnchorExpired) }
        let since = Date().addingTimeInterval(-Self.watched)
        closed = closed.filter { $0.value > since }
        var updated: [FilesItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        var unreachable = Set<UUID>()
        for folder in Set(open.keys).union(closed.keys) {
            if let host = folder.hostID, unreachable.contains(host) { continue }
            let before = saved.folders[folder.identifier] ?? [:]
            do {
                let children = try await FilesCatalog.children(of: folder)
                var after = Self.versions(children.items)
                updated += children.items.filter { before[$0.location.identifier] != after[$0.location.identifier] }
                if children.complete {
                    deleted += before.keys.filter { after[$0] == nil }.compactMap { FilesLocation(identifier: $0)?.itemIdentifier }
                } else {
                    // Past the Mac's listing limit: what it left out is not known to be gone.
                    after.merge(before) { listed, _ in listed }
                }
                saved.folders[folder.identifier] = after
            } catch let error as NSFileProviderError where error.code == .noSuchItem {
                // The folder is gone from the Mac, and everything Files had in it.
                deleted += before.keys.compactMap { FilesLocation(identifier: $0)?.itemIdentifier } + [folder.itemIdentifier]
                saved.folders[folder.identifier] = nil
                closed[folder] = nil
            } catch is FilesSource.NotFolder {
                closed[folder] = nil
            } catch {
                if let host = folder.hostID { unreachable.insert(host) }
            }
        }
        if !updated.isEmpty || !deleted.isEmpty { saved.anchor += 1 }
        save()
        return (updated, deleted)
    }

    private static func versions(_ items: [FilesItem]) -> [String: Data] {
        Dictionary(items.map { ($0.location.identifier, $0.itemVersion.contentVersion + $0.itemVersion.metadataVersion) }) { first, _ in first }
    }

    private func save() {
        guard let url, let data = try? JSONEncoder().encode(saved) else { return }
        try? data.write(to: url, options: .atomic)
    }
}

/// Lists a folder for Files, or the working set's changes.
final class FilesEnumerator: NSObject, NSFileProviderEnumerator {
    /// nil: the working set.
    private let folder: FilesLocation?

    init(_ folder: FilesLocation?, domain: NSFileProviderDomain) {
        self.folder = folder
        super.init()
        if let folder { Task { await FilesWorkingSet.shared.opened(folder, domain: domain) } }
    }

    func invalidate() {
        if let folder { Task { await FilesWorkingSet.shared.closedEnumerator(folder) } }
    }

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let folder = folder
        Task {
            do {
                let items: [FilesItem]
                if let folder {
                    do {
                        let children = try await FilesCatalog.children(of: folder)
                        await FilesWorkingSet.shared.told(folder, children)
                        items = children.items
                    } catch is FilesSource.NotFolder {
                        // A document's own enumerator: it holds the document.
                        items = [try await FilesCatalog.item(folder)]
                    }
                } else {
                    items = await FilesWorkingSet.shared.all()
                }
                for start in stride(from: 0, to: items.count, by: 200) {
                    observer.didEnumerate(Array(items[start..<min(start + 200, items.count)]))
                }
                observer.finishEnumerating(upTo: nil)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func enumerateChanges(for observer: NSFileProviderChangeObserver, from anchor: NSFileProviderSyncAnchor) {
        guard folder == nil else {
            // A replicated location hears of changes through the working set alone.
            observer.finishEnumeratingChanges(upTo: anchor, moreComing: false)
            return
        }
        Task {
            do {
                let (updated, deleted) = try await FilesWorkingSet.shared.changes(from: anchor)
                if !updated.isEmpty { observer.didUpdate(updated) }
                if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
                observer.finishEnumeratingChanges(upTo: await FilesWorkingSet.shared.anchor, moreComing: false)
            } catch {
                observer.finishEnumeratingWithError(error)
            }
        }
    }

    func currentSyncAnchor(completionHandler: @escaping (NSFileProviderSyncAnchor?) -> Void) {
        guard folder == nil else {
            completionHandler(nil)
            return
        }
        Task { completionHandler(await FilesWorkingSet.shared.anchor) }
    }
}
