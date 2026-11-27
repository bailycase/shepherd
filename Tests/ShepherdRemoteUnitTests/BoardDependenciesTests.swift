import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A finished picture goes stale when what its board reads from outside its file changes: a design
/// system's stylesheet or component, an imported piece. The digest of those files is in the picture's
/// key, so the boards that read a changed file draw again and no other board does.
@Suite struct BoardDependenciesTests {
    /// A design as its index lists it: files by path with their text, and each board's picture in a cache.
    private struct Design {
        var files: [String: String]

        var infos: [RemoteDesignFileInfo] {
            files.map { RemoteDesignFileInfo(path: $0.key, sha256: RemoteDesignCache.sha256(Data($0.value.utf8)), size: $0.value.utf8.count) }
        }

        func read(_ sha: String) -> Data? {
            files.values.first { RemoteDesignCache.sha256(Data($0.utf8)) == sha }.map { Data($0.utf8) }
        }

        func digests(_ boards: [String]) -> [String: String] {
            let result = BoardDependencies().digests(for: boards.map { DesignPath($0)! }, files: infos, read: read)
            return Dictionary(uniqueKeysWithValues: result.map { ($0.key.rawValue, $0.value) })
        }

        func key(_ board: String, _ digests: [String: String]) -> BoardPictureKey {
            BoardPictureKey(content: RemoteDesignCache.sha256(Data(files[board]!.utf8)), dependencies: digests[board] ?? "?",
                            board: CGSize(width: 1280, height: 800), width: 160, scale: 2, renderer: "1")
        }
    }

    private static func board(_ body: String) -> String { "<!doctype html><x-dc>\(body)</x-dc>" }

    private let boards = ["A.dc.html", "B.dc.html", "C.dc.html", "D.dc.html", "flows/E.dc.html", "F.dc.html"]

