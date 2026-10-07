import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdUI
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// Real files, real local and remote servers, and the page's actual formatter.
@Suite("Projects previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled))
@MainActor
struct ProjectsPreviewTests {
    @Test(arguments: [false, true])
    func relocatedSubagentSettings(enabled: Bool) async throws {
        let world = try await ProjectsPreviewWorld(empty: true)
        defer { world.stop() }
        world.vm.settings.piNativeSubagents = enabled
        world.vm.settingsSection = .subagents
        try await Preview.renderMatrix("settings-subagents-\(enabled ? "on" : "off")", size: CGSize(width: 1440, height: 1100)) {
            SettingsView(vm: world.vm)
        }
    }

    @Test(arguments: ["populated", "empty", "long", "filtered", "offline", "older-host", "narrow", "directory-missing"])
    func list(state: String) async throws {
        let world = try await ProjectsPreviewWorld(empty: state == "empty", long: state == "long", legacy: state == "older-host")
        defer { world.stop() }
        if state == "filtered" { world.vm.projects.filter = "only-this-folder" }
        if state == "directory-missing" {
            let missing = world.local.dir.appendingPathComponent("unavailable-checkout")
            try await world.local.server.addSpace(Space(name: "Unavailable checkout", path: missing.path), first: false)
            await world.vm.projects.load(world.vm.projectsSources, force: true)
        }
        if state == "offline" {
            world.vm.remoteHosts.connections.first?.phase = .disconnected
            await world.vm.projects.load(world.vm.projectsSources, force: true)
        }
        let size = CGSize(width: state == "narrow" ? 1050 : 1440, height: 900)
        try await Preview.renderMatrix("projects-\(state)", size: size) { RootView(vm: world.vm) }
    }

    /// The board's tree (SettingsProjects, parents and subprojects): shepherd with its two
    /// subprojects inside its folder, which share its two MCP servers (one adds its own), then
    /// payments, and the daemon on Build-01. Collapsed, shepherd folds its subprojects away.
    @Test(arguments: ["tree", "tree-collapsed", "tree-filtered"])
    func subprojects(state: String) async throws {
        let world = try await ProjectsPreviewWorld(empty: true)
        defer { world.stop() }
        let home = URL(fileURLWithPath: world.local.server.pi.userHome)
        let code = home.appendingPathComponent("code")
        let shepherd = code.appendingPathComponent("shepherd")
        let landing = shepherd.appendingPathComponent("landing"), testing = shepherd.appendingPathComponent("testing")
        let payments = code.appendingPathComponent("payments")
        func write(_ folder: URL, _ relative: String, _ text: String) throws {
            let url = folder.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try write(shepherd, ".pi/mcp.json", #"{"mcpServers":{"linear":{},"sentry":{}}}"#)
        try write(landing, ".pi/mcp.json", #"{"mcpServers":{"vercel":{}}}"#)
        try write(testing, "AGENTS.md", "# Tests\n")
        for skill in ["ledger", "refunds", "release"] { try write(payments, ".pi/skills/\(skill)/SKILL.md", "# \(skill)\n") }
        try write(payments, ".pi/mcp.json", #"{"mcpServers":{"stripe":{},"docs":{}}}"#)
        let spaces = [Space(name: "shepherd", path: shepherd.path), Space(name: "shepherd-landing", path: landing.path),
                      Space(name: "shepherd-testing", path: testing.path), Space(name: "payments", path: payments.path)]
        try await world.local.server.putState(ShepherdState(spaces: spaces))
        world.vm.adopt(world.local.server.state)
        let daemon = URL(fileURLWithPath: world.remote.server.pi.userHome).appendingPathComponent("srv/daemon")
        try write(daemon, ".pi/settings.json", #"{"extensions":["./a.ts","./b.ts"]}"#)
        try await world.remote.server.putState(ShepherdState(spaces: [Space(name: "daemon", path: daemon.path)]))
        try await eventuallyOnMain("the host's project") { world.vm.remoteHosts.connections.first?.state.spaces.count == 1 }
        await world.vm.projects.load(world.vm.projectsSources, force: true)
        let model = world.vm.projects
        #expect(model.visible.map(\.project.name) == ["shepherd", "shepherd-landing", "shepherd-testing", "payments", "daemon"])
        #expect(model.visible[1].configuration == "2 inherited · 1 local MCP")
        if state == "tree-collapsed" { model.collapsed = [model.visible[0].id] }
        if state == "tree-filtered" { model.filter = "testing" }
        try await Preview.renderMatrix("projects-\(state)", size: CGSize(width: 1440, height: 900)) { RootView(vm: world.vm) }
    }

    @Test func projectMCPMatchesTheSettingsCardsAndForms() async throws {
        let fixture = try await ProjectsPreviewWorld(detail: true)
        defer { fixture.stop() }
        let model = fixture.vm.projects
        await model.open(try #require(model.rows.first { $0.host.id == "local" }))
        await model.navigate(.category(.mcp))
        let entries = [
            MCPServerEntry(name: "docs", json: ["url": .string("https://docs.example.invalid/mcp"), "exposure": .string("deferred"),
                                               "headers": .object(["Authorization": .string("Bearer ${DOCS_TOKEN}")])]),
            MCPServerEntry(name: "ledger-with-a-long-name-for-production-accounting-tools", json: ["command": .string("ledger-server"), "args": .array([.string("--read-only")]), "enabled": .bool(false),
                                                                                               "env": .object(["SERVICE_TOKEN": .string("${LEDGER_TOKEN}")])]),
        ]
        try await model.saveMCP(entries, replacing: ["docs", "ledger"])
        let size = CGSize(width: 1440, height: 900)
        try await Preview.renderMatrix("projects-mcp", size: size) { SettingsView(vm: fixture.vm) }
        try await Preview.renderMatrix("projects-mcp-narrow", size: CGSize(width: 1024, height: 800)) { SettingsView(vm: fixture.vm) }
        model.selected?.host.unavailable = "Host offline"
        try await Preview.renderMatrix("projects-mcp-offline", size: size) { SettingsView(vm: fixture.vm) }
        model.selected?.host.unavailable = nil
        try await Preview.renderMatrix("projects-mcp-detail", size: CGSize(width: 1040, height: 720)) {
            ProjectMCPSettings(model: model, initiallyExpanded: "docs").padding(NW.Space.xxl)
                .frame(width: 1040, height: 720).background(Color.nw.bgWindow)
        }
        try await Preview.renderMatrix("projects-mcp-filtered", size: CGSize(width: 1040, height: 720)) {
            ProjectMCPSettings(model: model, initialQuery: "nothing-matches").padding(NW.Space.xxl)
                .frame(width: 1040, height: 720).background(Color.nw.bgWindow)
        }
        try await Preview.renderMatrix("projects-mcp-edit", size: CGSize(width: 570, height: 780)) {
            AddMCPServerSheet(project: model, initialKind: nil, editing: entries[0]) {}
        }
        try await Preview.renderMatrix("projects-mcp-local-edit", size: CGSize(width: 720, height: 780)) {
            AddMCPServerSheet(project: model, initialKind: nil, editing: entries[1]) {}
        }
        try await Preview.renderMatrix("projects-mcp-add", size: CGSize(width: 720, height: 780)) {
            AddMCPServerSheet(project: model, initialKind: .remote, editing: nil) {}
        }
        let oauth = MCPServerEntry(name: "linear-with-a-long-project-server-name", json: ["url": .string("https://linear.example.invalid/mcp")])
        try await model.saveMCP([oauth])
        try await Preview.renderMatrix("projects-mcp-oauth-unsigned", size: CGSize(width: 1040, height: 720)) {
            ProjectMCPSettings(model: model, initiallyExpanded: oauth.name).padding(NW.Space.xxl)
                .frame(width: 1040, height: 720).background(Color.nw.bgWindow)
        }
        let auth = fixture.local.dir.appendingPathComponent("pi/mcp-auth.json")
        try FileManager.default.createDirectory(at: auth.deletingLastPathComponent(), withIntermediateDirectories: true)
        let credentials = ["mcp__\(oauth.name.replacingOccurrences(of: "-", with: "_"))|\(oauth.url!)": ["tokens": ["access_token": "fixture-only"]]]
        try JSONSerialization.data(withJSONObject: credentials).write(to: auth)
        await model.refreshMCPCredentials()
        #expect(model.mcpSignedIn.contains(oauth.name))
        try await Preview.renderMatrix("projects-mcp-oauth-signed", size: CGSize(width: 1040, height: 720)) {
            ProjectMCPSettings(model: model, initiallyExpanded: oauth.name).padding(NW.Space.xxl)
                .frame(width: 1040, height: 720).background(Color.nw.bgWindow)
        }
        try FileManager.default.removeItem(at: auth)
        await model.refreshMCPCredentials()
        let native = try #require(model.selectedFile)
        let project = try #require(model.selected)
        try ((model.saved ?? "") + "\n").write(
            to: URL(fileURLWithPath: project.project.directory).appendingPathComponent(native.path), atomically: true, encoding: .utf8)
        await model.setMCPEnabled("docs", false)
        #expect(model.fileError != nil && model.dirty)
        try await Preview.renderMatrix("projects-mcp-conflict", size: size) { SettingsView(vm: fixture.vm) }
        await model.navigate(.file(native)); await model.discard()
        let shared = try #require(model.selectedFiles.first { $0.path == ".mcp.json" })
        await model.navigate(.file(shared))
        try await model.saveMCP([entries[0]])
        try await Preview.renderMatrix("projects-mcp-shared", size: CGSize(width: 1040, height: 720)) {
            ProjectMCPSettings(model: model, initiallyExpanded: "docs").padding(NW.Space.xxl)
                .frame(width: 1040, height: 720).background(Color.nw.bgWindow)
        }
        await model.navigate(.file(native))
        for name in model.mcp.entries.map(\.name) { try await model.removeMCP(name) }
        try await Preview.renderMatrix("projects-mcp-empty", size: size) { SettingsView(vm: fixture.vm) }
        model.draft = "{ invalid JSON"
        try await Preview.renderMatrix("projects-mcp-invalid", size: size) { SettingsView(vm: fixture.vm) }
    }

    @Test(arguments: ProjectFile.Category.allCases)
    func details(category: ProjectFile.Category) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        await world.vm.projects.open(project)
        await world.vm.projects.navigate(.category(category))
        if category == .extensions, let file = world.vm.projects.files.first(where: { $0.category == .extensions }) {
            await world.vm.projects.navigate(.file(file))
        }
        try await Preview.renderMatrix("projects-detail-\(category.rawValue)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
        }
    }

    @Test(arguments: ["inherit", "on", "off", "missing", "invalid", "long"])
    func codemode(state: String) async throws {
        let world = try await ProjectsPreviewWorld(detail: true)
        defer { world.stop() }
        let model = world.vm.projects
        let project = try #require(model.rows.first { $0.project.name == "payments" && $0.host.id == "local" })
        let settings = URL(fileURLWithPath: project.project.directory).appendingPathComponent(".pi/settings.json")
        if state == "missing" { try FileManager.default.removeItem(at: settings) }
        else if state == "invalid" { try "{ broken".write(to: settings, atomically: true, encoding: .utf8) }
        else {
            var value: [String: Any] = ["thinkingLevel": "high"]
            if state == "long" { value["note"] = String(repeating: "Long project settings remain editable. ", count: 30) }
            value = try PiCodemode.setting(state == "inherit" || state == "long" ? nil : state == "on", in: value)
            try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted]).write(to: settings)
        }
        await model.open(project)
        await model.navigate(.category(.pi))
        #expect((model.codemodeProblem != nil) == (state == "invalid"))
        try await Preview.renderMatrix("projects-codemode-\(state)", size: CGSize(width: 1440, height: 1100)) {
            SettingsView(vm: world.vm)
        }
    }

    @Test(arguments: ["narrow", "long"])
    func detailEdges(state: String) async throws {
        let world = try await ProjectsPreviewWorld(long: state == "long", detail: true)
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.host.id == "local" && !$0.project.minimal })
        await world.vm.projects.open(project)
        try await Preview.renderMatrix("projects-detail-\(state)", size: CGSize(width: state == "narrow" ? 1050 : 1440, height: 900)) {
            RootView(vm: world.vm)
        }
    }

    private func editExternalFile(_ state: String, model: ProjectsModel, project: ProjectsRow) async throws {
        let file = URL(fileURLWithPath: project.project.directory).appendingPathComponent("AGENTS.md")
        if state == "conflict" {
            model.draft += "\n- Unsaved change.\n"
            try "Externally changed instructions.\n".write(to: file, atomically: true, encoding: .utf8)
            await model.save()
        } else {
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createSymbolicLink(at: file, withDestinationURL: file.deletingLastPathComponent().appendingPathComponent(".pi/settings.json"))
            let selectedFile = try #require(model.selectedFile)
            await model.read(selectedFile)
        }
    }

    @Test(arguments: [false, true])
    func projectEditorFillsTheViewport(long: Bool) async throws {
        let world = try await ProjectsPreviewWorld(long: long)
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.host.id == "local" && $0.project.name.hasPrefix("dashboard") })
        await world.vm.projects.open(project)
        try await Preview.renderMatrix("projects-full-width-\(long ? "long" : "editor")", size: CGSize(width: 2400, height: 1100)) {
            RootView(vm: world.vm)
        }
    }

    @Test(arguments: ["edited", "discard", "saved", "invalid-json", "missing-skill", "missing-file", "conflict", "unsafe-file"])
    func editing(state: String) async throws {
        let world = try await ProjectsPreviewWorld()
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.project.name == (state == "missing-skill" ? "ops-scripts" : "dashboard") })
        let model = world.vm.projects
        await model.open(project)
        if state == "missing-skill" { await model.navigate(.category(.skills)) }
        else if state == "missing-file" {
            let file = try #require(model.files.first { $0.path == ".pi/APPEND_SYSTEM.md" })
            await model.read(file)
        } else if state == "conflict" || state == "unsafe-file" {
            try await editExternalFile(state, model: model, project: project)
        } else if state == "invalid-json" {
            await model.navigate(.category(.pi)); model.draft = "invalid JSON"; await model.save()
        } else {
            model.draft += "\n- Keep this instruction in this project only.\n"
            if state == "discard" { await model.navigate(.close) }
            if state == "saved" { await model.save() }
        }
        try await Preview.renderMatrix("projects-\(state)", size: CGSize(width: 1440, height: 1000)) { SettingsView(vm: world.vm) }
    }
}

