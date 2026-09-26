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

/// Design systems (DZSystem, NavDesigns): a system built from a repository on its build's page
/// beside the build agent's chat, a build still reading its project, Night Watch on the Design
/// systems page, and the Designs page's systems grid. Specimens are drawn by the board renderer
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
    /// wrote, a design drawn in it, and Night Watch.
    private func systemWorkspace(written: Bool = true) async throws -> (workspace: PreviewWorkspace, build: Design, agent: Agent) {
        let workspace = try PreviewWorkspace()
        workspace.settings.designToolEnabled = true
        let vm = workspace.vm
        vm.designNetwork = .none
        vm.designLiveCap = 0
        workspace.server.designSystems.register(NightWatchSystem.builtIn())
        let project = workspace.dir.appendingPathComponent("dashboard-web", isDirectory: true)
        let stylesheet = project.appendingPathComponent("web/static/tokens.css")
        try FileManager.default.createDirectory(at: stylesheet.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.acmeStylesheet.utf8).write(to: stylesheet)
        let web = Space(name: "dashboard-web", path: project.path)
        var (agent, tab) = try await workspace.agent("dashboard-web", in: web, order: 0, live: true)
        let build = Design(name: "dashboard-web", spaceID: web.id, agentID: agent.id, createdAt: 1_000, buildsSystem: true)
        agent.designID = build.id
        try await workspace.seed(ShepherdState(spaces: [web], tabs: [tab], agents: [agent]))
        _ = try await workspace.server.createDesign(build)
        if written {
            _ = try await workspace.server.writeDesignSystem(Self.acmeWrite, for: build.id)
            let checkout = Design(name: "Checkout funnel dashboard", spaceID: web.id, createdAt: 2_000)
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

    /// Night Watch on the Design systems page: generated from ShepherdUI's tokens, with no chat.
    @Test func designSystemNightWatch() async throws {
        let (workspace, _, _) = try await systemWorkspace(written: false)
        defer { workspace.stop() }
        let vm = workspace.vm
        vm.openDesignSystem("night-watch")
        #expect(vm.shownDestination == .designSystem)
        try await Preview.render("page-design-system-night-watch", size: Self.systemPageSize) {
            DesignSystemDestination(vm: vm)
        }
    }

    /// NavDesigns' systems: acme-web with its swatches and source, Night Watch, and "Build one
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
