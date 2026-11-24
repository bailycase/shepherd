import FileProvider
import Foundation
import ShepherdRemote

/// How Files learns that something changed on a Mac. A replicated location hears of changes only through its working set,
/// and a Mac sends no feed of them, so the extension keeps what it last told Files of each folder (child identifier →
/// version) and lists again the folders someone is looking at: one Files shows, or one holding a document an app has
/// open. The difference is the change. Looking at a folder asks for that pass (`presented`); so does the app coming to
/// the front (`FilesLocationBridge`).
actor FilesWorkingSet {
    static let shared = FilesWorkingSet()

    /// How long a folder someone looked at is still listed again on each pass.
    static let watched: TimeInterval = 15 * 60
    /// The least time between two passes a look asks for.
    static let signalSpacing: TimeInterval = 2

    private struct Saved: Codable {
        var anchor = 0
        /// Folder identifier → its children's identifiers → their content versions.
        var folders: [String: [String: Data]] = [:]
    }

    private var saved: Saved
    private var presented: [FilesLocation: Date] = [:]
    private var lastSignal = Date.distantPast
    private let url: URL?

    init() {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        try? folder.map { try FileManager.default.createDirectory(at: $0, withIntermediateDirectories: true) }
        url = folder?.appendingPathComponent("files-working-set.json")
        saved = url.flatMap { try? Data(contentsOf: $0) }.flatMap { try? JSONDecoder().decode(Saved.self, from: $0) } ?? Saved()
    }

    var anchor: NSFileProviderSyncAnchor { NSFileProviderSyncAnchor(Data(String(saved.anchor).utf8)) }

    /// Files was just given `items` as the children of `folder`.
    func told(_ folder: FilesLocation, _ items: [FilesItem]) {
        saved.folders[folder.identifier] = Self.versions(items)
        save()
    }

    /// Someone looks at `location` (a folder on screen, or a document an app holds open, which is watched through its
    /// folder): it is listed again on the next passes, and a pass is asked for.
    func presented(_ location: FilesLocation, domain: NSFileProviderDomain) {
        let now = Date()
        presented[location] = now
        presented[location.parent] = now
        guard now.timeIntervalSince(lastSignal) > Self.signalSpacing else { return }
        lastSignal = now
        NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in }
    }

    /// Every folder Files was told of, listed again: the working set's full listing, asked for only when Files starts over.
    func all() async -> [FilesItem] {
        var items: [FilesItem] = []
        for identifier in saved.folders.keys {
            guard let folder = FilesLocation(identifier: identifier),
                  let children = try? await FilesCatalog.children(of: folder) else { continue }
            saved.folders[identifier] = Self.versions(children)
            items += children
        }
        save()
        return items
    }

    /// What changed in the folders someone looked at lately since Files was last told of them.
    func changes() async -> (updated: [FilesItem], deleted: [NSFileProviderItemIdentifier]) {
        let since = Date().addingTimeInterval(-Self.watched)
        presented = presented.filter { $0.value > since }
        var updated: [FilesItem] = []
        var deleted: [NSFileProviderItemIdentifier] = []
        var unreachable = Set<UUID>()
        for folder in presented.keys {
            if let host = folder.hostID, unreachable.contains(host) { continue }
            let before = saved.folders[folder.identifier] ?? [:]
            do {
                let children = try await FilesCatalog.children(of: folder)
                let after = Self.versions(children)
                updated += children.filter { before[$0.location.identifier] != after[$0.location.identifier] }
                deleted += before.keys.filter { after[$0] == nil }.compactMap { FilesLocation(identifier: $0)?.itemIdentifier }
                saved.folders[folder.identifier] = after
            } catch let error as NSFileProviderError where error.code == .noSuchItem {
                // The folder is gone from the Mac, and everything Files had in it.
                deleted += before.keys.compactMap { FilesLocation(identifier: $0)?.itemIdentifier } + [folder.itemIdentifier]
                saved.folders[folder.identifier] = nil
                presented[folder] = nil
            } catch is FilesSource.NotFolder {
                presented[folder] = nil
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

    init(_ folder: FilesLocation?) {
        self.folder = folder
    }

    func invalidate() {}

    func enumerateItems(for observer: NSFileProviderEnumerationObserver, startingAt page: NSFileProviderPage) {
        let folder = folder
        Task {
            do {
                let items: [FilesItem]
                if let folder {
                    do {
                        items = try await FilesCatalog.children(of: folder)
                        await FilesWorkingSet.shared.told(folder, items)
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
            let (updated, deleted) = await FilesWorkingSet.shared.changes()
            if !updated.isEmpty { observer.didUpdate(updated) }
            if !deleted.isEmpty { observer.didDeleteItems(withIdentifiers: deleted) }
            observer.finishEnumeratingChanges(upTo: await FilesWorkingSet.shared.anchor, moreComing: false)
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
