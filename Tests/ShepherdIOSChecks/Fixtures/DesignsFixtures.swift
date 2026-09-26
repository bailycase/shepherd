import Foundation
import UIKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// Designs track's screens (MobileAgents' Designs row and Recents, MobileDesigns, MobileDesignBoard,
// MobileSearch's Designs section, MobileMore's Design systems). Studio serves designs.v1 from the
// files below; like every fixture host it refuses anything that would change it (a comment, a
// new design, a tweak), and every board renders on the simulator, never on the host.
extension FixtureCatalog {
    static var designs: [FixtureScreen] {
        let checkout = DesignsFixtures.ref(DesignsFixtures.checkout)
        let phone = DesignsFixtures.phone.rawValue
        let quiet = DesignsFixtures.hosts(updating: false)
        let updating = DesignsFixtures.hosts(updating: true)
        return [
            FixtureScreen(name: "home-designs", hosts: quiet, prepare: { app in
                await DesignsFixtures.listed(app)
                await HomeFeed.of(app.hosts).refresh()
            }),
            FixtureScreen(name: "designs", hosts: quiet, routes: [.designs(.list)], prepare: { app in
                await DesignsFixtures.listed(app)
                await DesignsFixtures.drawn(images: 4)
            }),
            FixtureScreen(name: "design", hosts: quiet, routes: [.designs(.design(checkout))], prepare: { app in
                await DesignsFixtures.synced(app, checkout)
                await DesignsFixtures.drawn(images: 4)
            }),
            FixtureScreen(name: "design-board", hosts: updating,
                          routes: [.designs(.design(checkout)), .designs(.board(checkout, path: phone))], prepare: { app in
                guard let model = await DesignsFixtures.board() else { return }
                model.commenting = true
                model.selected = DesignsFixtures.stepsComment
                await DesignsFixtures.checkLiveViews()
            }),
            FixtureScreen(name: "design-comment", hosts: updating,
                          routes: [.designs(.design(checkout)), .designs(.board(checkout, path: phone))], prepare: { app in
                guard let model = await DesignsFixtures.board() else { return }
                // A tap on the Steps list's second step, as Comment on takes it.
                await model.pickForComment(at: CGPoint(x: 120, y: 330))
                model.draftText = "Label the drop-off between each step"
                await FixtureWindows.wait(seconds: 3) { model.draft != nil }
                // The keyboard (and the simulator's first-run tip over it) stays out of the shot.
                try? await Task.sleep(for: .seconds(1))
                UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                print(model.draft == nil ? "FIXTURE CHECK FAILED: the tap named no element" : "FIXTURE CHECK ok: picked \(model.draft!.tag)")
            }),
            FixtureScreen(name: "design-boards", hosts: quiet,
                          routes: [.designs(.design(checkout)), .designs(.board(checkout, path: phone))],
                          presented: .designs(.boards(checkout, current: phone)), prepare: { _ in
                await DesignsFixtures.drawn(images: 4)
            }),
            FixtureScreen(name: "search-designs", hosts: quiet, routes: [.search(.search(query: "funnel"))], prepare: { app in
                await DesignsFixtures.listed(app)
            }),
            FixtureScreen(name: "more-designs", hosts: quiet, routes: [.home(.more)], prepare: { app in
                await DesignsFixtures.listed(app)
            }),
            FixtureScreen(name: "design-systems", hosts: quiet, routes: [.home(.more), .designs(.systems)], prepare: { app in
                await DesignsFixtures.listed(app)
            }),
            FixtureScreen(name: "design-system", hosts: quiet, routes: [.designs(.system(host: FixtureData.studio, namespace: "acme-web"))]),
            FixtureScreen(name: "new-design", hosts: quiet, presented: .designs(.newDesign(brief: "funnel", host: nil)), prepare: { app in
                await DesignsFixtures.listed(app)
            }),
        ]
    }
}

/// What a fixture host serves over designs.v1: its listing, each design's files, comments and
/// systems. Reads only; the host refuses every write before this sees it.
struct FixtureDesigns {
    struct Design {
        var record: ShepherdCore.Design
        var index: DesignIndex
        var files: [String: Data]
        var comments = DesignComments()
    }

    var designs: [Design]
    var systems: [DesignSystemRead]