@MainActor
final class ProjectsPreviewWorld {
    let local: ScratchServer
    let remote: ScratchServer
    let vm: ShepherdViewModel

    init(empty: Bool = false, long: Bool = false, legacy: Bool = false, detail: Bool = false) async throws {
        let dir = try makeScratchDirectory("prv-projects")
        let home = dir.appendingPathComponent("home")
        let pi = PiSetup(engine: PiSetup.app.engine, home: dir.appendingPathComponent("pi"), userHome: home.path)
        local = try ScratchServer(dir: dir, pi: pi)
        let remoteDir = try makeScratchDirectory("prv-proj-host")
        let remoteHome = remoteDir.appendingPathComponent("home")
        remote = try ScratchServer(dir: remoteDir, pi: PiSetup(engine: PiSetup.app.engine, home: remoteDir.appendingPathComponent("pi"), userHome: remoteHome.path))
        let defaults = ScratchDefaults()
        let settings = AppSettings(store: defaults)
        let hosts = RemoteHostStore(defaults: defaults)
        vm = ShepherdViewModel(server: local.server, settings: settings, keybindings: KeybindingsStore(store: defaults),
                               themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .light),
                               remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in },
                               restoresAgentsAtLaunch: false, checkoutReader: nil)
        vm.showSettings = true; vm.settingsSection = .projects
        if !empty {
            let names = [long ? "dashboard-with-a-very-long-name-and-an-equally-long-directory" : detail ? "payments" : "dashboard", "mobile", "ops-scripts"]
            let localSpaces = names.map { Space(name: $0, path: home.appendingPathComponent((detail ? "code/" : "Developer/") + $0).path) }
            let remoteSpaces = [detail ? "payments" : "api-service", "docs-site", "payments"].map { Space(name: $0, path: remoteHome.appendingPathComponent((detail ? "code/" : "work/") + $0).path) }
            for space in localSpaces + remoteSpaces { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
            func file(_ space: Space, _ relative: String, _ text: String) throws {
                let url = URL(fileURLWithPath: space.path).appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            for space in [localSpaces[0], localSpaces[1], remoteSpaces[0], remoteSpaces[1]] {
                try file(space, "AGENTS.md", "# Project instructions\n\n- Work only in this project.\n- Validate changes before a pull request.\n")
            }
            if detail {
                let paymentsGuidance = "# payments\n\nGo services for the ledger and the refund outbox.\n\n## Rules\n- Money is always integer minor units. Never floats.\n- Every ledger write goes through `ledger.Tx`.\n- Run `make test` before saying a change is done.\n\n## Layout\n- `ledger/` double-entry core, `ledger/outbox/` events\n\n\n"
                try file(localSpaces[0], "AGENTS.md", paymentsGuidance)
                try file(remoteSpaces[0], "AGENTS.md", paymentsGuidance)
                try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-172_800)], ofItemAtPath: localSpaces[0].path + "/AGENTS.md")
                let global = home.appendingPathComponent(".pi/agent/AGENTS.md")
                try FileManager.default.createDirectory(at: global.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("# Personal instructions\n".utf8).write(to: global)
                let parent = home.appendingPathComponent("code/AGENTS.md")
                try Data("# Parent guidance\n".utf8).write(to: parent)
                try file(localSpaces[0], ".pi/skills/payments-tests/SKILL.md", "# Payments tests\nRun make test.\n")
                try file(localSpaces[0], ".pi/skills/release/SKILL.md", "# Release checks\nRead the release docs.\n")
                try file(localSpaces[0], ".pi/extensions/ledger.ts", "export default function ledger() {}\n")
            }
            for name in ["design-review", "useful-tests"] {
                try file(localSpaces[0], ".pi/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: Project-only guidance\n---\n\n# \(name)\n\nRead the project's instructions.\n")
            }
            try file(localSpaces[1], ".pi/skills/mobile/SKILL.md", "# Mobile project\nUse the native client.\n")
            try file(localSpaces[0], ".pi/settings.json", "{\n  \"thinkingLevel\": \"high\"\n}\n")
            try file(localSpaces[0], ".pi/mcp.json", detail ? "{\"mcpServers\":{\"docs\":{},\"ledger\":{}}}" : "{\n  \"mcpServers\": {\"docs\": {\"url\": \"https://example.invalid/mcp\"}}\n}\n")
            try file(localSpaces[0], ".pi/extensions/project.ts", "// A project extension is edited, never executed, by this page.\nexport default function project() {}\n")
            try file(remoteSpaces[0], ".pi/settings.json", "{\"extensions\":[\"./one.ts\",\"./two.ts\",\"./three.ts\"]}")
            for space in [remoteSpaces[0], remoteSpaces[2]] { try file(space, ".pi/mcp.json", "{\"mcpServers\":{\"docs\":{},\"tools\":{}}}") }
            let system = dir.appendingPathComponent("design-systems/dashboard/system.json")
            try FileManager.default.createDirectory(at: system.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(DesignSystemInfo(namespace: "dashboard", title: "Dashboard", createdAt: 0, spaceID: localSpaces[0].id)).write(to: system)
            try await local.server.putState(ShepherdState(spaces: localSpaces))
            try await remote.server.putState(ShepherdState(spaces: remoteSpaces))
            vm.adopt(local.server.state)
        }
        let tokenURL = remote.dir.appendingPathComponent("token")
        if legacy { remote.server.advertisedCapabilities = [] }
        let port = try remote.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        hosts.addHost(name: detail ? "Build-01" : "build-01", host: "127.0.0.1", port: port, token: token)
        try await eventuallyOnMain("the project host to connect") { hosts.connections.first?.phase == .connected && (empty || hosts.connections.first?.state.spaces.count == 3) }
        await vm.projects.load(vm.projectsSources)
    }

    func stop() {
        for connection in vm.remoteHosts.connections { vm.remoteHosts.removeHost(id: connection.id) }
        remote.stop(); local.stop()
    }
}
