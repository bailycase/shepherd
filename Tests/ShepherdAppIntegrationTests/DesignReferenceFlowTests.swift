import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Design references end to end (docs/designs.md › Design references): a real server, a stub pi,
/// and boards drawn off screen by the renderer. A reference readies its files in the drop folder
/// (the board's or the element's PNG, the standalone page, the element's markup and styles, the
/// tokens with their sources); sent, pi reads the host's fence and the files' paths, and the
/// thread's design_get draws through the app.
@Suite("Design references", .mainActorExclusive)
@MainActor
struct DesignReferenceFlowTests {
    static let hero = """
        <!doctype html>
        <html lang="en">
        <head><meta charset="utf-8"><title>Hero</title><script src="./support.js"></script>
        <link rel="stylesheet" href="ds/acme-web/tokens.css"></head>
        <body>
        <x-dc>
        <helmet><style>body{margin:0}</style></helmet>
        <div style="width: 400px; height: 300px; box-sizing: border-box; padding: var(--space-6); color: var(--accent)">
        <h1 style="margin: 0; font-size: 20px">Checkout</h1>
        <button style="width: 120px; height: 40px; border-radius: 8px; background: var(--accent)" onclick="alert(1)">Pay now</button>
        </div>
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":400,"height":300}}'>
        class Component extends DCLogic { renderVals() { return {}; } }
        </script>
        </body>
        </html>
        """
    /// helmet (0), style (1), the card (2, `1`), its title (3, `1/0`) and button (4, `1/1`).
    static let button = DesignElementID("Hero.dc.html#4:1/1")!
    static let card = DesignElementID("Hero.dc.html#2:1")!

    static let tokens: JSONValue = .object([
        "format": .string("shepherd-tokens/1"), "name": .string("acme-web"), "namespace": .string("acme-web"),
        "colors": .array([.object(["name": .string("--accent"), "value": .string("#4f46e5"),
                                   "source": .object(["file": .string("web/static/tokens.css"), "line": .number(8)])])]),
        "spacing": .array([.object(["name": .string("--space-6"), "px": .number(24),
                                    "source": .object(["file": .string("web/static/tokens.css"), "line": .number(22)])])]),
    ])

    private struct Workspace {
        let app: AppHarness
        let vm: ShepherdViewModel
        let design: Design
        let thread: AgentFixture
        let drawer: Agent
        let log: URL
        let drops: URL
    }

