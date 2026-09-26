import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Design systems against a real server: a design agent builds one from its project (read, never
/// written), writes it to the support directory's `design-systems/`, installs it in its design,
/// reads it back, and only that design's agent may write it again. Re-sync reads the project
/// again.
@Suite("Design systems", .integrationTimeLimit)
struct DesignSystemTests {
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

    static let tokens: JSONValue = .object([
        "format": .string(DesignSystemTokens.format),
        "name": .string("acme-web"),
        "colors": .array([
            .object(["name": .string("--accent"), "value": .string("#4f46e5"),
                     "source": .object(["file": .string("web/static/tokens.css"), "line": .number(6)])]),
            .object(["name": .string("--bg"), "value": .string("#f8fafc"),
                     "source": .object(["file": .string("web/static/tokens.css"), "line": .number(2)])]),
        ]),
        "type": .array([.object(["name": .string("display"), "size": .number(26), "weight": .number(700)])]),
        "spacing": .array([.object(["name": .string("--space-4"), "px": .number(16),
                                    "source": .object(["file": .string("web/static/tokens.css"), "line": .number(7)])])]),
        "radii": .array([]),
        "components": .array([.object(["name": .string("Button"),
                                        "source": .object(["file": .string("templates/partials/button.html")]),
                                        "specimen": .string("components/Button.html")])]),
    ])

    struct Workspace {
        var h: ScratchServer
        var repo: URL
        var design: DesignID
        var drawer: AgentID
        var other: DesignID
        var otherDrawer: AgentID
        var stranger: AgentID
    }

    /// A project (a git repository with a stylesheet and a template), a system build reading it
    /// and a canvas, with their agents, and an agent that draws nothing.
    private func workspace() async throws -> Workspace {
        let h = try ScratchServer.fresh()
        let repo = try makeScratchRepo(files: [
            "web/static/tokens.css": Self.stylesheet,
            "templates/partials/button.html": "<button class=\"btn\" style=\"background: #4338ca\">Export CSV</button>\n",
        ])
        let space = Fixture.space("dashboard-web", path: repo.path)
        let design = DesignID(), other = DesignID()
        var drawer = Fixture.agent(in: space, name: "Checkout funnel")
        drawer.agent.designID = design
        var otherDrawer = Fixture.agent(in: space, name: "Settings")
        otherDrawer.agent.designID = other
        let stranger = Fixture.agent(in: space, name: "worker")
        try await h.seed(Fixture.workspace([drawer, otherDrawer, stranger], space: space))
        // The first reads the project as a system build (designs stand alone: only a build has
        // a project to read); the other is a canvas.
        _ = try await h.server.createDesign(Design(id: design, name: "Checkout funnel",
                                                   agentID: drawer.agent.id, createdAt: 1_000, buildsSystem: true,
                                                   sourceSpaceID: space.id))
        _ = try await h.server.createDesign(Design(id: other, name: "Settings",
                                                   agentID: otherDrawer.agent.id, createdAt: 1_000))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return Workspace(h: h, repo: repo, design: design, drawer: drawer.agent.id, other: other,
                         otherDrawer: otherDrawer.agent.id, stranger: stranger.agent.id)
    }

    private static func write(install: Bool = true, base: UInt64? = nil) -> DesignSystemWrite {
        DesignSystemWrite(namespace: "acme-web", tokens: tokens,
                          files: ["README.md": .string("# acme-web\n\nRead from dashboard-web.\n"),
                                  "components/Button.html": .string("<button class=\"btn\">Export CSV</button>\n")],
                          sources: ["web/static/tokens.css"], install: install, baseRevision: base)
    }

    @Test func anAgentBuildsASystemFromItsProjectAndInstallsItInItsDesign() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        let repoBefore = DesignTests.contents(of: w.repo)
        let agent = try ExtensionClient(path: w.h.socketPath)

        try agent.send(.designSystemWrite(id: 1, agentID: w.drawer, designID: w.design, system: Self.write()))
        guard case .designSystemWritten(1, let result) = try await agent.reply() else { Issue.record("no write result"); return }
        #expect(result.changed && result.summary.info.revision == 1 && result.summary.info.ownerDesignID == w.design)
        #expect(result.summary.counts == DesignSystemCounts(colors: 2, type: 1, lengths: 1, components: 1))
        #expect(result.summary.info.sources == ["web/static/tokens.css"] && result.summary.info.syncedAt != nil)
        #expect(result.installed?.changed == true)

        // The system's folder: its files, a stylesheet generated from its tokens, and Shepherd's record.
        let folder = try #require(w.h.server.designSystems.folder(for: "acme-web"))
        let system = DesignTests.contents(of: folder)
        #expect(Set(system.keys) == ["tokens.json", "tokens.css", "README.md", "components/Button.html", "system.json"])
        let css = String(decoding: try #require(system["tokens.css"]), as: UTF8.self)
        #expect(css.hasPrefix(DesignSystemTokens.generatedMarker) && css.contains("--accent: #4f46e5;"))

        // The installed copy: every file but system.json under ds/acme-web/, and its record.
        let project = try #require(w.h.server.designs.projectFolder(for: w.design))
        let installed = DesignTests.contents(of: project.appendingPathComponent("ds/acme-web"))
        #expect(Set(installed.keys) == ["tokens.json", "tokens.css", "README.md", "components/Button.html"])
        #expect(installed["tokens.json"] == system["tokens.json"])
        let snapshot = try await w.h.server.designSnapshot(w.design)
        let record = try #require(snapshot.index.designSystems?.first)
        #expect(record.namespace == "acme-web" && record.title == "acme-web" && record.isShepherds)
        #expect(record.extra["version"] == .string("1"))
        #expect(snapshot.boards.isEmpty, "a system's files are no boards")
        #expect(w.h.server.state.designs.first { $0.id == w.design }?.systemNamespace == "acme-web")
        #expect(try w.h.persisted().designs.first { $0.id == w.design }?.systemNamespace == "acme-web")

        // The project was only read.
        #expect(DesignTests.contents(of: w.repo) == repoBefore)
        #expect(try git(["status", "--porcelain"], in: w.repo).isEmpty)
    }

    @Test func systemReadListsTheSystemsAndTheDesignsOwnFirst() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        w.h.server.designSystems.register(.init(
            info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", revision: 1, createdAt: 0),
            files: ["tokens.json": try DesignSystemTokens(name: "Night Watch", colors: [.init(name: "--lantern", value: "#e39a26")]).encoded(),
                    "README.md": Data("# Night Watch\n".utf8)]))
        _ = try await w.h.server.writeDesignSystem(Self.write(), for: w.design)
        try await w.h.server.installDesignSystem(w.design, namespace: "night-watch")
        let agent = try ExtensionClient(path: w.h.socketPath)

        try agent.send(.designSystemRead(id: 1, agentID: w.drawer, designID: w.design, namespace: nil))
        guard case .designSystems(1, let listing) = try await agent.reply() else { Issue.record("no listing"); return }
        #expect(listing.systems.map(\.namespace) == ["night-watch", "acme-web"])
        #expect(listing.systems.first?.builtIn == true)
        #expect(listing.primary == "night-watch", "the system installed last is the one the design is drawn in")
        #expect(listing.installed.map(\.namespace) == ["night-watch", "acme-web"])
        #expect(listing.installed.last?.tokens?.colors.first?.source?.label == "tokens.css:6")
        #expect(listing.installed.last?.tokensFile == "ds/acme-web/tokens.json")

        try agent.send(.designSystemRead(id: 2, agentID: w.drawer, designID: w.design, namespace: "acme-web"))
        guard case .designSystem(2, let read) = try await agent.reply() else { Issue.record("no system"); return }
        #expect(read.tokens?.components.first?.specimen == "components/Button.html")
        #expect(read.readme?.hasPrefix("# acme-web") == true)
        #expect(read.files == ["README.md", "components/Button.html", "tokens.css", "tokens.json"])

        try agent.send(.designSystemRead(id: 3, agentID: w.drawer, designID: w.design, namespace: "Acme Web"))
        guard case .error(3, "invalid_namespace", _) = try await agent.reply() else { Issue.record("a bad namespace was read"); return }
        try agent.send(.designSystemRead(id: 4, agentID: w.drawer, designID: w.design, namespace: "nope"))
        guard case .error(4, "no_such_system", _) = try await agent.reply() else { Issue.record("a missing system was read"); return }
        try agent.send(.designSystemRead(id: 5, agentID: w.stranger, designID: w.design, namespace: nil))
        guard case .error(5, "not_your_design", _) = try await agent.reply() else { Issue.record("a stranger read"); return }
    }

    /// What a system's page draws its specimens from: every file of the system but Shepherd's
    /// record, a built-in's included.
    @Test func aSystemsFilesAreReadWithoutItsRecord() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        _ = try await w.h.server.writeDesignSystem(Self.write(install: false), for: w.design)
        let files = try await w.h.server.designSystemContents("acme-web")
        #expect(Set(files.keys) == ["tokens.json", "tokens.css", "README.md", "components/Button.html"])
        #expect(files["components/Button.html"] == Data("<button class=\"btn\">Export CSV</button>\n".utf8))
        w.h.server.designSystems.register(.init(info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", createdAt: 0),
                                                files: ["tokens.css": Data(":root{}".utf8)]))
        #expect(try await w.h.server.designSystemContents("night-watch") == ["tokens.css": Data(":root{}".utf8)])
        await #expect(throws: DesignSystemError.invalidNamespace("Acme Web")) { try await w.h.server.designSystemContents("Acme Web") }
        await #expect(throws: DesignSystemError.self) { try await w.h.server.designSystemContents("nope") }
    }

    @Test func onlyTheAgentOfTheDesignThatBuiltASystemWritesIt() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        w.h.server.designSystems.register(.init(
            info: DesignSystemInfo(namespace: "night-watch", title: "Night Watch", revision: 1, createdAt: 0),
            files: ["tokens.json": Data("{}".utf8)]))
        let agent = try ExtensionClient(path: w.h.socketPath)
        try agent.send(.designSystemWrite(id: 1, agentID: w.drawer, designID: w.design, system: Self.write(install: false)))
        guard case .designSystemWritten(1, _) = try await agent.reply() else { Issue.record("the owner's write failed"); return }
        let folder = try #require(w.h.server.designSystems.folder(for: "acme-web"))
        let before = DesignTests.contents(of: folder)

        // Another design's agent, an agent that draws nothing, and a built-in.
        var edit = Self.write(install: false)
        edit.files = ["README.md": .string("# mine now\n")]
        try agent.send(.designSystemWrite(id: 2, agentID: w.otherDrawer, designID: w.other, system: edit))
        guard case .error(2, "not_your_system", _) = try await agent.reply() else { Issue.record("another design's agent wrote"); return }
        try agent.send(.designSystemWrite(id: 3, agentID: w.stranger, designID: w.design, system: edit))
        guard case .error(3, "not_your_design", _) = try await agent.reply() else { Issue.record("a stranger wrote"); return }
        try agent.send(.designSystemWrite(id: 4, agentID: w.drawer, designID: w.design,
                                          system: DesignSystemWrite(namespace: "night-watch", tokens: .object([:]))))
        guard case .error(4, "read_only_system", _) = try await agent.reply() else { Issue.record("a built-in was written"); return }
        // A write based on an old revision, bad files and bad tokens.
        edit.baseRevision = 0
        try agent.send(.designSystemWrite(id: 5, agentID: w.drawer, designID: w.design, system: edit))
        guard case .error(5, "stale_revision", _) = try await agent.reply() else { Issue.record("a stale write went through"); return }
        try agent.send(.designSystemWrite(id: 6, agentID: w.drawer, designID: w.design,
                                          system: DesignSystemWrite(namespace: "acme-web", files: ["../escape.css": .string("x")])))
        guard case .error(6, "invalid_file", _) = try await agent.reply() else { Issue.record("a file outside the system"); return }
        try agent.send(.designSystemWrite(id: 7, agentID: w.drawer, designID: w.design, system: DesignSystemWrite(
            namespace: "acme-web", tokens: .object(["colors": .array([.object(["name": .string("--x"), "value": .string("red;}")])])]))))
        guard case .error(7, "invalid_tokens", _) = try await agent.reply() else { Issue.record("tokens that break out"); return }
        try agent.send(.designSystemWrite(id: 8, agentID: w.drawer, designID: w.design,
                                          system: DesignSystemWrite(namespace: "acme-web", sources: ["/etc/passwd.css"])))
        guard case .error(8, "invalid_source", _) = try await agent.reply() else { Issue.record("a source outside the project"); return }
        #expect(DesignTests.contents(of: folder) == before)

        // Installing someone else's system writes only the installer's own design.
        try agent.send(.designSystemWrite(id: 9, agentID: w.otherDrawer, designID: w.other,
                                          system: DesignSystemWrite(namespace: "acme-web", install: true)))
        guard case .designSystemWritten(9, let installed) = try await agent.reply() else { Issue.record("the install failed"); return }
        #expect(!installed.changed && installed.installed?.changed == true)
        #expect(DesignTests.contents(of: folder) == before)
        let other = try #require(w.h.server.designs.projectFolder(for: w.other))
        #expect(FileManager.default.fileExists(atPath: other.appendingPathComponent("ds/acme-web/tokens.json").path))
    }

    /// A canvas belongs to no project: a system its agent writes records none, keeps its sources
    /// unread, and can't be re-synced.
    @Test func aCanvasHasNoProjectToReadASystemFrom() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        var write = Self.write(install: false)
        write.namespace = "sketch"
        let result = try await w.h.server.writeDesignSystem(write, for: w.other)
        #expect(result.changed && result.summary.info.spaceID == nil && result.summary.info.syncedAt == nil)
        #expect(result.summary.info.sources == ["web/static/tokens.css"] && result.notes.isEmpty)
        await #expect(throws: DesignSystemError.self) { try await w.h.server.resyncDesignSystem("sketch") }
    }

    @Test func aSystemInstalledFromElsewhereKeepsItsFolder() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        _ = try await w.h.server.writeDesignSystem(Self.write(install: false), for: w.design)
        // A canvas from claude.ai: its own record and copy of a system in ds/acme-web/.
        _ = try await w.h.server.updateDesignIndex(w.design, patch: .object(["designSystems": .array([.object([
            "title": .string("Acme"), "namespace": .string("acme-web"), "artifact": .string("https://claude.ai/artifact/abc"),
            "version": .string("v7"), "copiedAt": .string("2026-09-01T00:00:00Z"),
        ])])]))
        let project = try #require(w.h.server.designs.projectFolder(for: w.design))
        let ds = project.appendingPathComponent("ds/acme-web", isDirectory: true)
        try FileManager.default.createDirectory(at: ds, withIntermediateDirectories: true)
        try Data(":root {\n  --accent: #ff0000;\n  --space-2: 8px;\n}\n".utf8).write(to: ds.appendingPathComponent("tokens.css"))
        let before = DesignTests.contents(of: project)

        await #expect(throws: DesignSystemError.namespaceTaken("acme-web")) {
            try await w.h.server.installDesignSystem(w.design, namespace: "acme-web")
        }
        #expect(DesignTests.contents(of: project) == before)
        let snapshot = try await w.h.server.designSnapshot(w.design)
        #expect(snapshot.index.designSystems?.first?.extra["artifact"] == .string("https://claude.ai/artifact/abc"))

        // Its tokens still read, from its stylesheet, for design_check.
        let listing = try await w.h.server.designSystemListing(w.design)
        let copy = try #require(listing.installed.first)
        #expect(!copy.shepherd && copy.tokensFile == "ds/acme-web/tokens.css")
        #expect(copy.tokens?.colors.map(\.value) == ["#ff0000"] && copy.tokens?.spacing.map(\.px) == [8])
    }

    @Test func aResyncReadsTheProjectAgainAndDesignsKeepTheirCopy() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        _ = try await w.h.server.writeDesignSystem(Self.write(), for: w.design)
        let folder = try #require(w.h.server.designSystems.folder(for: "acme-web"))
        let project = try #require(w.h.server.designs.projectFolder(for: w.design))
        let installed = DesignTests.contents(of: project.appendingPathComponent("ds/acme-web"))
        let before = try await w.h.server.designSystem("acme-web").summary.info
        let notified = Locked(0)
        await MainActor.run { w.h.server.onDesignSystemsChanged = { notified.withValue { $0 += 1 } } }

        // The project changes on its own: the accent moves a line and changes, a color joins.
        let changed = Self.stylesheet
            .replacingOccurrences(of: "  --accent: #4f46e5;\n", with: "")
            .replacingOccurrences(of: "  --radius-md: 8px;\n", with: "  --radius-md: 8px;\n  --accent: #4338ca;\n  --danger: #dc2626;\n")
        try Data(changed.utf8).write(to: w.repo.appendingPathComponent("web/static/tokens.css"))
        let repoBefore = DesignTests.contents(of: w.repo)

        let result = try await w.h.server.resyncDesignSystem("acme-web")
        #expect(result.changes.updated == ["--accent", "--space-4"], "the accent's value and line, the step's line")
        #expect(result.changes.added == ["--surface", "--border", "--radius-md", "--danger"])
        #expect(result.summary.info.revision == before.revision + 1)
        #expect((result.summary.info.syncedAt ?? 0) >= (before.syncedAt ?? 0))
        let tokens = try DesignSystemTokens.decode(Data(contentsOf: folder.appendingPathComponent("tokens.json")))
        #expect(tokens.colors.first { $0.name == "--accent" }.map { "\($0.value) \($0.source?.label ?? "")" } == "#4338ca tokens.css:8")
        let css = try String(contentsOf: folder.appendingPathComponent("tokens.css"), encoding: .utf8)
        #expect(css.contains("--accent: #4338ca;") && css.contains("--danger: #dc2626;"))

        // Designs keep what they installed; the project was only read.
        #expect(DesignTests.contents(of: project.appendingPathComponent("ds/acme-web")) == installed)
        #expect(DesignTests.contents(of: w.repo) == repoBefore)
        await drainMainQueue()
        #expect(notified.current == 1)

        // A system without stylesheets has nothing to read again.
        _ = try await w.h.server.writeDesignSystem(DesignSystemWrite(namespace: "plain", tokens: .object([:])), for: w.design)
        await #expect(throws: DesignSystemError.self) { try await w.h.server.resyncDesignSystem("plain") }
    }

    @Test func aLinkNeverLeadsASystemOutsideTheSupportDirectory() async throws {
        let w = try await workspace()
        defer { w.h.stop() }
        let manager = FileManager.default
        let outside = try makeScratchDirectory()
        try Data("{}".utf8).write(to: outside.appendingPathComponent("tokens.json"))
        try Data("# not a system\n".utf8).write(to: outside.appendingPathComponent("README.md"))
        let outsideBefore = DesignTests.contents(of: outside)

        // design-systems/leak is a link out of the store: never listed, read, written or installed.
        let store = w.h.server.designSystems
        try manager.createDirectory(at: store.directory, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: store.directory.appendingPathComponent("leak"), withDestinationURL: outside)
        #expect(store.folder(for: "leak") == nil)
        #expect(await w.h.server.designSystemSummaries().allSatisfy { $0.info.namespace != "leak" })
        await #expect(throws: DesignSystemError.notAFolder("leak")) { try await w.h.server.designSystem("leak") }
        await #expect(throws: DesignSystemError.notAFolder("leak")) {
            try await w.h.server.installDesignSystem(w.design, namespace: "leak")
        }
        let agent = try ExtensionClient(path: w.h.socketPath)
        try agent.send(.designSystemWrite(id: 1, agentID: w.drawer, designID: w.design,
                                          system: DesignSystemWrite(namespace: "leak", tokens: Self.tokens)))
        guard case .error(1, "not_a_folder", _) = try await agent.reply() else { Issue.record("a write followed the link"); return }

        // Inside a real system, a linked file is left out and a linked folder is never written through.
        _ = try await w.h.server.writeDesignSystem(Self.write(), for: w.design)
        let folder = try #require(store.folder(for: "acme-web"))
        try manager.createSymbolicLink(at: folder.appendingPathComponent("stolen.md"),
                                       withDestinationURL: outside.appendingPathComponent("README.md"))
        try manager.createSymbolicLink(at: folder.appendingPathComponent("out"), withDestinationURL: outside)
        #expect(try await w.h.server.designSystem("acme-web").files == ["README.md", "components/Button.html", "tokens.css", "tokens.json"])
        var through = Self.write(install: false)
        through.files = ["out/escape.md": .string("x")]
        try agent.send(.designSystemWrite(id: 2, agentID: w.drawer, designID: w.design, system: through))
        guard case .error(2, "invalid_file", _) = try await agent.reply() else { Issue.record("a write went through a linked folder"); return }

        // A design's installed copy with a linked folder is refused before anything is made through it.
        let project = try #require(w.h.server.designs.projectFolder(for: w.design))
        let components = project.appendingPathComponent("ds/acme-web/components")
        try manager.removeItem(at: components)
        try manager.createSymbolicLink(at: components, withDestinationURL: outside)
        await #expect(throws: DesignSystemError.invalidFile("components/Button.html")) {
            try await w.h.server.installDesignSystem(w.design, namespace: "acme-web")
        }
        #expect(DesignTests.contents(of: outside) == outsideBefore)
    }
}
