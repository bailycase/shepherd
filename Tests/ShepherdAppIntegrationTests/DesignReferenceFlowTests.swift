import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Design references end to end (docs/designs.md › Design references): a real server, a stub pi,
/// and boards drawn off screen by the renderer. A send keeps the piece's copy under the support
/// directory (the board's or the element's PNG, the standalone page, the element's markup and
/// styles, the tokens with their sources), drawn at the version the reference pinned; pi reads
/// the host's fence with the copy's paths, and the thread's design_get reads that copy.
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

    /// Sends `references` to the live thread and answers the record pi read and the copy's folder.
    private func sent(_ w: Workspace, _ references: [DesignReference], text: String = "Build the pay button")
        async throws -> (record: DesignReferenceRecord, folder: URL, prompt: String) {
        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        let server = w.app.server, id = w.thread.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        let before = AppHarness.prompts(in: w.log).count
        try await w.vm.sendDesignReferences(references, text: text, to: id)
        try await eventuallyAsync("pi to get the message") { AppHarness.prompts(in: w.log).count > before }
        let prompt = try #require(AppHarness.prompts(in: w.log).last)
        let record = try #require(DesignReferenceFence.parse(prompt)?.records.first)
        let payload = try #require(record.payloadID)
        let folder = w.app.dir.appendingPathComponent("design-refs/\(id.rawValue)/\(payload.uuidString.lowercased())", isDirectory: true)
        return (record, folder, prompt)
    }

    @Test func aSentElementKeepsItsDrawnCopyAndTheTokensItUses() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        store.draft = "keep this draft"
        let (record, folder, prompt) = try await sent(w, [try reference(w, element: Self.button)])

        #expect(store.draft == "keep this draft", "a reference's send leaves the draft alone")
        #expect(record.elementLabel == "Pay now" && record.design == "Checkout ☕️")
        let names = ["Hero-4@2x.png", "Hero.html", "Hero-4.element.html", "Hero-4.styles.json", "Hero-4-tokens.md"]
        #expect(record.files == names.map { folder.appendingPathComponent($0).path }, "kept under the support directory")
        #expect(DesignReferenceFence.parse(prompt)?.text == "Build the pay button\n\n1 design reference attached.")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: w.drops.path))?.isEmpty ?? true, "nothing in the drop folder")

        let png = try #require(NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent(names[0]))))
        #expect(png.pixelsWide == 240 && png.pixelsHigh == 80, "the button cut from its board at twice its size")
        let page = try String(contentsOf: folder.appendingPathComponent(names[1]), encoding: .utf8)
        #expect(page.contains("Pay now") && !page.localizedCaseInsensitiveContains("<script") && !page.contains("onclick"))
        #expect(!page.contains("data-dc-"))
        let element = try String(contentsOf: folder.appendingPathComponent(names[2]), encoding: .utf8)
        #expect(element.hasPrefix("<button") && element.contains("Pay now") && !element.contains("onclick") && !element.contains("data-dc-"))
        let styles = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appendingPathComponent(names[3])))
            as? [[String: Any]])
        let own = try #require(styles.first?["style"] as? [String: String])
        #expect(styles.first?["tag"] as? String == "button" && own["width"] == "120px" && own["border-radius"] == "8px")
        #expect(own["background-color"] == "rgb(79, 70, 229)", "the token's value, as drawn")
        let tokens = try String(contentsOf: folder.appendingPathComponent(names[4]), encoding: .utf8)
        #expect(tokens.contains("--accent: #4f46e5 · color · acme-web · web/static/tokens.css:8"))
        #expect(!tokens.contains("--space-6"), "the card's padding is not the button's")

        let payloadID = try #require(record.payloadID)
        let payload = try #require(await w.app.server.designReferencePayload(agentID: w.thread.agent.id, payloadID: payloadID))
        #expect(payload.payload.computedStyles?["border-radius"] == "8px" && payload.payload.picture?.pixelWidth == 240)
        #expect(payload.payload.styles == ["width", "height", "border-radius", "background"])

        let grant = try #require(w.app.server.state.agents.first { $0.id == w.thread.agent.id }?.designGrants.first)
        #expect(grant.element == Self.button.description && grant.label == "Pay now")
        let client = try ExtensionClient(path: w.app.scratch.socketPath)
        try client.send(.designGet(id: 1, agentID: w.thread.agent.id, reference: record.ref, what: "image"))
        let reply = try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
        guard case .designReference(1, let answer) = reply else { Issue.record("design_get image was refused: \(reply)"); return }
        #expect(answer.image == folder.appendingPathComponent(names[0]).path)
    }

    @Test func aBoardsReferenceDrawsTheBoardWhole() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let (record, folder, _) = try await sent(w, [try reference(w)])
        #expect(record.files?.map { URL(fileURLWithPath: $0).lastPathComponent } == ["Hero@2x.png", "Hero.html", "Hero-tokens.md"])
        let png = try #require(NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent("Hero@2x.png"))))
        #expect(png.pixelsWide == 800 && png.pixelsHigh == 600)
        let tokens = try String(contentsOf: folder.appendingPathComponent("Hero-tokens.md"), encoding: .utf8)
        #expect(tokens.contains("--space-6: 24px · spacing · acme-web · web/static/tokens.css:22") && tokens.contains("--accent"))
    }

    /// Picked, then the design moved on: the send draws the version picked, from its pin.
    @Test func aPickedVersionIsDrawnAfterTheDesignMovesOn() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let picked = try await w.vm.prepareDesignReference(try reference(w, element: Self.button))
        #expect(picked.piece == "button “Pay now”")
        #expect(DesignReferencePresentation.sends(picked.outline) == "Sends a picture, its HTML, 4 styles and 1 token from acme-web.")
        _ = try await w.app.server.writeDesignBoard(w.design.id, path: try DesignPath.validate("Hero.dc.html"),
                                                    source: Self.hero.replacingOccurrences(of: "Pay now", with: "Pay $24"))
        let (record, folder, _) = try await sent(w, [picked.reference])
        #expect(record.revision == picked.reference.revision)
        let element = try String(contentsOf: folder.appendingPathComponent("Hero-4.element.html"), encoding: .utf8)
        #expect(element.contains("Pay now") && !element.contains("Pay $24"), "the version picked, not the design now")
    }

    @Test(arguments: ["props", "tokens", "frame"])
    func aPinnedRenderingKeepsPropsTokensFrameAndUnknownIndexKeys(change: String) async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let path = DesignPath("Hero.dc.html")!
        let source = Self.hero.replacingOccurrences(of: "Pay now", with: "{{ caption }}")
            .replacingOccurrences(of: "renderVals() { return {}; }", with: "renderVals() { return { caption: this.props.caption || 'Default' }; }")
        _ = try await w.app.server.writeDesignBoard(w.design.id, path: path, source: source)
        _ = try await w.app.server.updateDesignIndex(w.design.id, patch: DesignIndex.tweakPatch(path, ["caption": .string("Old caption")]))
        _ = try await w.app.server.updateDesignIndex(w.design.id, patch: .object(["unknownPinMetadata": .object(["kept": .bool(true)])]))
        let picked = try await w.vm.prepareDesignReference(try reference(w))
        let oldRevision = try #require(picked.reference.revision)
        let sha = try await w.app.server.designBoard(w.design.id, path: path).sha256
        switch change {
        case "props":
            _ = try await w.app.server.updateDesignIndex(w.design.id, patch: DesignIndex.tweakPatch(path, ["caption": .string("New caption")]))
        case "frame":
            _ = try await w.app.server.updateDesignIndex(w.design.id, patch: .object([
                "boards": .object([path.rawValue: .object(["w": .number(600), "title": .string("Renamed")])]),
                "unknownPinMetadata": .null]))
        default:
            var changedTokens = Self.tokens
            if case .object(var fields) = changedTokens {
                fields["colors"] = .array([.object(["name": .string("--accent"), "value": .string("#ff0000")])])
                changedTokens = .object(fields)
            }
            _ = try await w.app.server.writeDesignSystem(.init(namespace: "acme-web", tokens: changedTokens, install: true), for: w.design.id)
        }
        #expect(try await w.app.server.designBoard(w.design.id, path: path).sha256 == sha, "board text never changed after pinning")
        guard case .updatedSince = await w.app.server.designReferenceFreshness(picked.reference) else {
            Issue.record("props/CSS/frame-only changes must be stale"); return
        }
        let kept = try #require(try await w.app.server.designs.pinnedRender(w.design.id, revision: oldRevision, boards: [path]))
        #expect(kept.files.index.extra["unknownPinMetadata"] == .object(["kept": .bool(true)]))
        let (record, folder, _) = try await sent(w, [picked.reference])
        #expect(record.revision == oldRevision && record.width == 400)
        let page = try String(contentsOf: folder.appendingPathComponent("Hero.html"), encoding: .utf8)
        #expect(page.contains("Old caption") && !page.contains("New caption"))
        #expect(page.contains("#4f46e5") && !page.contains("#ff0000"))
        let png = try #require(NSBitmapImageRep(data: try Data(contentsOf: folder.appendingPathComponent("Hero@2x.png"))))
        #expect(png.pixelsWide == 800 && png.pixelsHigh == 600)
        let note = try String(contentsOf: folder.appendingPathComponent("Hero-tokens.md"), encoding: .utf8)
        #expect(note.contains("#4f46e5") && !note.contains("#ff0000"))
    }

    @Test func aWholeDesignPinStillDrawsABoardRemovedFromTheLiveCanvas() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let second = DesignPath("Second.dc.html")!
        _ = try await w.app.server.writeDesignBoard(w.design.id, path: second, source: Self.hero.replacingOccurrences(of: "Pay now", with: "Second board"))
        _ = try await w.app.server.updateDesignIndex(w.design.id, patch: .object(["boards": .object([
            second.rawValue: .object(["x": .number(480), "y": .number(0), "w": .number(400), "h": .number(300)])])]))
        let whole = DesignReference(designID: w.design.id, board: nil)!
        let picked = try await w.vm.prepareDesignReference(whole)
        _ = try await w.app.server.updateDesignIndex(w.design.id, patch: .object(["boards": .object([second.rawValue: .null])]))
        let (record, folder, _) = try await sent(w, [picked.reference])
        #expect(record.boards == 2 && record.boardCount == 2)
        let id = try #require(record.payloadID)
        let payload = try #require(await w.app.server.designReferencePayload(agentID: w.thread.agent.id, payloadID: id))
        let removed = try #require(payload.payload.boards?.first { $0.board == second })
        let html = try #require(removed.html)
        #expect(try String(contentsOf: folder.appendingPathComponent(html.name), encoding: .utf8).contains("Second board"))
        #expect(removed.picture?.pixelWidth == 800)
    }

    @Test func captureUsesResolvedInputsEvenWhenTheLiveBoardChangesBeforeDrawing() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let handler = try #require(w.app.server.onDesignReferenceCapture)
        w.app.server.onDesignReferenceCapture = { request, respond in
            Task { @MainActor in
                do {
                    _ = try await w.app.server.writeDesignBoard(w.design.id, path: DesignPath("Hero.dc.html")!,
                        source: Self.hero.replacingOccurrences(of: "Pay now", with: "Too late"))
                    handler(request, respond)
                } catch { respond(.failure(DesignReferenceError("test_write", "\(error)"))) }
            }
        }
        let (_, folder, _) = try await sent(w, [try reference(w)])
        let page = try String(contentsOf: folder.appendingPathComponent("Hero.html"), encoding: .utf8)
        #expect(page.contains("Pay now") && !page.contains("Too late"))
    }

    /// "Send vN": the chip in the composer takes the design's version now.
    @Test func sendingTheLatestVersionPutsItInTheComposer() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let first = try await w.vm.attachDesignReference(try reference(w, element: Self.button), to: w.thread.agent.id)
        _ = try await w.app.server.writeDesignBoard(w.design.id, path: try DesignPath.validate("Hero.dc.html"),
                                                    source: Self.hero.replacingOccurrences(of: "Pay now", with: "Pay $24"))
        let latest = try await w.vm.sendLatestDesignReference(first.reference, to: w.thread.agent.id)
        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        #expect(store.attachedReferences.map(\.id) == [latest.id], "in the older chip's place")
        #expect((latest.reference.revision ?? 0) > (first.reference.revision ?? 0))
        #expect(latest.outline?.kind == .element)
    }

    /// A design's own agent is never a reference's thread, and a reference to another Mac's
    /// design is refused with its reason.
    @Test func aDesignsAgentOrAnotherMacsDesignIsRefused() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        await #expect(throws: DesignReferenceFailure.self) {
            _ = try await w.vm.attachDesignReference(try reference(w), to: w.drawer.id)
        }
        await #expect(throws: DesignReferenceFailure.self) {
            try await w.vm.sendDesignReferences([try reference(w)], text: "x", to: w.drawer.id)
        }
        var remote = try reference(w)
        remote.host = .remote(UUID())
        do {
            _ = try await w.vm.prepareDesignReference(remote)
            Issue.record("another Mac's design was prepared")
        } catch let failure as DesignReferenceFailure {
            #expect(failure.message.contains("another Mac"))
        }
        #expect(w.app.server.state.agents.allSatisfy { $0.designGrants.isEmpty })
    }

    // MARK: From the canvas (RefImplementSheet, RefImplementBoard, RefSentStay, RefCopied)

    /// The pay button as the canvas picks it.
    private func buttonPick() throws -> DesignElementPick {
        DesignElementPick(board: try DesignPath.validate("Hero.dc.html"), id: Self.button, rect: CGRect(x: 0, y: 44, width: 120, height: 40),
                          kind: .shape, label: "Pay now", tag: "button · Pay now")
    }

    /// Implement in a thread… into the thread picked: the piece pinned as the sheet opens, the
    /// thread gets it with the message, and "Open the thread after sending" lands there (and is
    /// remembered).
    @Test func implementingIntoAThreadSendsThePieceAndOpensTheThread() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let store = w.vm.threadStores.store(for: w.thread.agent.id)
        let server = w.app.server, id = w.thread.agent.id
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        screen.setSelection([.init(board: try DesignPath.validate("Hero.dc.html"), element: try buttonPick())])
        screen.implementSelection(designName: w.design.name)
        let model = try #require(w.vm.implementSheet)
        try await eventuallyOnMain("the piece to be pinned") { model.prepared != nil }
        #expect(model.title == "Implement button “Pay now”")
        #expect(model.threads.map(\.id) == [id], "a design's own agent is never offered")
        model.message = "Build the pay button"
        model.opensThread = true
        let before = AppHarness.prompts(in: w.log).count
        w.vm.sendImplementSheet(model)
        try await eventuallyOnMain("the send", timeout: .seconds(60)) { w.vm.implementSheet == nil }
        try await eventuallyAsync("pi to get the message") { AppHarness.prompts(in: w.log).count > before }
        let prompt = try #require(AppHarness.prompts(in: w.log).last)
        #expect(DesignReferenceFence.parse(prompt)?.records.first?.elementLabel == "Pay now")
        #expect(DesignReferenceFence.parse(prompt)?.text == "Build the pay button\n\n1 design reference attached.")
        #expect(w.vm.selectedAgentID == id && w.vm.referenceToast == nil, "landed in the thread")
        #expect(w.vm.settings.implementOpensThread)
    }

    /// Implement in a new thread: it starts in the project on a new worktree named for the piece,
    /// gets the piece as its first message, and the canvas stays with a toast offering it.
    @Test func implementingInANewThreadStartsItOnAWorktreeAndStaysOnTheCanvas() async throws {
        try StubPi.installAsEngine()
        let w = try await workspace()
        defer { w.app.stop() }
        let repo = try makeScratchRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let spaceID = try #require(await w.vm.addSpace(at: repo))
        w.vm.selectAgent(w.drawer.id)
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        screen.select("Hero.dc.html")
        screen.implementSelection(designName: w.design.name)
        let model = try #require(w.vm.implementSheet)
        try await eventuallyOnMain("the piece to be pinned") { model.prepared != nil }
        model.mode = .new
        model.project = spaceID
        model.opensThread = false
        #expect(model.chosenProject?.isRepo == true && model.branch == "agent/implement-hero")
        w.vm.sendImplementSheet(model)
        try await eventuallyOnMain("the send", timeout: .seconds(60)) { w.vm.implementSheet == nil }
        let agent = try #require(w.app.server.state.agents.first { $0.worktreeBranch == "agent/implement-hero" })
        #expect(agent.spaceID == spaceID && agent.name == "Implement Hero" && !agent.nameIsFinal)
        let worktree = try #require(agent.worktreePath)
        defer { try? FileManager.default.removeItem(atPath: worktree) }
        #expect(FileManager.default.fileExists(atPath: worktree))
        guard case .sent(let thread, _)? = w.vm.referenceToast?.kind else { Issue.record("no toast"); return }
        #expect(thread == agent.id && w.vm.selectedAgentID == w.drawer.id, "the canvas stays")
        #expect(!w.vm.settings.implementOpensThread, "the choice is remembered")
        let server = w.app.server
        try await eventuallyAsync("the new thread to get the piece", timeout: .seconds(30)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && ($0.designReferences != nil || $0.blocks.contains { DesignReferenceFence.opens($0.text) }) }
        }
        #expect(server.state.agents.first { $0.id == agent.id }?.designGrants.count == 1)
    }

    /// Copy reference: the piece pinned, its string on the pasteboard (the test's own), a toast.
    @Test func copyingAReferencePutsItsStringOnThePasteboard() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        var copied: [String] = []
        w.vm.copyToPasteboard = { copied.append($0) }
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        screen.setSelection([.init(board: try DesignPath.validate("Hero.dc.html"), element: try buttonPick())])
        screen.copySelectionReference(designName: w.design.name)
        try await eventuallyOnMain("the toast") { w.vm.referenceToast != nil }
        let reference = try #require(copied.first.flatMap { DesignReference(string: $0) })
        #expect(reference.element == Self.button && reference.revision != nil, "pinned when copied")
        #expect(w.vm.referenceToast?.kind == .copied && w.vm.referenceToast?.piece == "button “Pay now”")
    }

    /// Copy reference, then a paste into a thread's composer (RefCopied, RefPasted, RefSentThread):
    /// the reference becomes a chip and leaves the words, the composer's send carries it, the sent
    /// message draws the chip from the copy the host kept, and that chip stays (greyed, "deleted")
    /// once the design is gone.
    @Test func aCopiedReferencePastedIntoAThreadGoesAsItsChip() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        var copied: [String] = []
        w.vm.copyToPasteboard = { copied.append($0) }
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        screen.setSelection([.init(board: try DesignPath.validate("Hero.dc.html"), element: try buttonPick())])
        screen.copySelectionReference(designName: w.design.name)
        try await eventuallyOnMain("the copy") { !copied.isEmpty }
        let string = try #require(copied.first)

        let id = w.thread.agent.id
        let store = w.vm.threadStores.store(for: id)
        let server = w.app.server
        let polling = Task { await store.run { try await server.nativeThread(agentID: id, request: $0) } }
        defer { polling.cancel(); store.stop() }
        try await eventuallyOnMain("the thread to connect") { store.ready }
        // "tools:0": the stub runs a turn the way pi does, the user's message streamed first.
        let pasted = try #require(ComposerReferencePaste.extract("tools:0 build this " + string, previous: "tools:0 build this "))
        #expect(pasted.references.map(\.string) == [string] && !pasted.draft.contains(DesignReference.scheme))
        let chips = try #require(w.vm.designReferenceChips(for: id))
        for reference in pasted.references { try await chips.io.attach(reference) }
        #expect(store.attachedReferences.map(\.reference.string) == [string], "the paste is a chip, pinned as copied")

        store.draft = pasted.draft
        let before = AppHarness.prompts(in: w.log).count
        await store.send()
        try await eventuallyAsync("pi to get the message") { AppHarness.prompts(in: w.log).count > before }
        #expect(store.attachedReferences.isEmpty && store.draft.isEmpty)
        let prompt = try #require(AppHarness.prompts(in: w.log).last)
        let record = try #require(DesignReferenceFence.parse(prompt)?.records.first)
        #expect(record.ref == string && record.elementLabel == "Pay now")

        try await eventuallyOnMain("the sent message's chip") {
            store.snapshot?.messages.contains { $0.role == "user" && $0.designReferences?.first?.ref == string } == true
        }
        let message = try #require(store.snapshot?.messages.first { $0.designReferences != nil })
        let bubble = try #require(nativeUserBubbles(message).first)
        #expect(bubble.references.map(\.ref) == [string] && !bubble.text.contains(DesignReference.scheme))
        let payload = try #require(record.payloadID)
        await chips.loadSent(payload)
        #expect(chips.sent[payload]?.freshness == .current && chips.sent[payload]?.picture != nil)
        #expect(chips.sent[payload]?.crumbs.last == "button “Pay now”")

        _ = try await server.deleteDesign(w.design.id)
        chips.designsChanged()
        await chips.loadSent(payload)
        #expect(chips.sent[payload]?.freshness == .deleted, "the chip says the design is gone")
        #expect(chips.sent[payload]?.picture != nil, "and still draws the copy that was sent")
    }

    /// Note back (RefNoteBack): the thread a piece went to leaves a note on it, and the design's
    /// canvas shows it at once as the thread's own pin (never a comment), whose card opens the
    /// thread; Resolve takes it off the canvas.
    @Test func aThreadsNoteBackShowsOnTheCanvasAsItsPin() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        let (record, _, _) = try await sent(w, [try reference(w, element: Self.button)])
        let screen = w.vm.designScreen(w.design.id)
        await screen.refresh()
        #expect(screen.threadNotes.isEmpty)

        let client = try ExtensionClient(path: w.app.scratch.socketPath)
        try client.send(.designNote(id: 7, agentID: w.thread.agent.id, reference: record.ref, text: "Implemented in #142."))
        let reply = try await Task.detached { try client.readReply(timeout: .seconds(30)) }.value
        guard case .designNote(7, let note) = reply else { Issue.record("the note was refused: \(reply)"); return }
        try await eventuallyOnMain("the canvas to show the note") { screen.threadNotes == [note] }
        let pin = try #require(screen.pins.first { if case .threadNote = $0.style { true } else { false } })
        #expect(pin.style == .threadNote(w.thread.agent.name))
        let comments = try await w.app.server.designs.comments(w.design.id)
        #expect(comments.comments.isEmpty, "a note is never a comment")

        screen.openThread(pin.id)
        #expect(screen.openThreadNote == note)
        await screen.resolveNote(note.id)?.value
        #expect(screen.threadNotes.isEmpty && screen.pins.allSatisfy { if case .threadNote = $0.style { false } else { true } })
        #expect(try await w.app.server.designThreadNotes(w.design.id).isEmpty)
    }

    /// Isolation (docs/designs.md): a thread's chips, "Looked at…" lines and @ picker exist only
    /// while the Design tool is on, and never in a design's own chat.
    @Test func onlyAnOrdinaryThreadWithTheDesignToolOnGetsReferences() async throws {
        let w = try await workspace()
        defer { w.app.stop() }
        #expect(w.vm.designReferenceChips(for: w.thread.agent.id) != nil)
        #expect(w.vm.designReferenceChips(for: w.drawer.id) == nil, "a design's agent")
        w.app.settings.designToolEnabled = false
        #expect(w.vm.designReferenceChips(for: w.thread.agent.id) == nil, "the Design tool off")
    }
}
