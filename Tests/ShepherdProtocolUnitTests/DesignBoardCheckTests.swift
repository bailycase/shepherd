import Foundation
import Testing
import ShepherdProtocol

/// What a board's source must pass before it is written.
@Suite("Design board checks")
struct DesignBoardCheckTests {
    static func board(head: String = DesignBoardCheck.supportScript, root: String = #"<div style="width: 390px; height: 844px">Hi</div>"#,
                      script: String = "", props: String = #"{"$preview":{"width":390,"height":844}}"#) -> String {
        """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>T</title>\(head)</head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        \(root)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='\(props)'>
        class Component extends DCLogic { renderVals() { \(script) return {}; } }
        </script>
        </body>
        </html>
        """
    }

    @Test func aWellFormedBoardPasses() throws {
        #expect(try DesignBoardCheck.check(Self.board()) == [])
    }

    @Test func everyFixtureBoardPasses() throws {
        let boards = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Designs/boards")
        for name in try FileManager.default.contentsOfDirectory(atPath: boards.path).sorted() where name.hasSuffix(".dc.html") {
            let source = try String(contentsOf: boards.appendingPathComponent(name), encoding: .utf8)
            #expect(throws: Never.self, "\(name)") { try DesignBoardCheck.check(source) }
        }
    }

    struct Refused: Sendable, CustomTestStringConvertible {
        let name: String
        let source: String
        let refusal: DesignBoardCheck.Refusal
        var testDescription: String { name }
    }

    @Test(arguments: [
        Refused(name: "no support.js line", source: board(head: #"<script src="support.js"></script>"#), refusal: .missingSupportScript),
        Refused(name: "an iframe", source: board(root: #"<div style="width: 390px; height: 844px"><iframe src="x"></iframe></div>"#), refusal: .forbiddenTag("iframe")),
        Refused(name: "an object", source: board(root: #"<div style="width: 390px; height: 844px"><OBJECT data="x"></OBJECT></div>"#), refusal: .forbiddenTag("object")),
        Refused(name: "an embed", source: board(root: #"<div style="width: 390px; height: 844px"><embed/></div>"#), refusal: .forbiddenTag("embed")),
        Refused(name: "a data: image", source: board(root: #"<div style="width: 390px; height: 844px"><img src="data:image/png;base64,AAAA"></div>"#), refusal: .dataURI),
        Refused(name: "a data: url in CSS", source: board(root: #"<div style="width: 390px; height: 844px; background: url('data:image/svg+xml,x')"></div>"#), refusal: .dataURI),
        Refused(name: "a data: url set by script", source: board(script: #"img.src = "data:text/html,x";"#), refusal: .dataURI),
        Refused(name: "no template", source: board().replacingOccurrences(of: "<x-dc>", with: "<div>").replacingOccurrences(of: "</x-dc>", with: "</div>"), refusal: .missingTemplate),
        Refused(name: "a root sized unlike $preview", source: board(root: #"<div style="width: 1280px; height: 844px"></div>"#),
                refusal: .sizeMismatch(root: .init(width: 1280, height: 844), preview: .init(width: 390, height: 844))),
        Refused(name: "too large", source: board(root: "<div>" + String(repeating: "x", count: DesignBoardCheck.maxBytes) + "</div>"),
                refusal: .tooLarge(bytes: board(root: "<div>" + String(repeating: "x", count: DesignBoardCheck.maxBytes) + "</div>").utf8.count)),
    ])
    func aBoardThatBreaksARuleIsRefused(_ refused: Refused) {
        #expect(throws: refused.refusal) { try DesignBoardCheck.check(refused.source) }
    }

    @Test(arguments: [
        (board(script: "el.innerHTML = '<b>x</b>';"), [DesignBoardCheck.Warning.innerHTML]),
        (board(script: "window.addEventListener('keydown', go);"), [.globalKeyHandler]),
        (board(script: "document.onkeyup = go;"), [.globalKeyHandler]),
        (board(props: #"{"accent":{"editor":"color"}}"#), [.missingPreview]),
    ])
    func aBoardThatPassesCanStillWarn(_ source: String, _ warnings: [DesignBoardCheck.Warning]) throws {
        #expect(try DesignBoardCheck.check(source) == warnings)
    }

    /// What reads like a forbidden thing but isn't one passes.
    @Test(arguments: [
        board(script: "const meta = { data: items };"),
        board(root: #"<div style="width: 390px; height: 844px"><p>Embedded objects are <b>data: sets</b></p></div>"#),
        board(root: #"<div style="width: 390px; height: 844px"><objectives></objectives></div>"#),
        board(root: #"<div style="padding: 8px">fluid root</div>"#),
    ])
    func aLookAlikePasses(_ source: String) {
        #expect(throws: Never.self) { try DesignBoardCheck.check(source) }
    }

    @Test func thePreviewSizeReadsThroughHTMLEscapes() {
        let source = Self.board(props: #"{"title":{"editor":"text","default":"Tom &amp; Jerry&#39;s"},"$preview":{"width":1440,"height":900}}"#)
        #expect(DesignBoardCheck.previewSize(of: source) == .init(width: 1440, height: 900))
    }
}
