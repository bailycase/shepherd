import CryptoKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// The Design tool on iPad (iPadDesign, iPadSplitView, iPadSidebar boards): a host serving
// designs.v1 with acme's "Checkout funnel dashboard" (four boards, three open comments, its
// design agent's chat), rendered on the simulator from the files the fixture host serves. The
// fixture host answers every read and refuses every write (a comment, a tweak, a move), so no
// screen depends on one. Run them on an iPad: `-r landscape` for the canvas beside its chat, and
// `-w` for the Split View screen.
extension FixtureCatalog {
    static var designPad: [FixtureScreen] {
        let design = DesignPadFixtures.ref
        let thread = FixtureData.ref(FixtureData.extensions)
        return [
            // The canvas beside its chat (iPadDesign), framed as the board frames it.
            FixtureScreen(name: "design-pad", hosts: DesignPadFixtures.hosts(),
                          routes: [.padDesign(.list), .padDesign(.design(design))],
                          prepare: { app in await DesignPadFixtures.settle(app) }),
            // A board's element tapped: its ring and tag, and the Tweak tab's controls for it.
            FixtureScreen(name: "design-pad-tweak", hosts: DesignPadFixtures.hosts(),
                          routes: [.padDesign(.list), .padDesign(.design(design))],
                          prepare: { app in
                              let canvas = await DesignPadFixtures.settle(app)
                              await DesignPadFixtures.select(canvas, board: "A.dc.html", at: CGPoint(x: 400, y: 440))
                              canvas.paneTab = .tweak
                          }),
            // The Comments tab, and a comment's thread open beside its pin.
            FixtureScreen(name: "design-pad-comments", hosts: DesignPadFixtures.hosts(),
                          routes: [.padDesign(.list), .padDesign(.design(design))],
                          prepare: { app in
                              let canvas = await DesignPadFixtures.settle(app)
                              canvas.paneTab = .comments
                              canvas.openThread(DesignPadFixtures.funnelComment.uuidString)
                          }),
            // Split View (iPadSplitView): a thread in one window, the design in the other, the
            // design agent's latest reply over its canvas with "Send to the thread".
            FixtureScreen(name: "design-pad-split", hosts: DesignPadFixtures.hosts(split: true), routes: [.thread(thread)],
                          prepare: { app in
                              FixtureWindows.shared.openBeside(.padDesign(.list))
                              await FixtureWindows.wait(seconds: 10) { app.windows.open.count > 1 }
                              if let window = app.windows.open.first(where: { $0.seed.id != MobileWindowSeed.lone.id }) {
                                  PadDesignHooks.open(design, navigator: window.navigator)
                              }
                              // The boards stack in one column, fitted; A picked whole wears its ring.
                              let canvas = await DesignPadFixtures.settle(app, viewport: nil)
                              canvas.pick(NWCanvasPick(board: "A.dc.html"))
                              await FixtureWindows.wait(seconds: 10) { canvas.isDrawn && !canvas.selectedWhole.isEmpty }
                          }),
            // The sidebar over a thread in portrait (iPadSidebar): Designs among the
            // destinations, and designs in Recents with their boards. Render with --sidebar.
            FixtureScreen(name: "design-pad-sidebar", hosts: DesignPadFixtures.hosts(), routes: [.thread(FixtureData.ref(FixtureData.preview))]),
            // The Designs list the sidebar's row opens.
            FixtureScreen(name: "designs-pad", hosts: DesignPadFixtures.hosts(), routes: [.padDesign(.list)],
                          prepare: { _ in
                              await FixtureWindows.wait(seconds: 20) { PadDesignThumbnails.shared.image(DesignPadFixtures.ref) != nil }
                          }),
        ]
    }
}

enum DesignPadFixtures {
    static let designID = DesignID(rawValue: "design-checkout")
    static let agentID = AgentID(rawValue: "agent-design-checkout")
    static let ref = PadDesignRef(host: FixtureData.studio, design: designID)
    static let agentRef = AgentRef(host: FixtureData.studio, agent: agentID)
    static let funnelComment = UUID(uuidString: "D0000000-0000-4000-8000-000000000001")!