    /// The Design tool on, a live thread (stub pi), a design's own agent, and Hero drawn in acme-web.
    private func workspace() async throws -> Workspace {
        let app = try AppHarness()
        app.settings.designToolEnabled = true
        let space = Fixture.space(path: app.dir.path)
        let log = app.dir.appendingPathComponent("pi.log")
        let thread = try await app.liveAgent("Build checkout", in: space, log: log)
        var drawer = Fixture.agent("Checkout", in: space, order: 1)
        let design = Design(name: "Checkout ☕️", agentID: drawer.agent.id, createdAt: 1_000)
        drawer.agent.designID = design.id
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: [thread, drawer]))
        vm.designNetwork = .none
        let drops = try makeScratchDirectory("drops")
        vm.designAttachDirectory = drops
        _ = try await app.server.createDesign(design)
        let hero = try DesignPath.validate("Hero.dc.html")
        _ = try await app.server.writeDesignBoard(design.id, path: hero, source: Self.hero)
        _ = try await app.server.updateDesignIndex(design.id, patch: .object(["boards": .object([
            "Hero.dc.html": .object(["x": .number(0), "y": .number(0), "w": .number(400), "h": .number(300), "title": .string("Hero")]),
        ])]))
        _ = try await app.server.writeDesignSystem(DesignSystemWrite(namespace: "acme-web", tokens: Self.tokens, install: true), for: design.id)
        return Workspace(app: app, vm: vm, design: design, thread: thread, drawer: drawer.agent, log: log, drops: drops)
    }

    private func reference(_ w: Workspace, element: DesignElementID? = nil) throws -> DesignReference {
        try #require(w.vm.designReference(w.design.id, board: try DesignPath.validate("Hero.dc.html"), element: element))
    }

    @Test func aReferenceDrawsTheElementItsBoardsPageAndTheTokensItUses() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let prepared = try await w.vm.prepareDesignReference(try reference(w, element: Self.button), for: w.thread.agent.id)

        #expect(prepared.label == "Checkout ☕️ › Hero › Pay now")
        #expect(prepared.reference.revision != nil, "pinned at the design's revision")
        #expect(prepared.files.map(\.name) == ["Hero-4@2x.png", "Hero.html", "Hero-4.element.html", "Hero-4.styles.json", "Hero-4-tokens.md"])
        for file in prepared.files { #expect(file.path.hasPrefix(w.drops.path), "written in the drop folder") }

        let png = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: prepared.files[0].path))))
        #expect(png.pixelsWide == 240 && png.pixelsHigh == 80, "the button cut from its board at twice its size")

        let page = try String(contentsOfFile: prepared.files[1].path, encoding: .utf8)
        #expect(page.contains("Pay now") && !page.localizedCaseInsensitiveContains("<script") && !page.contains("onclick"))
        #expect(!page.contains("data-dc-"))

        let element = try String(contentsOfFile: prepared.files[2].path, encoding: .utf8)
        #expect(element.hasPrefix("<button") && element.contains("Pay now") && !element.contains("onclick") && !element.contains("data-dc-"))
        let styles = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: prepared.files[3].path)))
            as? [[String: Any]])
        let own = try #require(styles.first?["style"] as? [String: String])
        #expect(styles.first?["tag"] as? String == "button" && own["width"] == "120px" && own["border-radius"] == "8px")
        #expect(own["background-color"] == "rgb(79, 70, 229)", "the token's value, as drawn")

        let tokens = try String(contentsOfFile: prepared.files[4].path, encoding: .utf8)
        #expect(tokens.contains("--accent: #4f46e5 · color · acme-web · web/static/tokens.css:8"))
        #expect(!tokens.contains("--space-6"), "the card's padding is not the button's")
    }

    @Test func aBoardsReferenceDrawsTheBoardWhole() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let prepared = try await w.vm.prepareDesignReference(try reference(w), for: w.thread.agent.id)
        #expect(prepared.files.map(\.name) == ["Hero@2x.png", "Hero.html", "Hero-tokens.md"])
        let png = try #require(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: prepared.files[0].path))))
        #expect(png.pixelsWide == 800 && png.pixelsHigh == 600)
        let tokens = try String(contentsOfFile: prepared.files[2].path, encoding: .utf8)
        #expect(tokens.contains("--space-6: 24px · spacing · acme-web · web/static/tokens.css:22") && tokens.contains("--accent"))
    }

    /// Sent, pi reads the host's fence ahead of the words, then the line and the files' paths; the
    /// thread's agent holds the grant, and its design_get draws through the app.
    @Test func aSentReferenceReachesPiAndItsAgentCanReadIt() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        let server = w.app.server, id = w.thread.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        store.draft = "keep this draft"

        try await w.vm.sendDesignReferences([try reference(w, element: Self.button)], text: "Build the pay button", to: id)

        #expect(store.draft == "keep this draft", "a reference's send leaves the draft alone")
        try await eventuallyAsync("pi to get the message") { !AppHarness.prompts(in: w.log).isEmpty }
        let prompt = try #require(AppHarness.prompts(in: w.log).last)
        let parsed = try #require(DesignReferenceFence.parse(prompt))
        #expect(parsed.records.first?.elementLabel == "Pay now" && parsed.records.first?.design == "Checkout ☕️")
        #expect(parsed.records.first?.files == ["Hero-4@2x.png", "Hero.html", "Hero-4.element.html", "Hero-4.styles.json", "Hero-4-tokens.md"])
        #expect(parsed.text.hasPrefix("Build the pay button\n\n1 design reference attached.\n\nAttached files:\n- \(w.drops.path)/design-ref-"))
        #expect(parsed.text.contains("/Hero-4@2x.png\n") && parsed.text.hasSuffix("/Hero-4-tokens.md"))

        let grant = try #require(w.app.server.state.agents.first { $0.id == id }?.designGrants.first)
        #expect(grant.element == Self.button.description && grant.label == "Pay now")

        let client = try ExtensionClient(path: w.app.scratch.socketPath)
        let ref = try #require(parsed.records.first?.ref)
        try client.send(.designGet(id: 1, agentID: id, reference: ref, what: "image"))
        let reply = try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
        guard case .designReference(1, let answer) = reply else { Issue.record("design_get image was refused: \(reply)"); return }
        let image = try #require(answer.image)
        #expect(image.hasPrefix(w.drops.path) && image.hasSuffix("/Hero-4@2x.png"))
        #expect(NSBitmapImageRep(data: try Data(contentsOf: URL(fileURLWithPath: image)))?.pixelsWide == 240)
    }

    /// A design's own agent is never a reference's thread, and a reference to another Mac's
    /// design is refused with its reason.
    @Test func aDesignsAgentOrAnotherMacsDesignIsRefused() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        await #expect(throws: DesignReferenceFailure.self) {
            _ = try await w.vm.prepareDesignReference(try reference(w), for: w.drawer.id)
        }
        var remote = try reference(w)
        remote.host = .remote(UUID())
        do {
            _ = try await w.vm.prepareDesignReference(remote, for: w.thread.agent.id)
            Issue.record("another Mac's design was prepared")
        } catch let failure as DesignReferenceFailure {
            #expect(failure.message.contains("another Mac"))
        }
        #expect(w.app.server.state.agents.allSatisfy { $0.designGrants.isEmpty })
        #expect((try? FileManager.default.contentsOfDirectory(atPath: w.drops.path))?.isEmpty ?? true, "nothing was drawn")
    }
}
