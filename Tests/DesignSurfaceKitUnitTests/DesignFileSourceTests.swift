import Foundation
import Testing
import ShepherdProtocol
@testable import DesignSurfaceKit

/// A design's files as a remote host's cache would hand them over.
private struct CachedFiles: DesignFileSource {
    var files: [String: Data]
    var blobs: [String: (name: String, data: Data)]

    func projectFile(_ path: String) async -> Data? { files[path] }
    func blob(_ id: String) async -> (name: String, data: Data)? { blobs[id] }
}

/// A surface over a file source serves what the source answers, by the same routes: the runtime
/// at any `support.js` (whatever the source holds there), project files, and uploads for their id.
@Suite struct DesignFileSourceTests {
    fileprivate static let source = CachedFiles(
        files: ["A.dc.html": Data("<x-dc>A</x-dc>".utf8), "styles/app.css": Data(":root{}".utf8),
                "support.js": Data("window.stolen = 1".utf8)],
        blobs: ["3f2a91c0": ("3f2a91c0.png", Data([0x89, 0x50])), "other": ("elsewhere.png", Data([1]))])

    @Test func projectFilesAndUploadsComeFromTheSource() async throws {
        let board = try #require(await DesignSchemeHandler.body(.project(["A.dc.html"]), files: .source(Self.source)))
        #expect(board.data == Data("<x-dc>A</x-dc>".utf8))
        #expect(board.type == "text/html; charset=utf-8")
        let css = try #require(await DesignSchemeHandler.body(.project(["styles", "app.css"]), files: .source(Self.source)))
        #expect(css.type == "text/css; charset=utf-8")
        let blob = try #require(await DesignSchemeHandler.body(.blob("3f2a91c0"), files: .source(Self.source)))
        #expect(blob.data == Data([0x89, 0x50]) && blob.type == "image/png")
    }

    @Test func theRuntimeIsShepherdsWhateverTheSourceHolds() async throws {
        let runtime = try #require(await DesignSchemeHandler.body(.runtime, files: .source(Self.source)))
        #expect(runtime.data != Data("window.stolen = 1".utf8))
        #expect(runtime.data == DesignRuntime.supportScript)
    }

    @Test func whatTheSourceLacksOrMisnamesIsNotServed() async {
        #expect(await DesignSchemeHandler.body(.project(["nothing.css"]), files: .source(Self.source)) == nil)
        #expect(await DesignSchemeHandler.body(.blob("other"), files: .source(Self.source)) == nil, "an upload named for another id")
        #expect(await DesignSchemeHandler.body(.refused, files: .source(Self.source)) == nil)
    }
}