    func answer(_ request: RemoteDesignRequest) -> Result<RemoteDesignResult, FixtureError> {
        switch request {
        case .list:
            return .success(.listing(RemoteDesignListing(designs: designs.map(summary), systems: systems.map(\.summary))))
        case .index(let id):
            guard let design = design(id) else { return .failure(FixtureError("no design \(id)")) }
            return .success(.index(RemoteDesignIndex(snapshot: snapshot(design), files: design.files.keys.sorted().map { path in
                RemoteDesignFileInfo(path: path, sha256: RemoteDesignCache.sha256(design.files[path]!), size: design.files[path]!.count)
            })))
        case .boards(let id, let paths, let known):
            guard let design = design(id) else { return .failure(FixtureError("no design \(id)")) }
            var changed: [RemoteDesignFile] = []
            var unchanged: [String] = []
            var missing: [String] = []
            for path in paths ?? design.files.keys.sorted() {
                guard let data = design.files[path] else { missing.append(path); continue }
                let sha = RemoteDesignCache.sha256(data)
                if known[path] == sha { unchanged.append(path) } else {
                    changed.append(RemoteDesignFile(path: path, sha256: sha, size: data.count, data: data))
                }
            }
            return .success(.files(RemoteDesignFiles(designID: id, revision: 3, changed: changed, unchanged: unchanged, missing: missing)))
        case .file(let id, let path, _, let offset):
            guard let data = design(id)?.files[path], offset >= 0, offset <= data.count else { return .failure(FixtureError("no file")) }
            let piece = data.subdata(in: offset..<min(data.count, offset + RemoteProtocol.designChunkBytes))
            return .success(.chunk(RemoteDesignChunk(sha256: RemoteDesignCache.sha256(data), offset: offset, total: data.count, data: piece)))
        case .comments(let id):
            guard let design = design(id) else { return .failure(FixtureError("no design \(id)")) }
            return .success(.comments(design.comments))
        case .system(let namespace):
            guard let system = systems.first(where: { $0.summary.namespace == namespace }) else { return .failure(FixtureError("no system")) }
            return .success(.system(system))
        case .watch:
            return .success(.ok)
        default:
            return .failure(FixtureError("No fixture answer for this design request."))
        }
    }

    private func design(_ id: DesignID) -> Design? { designs.first { $0.record.id == id } }

    private func snapshot(_ design: Design) -> DesignSnapshot {
        DesignSnapshot(designID: design.record.id, revision: 3, index: design.index,
                       boards: Dictionary(uniqueKeysWithValues: design.index.boards.keys.compactMap { path in
                           design.files[path.rawValue].map { (path, RemoteDesignCache.sha256($0)) }
                       }))
    }

    private func summary(_ design: Design) -> RemoteDesignSummary {
        let snapshot = snapshot(design)
        let first = design.index.order.first.flatMap { path -> RemoteDesignFirstBoard? in
            guard let board = design.index.boards[path], let sha = snapshot.boards[path] else { return nil }
            return RemoteDesignFirstBoard(path: path, sha256: sha, width: board.w, height: board.h)
        }
        return RemoteDesignSummary(design: design.record, revision: 3, boardCount: design.index.boards.count,
                                   openComments: design.comments.open.count, firstBoard: first)
    }
}

enum DesignsFixtures {
    static let checkout = DesignID(rawValue: "design-checkout")
    static let events = DesignID(rawValue: "design-events")
    static let onboarding = DesignID(rawValue: "design-onboarding")
    static let settings = DesignID(rawValue: "design-settings")
    static let designer = AgentID(rawValue: "agent-designer")
    static let onboarder = AgentID(rawValue: "agent-onboarder")
    static let dashboardSpace = Space(id: SpaceID(rawValue: "space-dashboard"), name: "dashboard-web", path: "/Users/dev/dashboard-web")

    static let wide = DesignPath("A.dc.html")!
    static let table = DesignPath("B.dc.html")!
    static let trend = DesignPath("C.dc.html")!
    static let phone = DesignPath("A-phone.dc.html")!
    static let explorer = DesignPath("Events.dc.html")!
    static let welcome = DesignPath("Welcome.dc.html")!
    static let settingsBoard = DesignPath("Settings.dc.html")!

    static let cartComment = UUID(uuidString: "C0000000-0000-4000-8000-000000000001")!
    static let stepsComment = UUID(uuidString: "C0000000-0000-4000-8000-000000000002")!

    static func ref(_ design: DesignID) -> HostDesignRef { HostDesignRef(host: FixtureData.studio, design: design) }

