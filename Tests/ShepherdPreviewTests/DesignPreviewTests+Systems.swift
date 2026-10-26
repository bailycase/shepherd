import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Design systems (DZSystem, NavDesigns, DZStart): a system built from a repository on its build's
/// page beside the build agent's chat, a build still reading its project, Shepherd Design on the
/// Design systems page, the Designs page's systems grid, and New design's card. Specimens are drawn by the board renderer
/// off screen and shown from their snapshots.
extension DesignPreviewTests {
    private static let systemPageSize = CGSize(width: 1440 - AppLayout.sidebarDefaultWidth, height: 848)
    private static let systemWindowSize = CGSize(width: 1440, height: 900)

    /// DZSystem's acme-web: 11 colors, 4 type styles, 7 spacing and radius steps, and six
    /// components with their specimens.
    static let acmeStylesheet = """
        :root {
          --bg: #f8fafc;
          --surface: #ffffff;
          --border: #e2e8f0;

          --accent: #4f46e5;
          --accent-soft: #eef2ff;
          --text: #0f172a;
          --muted: #64748b;
          --faint: #94a3b8;

          --success: #059669;
          --danger: #dc2626;
          --warn: #d97706;
        }

        """

    static var acmeWrite: DesignSystemWrite {
        func color(_ name: String, _ value: String, _ line: Int) -> JSONValue {
            .object(["name": .string(name), "value": .string(value),
                     "source": .object(["file": .string("web/static/tokens.css"), "line": .number(Double(line))])])
        }
        func style(_ name: String, _ size: Double, _ weight: Double, _ sample: String, upper: Bool = false) -> JSONValue {
            var fields: [String: JSONValue] = ["name": .string(name), "size": .number(size), "weight": .number(weight),
                                               "family": .string("system-ui"), "sample": .string(sample)]
            if upper { fields["transform"] = .string("uppercase") }
            return .object(fields)
        }
        func step(_ name: String, _ px: Double) -> JSONValue { .object(["name": .string(name), "px": .number(px)]) }
        func component(_ name: String, _ file: String) -> JSONValue {
            .object(["name": .string(name), "source": .object(["file": .string("templates/partials/\(file).html")]),
                     "specimen": .string("components/\(name.replacingOccurrences(of: " ", with: "")).html")])
        }
        let font = "font-family: system-ui, -apple-system, 'Segoe UI', sans-serif;"
        let specimens: [String: String] = [
            "Button": "<span style=\"display: inline-flex; align-items: center; height: 34px; padding: 0 14px; border-radius: 8px; \(font) "
                + "font-size: 13px; font-weight: 600; background: var(--accent); color: #fff;\">Export CSV</span>"
                + "<span style=\"display: inline-flex; align-items: center; height: 34px; padding: 0 14px; border-radius: 8px; \(font) "
                + "font-size: 13px; font-weight: 600; background: var(--surface); color: var(--text); border: 1px solid var(--border);\">Cancel</span>",
            "Chip": "<span style=\"height: 28px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; "
                + "background: var(--accent-soft); color: var(--accent); \(font) font-size: 12.5px; font-weight: 600;\">All platforms</span>"
                + "<span style=\"height: 28px; display: inline-flex; align-items: center; padding: 0 12px; border-radius: 999px; "
                + "border: 1px solid var(--border); color: var(--muted); \(font) font-size: 12.5px;\">Web</span>",
            "KPItile": "<div style=\"display: flex; flex-direction: column; gap: 4px; padding: 10px 16px; background: var(--surface); "
                + "border: 1px solid var(--border); border-radius: 12px; \(font)\"><span style=\"font-size: 12px; color: var(--muted);\">Orders</span>"
                + "<span style=\"display: flex; align-items: baseline; gap: 8px;\"><span style=\"font-size: 22px; font-weight: 700; "
                + "color: var(--text);\">4,388</span><span style=\"font-size: 12px; font-weight: 600; color: var(--success);\">+6.9%</span></span></div>",
            "Card": "<div style=\"width: 180px; height: 60px; background: var(--surface); border: 1px solid var(--border); border-radius: 12px;\"></div>",
            "Navbar": "<div style=\"width: 280px; height: 40px; display: flex; align-items: center; gap: 14px; padding: 0 14px; "
                + "background: var(--surface); border: 1px solid var(--border); border-radius: 8px; \(font) font-size: 12px;\">"
                + "<span style=\"width: 14px; height: 14px; border-radius: 4px; background: var(--accent);\"></span>"
                + "<span style=\"font-weight: 700; color: var(--text);\">acme</span><span style=\"color: var(--muted);\">Overview</span>"
                + "<span style=\"font-weight: 600; color: var(--text); box-shadow: inset 0 -2px 0 var(--accent);\">Funnels</span></div>",
            "Input": "<span style=\"width: 190px; height: 34px; display: flex; align-items: center; padding: 0 12px; border: 1px solid var(--border); "
                + "border-radius: 8px; background: var(--surface); \(font) font-size: 13px; color: var(--faint);\">Search events…</span>",
        ]
        var files: [String: JSONValue] = ["README.md": .string("# acme-web\n\nRead from dashboard-web's tokens.css and its partials.\n")]
        for (name, html) in specimens { files["components/\(name).html"] = .string(html + "\n") }
        return DesignSystemWrite(
            namespace: "acme-web",
            tokens: .object([
                "format": .string(DesignSystemTokens.format), "name": .string("acme-web"),
                "colors": .array([color("--accent", "#4f46e5", 8), color("--accent-soft", "#eef2ff", 9), color("--text", "#0f172a", 10),
                                  color("--muted", "#64748b", 11), color("--faint", "#94a3b8", 12), color("--bg", "#f8fafc", 4),
                                  color("--surface", "#ffffff", 5), color("--border", "#e2e8f0", 6), color("--success", "#059669", 14),
                                  color("--danger", "#dc2626", 15), color("--warn", "#d97706", 16)]),
                "type": .array([style("display", 26, 700, "Checkout funnel"), style("title", 15, 600, "Top exit reasons"),
                                style("body", 14, 400, "Where people drop off between cart and order."),
                                style("label", 12, 600, "People · conversion", upper: true)]),
                "spacing": .array([step("--space-2", 8), step("--space-3", 12), step("--space-4", 16), step("--space-6", 24)]),
                "radii": .array([step("--radius-sm", 6), step("--radius-md", 8), step("--radius-lg", 12)]),
                "components": .array([component("Button", "button"), component("Chip", "chip"), component("KPI tile", "kpi"),
                                      component("Card", "card"), component("Nav bar", "nav"), component("Input", "input")]),
            ]),
            files: files, sources: ["web/static/tokens.css"])
    }

