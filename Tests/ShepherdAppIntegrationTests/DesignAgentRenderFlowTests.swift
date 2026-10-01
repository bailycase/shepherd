import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// `board_render` end to end (docs/designs.md › Rendering for the agent): a real server hands the
/// board's files to the app, which draws them off screen with the real renderer and answers a picture
/// whose pixels are the board's. The design is never opened: no canvas, no live view.
@Suite("Design agent renders", .mainActorExclusive)
@MainActor
struct DesignAgentRenderFlowTests {
    /// A 400×300 board: red on the left, blue on the right, and a center square whose color is a prop.
    static let board = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Two</title><script src="./support.js"></script></head>
        <body>
        <x-dc>
        <helmet><style>body { margin: 0 }</style></helmet>
        <div style="width: 400px; height: 300px; position: relative; background: #0000ff">
        <div style="position: absolute; left: 0; top: 0; width: 200px; height: 300px; background: #ff0000"></div>
        <div style="position: absolute; left: 150px; top: 100px; width: 100px; height: 100px; background: {{ accent }}"></div>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"accent":{"editor":"color","default":"#00ff00"},"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic {
          renderVals() { return { accent: this.props.accent ?? "#00ff00" }; }
        }
        </script>
        </body>
        </html>
        """

    private struct Workspace {
        let app: AppHarness
        let vm: ShepherdViewModel
        let design: Design
    }

    private func workspace(frame: Bool = true) async throws -> Workspace {
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [Fixture.agent("Thread", in: space)]))
        vm.designNetwork = .none
        let design = Design(name: "Two", createdAt: 1_000)
        _ = try await app.server.createDesign(design)
        _ = try await app.server.writeDesignBoard(design.id, path: try DesignPath.validate("Two.dc.html"), source: Self.board)
        if frame {
            _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
                "Two.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("Two")]),
            ])]))
        }
        return Workspace(app: app, vm: vm, design: design)
    }

    /// The pixel at (x, y) of an image, as 0...255 red, green and blue.
    private func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (Int, Int, Int) {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = CGContext(data: &bytes, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(bytes[0]), Int(bytes[1]), Int(bytes[2]))
    }

    private func decode(_ rendered: DesignRendered) throws -> CGImage {
        let data = try #require(Data(base64Encoded: rendered.image.data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        return try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
    }

    private func near(_ color: (Int, Int, Int), _ expected: (Int, Int, Int), tolerance: Int = 12) -> Bool {
        abs(color.0 - expected.0) <= tolerance && abs(color.1 - expected.1) <= tolerance && abs(color.2 - expected.2) <= tolerance
    }

    @Test func aBoardIsDrawnOffScreenAndItsPixelsAreTheBoards() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let rendered = try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html"))
        #expect(rendered.image.mimeType == "image/png")
        let image = try decode(rendered)
        #expect(image.width == 400 && image.height == 300, "at its frame's size, at one pixel per point")
        #expect(near(pixel(image, 20, 20), (255, 0, 0)), "red on the left")
        #expect(near(pixel(image, 380, 280), (0, 0, 255)), "blue on the right")
        #expect(near(pixel(image, 200, 150), (0, 255, 0)), "the prop's default in the middle")
        #expect(rendered.text.hasPrefix("Two.dc.html at 400×300 · image 400×300 PNG"))
        #expect(w.vm.designRendering.webViews == 0, "no canvas view, live or rasterizing, was needed or is left")
    }

    @Test func aWidthHeightScaleAndPropsChangeWhatIsDrawn() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let big = try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(
            path: "Two.dc.html", scale: 2, props: .object(["accent": .string("#ffff00")])))
        let image = try decode(big)
        #expect(image.width == 800 && image.height == 600, "scale 2")
        #expect(near(pixel(image, 400, 300), (255, 255, 0)), "the prop for this drawing")
        #expect(big.text.contains("2x") && big.text.contains("props accent"))

        // The design's own Tweak value is what an ordinary render draws; a prop given over it wins.
        _ = try await w.app.server.updateDesignIndex(w.design.id, patch: .object(["tweaks": .object(["Two.dc.html": .object(["accent": .string("#ff00ff")])])]))
        let tweaked = try decode(try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html")))
        #expect(near(pixel(tweaked, 200, 150), (255, 0, 255)), "the Tweak value")
        let over = try decode(try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(
            path: "Two.dc.html", props: .object(["accent": .string("#00ffff")]))))
        #expect(near(pixel(over, 200, 150), (0, 255, 255)))

        let narrow = try decode(try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html", width: 200, height: 150)))
        #expect(narrow.width == 200 && narrow.height == 150)
        #expect(near(pixel(narrow, 20, 20), (255, 0, 0)))
    }

    @Test func aBoardWithNoFrameIsDrawnAtItsPreviewSize() async throws {
        let w = try await workspace(frame: false)
        defer { w.app.stop() }
        let rendered = try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html"))
        let image = try decode(rendered)
        #expect(image.width == 400 && image.height == 300)
    }

    @Test func aBoardTheDesignDoesNotHaveIsRefusedWithItsCode() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        await #expect(throws: DesignStoreError.self) {
            try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Gone.dc.html"))
        }
        await #expect(throws: DesignRenderFailure.self) {
            try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html", width: 20))
        }
        await #expect(throws: DesignRenderFailure.self) {
            try await w.app.server.renderDesignBoard(w.design.id, request: DesignRenderRequest(path: "Two.dc.html", width: 8_000, height: 8_000, scale: 2))
        }
    }

    @MainActor
    final class Turns {
        var running = 0
        var peak = 0
        var order: [Int] = []
        var gates: [Int: CheckedContinuation<Void, Never>] = [:]
    }

    @Test func rendersTakeTurnsInTheOrderAskedAndNeverTwoAtOnce() async throws {
        let queue = DesignRenderQueue()
        let turns = Turns()
        var tasks: [Task<Void, Never>] = []
        for n in 1...4 {
            tasks.append(Task { @MainActor in
                await queue.run {
                    turns.running += 1
                    turns.peak = max(turns.peak, turns.running)
                    turns.order.append(n)
                    await withCheckedContinuation { turns.gates[n] = $0 }
                    turns.running -= 1
                }
            })
            try await eventuallyOnMain("render \(n) holds the turn or waits for it") { n == 1 ? turns.gates[1] != nil : queue.waitingCount == n - 1 }
        }
        for n in 1...4 {
            try await eventuallyOnMain("render \(n) has its turn") { turns.gates[n] != nil }
            #expect(turns.order == Array(1...n), "the next turn starts only when the one before it is done")
            turns.gates[n]?.resume()
        }
        for task in tasks { await task.value }
        #expect(turns.peak == 1 && turns.order == [1, 2, 3, 4])
    }

    @Test func manyRendersAskedTogetherAreDrawnOneAtATimeAndAllAnswered() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let server = w.app.server, design = w.design.id
        let colors = ["#ff0000", "#00ff00", "#ffff00", "#ff00ff", "#00ffff"]
        let pictures = try await withThrowingTaskGroup(of: (Int, DesignRendered).self) { group in
            for (index, color) in colors.enumerated() {
                group.addTask {
                    (index, try await server.renderDesignBoard(design, request: DesignRenderRequest(path: "Two.dc.html", props: .object(["accent": .string(color)]))))
                }
            }
            var drawn: [Int: DesignRendered] = [:]
            for try await (index, picture) in group { drawn[index] = picture }
            return drawn
        }
        #expect(pictures.count == colors.count)
        let expected: [(Int, Int, Int)] = [(255, 0, 0), (0, 255, 0), (255, 255, 0), (255, 0, 255), (0, 255, 255)]
        for (index, color) in expected.enumerated() {
            let image = try decode(try #require(pictures[index]))
            #expect(near(pixel(image, 200, 150), color), "render \(index) drew its own props")
        }
    }
}