    /// Studio serves designs; build-01 doesn't (its Design tool off), and the laptop is offline.
    /// `updating`: the design agent is at work on the Steps list comment (MobileDesignBoard).
    static func hosts(updating: Bool) -> [FixtureHostData] {
        var hosts = FixtureData.hosts()
        let now = Date().timeIntervalSince1970 * 1000
        let records = [
            Design(id: checkout, name: "Checkout funnel dashboard", spaceID: dashboardSpace.id, agentID: designer,
                   systemNamespace: "acme-web", createdAt: now - 86_400_000, lastActiveAt: now - 120_000, boardCount: 4),
            Design(id: events, name: "Events explorer", spaceID: dashboardSpace.id, systemNamespace: "acme-web",
                   createdAt: now - 3 * 86_400_000, lastActiveAt: now - 26 * 3_600_000, boardCount: 3),
            Design(id: onboarding, name: "Onboarding flow", spaceID: dashboardSpace.id, agentID: onboarder,
                   createdAt: now - 600_000, lastActiveAt: now - 60_000, boardCount: 2),
            Design(id: settings, name: "Settings redesign", spaceID: FixtureData.shepherdSpace.id, systemNamespace: "night-watch",
                   createdAt: now - 5 * 86_400_000, lastActiveAt: now - 4 * 86_400_000, boardCount: 2),
        ]
        hosts[0].state.spaces.append(dashboardSpace)
        hosts[0].state.designs = records
        hosts[0].state.agents += [
            Agent(id: designer, name: "Checkout funnel dashboard", spaceID: dashboardSpace.id, tabID: TabID(rawValue: "tab-designer"),
                  status: updating ? .working : .idle, nameIsFinal: true, designID: checkout),
            Agent(id: onboarder, name: "Onboarding flow", spaceID: dashboardSpace.id, tabID: TabID(rawValue: "tab-onboarder"),
                  status: .working, nameIsFinal: true, designID: onboarding),
        ]
        hosts[0].threads[designer] = FixtureData.snapshot([
            FixtureData.user("d1", "A checkout funnel dashboard for the product team"),
            FixtureData.assistant("d2", "Drew 4 boards: three directions and a phone version of the first.", at: 60_000),
        ], running: updating)
        hosts[0].threads[onboarder] = FixtureData.snapshot([FixtureData.user("o1", "An onboarding flow")], running: true)
        hosts[0].designs = FixtureDesigns(designs: [
            FixtureDesigns.Design(record: records[0], index: DesignIndex(title: "Checkout funnel dashboard", boards: [
                wide: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Funnel first"),
                table: DesignIndex.Board(x: 1360, y: 0, w: 1280, h: 800, title: "B · Step table"),
                trend: DesignIndex.Board(x: 2720, y: 0, w: 1280, h: 800, title: "C · Trend first"),
                phone: DesignIndex.Board(x: 0, y: 920, w: 390, h: 844, title: "A · phone"),
            ], order: [wide, table, trend, phone]), files: [
                wide.rawValue: Boards.funnel, table.rawValue: Boards.table, trend.rawValue: Boards.trend, phone.rawValue: Boards.phone,
            ], comments: comments(now: now)),
            FixtureDesigns.Design(record: records[1], index: DesignIndex(title: "Events explorer", boards: [
                explorer: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · Table first"),
                table: DesignIndex.Board(x: 1360, y: 0, w: 1280, h: 800, title: "B · Steps"),
                trend: DesignIndex.Board(x: 2720, y: 0, w: 1280, h: 800, title: "C · Trend"),
            ], order: [explorer, table, trend]), files: [
                explorer.rawValue: Boards.explorer, table.rawValue: Boards.table, trend.rawValue: Boards.trend,
            ]),
            FixtureDesigns.Design(record: records[2], index: DesignIndex(title: "Onboarding flow", boards: [
                welcome: DesignIndex.Board(x: 0, y: 0, w: 390, h: 844, title: "A · Welcome"),
                phone: DesignIndex.Board(x: 470, y: 0, w: 390, h: 844, title: "A · Funnel"),
            ], order: [phone, welcome]), files: [welcome.rawValue: Boards.welcome, phone.rawValue: Boards.phone]),
            FixtureDesigns.Design(record: records[3], index: DesignIndex(title: "Settings redesign", boards: [
                settingsBoard: DesignIndex.Board(x: 0, y: 0, w: 1280, h: 800, title: "A · General"),
                trend: DesignIndex.Board(x: 1360, y: 0, w: 1280, h: 800, title: "B · Usage"),
            ], order: [settingsBoard, trend]), files: [settingsBoard.rawValue: Boards.settings, trend.rawValue: Boards.trend]),
        ], systems: [
            DesignSystemRead(summary: DesignSystemSummary(
                info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", createdAt: now), builtIn: true,
                counts: DesignSystemCounts(colors: 3, type: 2, lengths: 2)),
                tokens: DesignSystemTokens(colors: [
                    .init(name: "--lantern", value: "#f2a93b"), .init(name: "--bg-base", value: "#0d0e10"),
                    .init(name: "--text-primary", value: "#e8e9ec"),
                ], type: [.init(name: "title", size: 24, weight: 600), .init(name: "body", size: 13)],
                spacing: [.init(name: "--space-l", px: 12)], radii: [.init(name: "--radius-l", px: 12)]),
                readme: nil, files: []),
            DesignSystemRead(summary: DesignSystemSummary(
                info: DesignSystemInfo(namespace: "acme-web", title: "acme-web", createdAt: now, syncedAt: now - 240_000,
                                       spaceID: dashboardSpace.id, sources: ["web/static/tokens.css"]),
                counts: DesignSystemCounts(colors: 5, type: 3, lengths: 3)),
                tokens: DesignSystemTokens(colors: [
                    .init(name: "--accent", value: "#4f46e5", source: .init(file: "web/static/tokens.css", line: 4)),
                    .init(name: "--text", value: "#0f172a", source: .init(file: "web/static/tokens.css", line: 5)),
                    .init(name: "--bg", value: "#f8fafc", source: .init(file: "web/static/tokens.css", line: 6)),
                    .init(name: "--line", value: "#e2e8f0", source: .init(file: "web/static/tokens.css", line: 7)),
                    .init(name: "--success", value: "#059669", source: .init(file: "web/static/tokens.css", line: 8)),
                ], type: [.init(name: "heading", size: 22, weight: 700), .init(name: "metric", size: 28, weight: 700),
                          .init(name: "body", size: 14)],
                spacing: [.init(name: "--space-3", px: 12), .init(name: "--space-4", px: 16)], radii: [.init(name: "--radius", px: 12)]),
                readme: "# acme-web\n", files: ["tokens.css", "tokens.json"]),
        ])
        return hosts
    }

