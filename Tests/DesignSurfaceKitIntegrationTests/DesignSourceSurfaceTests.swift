import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// A remote design's files as this device's cache holds them: no folder, only what it answers.
private final class SourcedFiles: DesignFileSource, @unchecked Sendable {
    let files: [String: Data]
    let blobs: [String: (name: String, data: Data)]
    private let lock = NSLock()
    private var asked: [String] = []

    init(files: [String: Data], blobs: [String: (name: String, data: Data)]) {
        self.files = files
        self.blobs = blobs
    }

    var requested: [String] { lock.withLock { asked } }

    func projectFile(_ path: String) async -> Data? {
        lock.withLock { asked.append(path) }
        return files[path]
    }

    func blob(_ id: String) async -> (name: String, data: Data)? {
        lock.withLock { asked.append("_blob/" + id) }
        return blobs[id]
    }
}

/// The same canvas renders a remote design: a board, the board it imports, a stylesheet and an
/// upload all come from the file source, and the runtime is the device's own.
@Suite(.mainActorExclusive)
@MainActor
struct DesignSourceSurfaceTests {
    @Test func aBoardRendersFromAFileSource() async throws {
        var files: [String: Data] = [:]
        for name in ["Main.dc.html", "Card.dc.html"] {
            files[name] = try Data(contentsOf: BoardHarness.fixtures.appendingPathComponent(name))
        }
        files["styles/remote.css"] = Data("#root { outline-color: rgb(1, 2, 3); }".utf8)
        let main = String(decoding: try #require(files["Main.dc.html"]), as: UTF8.self)
        // The board links the stylesheet and shows an upload, as a remote design's would.
        files["Main.dc.html"] = Data(main.replacingOccurrences(of: "</head>", with: """
            <link rel="stylesheet" href="./styles/remote.css"></head>
            """).replacingOccurrences(of: "</x-dc>", with: #"<img id="shot" style="position: absolute; left: 0; top: 0" src="/_blob/3f2a91c0"></x-dc>"#).utf8)
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="))
        let source = SourcedFiles(files: files, blobs: ["3f2a91c0": ("3f2a91c0.png", png)])
        let surface = DesignSurface(designID: DesignID(), source: source, network: .none)
        let view = DesignBoardView(surface: surface, board: try #require(DesignPath("Main.dc.html")), size: CGSize(width: 400, height: 300))

        #expect(try await view.load() == CGSize(width: 400, height: 300))
        #expect(surface.folder == nil)
        func text(_ body: String) async throws -> String? {
            try await view.webView.callAsyncJavaScript(body, arguments: [:], in: nil, contentWorld: .page) as? String
        }
        #expect(try await text("return document.title") == "Checkout")
        #expect(try await text("return Array.from(document.querySelectorAll('.card')).map(e => e.textContent).join(',')") == "A,B",
                "the imported board came from the source too")
        #expect(try await text("return getComputedStyle(document.getElementById('root')).outlineColor") == "rgb(1, 2, 3)")
        #expect(try await text("""
            const img = document.getElementById('shot');
            if (!img.complete) await new Promise(done => { img.onload = done; img.onerror = done; });
            return String(img.naturalWidth)
            """) == "1")
        #expect(source.requested.contains("Card.dc.html"))
        #expect(source.requested.contains("_blob/3f2a91c0"))
        #expect(!source.requested.contains("support.js"), "the runtime is served by the device, never asked of the source")
    }
}
