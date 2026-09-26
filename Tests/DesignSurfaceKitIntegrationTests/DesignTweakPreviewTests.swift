import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// Tweak in a live board (docs/designs.md › Tweak): the props canvas.json's `tweaks` holds reach
/// the board at boot and with a reload, and a preview changes what is drawn in place, without a
/// navigation, until it is kept or put back.
@MainActor
@Suite(.mainActorExclusive)
struct DesignTweakPreviewTests {
    static let board = """
    <!doctype html>
    <html lang="en">
    <head><meta charset="utf-8"><title>Tweak</title><script src="./support.js"></script></head>
    <body>
    <x-dc>
    <div id="root" style="width: 400px; height: 300px; padding: 4px; background: #ffffff">
    <sc-for list="{{ rows }}" as="row"><div class="row" style="padding: 2px">{{ row }}</div></sc-for>
    <h1 id="title" style="margin: 0">{{ title }}</h1>
    </div>
    </x-dc>
    <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300},"title":{"editor":"text","default":"Hello"},"count":{"editor":"int","default":2}}'>
    class Component extends DCLogic {
      renderVals() {
        const count = this.props.count ?? 2;
        return { title: this.props.title ?? 'Hello', rows: Array.from({ length: count }, (_, i) => 'Row ' + i) };
      }
    }
    </script>
    </body>
    </html>
    """

    static func canvas(_ tweaks: String) -> String {
        #"{"v":3,"boards":{"Main.dc.html":{"x":0,"y":0,"w":400,"h":300}},"order":["Main.dc.html"],"tweaks":{"Main.dc.html":"# + tweaks + "}}"
    }

    @Test func canvasTweaksAreTheBoardsPropsAtBootAndOnReload() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board, "canvas.json": Self.canvas(#"{"title":"Tweaked","count":3}"#)])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Tweaked")
        #expect(try await harness.page(view, "return document.querySelectorAll('.row').length") as? Int == 3)

        try await view.replaceSource(Self.board, props: #"{"count":1}"#)
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Hello", "a prop left out falls back")
        #expect(try await harness.page(view, "return document.querySelectorAll('.row').length") as? Int == 1)
        #expect(view.navigationsStarted == 1)
    }

    @Test func aBoardWithoutTweaksDrawsItsDefaults() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Hello")
    }

    /// A style preview reaches every rendering of an element (a loop draws one many times), keeps
    /// what the source says elsewhere, and is put back exactly.
    @Test func aStylePreviewChangesTheDrawnElementsAndIsPutBack() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let template = try #require(DesignTemplate(board: Self.board))
        let row = try #require(template.elements.first { $0.name == "div" && $0.tid > 0 }).tid
        let root = 0
        let paddings = "return Array.from(document.querySelectorAll('.row')).map(e => getComputedStyle(e).paddingTop).join(',')"

        let changed = await view.previewStyle([row: ["padding": "12px"], root: ["background": "#0f766e", "padding": nil]])
        #expect(changed == 3)
        #expect(try await harness.text(view, paddings) == "12px,12px")
        #expect(try await harness.text(view, "return getComputedStyle(document.getElementById('root')).backgroundColor") == "rgb(15, 118, 110)")
        #expect(try await harness.text(view, "return document.getElementById('root').style.padding") == "")

        await view.endPreview()
        #expect(try await harness.text(view, paddings) == "2px,2px")
        #expect(try await harness.text(view, """
            const root = getComputedStyle(document.getElementById('root'));
            return [root.paddingTop, root.backgroundColor].join('|')
            """) == "4px|rgb(255, 255, 255)")
        #expect(view.navigationsStarted == 1)
    }

    /// Kept: the written source reloads in place and what it says is drawn.
    @Test func aKeptPreviewIsWhatTheReloadedSourceDraws() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        _ = await view.previewStyle([0: ["padding": "24px"]])
        let written = try DesignStyleEdit.apply(["padding": "24px"], to: 0, in: Self.board)
        try await view.replaceSource(written)
        await view.endPreview()
        #expect(try await harness.text(view, "return getComputedStyle(document.getElementById('root')).paddingTop") == "24px")
    }

    @Test func aPropsPreviewDrawsAtOnce() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        #expect(await view.previewProps(#"{"count":4,"title":"Live"}"#))
        #expect(try await harness.page(view, "return document.querySelectorAll('.row').length") as? Int == 4)
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Live")
    }

    @Test func aValueATweakNeverWritesIsNotPreviewed() async throws {
        let harness = try BoardHarness(files: ["Main.dc.html": Self.board])
        let view = try harness.view("Main.dc.html")
        try await view.load()
        #expect(await view.previewStyle([0: ["padding": "1px; background: url(x)"]]) == 0)
        #expect(try await harness.text(view, "return getComputedStyle(document.getElementById('root')).paddingTop") == "4px")
    }
}