    /// A project with acme-web's stylesheet, its build (a live stub agent), the system that agent
    /// wrote, a design drawn in it, and Shepherd Design.
    private func systemWorkspace(written: Bool = true) async throws -> (workspace: PreviewWorkspace, build: Design, agent: Agent) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm
        vm.designNetwork = .none
        vm.designLiveCap = 0
        workspace.server.designSystems.register(ShepherdDesignSystem.builtIn())
        let project = workspace.dir.appendingPathComponent("dashboard-web", isDirectory: true)
        let stylesheet = project.appendingPathComponent("web/static/tokens.css")
        try FileManager.default.createDirectory(at: stylesheet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.acmeStylesheet.utf8).write(to: stylesheet)
        let web = Space(name: "dashboard-web", path: project.path)
        // The build's agent lives in the reserved designs space, reading the project it builds from.
        let designs = Space.designs()
        var (agent, tab) = try await workspace.agent("dashboard-web", in: designs, order: 0, live: true, cwd: web.path)
        let build = Design(name: "dashboard-web", agentID: agent.id, createdAt: 1_000, buildsSystem: true, sourceSpaceID: web.id)
        agent.designID = build.id
        try await workspace.seed(ShepherdState(spaces: [web, designs], tabs: [tab], agents: [agent]))
        _ = try await workspace.server.createDesign(build)
        if written {
            _ = try await workspace.server.writeDesignSystem(Self.acmeWrite, for: build.id)
            let checkout = Design(name: "Checkout funnel dashboard", createdAt: 2_000)
            _ = try await workspace.server.createDesign(checkout)
            try await DesignFixtures.draw(DesignFixtures.checkout, in: checkout.id, on: workspace.server, perRow: 3)
            _ = try await workspace.server.installDesignSystem(checkout.id, namespace: "acme-web")
        }
        let server = workspace.server
        try await eventuallyOnMain("the designs to load") { vm.state == server.state }
        await vm.loadDesignSystems()
        return (workspace, build, agent)
    }

    /// DZSystem: acme-web on its build's page, its specimens drawn, beside the build agent's chat.
    @Test func designSystemPage() async throws {
        let (workspace, build, agent) = try await systemWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openSystemBuild(build.id)
        #expect(vm.selectedAgentID == agent.id)
        // The build's words, as "Build one from a repo" sends them.
        let server = workspace.server
        var ready: NativeThreadSnapshot?
        try await eventuallyAsync("the build's pi to start") {
            if case .snapshot(let value)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()),
               !value.piSessionID.isEmpty {
                ready = value
            }
            return ready != nil
        }
        let snapshot = try #require(ready)
        _ = try await server.nativeThread(agentID: agent.id, request: .send(
            expectedSessionID: snapshot.piSessionID, generation: snapshot.generation, operationID: UUID(),
            text: ShepherdViewModel.systemBuildBrief, delivery: .followUp))
        await vm.loadDesignSpecimens("acme-web")
        let specimens = vm.designRendering.specimens
        let store = vm.threadStores.store(for: agent.id)
        try await Preview.render("app-window-design-system", size: Self.systemWindowSize, ready: {
            (0..<6).allSatisfy { specimens.image("acme-web", $0) != nil } && !store.rows.isEmpty && !store.running
        }) {
            RootView(vm: vm)
        }
        let page = vm.designSystemPage(.build(build.id))
        #expect(page.sections.map(\.count) == [11, 4, 7, 6, 4])
    }

    /// Every section of acme-web at once, its six specimens drawn by the board renderer.
    @Test func designSystemSections() async throws {
        let (workspace, _, _) = try await systemWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.shownDesignSystem = "acme-web"
        await vm.loadDesignSpecimens("acme-web")
        let specimens = vm.designRendering.specimens
        try await Preview.render("page-design-system-sections", size: CGSize(width: Self.systemPageSize.width, height: 1500), ready: {
            (0..<6).allSatisfy { specimens.image("acme-web", $0) != nil }
        }) {
            DesignSystemDestination(vm: vm)
        }
    }

    /// A build whose agent is still reading its project.
    @Test func designSystemBuilding() async throws {
        let (workspace, build, _) = try await systemWorkspace(written: false)
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openSystemBuild(build.id)
        #expect(vm.designSystemPage(.build(build.id)).building)
        try await Preview.render("app-window-design-system-building", size: Self.systemWindowSize) {
            RootView(vm: vm)
        }
    }

    /// Shepherd UI as the user's system holds it, written as a design's agent writes it: Shepherd Design's values in
    /// light and dark, steps that say what they are for, the page copy its tokens.json carries, and components, three
    /// of them with a specimen. What the boards draw for it comes from this write, never from strings in a view.
    static func shepherdUIWrite() throws -> DesignSystemWrite {
        var tokens = ShepherdDesignSystem.tokens()
        tokens.name = "Shepherd UI"
        tokens.namespace = "shepherd-ui"
        let uses = ["--radius-xs": "pills, keycaps", "--radius-s": "buttons, fields, rows", "--radius-m": "cards, composer, code",
                    "--radius-l": "popovers, sheets"]
        tokens.radii = tokens.radii.map { step in
            var step = step
            step.extra["use"] = uses[step.name].map(JSONValue.string)
            return step
        }
        let specimens: [(name: String, group: String, html: String)] = [
            ("SettingsButton", "Settings", """
                <div style="display:flex;gap:8px;align-items:center"><span style="height:28px;padding:0 12px;border-radius:6px;\
                background:var(--lantern);color:var(--text-on-lantern);font:500 13px Geist,system-ui;display:flex;align-items:center">\
                Start the agent</span><span style="height:28px;padding:0 12px;border-radius:6px;border:1px solid var(--line-strong);\
                color:var(--text-primary);font:500 13px Geist,system-ui;display:flex;align-items:center">Review</span></div>
                """),
            ("StatusBadge", "Chat & agents", """
                <div style="display:flex;gap:8px"><span style="padding:2px 8px;border-radius:4px;background:var(--done-tint);\
                color:var(--done);font:500 12px Geist,system-ui">Done</span><span style="padding:2px 8px;border-radius:4px;\
                background:var(--failed-tint);color:var(--failed);font:500 12px Geist,system-ui">Failed</span></div>
                """),
            ("SettingsField", "Settings", """
                <span style="width:220px;height:28px;border-radius:6px;border:1px solid var(--line-strong);background:var(--bg-sunken);\
                color:var(--text-tertiary);font:13px Geist,system-ui;display:flex;align-items:center;padding:0 10px;\
                box-sizing:border-box">Search settings</span>
                """),
        ]
        tokens.components = specimens.map { item in
            DesignSystemTokens.Component(name: item.name, specimen: "components/\(item.name).html", export: "Shepherd.\(item.name)",
                                         extra: ["group": .string(item.group)])
        } + ["AttachButton", "ThreadComposer", "SidebarRow"].map { DesignSystemTokens.Component(name: $0, export: "Shepherd.\($0)") }
        tokens.extra["page"] = .object([
            "tagline": .string("The app’s own components and tokens. Quiet chrome around agents at work."),
            "summary": .string("Shepherd UI is what the Shepherd app draws with: the colors, type and spacing of its native views, "
                + "and the components every board in this design imports. A board links its tokens and bundle once, then draws a "
                + "component by name."),
            "source": .string("Made in Shepherd chat UI from the app’s Shepherd Design values. Not read from a repository, so there is "
                + "nothing to re-sync."),
            "principles": .array([
                ["Readable measure.", "The thread column is at most 820pt and agent prose 640pt."],
                ["Shape, not labels.", "No speaker labels or avatars: your turn is a bubble, the agent’s is unboxed prose."],
                ["Lantern means you.", "Amber marks the primary action and what needs you. Running blue marks work, links and focus."],
            ].map { .object(["lead": .string($0[0]), "text": .string($0[1])]) }),
            "voice": .object([
                "lead": .string("Write like an engineer handing over work: plain, specific and short. The agent does things; "
                    + "Shepherd reports them."),
                "examples": .array([["The agent needs an answer about the retry schedule.", "pi is waiting for your input!"],
                                    ["Tests failed twice. Open the log?", "Oops! Something went wrong."]]
                    .map { .object(["say": .string($0[0]), "avoid": .string($0[1])]) }),
                "rules": .array([.string("Sentence case in drawn UI, Title Case in native menus."),
                                 .string("Status is a dot or glyph plus a word. Color is never the only signal.")]),
            ]),
            "sizes": .array([["control", "32px", "Buttons and popups"], ["row", "28px", "Sidebar and list rows"],
                             ["thread", "820px", "Thread column, most"]]
                .map { .object(["name": .string($0[0]), "value": .string($0[1]), "use": .string($0[2])]) }),
        ])
        var files: [String: JSONValue] = ["README.md": .string("# Shepherd UI\n")]
        for item in specimens { files["components/\(item.name).html"] = .string(item.html + "\n") }
        return DesignSystemWrite(namespace: "shepherd-ui", title: "Shepherd UI", tokens: tokens.json, files: files)
    }

    /// Shepherd UI on its page (DesignSystemPage and its eight sibling boards): written as a design's agent writes
    /// it, with a design drawn in it so the contents menu lists one. Rendered at both text scales, light and dark,
    /// and tall enough to show every card, its specimens drawn by the board renderer.
    @Test func designSystemShepherdUI() async throws {
        let (workspace, _, _) = try await systemWorkspace(written: false)
        defer { workspace.stop() }
        let vm = workspace.vm
        let owner = Design(name: "Shepherd chat UI", createdAt: 2_500, boardCount: 104)
        _ = try await workspace.server.createDesign(owner)
        _ = try await workspace.server.writeDesignSystem(try Self.shepherdUIWrite(), for: owner.id)
        var design = Design(name: "Refund ledger", createdAt: 3_000, boardCount: 4)
        design.systemNamespace = "shepherd-ui"
        _ = try await workspace.server.createDesign(design)
        vm.adopt(workspace.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        #expect(vm.shownDestination == .designSystem)
        let page = vm.designSystemPage(.system("shepherd-ui"))
        let reference = try #require(page.reference)
        #expect(reference.used.map(\.name) == ["Refund ledger"])
        #expect(reference.componentTotal == 6 && reference.components.count == 3)
        await vm.loadDesignSpecimens("shepherd-ui")
        let specimens = vm.designRendering.specimens
        try await Preview.renderMatrix("page-design-system-shepherd-ui", size: CGSize(width: Self.systemPageSize.width, height: 7600), ready: {
            reference.components.allSatisfy { specimens.image("shepherd-ui", $0.id) != nil }
        }) {
            DesignSystemDestination(vm: vm)
        }
    }

    /// A system built from a project on the same page: acme-web, no page copy, light values only, and Re-sync.
    @Test func designSystemProjectPage() async throws {
        let (workspace, _, _) = try await systemWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.shownDesignSystem = "acme-web"
        vm.openDestination(.designSystem)
        let page = vm.designSystemPage(.system("acme-web"))
        #expect(page.reference != nil && page.canResync)
        await vm.loadDesignSpecimens("acme-web")
        let specimens = vm.designRendering.specimens
        try await Preview.renderMatrix("page-design-system-acme-web", size: CGSize(width: Self.systemPageSize.width, height: 3200), ready: {
            (0..<6).allSatisfy { specimens.image("acme-web", $0) != nil }
        }) {
            DesignSystemDestination(vm: vm)
        }
    }

    /// The contents menu open (DesignSystemMenu), with the page behind it and with enough designs in the system that
    /// the menu has to scroll in a short window.
    @Test func designSystemContentsMenu() async throws {
        let (workspace, _, _) = try await systemWorkspace(written: false)
        defer { workspace.stop() }
        let vm = workspace.vm
        let owner = Design(name: "Shepherd chat UI", createdAt: 2_500, boardCount: 104)
        _ = try await workspace.server.createDesign(owner)
        _ = try await workspace.server.writeDesignSystem(try Self.shepherdUIWrite(), for: owner.id)
        for index in 1...2 {
            var design = Design(name: index == 1 ? "Refund ledger" : "Checkout funnel dashboard", createdAt: Double(3_000 + index), boardCount: 3 + index)
            design.systemNamespace = "shepherd-ui"
            _ = try await workspace.server.createDesign(design)
        }
        vm.adopt(workspace.server.state)
        await vm.loadDesignSystems()
        vm.openDesignSystem("shepherd-ui")
        let page = vm.designSystemPage(.system("shepherd-ui"))
        let reference = try #require(page.reference)
        try await Preview.renderMatrix("page-design-system-menu", size: CGSize(width: Self.systemPageSize.width, height: 700)) {
            DesignSystemReferencePage(vm: vm, model: page, reference: reference, menuOpen: true)
        }
        // Twelve designs in a short window: the list scrolls rather than running off the page.
        for index in 3...12 {
            var design = Design(name: "Design number \(index) with a rather long name that must truncate", createdAt: Double(3_000 + index), boardCount: index)
            design.systemNamespace = "shepherd-ui"
            _ = try await workspace.server.createDesign(design)
        }
        vm.adopt(workspace.server.state)
        await vm.loadDesignSystems()
        let many = vm.designSystemPage(.system("shepherd-ui"))
        #expect(many.reference?.used.count == 12)
        try await Preview.renderMatrix("page-design-system-menu-overflow", size: CGSize(width: Self.systemPageSize.width, height: 480)) {
            DesignSystemReferencePage(vm: vm, model: many, reference: try! #require(many.reference), menuOpen: true)
        }
    }

    /// DZStart: the system built here, naming the repo it was read from; no project to pick.
    @Test func newDesignFindsTheSystem() async throws {
        let (workspace, _, _) = try await systemWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openNewDesign()
        await vm.loadDesignSystems()
        #expect(vm.newDesign.systemToInstall(vm) == "acme-web")
        try await Preview.render("app-window-new-design-system", size: Self.systemWindowSize) {
            RootView(vm: vm)
        }
    }

    /// NavDesigns' systems: acme-web with its swatches and source, Shepherd Design, and "Build one
    /// from a repo".
    @Test func designsPageSystems() async throws {
        let (workspace, _, _) = try await systemWorkspace()
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openDestination(.designs)
        await vm.loadDesignThumbnails()
        try await Preview.render("page-designs-systems", size: Self.systemPageSize, ready: {
            vm.state.designs.filter { !$0.buildsSystem }.allSatisfy { vm.designRendering.thumbnails.image($0.id) != nil }
                && vm.designsPage.systems.count == 2
        }) {
            DesignsDestination(vm: vm)
        }
    }
}
