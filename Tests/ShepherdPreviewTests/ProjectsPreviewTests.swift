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
        try await Preview.renderMatrix("projects-\(state)", size: size) { SettingsView(vm: world.vm) }
    }

    @Test(arguments: ProjectFile.Category.allCases)
    func details(category: ProjectFile.Category) async throws {
        let world = try await ProjectsPreviewWorld()
        defer { world.stop() }
        let project = try #require(world.vm.projects.rows.first { $0.project.name == "dashboard" })
        await world.vm.projects.open(project)
        await world.vm.projects.navigate(.category(category))
        try await Preview.renderMatrix("projects-detail-\(category.rawValue)", size: CGSize(width: 1440, height: 900)) {
            SettingsView(vm: world.vm)
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

    init(empty: Bool = false, long: Bool = false, legacy: Bool = false) async throws {
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
            let names = [long ? "dashboard-with-a-very-long-name-and-an-equally-long-directory" : "dashboard", "mobile", "ops-scripts"]
            let localSpaces = names.map { Space(name: $0, path: home.appendingPathComponent("Developer/" + $0).path) }
            let remoteSpaces = ["api-service", "docs-site", "payments"].map { Space(name: $0, path: remoteHome.appendingPathComponent("work/" + $0).path) }
            for space in localSpaces + remoteSpaces { try FileManager.default.createDirectory(atPath: space.path, withIntermediateDirectories: true) }
            func file(_ space: Space, _ relative: String, _ text: String) throws {
                let url = URL(fileURLWithPath: space.path).appendingPathComponent(relative)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            for space in [localSpaces[0], localSpaces[1], remoteSpaces[0], remoteSpaces[1]] {
                try file(space, "AGENTS.md", "# Project instructions\n\n- Work only in this project.\n- Validate changes before a pull request.\n")
            }
            for name in ["design-review", "useful-tests"] { try file(localSpaces[0], ".pi/skills/\(name)/SKILL.md", "---\nname: \(name)\ndescription: Project-only guidance\n---\n\n# \(name)\n\nRead the project's instructions.\n") }
            try file(localSpaces[1], ".pi/skills/mobile/SKILL.md", "# Mobile project\nUse the native client.\n")
            try file(localSpaces[0], ".pi/settings.json", "{\n  \"thinkingLevel\": \"high\"\n}\n")
            try file(localSpaces[0], ".pi/mcp.json", "{\n  \"mcpServers\": {\"docs\": {\"url\": \"https://example.invalid/mcp\"}}\n}\n")
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
        hosts.addHost(name: "build-01", host: "127.0.0.1", port: port, token: token)
        try await eventuallyOnMain("the project host to connect") { hosts.connections.first?.phase == .connected && (empty || hosts.connections.first?.state.spaces.count == 3) }
        await vm.projects.load(vm.projectsSources)
    }

    func stop() {
        for connection in vm.remoteHosts.connections { vm.remoteHosts.removeHost(id: connection.id) }
        remote.stop(); local.stop()
    }
}
