import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Design systems end to end on a real server with the stub pi: "Build one from a repo" makes a
/// system build and starts its agent in the project with the build's words, its page follows the
/// system the agent writes, a system's specimens render through the board renderer, a system opens
/// from the Designs page and More ▸ Design systems, Re-sync reads the project again, New design
/// finds the project's tokens file and draws in its system, and the repository is left exactly
/// as it was.
@Suite("Design systems in the app", .mainActorExclusive)
@MainActor
struct DesignSystemFlowTests {
    static let stylesheet = """
        :root {
          --bg: #f8fafc;
          --surface: #ffffff;
          --border: #e2e8f0;

          --accent: #4f46e5;
          --space-4: 16px;
          --radius-md: 8px;
        }

        """

    static let repoFiles = [
        "web/static/tokens.css": stylesheet,
        "templates/partials/button.html": "<button class=\"btn\" style=\"background: #4338ca\">Export CSV</button>\n",
        "templates/pages/index.html": "<main>{% include 'partials/button.html' %}</main>\n",
    ]

    /// What the build's agent writes with system_write, as the extension sends it.
    static let write = DesignSystemWrite(
        namespace: "acme-web",
        tokens: .object([
            "format": .string(DesignSystemTokens.format),
            "name": .string("acme-web"),
            "colors": .array([
                .object(["name": .string("--accent"), "value": .string("#4f46e5"),
                         "source": .object(["file": .string("web/static/tokens.css"), "line": .number(6)])]),
                .object(["name": .string("--bg"), "value": .string("#f8fafc"),
                         "source": .object(["file": .string("web/static/tokens.css"), "line": .number(2)])]),
            ]),
            "type": .array([.object(["name": .string("display"), "size": .number(26), "weight": .number(700),
                                     "sample": .string("Checkout funnel")])]),
            "spacing": .array([.object(["name": .string("--space-4"), "px": .number(16)])]),
            "components": .array([.object(["name": .string("Button"),
                                            "source": .object(["file": .string("templates/partials/button.html")]),
                                            "specimen": .string("components/Button.html")])]),
        ]),
        files: ["README.md": .string("# acme-web\n\nRead from dashboard-web.\n"),
                "components/Button.html": .string(
                    "<span style=\"display: inline-flex; padding: 0 14px; height: 34px; align-items: center; border-radius: 8px; "
                        + "background: var(--accent); color: #fff;\">Export CSV</span>\n")],
        sources: ["web/static/tokens.css"])