    /// The fixture hosts with Studio serving the design: its Design tool on, the design and its
    /// agent in its state, the agent's chat among its threads. `split` gives the agent the reply
    /// iPadSplitView draws.
    static func hosts(split: Bool = false) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }) else { return hosts }
        let design = Design(id: designID, name: "Checkout funnel dashboard", agentID: agentID,
                            systemNamespace: "acme-web", createdAt: FixtureData.start,
                            lastActiveAt: Date().timeIntervalSince1970 * 1000 - 120_000, boardCount: 4)
        let settings = Design(id: DesignID(rawValue: "design-settings"), name: "Settings redesign",
                              systemNamespace: "night-watch", createdAt: FixtureData.start, lastActiveAt: FixtureData.start, boardCount: 6)
        var agent = FixtureData.agent(agentID, "Checkout funnel dashboard", .done)
        agent.designID = designID
        hosts[index].state.agents.append(agent)
        hosts[index].state.designs = [design, settings]
        hosts[index].threads[agentID] = split ? splitThread() : chat()
        hosts[index].designs = FixtureDesigns(designs: [checkout(design), empty(settings)], systems: [acmeWeb])
        return hosts
    }

    /// Waits for the design on screen to draw what it shows, then puts the canvas where the board
    /// puts it. Answers the canvas.
    @MainActor @discardableResult
    static func settle(_ app: MobileApp, viewport: NWCanvasViewport? = NWCanvasViewport(offset: CGPoint(x: 28, y: 46), zoom: 0.4),
                       agent: AgentRef = agentRef) async -> PadDesignCanvas {
        let designs = PadDesigns.of(app.hosts)
        let canvas = designs.canvas(ref)
        await FixtureWindows.wait(seconds: 15) { canvas.snapshot != nil }
        if let viewport { canvas.viewport = viewport }
        await FixtureWindows.wait(seconds: 30) { canvas.isDrawn }
        await FixtureWindows.wait(seconds: 10) { app.threads.store(for: agent).snapshot != nil }
        print("FIXTURE CHECK \(canvas.isDrawn ? "ok" : "FAILED: the boards on screen never drew") design")
        return canvas
    }

    /// Taps a board as a finger would with Select, and waits for its element's ring.
    @MainActor static func select(_ canvas: PadDesignCanvas, board: String, at point: CGPoint) async {
        canvas.pick(NWCanvasPick(board: board, point: point))
        await FixtureWindows.wait(seconds: 15) { !canvas.selectedElements.isEmpty }
        await FixtureWindows.wait(seconds: 15) { !canvas.tweak.presentation.isEmpty }
        await FixtureWindows.wait(seconds: 15) { canvas.isDrawn }
    }

    // MARK: The design

    static func checkout(_ design: Design) -> FixtureDesigns.Item {
        let files: [String: String] = [
            "A.dc.html": DesignPadBoards.funnel, "A-phone.dc.html": DesignPadBoards.phone,
            "B.dc.html": DesignPadBoards.steps, "C.dc.html": DesignPadBoards.trend,
        ]
        let path = { (raw: String) in DesignPath(raw)! }
        let index = DesignIndex(title: design.name, boards: [
            path("A.dc.html"): .init(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first"),
            path("A-phone.dc.html"): .init(x: 1380, y: 0, w: 390, h: 844, title: "A · phone"),
            path("B.dc.html"): .init(x: 0, y: 1000, w: 1280, h: 800, title: "B · Step table"),
            path("C.dc.html"): .init(x: 1380, y: 1000, w: 1280, h: 800, title: "C · Trend first"),
        ], order: [path("A.dc.html"), path("A-phone.dc.html"), path("B.dc.html"), path("C.dc.html")])
        let ago = Date().timeIntervalSince1970 * 1000
        let funnel = element("Checkout funnel", in: DesignPadBoards.funnel)
        let steps = element("Steps list", in: DesignPadBoards.phone)
        let kpis = element("KPI row", in: DesignPadBoards.funnel)
        let comments = DesignComments(revision: 3, comments: [
            DesignComment(id: funnelComment, number: 1, board: path("A.dc.html"), tid: funnel.tid, path: funnel.path, target: "Checkout funnel",
                          rect: DesignCommentRect(x: 32, y: 304, w: 900, h: 330),
                          text: "Show the absolute counts next to the percentages.", createdAt: ago - 120_000,
                          replies: [DesignCommentReply(author: .agent, text: "Done. Counts sit next to each percentage on both boards.",
                                                       createdAt: ago - 60_000)]),
            DesignComment(number: 2, board: path("A-phone.dc.html"), tid: steps.tid, path: steps.path, target: "Steps list",
                          rect: DesignCommentRect(x: 16, y: 250, w: 358, h: 300), text: "Thicker bars on phone.", createdAt: ago - 50_000),
            DesignComment(number: 3, board: path("A.dc.html"), tid: kpis.tid, path: kpis.path, target: "KPI row",
                          rect: DesignCommentRect(x: 32, y: 172, w: 1216, h: 110),
                          text: "Show counts next to the percentages here too.", createdAt: ago - 40_000),
        ])
        return FixtureDesigns.Item(design: design, revision: 12, index: index, files: files.mapValues { Data($0.utf8) }, comments: comments)
    }

    /// The element a board names `name` (`data-el`), as a comment anchors to it.
    static func element(_ name: String, in source: String) -> (tid: Int, path: [Int]) {
        let found = DesignTemplate(board: source)?.elements.first { DesignStyleEdit.attribute("data-el", of: $0.tid, in: source) == name }
        return found.map { ($0.tid, $0.path) } ?? (0, [0])
    }

    static func empty(_ design: Design) -> FixtureDesigns.Item {
        FixtureDesigns.Item(design: design, revision: 1, index: DesignIndex(title: design.name), files: [:], comments: DesignComments())
    }

    /// acme-web: the chip's three colors.
    static var acmeWeb: DesignSystemRead {
        let tokens = try? DesignSystemTokens(json: .object(["colors": .array([
            .object(["name": .string("--accent"), "value": .string("#4f46e5")]),
            .object(["name": .string("--ink"), "value": .string("#0f172a")]),
            .object(["name": .string("--bg"), "value": .string("#e2e8f0")]),
        ])]))
        let info = DesignSystemInfo(namespace: "acme-web", title: "acme-web", createdAt: FixtureData.start)
        return DesignSystemRead(summary: DesignSystemSummary(info: info), tokens: tokens, readme: nil, files: ["tokens.json"])
    }

    // MARK: The design agent's chat

    /// DZCanvas's chat: the brief, reading the system, drawing four boards, checking them, and the
    /// agent's summary.
    static func chat() -> NativeThreadSnapshot {
        FixtureData.snapshot([
            FixtureData.user("c1", "Design the checkout funnel dashboard for the product team. They need drop-off per step, a trend over time, and it has to work on a phone."),
            FixtureData.tool("c2", "design_read", args: #"{"path":"ds/acme-web/tokens.json"}"#, output: "acme-web · 18 tokens", at: 6_000),
            FixtureData.tool("c3", "board_write", args: #"{"path":"A.dc.html"}"#, output: "Drew A.dc.html", at: 40_000),
            FixtureData.tool("c4", "board_write", args: #"{"path":"B.dc.html"}"#, output: "Drew B.dc.html", at: 60_000),
            FixtureData.tool("c5", "board_write", args: #"{"path":"C.dc.html"}"#, output: "Drew C.dc.html", at: 80_000),
            FixtureData.tool("c6", "board_write", args: #"{"path":"A-phone.dc.html"}"#, output: "Drew A-phone.dc.html", at: 95_000),
            FixtureData.tool("c7", "design_check", args: #"{}"#, output: "Checked against acme-web · 0 off-system values", at: 100_000),
            FixtureData.assistant("c8", "Three directions, all in acme-web. **A** leads with the funnel, **B** with a step table you can sort and export, **C** with the trend. I drew a phone version of A because it holds up best at narrow widths.", at: 104_000),
        ])
    }

    /// iPadSplitView: the agent's latest reply, restyled to the worker's new tokens.
    static func splitThread() -> NativeThreadSnapshot {
        let now = Date().timeIntervalSince1970 * 1000 - FixtureData.start
        var thread = chat()
        thread.messages += [
            FixtureData.user("s1", "The worker just landed new tokens. Restyle the boards to them.", at: now - 90_000),
            FixtureData.tool("s2", "board_write", args: #"{"path":"A.dc.html"}"#, output: "Updated A.dc.html", at: now - 40_000),
            FixtureData.tool("s3", "board_write", args: #"{"path":"A-phone.dc.html"}"#, output: "Updated A-phone.dc.html", at: now - 20_000),
            FixtureData.assistant("s4", "Restyled boards to the new tokens the worker just landed. Want the thread to use these as the spec?", at: now - 5_000),
        ]
        return thread
    }
}

/// What a fixture host serves over designs.v1: its designs' files by path (hashed as served),
/// their indexes and comments, and its design systems. Reads only; the host refuses every write
/// before it gets here.
struct FixtureDesigns: Sendable {
    struct Item: Sendable {
        var design: Design
        var revision: UInt64
        var index: DesignIndex
        /// Files under `project/` by path (boards and anything they load), never canvas.json.
        var files: [String: Data]
        var comments: DesignComments
    }

    struct Refusal: Error {
        var code: String
        var message: String
    }

    var designs: [Item]
    var systems: [DesignSystemRead] = []

    func answer(_ request: RemoteDesignRequest) -> Result<RemoteDesignResult, Refusal> {
        switch request {
        case .list:
            return .success(.listing(RemoteDesignListing(designs: designs.map(summary), systems: systems.map(\.summary))))
        case .index(let id):
            return item(id).map { .index(RemoteDesignIndex(snapshot: snapshot($0), files: infos($0))) }
        case .boards(let id, let paths, let known):
            return item(id).map { item in
                var changed: [RemoteDesignFile] = [], unchanged: [String] = [], missing: [String] = []
                for path in paths ?? item.files.keys.sorted() {
                    guard let data = item.files[path] else { missing.append(path); continue }
                    let sha = Self.sha256(data)
                    if known[path] == sha { unchanged.append(path); continue }
                    changed.append(RemoteDesignFile(path: path, sha256: sha, size: data.count,
                                                    data: data.count <= RemoteProtocol.designChunkBytes ? data : nil))
                }
                return .files(RemoteDesignFiles(designID: id, revision: item.revision, changed: changed, unchanged: unchanged, missing: missing))
            }
        case .file(let id, let path, let sha, let offset):
            guard case .success(let item) = item(id), let data = item.files[path] else {
                return .failure(Refusal(code: RemoteDesignCode.noSuchFile, message: "no file at \(path)"))
            }
            guard Self.sha256(data) == sha else { return .failure(Refusal(code: RemoteDesignCode.staleFile, message: "\(path) changed")) }
            guard offset >= 0, offset <= data.count else { return .failure(Refusal(code: "invalid_offset", message: "offset \(offset)")) }
            let end = min(data.count, offset + RemoteProtocol.designChunkBytes)
            return .success(.chunk(RemoteDesignChunk(sha256: sha, offset: offset, total: data.count, data: data.subdata(in: offset..<end))))
        case .asset(_, let blob, _):
            return .failure(Refusal(code: RemoteDesignCode.noSuchFile, message: "no upload \(blob)"))
        case .comments(let id):
            return item(id).map { .comments($0.comments) }
        case .system(let namespace):
            guard let system = systems.first(where: { $0.summary.namespace == namespace }) else {
                return .failure(Refusal(code: "no_such_system", message: "no design system \(namespace)"))
            }
            return .success(.system(system))
        case .watch:
            return .success(.ok)
        case .addComment, .replyToComment, .resolveComment, .writeBoards, .updateIndex, .duplicateBoard, .restoreVersions:
            return .failure(Refusal(code: "fixture", message: "The fixture host changes nothing."))
        }
    }

    private func item(_ id: DesignID) -> Result<Item, Refusal> {
        guard let item = designs.first(where: { $0.design.id == id }) else {
            return .failure(Refusal(code: "no_such_design", message: "unknown design \(id)"))
        }
        return .success(item)
    }

    private func snapshot(_ item: Item) -> DesignSnapshot {
        var boards: [DesignPath: String] = [:]
        for path in item.index.boards.keys { if let data = item.files[path.rawValue] { boards[path] = Self.sha256(data) } }
        return DesignSnapshot(designID: item.design.id, revision: item.revision, index: item.index, boards: boards)
    }

    private func infos(_ item: Item) -> [RemoteDesignFileInfo] {
        item.files.keys.sorted().map { RemoteDesignFileInfo(path: $0, sha256: Self.sha256(item.files[$0]!), size: item.files[$0]!.count) }
    }

    private func summary(_ item: Item) -> RemoteDesignSummary {
        let first = item.index.order.first.flatMap { path -> RemoteDesignFirstBoard? in
            guard let board = item.index.boards[path], let data = item.files[path.rawValue] else { return nil }
            return RemoteDesignFirstBoard(path: path, sha256: Self.sha256(data), width: board.w, height: board.h)
        }
        return RemoteDesignSummary(design: item.design, revision: item.revision, boardCount: item.index.boards.count,
                                   openComments: item.comments.open.count, firstBoard: first)
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