    /// Two comments on the phone board, pinned on its first step and its Steps list.
    static func comments(now: Double) -> DesignComments {
        let source = String(decoding: Boards.phone, as: UTF8.self)
        func anchor(_ marker: String) -> (tid: Int, path: [Int]) {
            guard let template = DesignTemplate(board: source) else { return (0, [0]) }
            let bytes = Array(source.utf8)
            let element = template.elements.first { element in
                guard let range = element.tagRange else { return false }
                return String(decoding: bytes[range], as: UTF8.self).contains(marker)
            }
            return (element?.tid ?? 0, element?.path ?? [0])
        }
        let cart = anchor(#"data-el="Cart viewed""#)
        let steps = anchor(#"data-el="Steps list""#)
        return DesignComments(revision: 2, comments: [
            DesignComment(id: cartComment, number: 1, board: phone, tid: cart.tid, path: cart.path, label: "100.0%", target: "Cart viewed",
                          rect: DesignCommentRect(x: 300, y: 262, w: 58, h: 18), text: "Round the bar ends.",
                          createdAt: now - 900_000,
                          replies: [DesignCommentReply(author: .agent, text: "Done on A and A · phone.", createdAt: now - 600_000)]),
            DesignComment(id: stepsComment, number: 2, board: phone, tid: steps.tid, path: steps.path, label: "Steps", target: "Steps list",
                          rect: DesignCommentRect(x: 18, y: 222, w: 354, h: 300),
                          text: "Make the bars thicker on phones. Hard to read at a glance.", createdAt: now - 20_000),
        ])
    }

    // MARK: Waiting for what a screen shows

    /// Every serving host's designs listed.
    @MainActor static func listed(_ app: MobileApp) async {
        let designs = MobileDesigns.of(app.hosts)
        await designs.refresh()
        await FixtureWindows.wait(seconds: 10) { !designs.model.tiles.isEmpty }
    }

    @MainActor static func synced(_ app: MobileApp, _ ref: HostDesignRef) async {
        let designs = MobileDesigns.of(app.hosts)
        await FixtureWindows.wait(seconds: 10) { designs.indexes[ref] != nil }
    }

    /// Boards drawn into images by the renderer (the tiles).
    @MainActor static func drawn(images: Int) async {
        await FixtureWindows.wait(seconds: 30) { DesignRendering.shared.renderedImages >= images }
    }

    /// The board screen on show, once its board has drawn and its pins are placed.
    @MainActor static func board() async -> DesignBoardModel? {
        await FixtureWindows.wait(seconds: 10) { DesignBoardModel.onScreen?.live != nil }
        guard let model = DesignBoardModel.onScreen, let live = model.live else {
            print("FIXTURE CHECK FAILED: no board on screen")
            return nil
        }
        await FixtureWindows.wait(seconds: 20) { live.booted || live.failure != nil }
        if !live.booted { print("FIXTURE CHECK FAILED: the board didn't draw") }
        await model.measurePins()
        return model
    }

    /// At most two web views lived at once: the board on screen and the renderer's.
    @MainActor static func checkLiveViews() async {
        let peak = DesignRendering.shared.peakLiveViews
        print(peak <= DesignRendering.liveCap ? "FIXTURE CHECK ok: at most \(peak) live web views"
              : "FIXTURE CHECK FAILED: \(peak) live web views at once (the cap is \(DesignRendering.liveCap))")
    }
}

/// Boards for the fixtures, written for them: a checkout funnel dashboard in a made-up product's
/// own light system (acme), and a settings page in Night Watch.
private enum Boards {
    static func board(_ title: String, width: Int, height: Int, style: String, body: String) -> Data {
        Data("""
        <!doctype html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <title>\(title)</title>
        <script src="./support.js"></script>
        </head>
        <body>
        <x-dc>
        <helmet>
        <style>
        body{margin:0;font-family:-apple-system,system-ui,sans-serif;-webkit-font-smoothing:antialiased}
        \(style)
        </style>
        </helmet>
        \(body)
        </x-dc>
        <script type="text/x-dc" data-dc-script data-props='{"$preview":{"width":\(width),"height":\(height)}}'>
        class Component extends DCLogic {
          renderVals() { return {}; }
        }
        </script>
        </body>
        </html>
        """.utf8)
    }

    static let acme = """
    .page{background:#f8fafc;color:#0f172a;display:flex;flex-direction:column;overflow:hidden}
    .bar{display:flex;align-items:center;gap:8px;background:#fff;border-bottom:1px solid #e2e8f0;font-weight:700}
    .mark{width:20px;height:20px;border-radius:6px;background:#4f46e5}
    .card{background:#fff;border:1px solid #e2e8f0;border-radius:12px}
    .kpi{display:flex;flex-direction:column;gap:8px;padding:18px 20px}
    .kpi span:first-child{font-size:13px;color:#64748b}
    .kpi b{font-size:28px;letter-spacing:-0.02em}
    .kpi em{font-style:normal;font-size:13px;font-weight:600;color:#059669;margin-left:8px}
    .step{display:flex;flex-direction:column;gap:6px;padding:10px 0;border-top:1px solid #e2e8f0}
    .step:first-of-type{border-top:none}
    .step>span:first-child{display:flex;font-size:14px}
    .step>span:first-child b{margin-left:auto}
    .track{height:10px;border-radius:5px;background:#eef2ff;display:block}
    .fill{display:block;height:100%;border-radius:5px;background:#4f46e5}
    """

    static let steps = [("Cart viewed", "100.0"), ("Checkout started", "26.8"), ("Shipping entered", "20.5"),
                        ("Payment entered", "13.5"), ("Order placed", "9.1")]

    static func stepRows(marked: Bool) -> String {
        steps.enumerated().map { index, step in
            let mark = marked && index == 0 ? #" data-el="Cart viewed""# : ""
            return #"<div class="step"><span>\#(step.0)<b\#(mark)>\#(step.1)%</b></span><span class="track"><span class="fill" style="width: \#(step.1)%"></span></span></div>"#
        }.joined(separator: "\n")
    }

    static let phone = board("Checkout funnel · phone", width: 390, height: 844, style: acme, body: """
    <div class="page" style="width: 390px; height: 844px;">
    <div class="bar" style="height: 54px; padding: 0 18px; font-size: 16px;"><span class="mark"></span>acme<span style="margin-left: auto; font-size: 13px; font-weight: 500; color: #64748b;">30 days</span></div>
    <div style="padding: 20px 18px; display: flex; flex-direction: column; gap: 14px;">
    <span style="font-size: 22px; font-weight: 700;">Checkout funnel</span>
    <div style="display: grid; grid-template-columns: repeat(2, minmax(0, 1fr)); gap: 10px;">
    <div class="card kpi"><span>Conversion</span><span><b>9.1%</b><em>+0.6pt</em></span></div>
    <div class="card kpi"><span>Orders</span><span><b>4,388</b><em>+6.9%</em></span></div>
    </div>
    <div class="card" data-el="Steps list" style="padding: 14px 16px;">
    <div style="font-size: 15px; font-weight: 600; margin-bottom: 10px;">Steps</div>
    \(stepRows(marked: true))
    </div>
    </div>
    </div>
    """)

    static let funnel = board("Checkout funnel · A", width: 1280, height: 800, style: acme, body: """
    <div class="page" style="width: 1280px; height: 800px;">
    <div class="bar" style="height: 60px; padding: 0 32px; font-size: 16px;"><span class="mark"></span>acme<span style="margin-left: 40px; font-size: 13px; font-weight: 500; color: #4f46e5;">Funnels</span><span style="font-size: 13px; font-weight: 500; color: #64748b;">Events</span><span style="margin-left: auto; font-size: 13px; font-weight: 500; color: #64748b;">Last 30 days</span></div>
    <div style="padding: 28px 32px; display: flex; flex-direction: column; gap: 20px;">
    <span style="font-size: 26px; font-weight: 700;">Checkout funnel</span>
    <div style="display: grid; grid-template-columns: repeat(4, minmax(0, 1fr)); gap: 16px;">
    <div class="card kpi"><span>Visitors</span><span><b>48,210</b><em>+4.2%</em></span></div>
    <div class="card kpi"><span>Checkout rate</span><span><b>26.8%</b><em>+1.1pt</em></span></div>
    <div class="card kpi"><span>Conversion</span><span><b>9.1%</b><em>+0.6pt</em></span></div>
    <div class="card kpi"><span>Orders</span><span><b>4,388</b><em>+6.9%</em></span></div>
    </div>
    <div style="display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 16px;">
    <div class="card" style="grid-column: span 2; padding: 18px 20px;"><div style="font-size: 15px; font-weight: 600; margin-bottom: 8px;">Steps</div>\(stepRows(marked: false))</div>
    <div class="card" style="padding: 18px 20px; display: flex; flex-direction: column; gap: 12px;"><span style="font-size: 15px; font-weight: 600;">Biggest drop-off</span><span style="font-size: 32px; font-weight: 700; color: #dc2626;">−73.2%</span><span style="font-size: 13px; color: #64748b;">Cart viewed → Checkout started</span></div>
    </div>
    </div>
    </div>
    """)

    static let table = board("Checkout funnel · B", width: 1280, height: 800, style: acme + """
    td,th{padding:14px 20px;text-align:left;border-top:1px solid #e2e8f0;font-size:14px}
    th{font-size:12px;color:#64748b;font-weight:600;border-top:none}
    """, body: """
    <div class="page" style="width: 1280px; height: 800px;">
    <div class="bar" style="height: 60px; padding: 0 32px; font-size: 16px;"><span class="mark"></span>acme</div>
    <div style="padding: 28px 32px; display: flex; flex-direction: column; gap: 20px;">
    <span style="font-size: 26px; font-weight: 700;">Checkout funnel · steps</span>
    <div class="card"><table style="width: 100%; border-collapse: collapse;"><tr><th>Step</th><th>People</th><th>Of visitors</th><th>Drop-off</th></tr>
    <tr><td>Cart viewed</td><td>48,210</td><td>100.0%</td><td>—</td></tr>
    <tr><td>Checkout started</td><td>12,920</td><td>26.8%</td><td style="color: #dc2626;">−73.2%</td></tr>
    <tr><td>Shipping entered</td><td>9,883</td><td>20.5%</td><td style="color: #dc2626;">−23.5%</td></tr>
    <tr><td>Payment entered</td><td>6,508</td><td>13.5%</td><td style="color: #dc2626;">−34.1%</td></tr>
    <tr><td>Order placed</td><td>4,388</td><td>9.1%</td><td style="color: #dc2626;">−32.6%</td></tr></table></div>
    </div>
    </div>
    """)

    static let trend = board("Checkout funnel · C", width: 1280, height: 800, style: acme, body: """
    <div class="page" style="width: 1280px; height: 800px;">
    <div class="bar" style="height: 60px; padding: 0 32px; font-size: 16px;"><span class="mark"></span>acme</div>
    <div style="padding: 28px 32px; display: flex; flex-direction: column; gap: 20px;">
    <span style="font-size: 26px; font-weight: 700;">Conversion over time</span>
    <div class="card" style="padding: 24px;"><svg width="1150" height="420" viewBox="0 0 1150 420"><path d="M0 330 C 120 300, 200 340, 320 280 S 520 220, 640 240 S 860 140, 980 160 S 1100 90, 1150 100" fill="none" stroke="#4f46e5" stroke-width="4"/><path d="M0 380 L1150 380" stroke="#e2e8f0" stroke-width="2"/></svg></div>
    </div>
    </div>
    """)

    static let explorer = board("Events explorer", width: 1280, height: 800, style: acme, body: """
    <div class="page" style="width: 1280px; height: 800px;">
    <div class="bar" style="height: 60px; padding: 0 32px; font-size: 16px;"><span class="mark"></span>acme<span style="margin-left: 40px; font-size: 13px; font-weight: 500; color: #4f46e5;">Events</span></div>
    <div style="padding: 28px 32px; display: flex; flex-direction: column; gap: 14px;">
    <span style="font-size: 26px; font-weight: 700;">Events</span>
    <div class="card" style="height: 44px;"></div>
    <div class="card" style="display: flex; flex-direction: column;">
    \((0..<8).map { _ in #"<div style="height: 52px; border-top: 1px solid #e2e8f0; display: flex; align-items: center; gap: 16px; padding: 0 20px;"><span style="width: 180px; height: 10px; border-radius: 5px; background: #e2e8f0;"></span><span style="width: 320px; height: 10px; border-radius: 5px; background: #eef2ff;"></span></div>"# }.joined(separator: "\n"))
    </div>
    </div>
    </div>
    """)

    static let welcome = board("Onboarding · welcome", width: 390, height: 844, style: acme, body: """
    <div class="page" style="width: 390px; height: 844px; padding: 80px 24px 40px; box-sizing: border-box; gap: 18px;">
    <span class="mark" style="width: 48px; height: 48px; border-radius: 14px;"></span>
    <span style="font-size: 30px; font-weight: 700; letter-spacing: -0.02em;">Welcome to acme</span>
    <span style="font-size: 16px; color: #64748b; line-height: 1.5;">See where shoppers drop off, and what to fix first.</span>
    <span style="margin-top: auto; height: 50px; border-radius: 12px; background: #4f46e5; color: #fff; font-weight: 600; display: flex; align-items: center; justify-content: center;">Get started</span>
    </div>
    """)

    static let settings = board("Settings · general", width: 1280, height: 800, style: """
    .nw{background:#0d0e10;color:#e8e9ec;display:flex}
    .row{display:flex;align-items:center;justify-content:space-between;padding:14px 18px;border-top:1px solid #1f2226;font-size:13px}
    """, body: """
    <div class="nw" style="width: 1280px; height: 800px;">
    <div style="width: 260px; background: #15171a; border-right: 1px solid #1f2226; padding: 20px 12px; display: flex; flex-direction: column; gap: 6px; font-size: 13px;">
    <span style="padding: 8px 10px; border-radius: 6px; background: #22252a;">General</span><span style="padding: 8px 10px; color: #9aa0a9;">Appearance</span><span style="padding: 8px 10px; color: #9aa0a9;">Agents</span><span style="padding: 8px 10px; color: #9aa0a9;">Remote</span>
    </div>
    <div style="flex-grow: 1; padding: 32px 40px; display: flex; flex-direction: column; gap: 18px;">
    <span style="font-size: 22px; font-weight: 600;">General</span>
    <div style="border: 1px solid #1f2226; border-radius: 10px; background: #15171a;"><div class="row" style="border-top: none;">Open at login<span style="width: 32px; height: 18px; border-radius: 9px; background: #f2a93b;"></span></div><div class="row">Default model<span style="color: #9aa0a9;">claude-opus</span></div><div class="row">Theme<span style="color: #9aa0a9;">Night Watch</span></div></div>
    </div>
    </div>
    """)
}
