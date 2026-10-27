import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A remote thread's Files tree: lazy folders, the filter over expanded ones, and one file read in place.
@Suite("Thread files model")
@MainActor
struct ThreadFilesModelTests {
    nonisolated static let tree: [String: ThreadFileListing] = [
        "": ThreadFileListing(entries: [ThreadFileEntry(name: "Widgets", kind: .directory), ThreadFileEntry(name: "render.py", kind: .file, size: 40)]),
        "Widgets": ThreadFileListing(entries: [ThreadFileEntry(name: "NeedsYouWidget.swift", kind: .file, size: 900),
                                               ThreadFileEntry(name: "Count.swift", kind: .file, size: 10)], truncated: true),
    ]

    static func model(read: @escaping ThreadFilesModel.Read = { _ in Data("let x = 1\n".utf8) }) -> ThreadFilesModel {
        ThreadFilesModel(list: { path, _ in
            guard let listing = tree[path] else { throw RemoteHostClientError.rejected(code: "not_found", message: "No such file or folder") }
            return listing
        }, read: read)
    }

    @Test func foldersLoadWhenOpenedAndTheFilterKeepsFolders() async {
        let model = Self.model()
        await model.loadIfNeeded()
        #expect(model.phase == .loaded)
        #expect(model.rows.map(\.id) == ["Widgets", "render.py"])

        await model.toggle("Widgets")
        #expect(model.rows.map(\.id) == ["Widgets", "Widgets/NeedsYouWidget.swift", "Widgets/Count.swift", "Widgets/…", "render.py"])
        #expect(model.rows[1].depth == 1 && model.rows[3].kind == .note)
        #expect(model.rows[0].kind == .folder(expanded: true, loading: false))

        model.filter = "needs"
        #expect(model.rows.map(\.id) == ["Widgets", "Widgets/NeedsYouWidget.swift", "Widgets/…"])
        model.filter = ""
        await model.toggle("Widgets")
        #expect(model.rows.map(\.id) == ["Widgets", "render.py"])
    }

    @Test func aFileOpensInPlaceAndAFailureSaysWhy() async {
        let model = Self.model(read: { path in
            if path == "blob" { throw RemoteHostClientError.rejected(code: "binary", message: "Binary file (not UTF-8 text)") }
            return Data("let x = 1\n".utf8)
        })
        await model.open("render.py")
        #expect(model.openPath == "render.py" && model.content == .text("let x = 1\n"))
        await model.open("blob")
        #expect(model.content == .failed("Binary file (not UTF-8 text)"))
        model.close()
        #expect(model.openPath == nil)
    }

    @Test func aFailedRootLoadsAgain() async {
        let model = ThreadFilesModel(list: { _, _ in throw RemoteHostClientError.rejected(code: "update_required", message: "Files needs a newer Shepherd on the host.") },
                                     read: { _ in Data() })
        await model.loadIfNeeded()
        #expect(model.phase == .failed("Files needs a newer Shepherd on the host."))
    }
}
