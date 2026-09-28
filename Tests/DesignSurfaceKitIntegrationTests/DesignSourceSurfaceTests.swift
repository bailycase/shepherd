import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
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

private final class TweakedRemoteTransport: RemoteDesignTransport, @unchecked Sendable {
    let id = DesignID()
    let path = DesignPath("Main.dc.html")!
    let requested = Locked<[String]>([])
    let board = Data("""
        <html><head><script src="./support.js"></script></head><body>
        <x-dc><div id="value" style="width:400px;height:300px">Pinned rows {{ rows }}</div></x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"rows":{"editor":"int","default":4},"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return { rows: this.props.rows }; } }
        </script></body></html>
        """.utf8)

    func design(_ request: RemoteDesignRequest) async throws -> RemoteDesignResult {
        let sha = RemoteDesignCache.sha256(board)
        switch request {
        case .index:
            var index = DesignIndex(title: "Tweaked", boards: [path: .init(x: 0, y: 0, w: 400, h: 300)], order: [path])
            index = try index.merging(DesignIndex.tweakPatch(path, ["rows": .number(7)]))
            return .index(.init(snapshot: .init(designID: id, revision: 3, index: index, boards: [path: sha]),
                                files: [.init(path: path.rawValue, sha256: sha, size: board.count)]))
        case .boards(_, let paths, _):
            requested.withValue { $0 += paths }
            return .files(.init(designID: id, revision: 3, changed: paths.contains(path.rawValue) ? [.init(path: path.rawValue, sha256: sha, size: board.count, data: board)] : [],
                                unchanged: [], missing: paths.filter { $0 != path.rawValue }))
        default: throw RemoteHostClientError.rejected(code: "unexpected", message: "Unexpected request")
        }
    }
}

/// The same canvas renders a remote design: a board, the board it imports, a stylesheet and an
/// upload all come from the file source, and the runtime is the device's own.
@Suite(.mainActorExclusive)
@MainActor
struct DesignSourceSurfaceTests {
    @Test(arguments: [false, true])
    func freshRemoteViewsReadPersistedTweaksWithoutFetchingCanvasAsABoard(syncFirst: Bool) async throws {
        let transport = TweakedRemoteTransport()
        let source = RemoteDesignSource(key: .init(host: UUID(), design: transport.id), cache: RemoteDesignCache()) { transport }
        if syncFirst { try await source.sync() }
        let surface = DesignSurface(designID: transport.id, source: source, network: .none)
        for _ in 0..<2 {
            let view = DesignBoardView(surface: surface, board: transport.path, size: CGSize(width: 400, height: 300))
            try await view.load()
            let text = try await view.webView.callAsyncJavaScript("return document.getElementById('value').textContent",
                arguments: [:], in: nil, contentWorld: .page) as? String
            #expect(text == "Pinned rows 7")
        }
        #expect(!transport.requested.current.contains("canvas.json"))
    }

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
