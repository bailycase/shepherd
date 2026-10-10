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

@Suite("Remote Projects controls", .mainActorExclusive)
@MainActor
struct ProjectsRemoteControlTests {
    @Test func remoteRowsAndSavesReachOnlyTheSelectedHostThroughAccessibility() async throws {
        try await #require(processExitsWith: .success) { try await Self.pressRemoteControls() }
    }

    private static func pressRemoteControls() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let local = try ScratchServer()
        let remote = try ScratchServer()
        defer { remote.stop(); local.stop() }
        try local.server.start(); try remote.server.start()
        let localRoot = local.dir.appendingPathComponent("local-project")
        let remoteRoot = remote.dir.appendingPathComponent("remote-project")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try "Local instructions\n".write(to: localRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Host instructions\n".write(to: remoteRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let remoteMCP = remoteRoot.appendingPathComponent(".shepherd/mcp.json")
        try FileManager.default.createDirectory(at: remoteMCP.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"remote-tools":{"command":"remote-server","future":"keep"}}}"#
            .write(to: remoteMCP, atomically: true, encoding: .utf8)
        try await local.server.addSpace(Space(name: "Local project", path: localRoot.path), first: false)
        try await remote.server.addSpace(Space(name: "Remote project", path: remoteRoot.path), first: false)
        let tokenURL = remote.dir.appendingPathComponent("token")
        let port = try remote.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let defaults = ScratchDefaults()
        let hosts = RemoteHostStore(defaults: defaults)
        hosts.addHost(name: "mac-mini", host: "127.0.0.1", port: port, token: token)
        defer { for connection in hosts.connections { hosts.removeHost(id: connection.id) } }
        try await eventuallyOnMain("the authenticated Projects host") { hosts.connections.first?.phase == .connected }
        let vm = ShepherdViewModel(server: local.server, settings: AppSettings(store: defaults), keybindings: KeybindingsStore(store: defaults),
            themeManager: ThemeManager(store: defaults, environmentTheme: nil, systemColorScheme: .dark),
            remoteHosts: hosts, sidebarDefaults: defaults, themeInstaller: { _ in }, restoresAgentsAtLaunch: false, checkoutReader: nil)
        vm.showSettings = true; vm.settingsSection = .projects
        let model = vm.projects
        await model.load(vm.projectsSources)
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, SettingsView(vm: vm))
        defer { window.close() }
        try await eventuallyOnMain("the remote host filter control") {
            window.layout()
            return AccessibilityNode.all(under: window.host).contains { $0.label == "mac-mini" && $0.role == ControlRole.radioButton }
        }
        try ControlPress.press("mac-mini", role: ControlRole.radioButton, under: window.host)
        #expect(model.visible.allSatisfy { $0.host.name == "mac-mini" })
        window.layout()
        try ControlPress.press("Open Remote project", under: window.host)
        try await eventuallyOnMain("the remote project's instructions") { model.fileLoaded }
        #expect(model.draft == "Host instructions\n")
        window.layout()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let textView = try #require(editor(in: window.host))
        let text = "Only the host project changed\n"
        textView.string = text; textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
        try await eventuallyOnMain("the remote project edit") { model.dirty }
        window.layout()
        try ControlPress.press("Save", under: window.host)
        try await eventuallyOnMain("the host-only save") { !model.saving && !model.dirty && model.notice != nil }
        #expect(try String(contentsOf: remoteRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8) == text)
        #expect(try String(contentsOf: localRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "Local instructions\n")
        try window.press("Project category MCP servers")
        try await eventuallyOnMain("remote project MCP cards") {
            window.layout()
            return model.fileLoaded && window.element("remote-tools, Not checked yet") != nil
        }
        try window.press("remote-tools", role: ControlRole.checkBox)
        try await eventuallyOnMain("remote MCP save") { !model.saving && model.mcp.rows.first?.status == .off }
        let result = ProjectMCPConfiguration(text: try String(contentsOf: remoteMCP, encoding: .utf8), path: ".shepherd/mcp.json")
        #expect(result.entries.first?.json["enabled"] == .bool(false))
        #expect(result.entries.first?.json["future"] == .string("keep"))
        #expect(!FileManager.default.fileExists(atPath: localRoot.appendingPathComponent(".shepherd/mcp.json").path))
        try window.press(".mcp.json")
        try await eventuallyOnMain("missing shared project MCP file") { model.fileLoaded && model.selectedFile?.path == ".mcp.json" }
        #expect(model.mcp.entries.isEmpty && !model.mcp.native)
        try window.press(".shepherd/mcp.json")
        try await eventuallyOnMain("native project MCP restored") { model.fileLoaded && model.mcp.entries.first?.name == "remote-tools" }
    }
}