    /// Every file of the working tree (not `.git`, whose index git may refresh on a read), by path.
    static func workingTree(_ folder: URL) -> [String: Data] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil) else { return [:] }
        var files: [String: Data] = [:]
        let root = folder.resolvingSymlinksInPath().path + "/"
        while let url = walker.nextObject() as? URL {
            let relative = String(url.resolvingSymlinksInPath().path.dropFirst(root.count))
            if relative == ".git" { walker.skipDescendants(); continue }
            if let data = try? Data(contentsOf: url), !url.hasDirectoryPath { files[relative] = data }
        }
        return files
    }

    private func start(_ app: AppHarness, repo: URL) async throws -> (ShepherdViewModel, Space) {
        app.settings.designToolEnabled = true
        let space = Fixture.space("dashboard-web", path: repo.path)
        let vm = try await app.start(with: Fixture.state(spaces: [space], agents: []))
        vm.designNetwork = .none
        app.server.designSystems.register(NightWatchSystem.builtIn())
        return (vm, space)
    }

    /// What the build's agent does once it has read the project: system_write over the
    /// extension socket, as its design's agent.
    private func writeSystem(_ app: AppHarness, agent: AgentID, design: DesignID) async throws -> DesignSystemWriteResult {
        nonisolated(unsafe) let client = try ExtensionClient(path: app.scratch.socketPath)
        try client.send(.designSystemWrite(id: 1, agentID: agent, designID: design, system: Self.write))
        let reply = try await Task.detached { try client.readReply(timeout: .seconds(20)) }.value
        guard case .designSystemWritten(1, let result) = reply else { throw TimedOut(what: "a system_write result, got \(reply)") }
        return result
    }

    @Test func buildingASystemFromARepoShowsItOnItsPageAndLeavesTheRepoAsItWas() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: Self.repoFiles)
        let before = Self.workingTree(repo)
        let head = try git(["rev-parse", "HEAD"], in: repo)
        let (vm, space) = try await start(app, repo: repo)

        // Build one from a repo: a system build in the project, its agent started with the words.
        vm.openDestination(.designs)
        vm.buildDesignSystem(in: space.id)
        try await eventuallyOnMain("the build's page to be on screen") { vm.shownDesign?.buildsSystem == true }
        let build = try #require(vm.shownDesign)
        let agent = try #require(vm.selectedAgent)
        #expect(build.name == "dashboard-web" && build.spaceID == space.id)
        #expect(agent.designID == build.id && agent.name == "dashboard-web")
        #expect(vm.shownDestination == nil)
        #expect(vm.sidebarLists.all.isEmpty, "a build has no Recents row, and neither has its agent")
        #expect(!vm.designsPage.cards.contains { $0.id == build.id })
        #expect(vm.designsPage.systems.contains { $0.id == .build(build.id) }, "it waits on the grid as its build")
        #expect(vm.designSystemPage(.build(build.id)).building)
        #expect(try JSONDecoder().decode(ShepherdState.self, from: Data(contentsOf: app.scratch.stateURL))
            .designs.first { $0.id == build.id }?.buildsSystem == true)
        let server = app.server
        try await eventuallyAsync("pi to receive the build's words", timeout: .seconds(20)) {
            guard case .snapshot(let snapshot)? = try? await server.nativeThread(agentID: agent.id, request: .snapshot()) else { return false }
            return snapshot.messages.contains { $0.role == "user" && $0.blocks.first?.text == ShepherdViewModel.systemBuildBrief }
        }

        // A second click on the same project opens the same build.
        vm.openDestination(.designs)
        vm.buildDesignSystem(in: space.id)
        #expect(vm.shownDesign?.id == build.id && vm.state.designs.count == 1)

        // The agent writes the system: its page shows it.
        let result = try await writeSystem(app, agent: agent.id, design: build.id)
        #expect(result.changed && result.summary.info.ownerDesignID == build.id && result.summary.info.spaceID == space.id)
        try await eventuallyOnMain("the page to show the system") { vm.designSystemPage(.build(build.id)).namespace == "acme-web" }
        let page = vm.designSystemPage(.build(build.id))
        #expect(!page.building && page.canResync)
        #expect(page.sections.map(\.count) == [2, 1, 1, 1, 0])
        #expect(page.source.map(\.text).joined() == "Read from dashboard-web: web/static/tokens.css and 1 template in templates/partials/ · synced just now")
        #expect(page.components.map(\.template) == ["partials/button.html"])

        // Its Button specimen renders through the board renderer, from the system's own files.
        await vm.loadDesignSpecimens("acme-web")
        let specimens = vm.designRendering.specimens
        try await eventuallyOnMain("the Button specimen to render", timeout: .seconds(60)) { specimens.image("acme-web", 0) != nil }
        let image = try #require(specimens.image("acme-web", 0))
        #expect(CGFloat(image.width) >= DesignSpecimenBoard.size.width)

        // The Designs page's card and More ▸ Design systems open the build's page.
        let card = try #require(vm.designsPage.systems.first { $0.id == .system("acme-web") })
        #expect(card.source == "dashboard-web · tokens.css" && card.swatches.map(\.light) == ["#4f46e5", "#f8fafc"])
        vm.openDestination(.designs)
        vm.openDesignSystem("acme-web")
        #expect(vm.shownDesign?.id == build.id && vm.shownDestination == nil)
        vm.openDestination(.automations)
        vm.openSidebarDestination(.designSystems)
        #expect(vm.shownDesign?.id == build.id)

        // Re-sync reads the project again.
        let synced = try #require(vm.designSystems.summary("acme-web")?.info.syncedAt)
        vm.resyncDesignSystem("acme-web")
        try await eventuallyOnMain("the re-sync to land") {
            !vm.designSystems.syncing.contains("acme-web") && (vm.designSystems.summary("acme-web")?.info.syncedAt ?? 0) > synced
        }

        // New design draws in the system built from its project.
        vm.openNewDesign()
        #expect(vm.newDesign.systemToInstall(vm) == "acme-web")

        // Night Watch has no agent of its own: it opens as the Design systems page.
        vm.openDesignSystem("night-watch")
        #expect(vm.shownDestination == .designSystem && vm.designSystemShown == "night-watch")
        #expect(vm.designSystemPage(.system("night-watch")).builtIn)

        // The repository was only read.
        #expect(Self.workingTree(repo) == before)
        #expect(try git(["rev-parse", "HEAD"], in: repo) == head)
        #expect(try git(["status", "--porcelain"], in: repo).isEmpty)
    }

    @Test func newDesignFindsTheProjectsTokensFileAndInstallsTheSystemPicked() async throws {
        try StubPi.installOnPath()
        let app = try AppHarness()
        defer { app.stop() }
        let repo = try makeScratchRepo(files: Self.repoFiles)
        let before = Self.workingTree(repo)
        let (vm, space) = try await start(app, repo: repo)
        await vm.loadDesignSystems()

        vm.openNewDesign()
        let draft = vm.newDesign
        await draft.detect(vm)
        #expect(draft.tokensFiles[space.id] == .some("web/static/tokens.css"))
        #expect(draft.systemToInstall(vm) == nil, "no system was built from the project yet")

        draft.choose(system: "night-watch")
        #expect(draft.systemToInstall(vm) == "night-watch")
        draft.brief = "A settings page"
        draft.send(vm)
        try await eventuallyOnMain("the design to open") { vm.shownDesign != nil && !draft.starting }
        let design = try #require(vm.shownDesign)
        #expect(design.systemNamespace == "night-watch" && !design.buildsSystem)
        let snapshot = try await app.server.designSnapshot(design.id)
        #expect(snapshot.index.designSystems?.map(\.namespace) == ["night-watch"])
        #expect(Self.workingTree(repo) == before)
    }
}
