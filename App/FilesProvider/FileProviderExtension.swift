import FileProvider
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import UIKit

/// Shepherd in Files: every paired Mac, its threads, and each thread's folder, read and saved over the same connection
/// the app uses (`files.v1`). Any app that opens documents in place (a Markdown editor, a code editor) reads a file from
/// the Mac and saves back to it.
///
/// A save lands only over the text Files took in (`FilesBases`). When the Mac's file moved on meanwhile (an agent edited
/// it), the phone's text is kept beside it as "name (iPhone).ext" and Files shows the Mac's again: neither is lost. A
/// save while the Mac is unreachable waits, and Files tries it again. v1 reads and writes UTF-8 text of at most 256 KiB
/// and makes files but not folders; nothing is renamed, moved or deleted from here. A Mac without `files.create.v1` is
/// read only.
final class FileProviderExtension: NSObject, NSFileProviderReplicatedExtension {
    private let domain: NSFileProviderDomain

    required init(domain: NSFileProviderDomain) {
        self.domain = domain
        super.init()
    }

    func invalidate() {
        Task { await FilesSource.shared.closeAll() }
    }

    // MARK: Reading

    func item(for identifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest,
              completionHandler: @escaping (NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        Task {
            do {
                guard let location = FilesLocation(identifier) else { throw NSFileProviderError(.noSuchItem) }
                completionHandler(try await FilesCatalog.item(location), nil)
            } catch {
                completionHandler(nil, Self.files(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func fetchContents(for itemIdentifier: NSFileProviderItemIdentifier, version requestedVersion: NSFileProviderItemVersion?,
                       request: NSFileProviderRequest, completionHandler: @escaping (URL?, NSFileProviderItem?, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let domain = domain
        Task {
            do {
                guard let location = FilesLocation(itemIdentifier), case .entry(let host, let agent, let path) = location else {
                    throw NSFileProviderError(.noSuchItem)
                }
                // The version first, then the text: a change between them only makes Files fetch once more.
                let item = try await FilesCatalog.item(location)
                let data = try await FilesSource.shared.read(host, agent, path)
                await FilesBases.shared.store(location.identifier, version: item.itemVersion.contentVersion,
                                              text: String(decoding: data, as: UTF8.self))
                let folder = (try? NSFileProviderManager(for: domain)?.temporaryDirectoryURL()) ?? FileManager.default.temporaryDirectory
                let url = folder.appendingPathComponent(UUID().uuidString)
                try data.write(to: url)
                completionHandler(url, item, nil)
            } catch {
                completionHandler(nil, nil, Self.files(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func enumerator(for containerItemIdentifier: NSFileProviderItemIdentifier, request: NSFileProviderRequest) throws -> NSFileProviderEnumerator {
        if containerItemIdentifier == .workingSet { return FilesEnumerator(nil, domain: domain) }
        guard let location = FilesLocation(containerItemIdentifier) else { throw NSFileProviderError(.noSuchItem) }
        return FilesEnumerator(location, domain: domain)
    }

    // MARK: Writing

    func createItem(basedOn itemTemplate: NSFileProviderItem, fields: NSFileProviderItemFields, contents url: URL?,
                    options: NSFileProviderCreateItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        // The system unlinks the contents once this returns its answer, so they are read now.
        let text = Result { try url.map(Self.text(at:)) ?? "" }
        let isFolder = itemTemplate.contentType?.conforms(to: .folder) == true
        let parent = FilesLocation(itemTemplate.parentItemIdentifier)
        let name = itemTemplate.filename
        Task {
            do {
                guard !isFolder else { throw Self.unsupported("Shepherd can't make folders on the Mac from here.") }
                guard let parent, let location = parent.child(name), case .entry(let host, let agent, let path) = location else {
                    throw Self.unsupported("Files can be made only in a thread's folder.")
                }
                let text = try text.get()
                if let existing = try await FilesCatalog.children(of: parent).items.first(where: { $0.location == location }) {
                    guard options.contains(.mayAlreadyExist) else { throw NSFileProviderError(.filenameCollision) }
                    // Files is taking in what it had again (after a reset): the Mac's file is the one, and the phone's
                    // text, when it differs, is kept beside it.
                    let mac = String(decoding: try await FilesSource.shared.read(host, agent, path), as: UTF8.self)
                    if mac != text { try await Self.keepCopy(text, of: existing) }
                    await FilesBases.shared.store(location.identifier, version: existing.itemVersion.contentVersion, text: mac)
                    completionHandler(existing, [], mac != text, nil)
                } else {
                    try Self.check(try await FilesSource.shared.create(host, agent, path, text: text))
                    let item = try await FilesCatalog.item(location)
                    await FilesBases.shared.store(location.identifier, version: item.itemVersion.contentVersion, text: text)
                    completionHandler(item, [], false, nil)
                }
            } catch {
                completionHandler(nil, [], false, Self.files(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    func modifyItem(_ item: NSFileProviderItem, baseVersion version: NSFileProviderItemVersion, changedFields: NSFileProviderItemFields,
                    contents newContents: URL?, options: NSFileProviderModifyItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (NSFileProviderItem?, NSFileProviderItemFields, Bool, Error?) -> Void) -> Progress {
        let progress = Progress(totalUnitCount: 1)
        let location = FilesLocation(item.itemIdentifier)
        // The system unlinks the contents once this returns its answer, so they are read now. One that can't be read
        // fails the save, and Files keeps the edit and tries it again.
        let text: Result<String, Error>? = changedFields.contains(.contents)
            ? Result { guard let newContents else { throw NSFileProviderError(.cannotSynchronize) }; return try Self.text(at: newContents) }
            : nil
        let domain = domain
        Task {
            do {
                guard let location else { throw NSFileProviderError(.noSuchItem) }
                guard let text, case .entry(let host, let agent, let path) = location else {
                    // Only a name, a place or dates changed: the Mac's item stands, which undoes a rename or a move.
                    completionHandler(try await FilesCatalog.item(location), [], false, nil)
                    progress.completedUnitCount = 1
                    return
                }
                let fetchMac = try await Self.save(try text.get(), to: location, host: host, agent: agent, path: path, base: version.contentVersion)
                if fetchMac { NSFileProviderManager(for: domain)?.signalEnumerator(for: .workingSet) { _ in } }
                completionHandler(try await FilesCatalog.item(location), [], fetchMac, nil)
            } catch {
                completionHandler(nil, [], false, Self.files(error))
            }
            progress.completedUnitCount = 1
        }
        return progress
    }

    /// Saves the phone's `text` over the Mac's file only while it still holds the text Files had at `base`. Otherwise
    /// (the Mac's moved on, or the extension doesn't hold that text) the phone's text is kept beside it and the answer is
    /// true: Files fetches the Mac's. The Mac does the comparing, in the same step as the write.
    private static func save(_ text: String, to location: FilesLocation, host: UUID, agent: AgentID, path: String,
                             base: Data) async throws -> Bool {
        let source = FilesSource.shared
        let current: FilesItem
        do {
            current = try await FilesCatalog.item(location)
        } catch let error as NSFileProviderError where error.code == .noSuchItem {
            // Gone from the Mac since: the phone's text puts it back.
            try check(try await source.create(host, agent, path, text: text))
            let item = try await FilesCatalog.item(location)
            await FilesBases.shared.store(location.identifier, version: item.itemVersion.contentVersion, text: text)
            return false
        }
        if let expected = await FilesBases.shared.text(location.identifier, version: base) {
            switch try await source.write(host, agent, path, text: text, expected: expected) {
            case .saved:
                // What Files has now is the phone's text, under the version the Mac lists next. One that moved on again
                // since is fetched; until then a save from it still compares against the phone's text and is kept apart.
                let saved = try await FilesCatalog.item(location)
                await FilesBases.shared.store(location.identifier, version: saved.itemVersion.contentVersion, text: text)
                return String(decoding: try await source.read(host, agent, path), as: UTF8.self) != text
            case .failed(let message): throw FilesSource.failure(message)
            case .changed(let mac) where mac == text: return false
            case .changed: break
            }
        } else if String(decoding: try await source.read(host, agent, path), as: UTF8.self) == text {
            return false
        }
        try await keepCopy(text, of: current)
        return true
    }

    /// Keeps the phone's `text` beside `item` on the Mac, under a free "name (iPhone).ext".
    private static func keepCopy(_ text: String, of item: FilesItem) async throws {
        let parent = item.location.parent
        let taken = Set(try await FilesCatalog.children(of: parent).items.map(\.filename))
        let name = FilesNames.conflictCopy(of: item.filename, device: await MainActor.run { UIDevice.current.model }, taken: taken)
        guard case .entry(let host, let agent, let copy)? = parent.child(name) else { throw NSFileProviderError(.noSuchItem) }
        try check(try await FilesSource.shared.create(host, agent, copy, text: text))
    }

    /// The UTF-8 text of a file Files hands over, refused past what a Mac takes.
    private static func text(at url: URL) throws -> String {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= ThreadFilesLimits.readBytes else { throw unsupported(textOnly) }
        guard let text = ThreadFileSystem.decodeText(try Data(contentsOf: url)) else { throw unsupported(textOnly) }
        return text
    }

    func deleteItem(identifier: NSFileProviderItemIdentifier, baseVersion version: NSFileProviderItemVersion,
                    options: NSFileProviderDeleteItemOptions = [], request: NSFileProviderRequest,
                    completionHandler: @escaping (Error?) -> Void) -> Progress {
        // Files puts it back: deleting stays on the Mac.
        completionHandler(NSFileProviderError(.deletionRejected))
        return Progress()
    }

    // MARK: Errors

    private static let textOnly = "Shepherd opens and saves UTF-8 text files of up to 256 KB."

    private static func check(_ result: ThreadFileSaveResult) throws {
        switch result {
        case .saved: return
        case .failed(let message): throw FilesSource.failure(message)
        case .changed: throw FilesSource.failure("The file changed on the Mac.")
        }
    }

    private static func unsupported(_ message: String) -> NSError {
        NSError(domain: NSCocoaErrorDomain, code: NSFeatureUnsupportedError, userInfo: [NSLocalizedDescriptionKey: message])
    }

    /// Files takes errors from its own domain and Cocoa's only.
    private static func files(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == NSFileProviderErrorDomain || ns.domain == NSCocoaErrorDomain { return error }
        if error is FilesSource.NotFolder { return NSFileProviderError(.noSuchItem) }
        return NSError(domain: NSCocoaErrorDomain, code: NSXPCConnectionReplyInvalid, userInfo: [NSUnderlyingErrorKey: ns])
    }
}
