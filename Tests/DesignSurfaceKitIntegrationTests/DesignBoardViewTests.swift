import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import Testing
import WebKit
@testable import DesignSurfaceKit

/// Boards rendered offscreen by the real runtime in a real `WKWebView` (no window).
@MainActor
@Suite(.mainActorExclusive)
struct DesignBoardViewTests {
    // MARK: Element ids

    nonisolated static let goldenBoards = ["Minimal.dc.html", "Edges.dc.html", "DZStart.dc.html", "NWDesignTool.dc.html", "ThreadRichContent.dc.html"]

    /// Every element the runtime draws carries the tid WebKit's own numbering (the golden file,
    /// which ShepherdProtocol's `DesignTemplate` matches) gives it, with the same tag; and every
    /// element that doesn't depend on data is drawn.
    @Test(arguments: goldenBoards)
    func everyRenderedElementCarriesTheTidTheGoldenFileGivesIt(_ name: String) async throws {
        let source = try String(contentsOf: BoardHarness.designs.appendingPathComponent("boards/\(name)"), encoding: .utf8)
        let data = try Data(contentsOf: BoardHarness.designs.appendingPathComponent("element-ids.json"))
        let boards = try #require((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["boards"] as? [String: [String]])
        let golden = try #require(boards[name])
        let template = try #require(DesignTemplate(board: source))
        #expect(template.elements.map { "\($0.tid):" + $0.path.map(String.init).joined(separator: "/") + " \($0.name)" } == golden)

        let harness = try BoardHarness(files: [name: source])
        let view = try harness.view(name, size: CGSize(width: 1600, height: 1200))
        try await view.load()

        var drawn: [Int: Set<String>] = [:]
        for entry in try await harness.stamped(view) {
            let parts = entry.split(separator: " ")
            let tid = try #require(Int(parts[0]))
            drawn[tid, default: []].insert(String(parts[1]))
        }
        for (tid, tags) in drawn {
            #expect(tid < template.elements.count, "\(name): tid \(tid) is past the template")
            if tid < template.elements.count {
                #expect(tags == [template.elements[tid].name], "\(name): tid \(tid) is a \(template.elements[tid].name), drawn as \(tags)")
            }
        }

        let structural: Set<String> = ["helmet", "sc-if", "sc-for", "dc-import"]
        func dependsOnData(_ element: DesignTemplateElement) -> Bool {
            var parent = element.parent
            while let tid = parent {
                if ["sc-if", "sc-for", "dc-import"].contains(template.elements[tid].name) { return true }
                parent = template.elements[tid].parent
            }
            return false
        }
        let always = template.elements.filter { !structural.contains($0.name) && !dependsOnData($0) }.map(\.tid)
        #expect(Set(always).subtracting(drawn.keys).isEmpty, "\(name): not drawn: \(Set(always).subtracting(drawn.keys).sorted())")
    }

    // MARK: Rendering

    @Test func loopsConditionalsImportsAndHandlersRenderFromRenderVals() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        let size = try await view.load()
        #expect(size == CGSize(width: 400, height: 300))
        #expect(harness.events.first == .booted(size: CGSize(width: 400, height: 300), preview: CGSize(width: 400, height: 300)))