    private func design() -> Design {
        Design(files: [
            // A links the system's stylesheet; B reads nothing outside its file.
            "A.dc.html": Self.board(#"<link rel="stylesheet" href="ds/acme/tokens.css"><p>A</p>"#),
            "B.dc.html": Self.board("<p>B</p>"),
            // C imports a piece; D imports nothing; E (in a folder) imports a system component; F imports C (so Card through C).
            "C.dc.html": Self.board(#"<dc-import name="Card"></dc-import>"#),
            "D.dc.html": Self.board("<p>D</p>"),
            "flows/E.dc.html": Self.board(#"<dc-import name="ds/acme/Button"></dc-import>"#),
            "F.dc.html": Self.board(#"<dc-import name="C"></dc-import>"#),
            "Card.dc.html": Self.board("<p>Card</p>"),
            "ds/acme/Button.dc.html": Self.board(#"<button class="b">Go</button>"#),
            "ds/acme/tokens.css": ":root{--accent:#4f46e5} @import 'base.css';",
            "ds/acme/base.css": "body{margin:0}",
            "ds/acme/other.css": ".unused{color:red}",
        ])
    }

    /// Whether a board's picture is kept under its key now: false means it draws again.
    private func kept(_ cache: BoardPictureCache, _ design: Design, _ board: String) -> Bool {
        cache.contains(design.key(board, design.digests(boards)))
    }

    private func cache() -> BoardPictureCache {
        BoardPictureCache(directory: FileManager.default.temporaryDirectory.appendingPathComponent("bdt-\(UUID().uuidString.prefix(8))"))
    }

    @Test func aBoardThatReadsNothingOutsideItsFileHasNoDigest() {
        let digests = design().digests(boards)
        #expect(digests["B.dc.html"] == "")
        #expect(digests["D.dc.html"] == "")
        #expect(digests["A.dc.html"] != "")
    }

    @Test func aChangedDesignSystemFileDrawsTheBoardsThatReadItAgain() {
        let cache = cache()
        defer { cache.removeAll() }
        var design = design()
        let before = design.digests(boards)
        for board in boards { cache.store(Data(board.utf8), for: design.key(board, before)) }

        // tokens.css changes: A reads it (and base.css through its @import), nothing else does.
        design.files["ds/acme/tokens.css"] = ":root{--accent:#dc2626} @import 'base.css';"
        let after = design.digests(boards)
        #expect(!kept(cache, design, "A.dc.html"))
        for board in boards where board != "A.dc.html" { #expect(kept(cache, design, board), "\(board) keeps its picture") }
        #expect(after["A.dc.html"] != before["A.dc.html"])
    }

    @Test func aFileAStylesheetImportsCountsToo() {
        var design = design()
        let before = design.digests(boards)["A.dc.html"]
        design.files["ds/acme/base.css"] = "body{margin:8px}"
        #expect(design.digests(boards)["A.dc.html"] != before)
    }

    @Test func aFileNoBoardNamesChangesNothing() {
        var design = design()
        let before = design.digests(boards)
        design.files["ds/acme/other.css"] = ".unused{color:blue}"
        design.files["ds/acme/new-icon.svg"] = "<svg/>"
        #expect(design.digests(boards) == before)
    }

    @Test func aChangedImportedPieceDrawsItsImportersAgain() {
        let cache = cache()
        defer { cache.removeAll() }
        var design = design()
        let before = design.digests(boards)
        for board in boards { cache.store(Data(board.utf8), for: design.key(board, before)) }

        design.files["Card.dc.html"] = Self.board("<p>Card, changed</p>")
        // C imports Card, F imports C: both draw again. A, B, D, E don't. (Card itself changed, so it would draw again by its own hash.)
        #expect(!kept(cache, design, "C.dc.html"))
        #expect(!kept(cache, design, "F.dc.html"))
        for board in ["A.dc.html", "B.dc.html", "D.dc.html", "flows/E.dc.html"] { #expect(kept(cache, design, board), "\(board) keeps its picture") }
    }

    @Test func aChangedSystemComponentDrawsTheBoardsThatImportItAgain() {
        let cache = cache()
        defer { cache.removeAll() }
        var design = design()
        let before = design.digests(boards)
        for board in boards { cache.store(Data(board.utf8), for: design.key(board, before)) }

        design.files["ds/acme/Button.dc.html"] = Self.board(#"<button class="b">Go on</button>"#)
        #expect(!kept(cache, design, "flows/E.dc.html"))
        for board in boards where board != "flows/E.dc.html" { #expect(kept(cache, design, board), "\(board) keeps its picture") }
    }

    @Test func aPieceThatAppearsDrawsTheBoardThatNamedItAgain() {
        var design = design()
        design.files["G.dc.html"] = Self.board(#"<dc-import name="Later"></dc-import>"#)
        let before = design.digests(["G.dc.html"])
        design.files["Later.dc.html"] = Self.board("<p>Later</p>")
        #expect(design.digests(["G.dc.html"]) != before)
    }

    @Test func aBoardThatImportsByANameWithAHoleReadsEveryPiece() {
        var design = design()
        design.files["H.dc.html"] = Self.board(#"<dc-import name="{{kind}}"></dc-import>"#)
        let before = design.digests(["H.dc.html"])
        design.files["Card.dc.html"] = Self.board("<p>Card, changed</p>")
        #expect(design.digests(["H.dc.html"]) != before)
    }

    @Test func importsThatCycleEnd() {
        var design = design()
        design.files["P.dc.html"] = Self.board(#"<dc-import name="Q"></dc-import>"#)
        design.files["Q.dc.html"] = Self.board(#"<dc-import name="P"></dc-import>"#)
        #expect(design.digests(["P.dc.html"])["P.dc.html"] != "")
    }

    @Test func theDigestDoesNotDependOnTheOrderFilesAreListed() {
        let design = design()
        let a = BoardDependencies().digests(for: [DesignPath("A.dc.html")!], files: design.infos, read: design.read)
        let b = BoardDependencies().digests(for: [DesignPath("A.dc.html")!], files: design.infos.reversed(), read: design.read)
        #expect(a == b)
    }
}
