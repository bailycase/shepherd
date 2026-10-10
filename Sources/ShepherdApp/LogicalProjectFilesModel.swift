import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol

/// The Files tab's state: one directory of the Project owner's private folder, and at most one file previewed as data. Every
/// answer is checked against the request that asked for it, so a slow reply for a folder the person already left never replaces
/// the one they are looking at.
@MainActor
@Observable
final class LogicalProjectFilesModel {
    enum Listing: Equatable {
        case loading
        case listed(LogicalProjectFileListing)
        case failed(String)
    }

    enum Preview: Equatable {
        case loading(name: String)
        case text(name: String, text: String)
        case image(name: String, data: Data)
        case failed(name: String, message: String)

        var name: String {
            switch self {
            case .loading(let name), .text(let name, _), .image(let name, _), .failed(let name, _): name
            }
        }
    }

    private(set) var ref: LogicalProjectRef?
    /// The owner-relative directory shown ("" is the Project's root).
    private(set) var path = ""
    private(set) var listing: Listing = .loading
    private(set) var preview: Preview?
    @ObservationIgnored private var serial = 0

    /// Lists `path` (the root by default) of `ref`'s folder on its owner.
    func open(_ ref: LogicalProjectRef, path: String = "", via model: LogicalProjectsModel) async {
        self.ref = ref
        self.path = path
        preview = nil
        listing = .loading
        serial += 1
        let mine = serial
        do {
            let result = try await model.files(ref, path: path)
            guard mine == serial, self.ref == ref else { return }
            listing = .listed(result)
        } catch {
            guard mine == serial, self.ref == ref else { return }
            listing = .failed(LogicalProjectsModel.filesMessage(error))
        }
    }

    /// Previews one file as data: never opened, launched or rendered as anything active.
    /// `ref` names the Project when no listing opened it yet (a card's chip before the tab was up).
    func read(_ entry: LogicalProjectFileEntry, in project: LogicalProjectRef? = nil, via model: LogicalProjectsModel) async {
        if let project, ref == nil { ref = project }
        guard let ref else { return }
        preview = .loading(name: entry.name)
        serial += 1
        let mine = serial
        do {
            let file = try await model.read(ref, path: entry.relativePath)
            guard mine == serial, self.ref == ref else { return }
            if file.mimeType.hasPrefix("image/") {
                preview = NSImage(data: file.data) == nil
                    ? .failed(name: entry.name, message: "This image can't be shown.")
                    : .image(name: entry.name, data: file.data)
            } else if let text = String(data: file.data, encoding: .utf8) {
                preview = .text(name: entry.name, text: text)
            } else {
                preview = .failed(name: entry.name, message: "This file can't be previewed.")
            }
        } catch {
            guard mine == serial, self.ref == ref else { return }
            preview = .failed(name: entry.name, message: LogicalProjectsModel.filesMessage(error))
        }
    }

    func closePreview() {
        serial += 1
        preview = nil
    }

    /// The folder above the one shown; nil at the root.
    var parent: String? {
        guard !path.isEmpty else { return nil }
        let up = (path as NSString).deletingLastPathComponent
        return up == "." || up == "/" ? "" : up
    }

    /// "1.4 KB", "92 bytes".
    static func sizeText(_ bytes: Int64) -> String {
        bytes < 1024 ? "\(bytes) bytes" : ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