        #expect(try await harness.text(view, "return document.title") == "Checkout")
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Checkout")
        #expect(try await harness.text(view, """
            return Array.from(document.querySelectorAll('.row')).map(e => e.textContent + '|' + e.dataset.index).join(',')
            """) == "First · 0|0,Second · 1|1,Third · 2|2")
        #expect(try await harness.text(view, """
            return [!!document.getElementById('open'), !!document.getElementById('closed')].join(',')
            """) == "true,false")
        #expect(try await harness.text(view, """
            const root = document.getElementById('root');
            return [root.className, getComputedStyle(root).backgroundColor, getComputedStyle(root).color].join('|')
            """) == "board wide|rgb(10, 20, 30)|rgb(250, 250, 250)")
        #expect(try await harness.text(view, "return document.getElementById('field').value") == "typed")
        #expect(try await harness.text(view, "return document.querySelector('svg path').getAttribute('stroke-width')") == "2")

        // An imported board renders inline with its props, carrying the tid of its <dc-import>.
        let template = try #require(DesignTemplate(board: harness.source("Main.dc.html")))
        let importTid = try #require(template.elements.first { $0.name == "dc-import" }).tid
        #expect(try await harness.text(view, """
            return Array.from(document.querySelectorAll('.card')).map(e =>
              [e.textContent, getComputedStyle(e).color, getComputedStyle(e).fontWeight,
               e.getAttribute('data-dc-owner'), e.querySelector('span').getAttribute('data-dc-owner'),
               e.hasAttribute('data-dc-tid')].join('|')).join(',')
            """) == "A|rgb(250, 250, 250)|600|\(importTid)|\(importTid)|false,B|rgb(250, 250, 250)|600|\(importTid)|\(importTid)|false")

        // Handlers bound from renderVals() run, and setState re-renders.
        // Each click is its own task, as a person's are: React applies a click's update before the next.
        _ = try await harness.page(view, "document.getElementById('count').click()")
        _ = try await harness.page(view, "document.getElementById('count').click()")
        #expect(try await harness.text(view, "return document.getElementById('count').textContent") == "Clicked 2")
        #expect(harness.problems.isEmpty)
    }

    @Test func missingValuesRenderTheirHints() async throws {
        let board = """
            <!doctype html><html><head><script src="./support.js"></script></head><body>
            <x-dc><div style="width: 200px; height: 100px">
            <sc-for list="{{rows}}" as="row" hint-placeholder-count="3"><p class="row">{{row.label}}</p></sc-for>
            <sc-if value="{{ready}}" hint-placeholder-val="{{ true }}"><p id="ready">Ready</p></sc-if>
            <sc-if value="{{gone}}"><p id="gone">Gone</p></sc-if>
            <span id="expression">[{{ a + b }}]</span>
            </div></x-dc>
            </body></html>
            """
        let harness = try BoardHarness(files: ["Streaming.dc.html": board])
        let view = try harness.view("Streaming.dc.html", size: CGSize(width: 200, height: 100))
        try await view.load()
        #expect(try await harness.text(view, """
            return [document.querySelectorAll('.row').length, !!document.getElementById('ready'),
                    !!document.getElementById('gone'), document.getElementById('expression').textContent].join(',')
            """) == "3,true,false,[]")
    }

    // MARK: Live reload

    @Test func replacingTheSourceReRendersInPlaceAndKeepsState() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        _ = try await harness.page(view, "window.__marker = 'kept'; document.getElementById('count').click()")
        _ = try await harness.page(view, "document.getElementById('count').click()")

        // The template changes: the same logic keeps its state.
        var source = try harness.source("Main.dc.html")
        source = source.replacingOccurrences(of: "<h1 id=\"title\"", with: "<h2 id=\"subtitle\">Now</h2>\n<h1 id=\"title\"")
        try await view.replaceSource(source)
        #expect(try await harness.text(view, "return document.getElementById('subtitle').textContent") == "Now")
        #expect(try await harness.text(view, "return document.getElementById('count').textContent") == "Clicked 2")

        // The logic changes: its state carries over.
        source = source.replacingOccurrences(of: "title: 'Checkout'", with: "title: 'Payment'")
        try await view.replaceSource(source)
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Payment")
        #expect(try await harness.text(view, "return document.getElementById('count').textContent") == "Clicked 2")

        // Logic that doesn't compile is refused, and the board keeps what it showed.
        await #expect(throws: DesignBoardError.self) {
            try await view.replaceSource(source.replacingOccurrences(of: "renderVals() {", with: "renderVals() {{"))
        }
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Payment")

        #expect(try await harness.text(view, "return window.__marker") == "kept")
        #expect(view.navigationsStarted == 1)
    }

    // MARK: The sandbox

    @Test func aBoardReachesOnlyItsOwnDesign() async throws {
        let harness = try BoardHarness()
        try Data("secret".utf8).write(to: harness.folder.appendingPathComponent("secret.txt"))
        let assets = harness.folder.appendingPathComponent("assets", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        try Data([0x89, 0x50, 0x4E, 0x47]).write(to: assets.appendingPathComponent("abc123.png"))
        try FileManager.default.createSymbolicLink(atPath: harness.project.appendingPathComponent("escape.txt").path,
                                                   withDestinationPath: "../secret.txt")
        let view = try harness.view("Main.dc.html")
        try await view.load()

        let reached = try await harness.text(view, """
            const probe = async (url) => { try { return String((await fetch(url)).status); } catch (e) { return 'blocked'; } };
            const image = (url) => new Promise(resolve => {
              const i = new Image(); i.onload = () => resolve('loaded'); i.onerror = () => resolve('blocked'); i.src = url;
            });
            return [
              await probe('/project/canvas.json'), await probe('/project/support.js'), await probe('/_blob/abc123'),
              await probe('/secret.txt'), await probe('/project/escape.txt'), await probe('/project/%2E%2E/secret.txt'),
              await probe('/project/Missing.dc.html'), await probe('https://example.com/'),
              await image('https://example.com/x.png'), String(window.open('https://example.com/') === null),
              typeof (window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.shepherdDesign)
            ].join(',');
            """)
        // The last: the bridge's message handler lives only in Shepherd's content world.
        #expect(reached == "200,200,200,404,404,404,404,blocked,blocked,true,undefined")

        // No navigation leaves the board: another site is refused, and an in-project link is
        // handed to the host instead.
        _ = try await harness.page(view, "location.href = 'https://example.com/'")
        try await eventuallyOnMain("the navigation to be refused") { view.navigationsRefused >= 1 }
        _ = try await harness.page(view, "document.getElementById('next').click()")
        try await eventuallyOnMain("the link to reach the host") { harness.events.contains(.link(DesignPath("Next.dc.html")!)) }
        // A leading `/` is the canvas root.
        _ = try await harness.page(view, "document.getElementById('rooted').click()")
        try await eventuallyOnMain("the rooted link to reach the host") { harness.events.contains(.link(DesignPath("flows/Cart.dc.html")!)) }
        #expect(view.navigationsStarted == 1)
        #expect(view.webView.url == harness.surface.url(for: DesignPath("Main.dc.html")!))
        #expect(try await harness.text(view, "return document.getElementById('title').textContent") == "Checkout")
    }

    // MARK: Snapshots

    @Test func aSnapshotHasTheBoardsSize() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        try await view.load()
        let image = try await view.snapshot()
        let scale = image.width / 400
        #expect(scale >= 1)
        #expect(image.width == 400 * scale && image.height == 300 * scale)
        // The board's own background, near its bottom right corner.
        let pixel = try #require(Self.pixel(of: image, x: 395 * scale, y: 295 * scale))
        #expect(abs(pixel.red - 10) <= 3 && abs(pixel.green - 20) <= 3 && abs(pixel.blue - 30) <= 3, "\(pixel)")
    }

    /// At the canvas's zoom the view is smaller, but the page lays out at the board's size and a
    /// snapshot still covers the whole board.
    @Test func aZoomedBoardLaysOutAtItsOwnSize() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Main.dc.html")
        view.zoom = 0.5
        #expect(view.frame.size == CGSize(width: 200, height: 150))
        let drawn = try await view.load()
        #expect(drawn == CGSize(width: 400, height: 300))
        let image = try await view.snapshot()
        let scale = image.width / 400
        #expect(scale >= 1)
        #expect(image.width == 400 * scale && image.height == 300 * scale)
        let pixel = try #require(Self.pixel(of: image, x: 395 * scale, y: 295 * scale))
        #expect(abs(pixel.red - 10) <= 3 && abs(pixel.green - 20) <= 3 && abs(pixel.blue - 30) <= 3, "\(pixel)")
        let small = try await view.snapshot(width: 100)
        #expect(small.width == 100 * scale && small.height == 75 * scale)
    }

    // MARK: Failures

    @Test func aMissingBoardFailsToLoad() async throws {
        let harness = try BoardHarness()
        let view = try harness.view("Nowhere.dc.html")
        do {
            try await view.load()
            Issue.record("a missing board loaded")
        } catch {
            guard case DesignBoardError.loadFailed = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func aBoardWithoutTheRuntimeLineFailsToLoad() async throws {
        let harness = try BoardHarness(files: ["Bare.dc.html": "<!doctype html><html><body><x-dc><div>{{x}}</div></x-dc></body></html>"])
        let view = try harness.view("Bare.dc.html")
        await #expect(throws: DesignBoardError.noRuntime) { try await view.load() }
    }

    @Test func brokenLogicIsReportedAndTheMarkupStillRenders() async throws {
        let board = """
            <!doctype html><html><head><script src="./support.js"></script></head><body>
            <x-dc><div id="root" style="width: 200px; height: 100px">Still here {{missing}}</div></x-dc>
            <script type="text/x-dc" data-dc-script>
            class Component extends DCLogic { renderVals() { return { ; } }
            </script>
            </body></html>
            """
        let harness = try BoardHarness(files: ["Broken.dc.html": board])
        let view = try harness.view("Broken.dc.html", size: CGSize(width: 200, height: 100))
        try await view.load()
        #expect(harness.problems.contains { $0.phase == "logic" })
        #expect(try await harness.text(view, "return document.getElementById('root').textContent") == "Still here ")
    }

    @Test func aRenderErrorIsReported() async throws {
        let board = """
            <!doctype html><html><head><script src="./support.js"></script></head><body>
            <x-dc><div style="width: 200px; height: 100px">{{x}}</div></x-dc>
            <script type="text/x-dc" data-dc-script>
            class Component extends DCLogic { renderVals() { throw new Error('no values today'); } }
            </script>
            </body></html>
            """
        let harness = try BoardHarness(files: ["Throws.dc.html": board])
        let view = try harness.view("Throws.dc.html", size: CGSize(width: 200, height: 100))
        try await view.load()
        #expect(harness.problems.contains { $0.phase == "render" && $0.message.contains("no values today") })
    }

    // MARK: Helpers

    struct Pixel: CustomStringConvertible {
        var red: Int, green: Int, blue: Int
        var description: String { "rgb(\(red), \(green), \(blue))" }
    }

    static func pixel(of image: CGImage, x: Int, y: Int) -> Pixel? {
        var bytes = [UInt8](repeating: 0, count: 4)
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return Pixel(red: Int(bytes[0]), green: Int(bytes[1]), blue: Int(bytes[2]))
    }
}
