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

@Suite("Projects controls", .mainActorExclusive)
@MainActor
struct ProjectsRemoteControlTests {
    @Test func theFleetWideScreenEditsThisMacsSpacesAndNeverAnotherHostsThroughAccessibility() async throws {
        try await #require(processExitsWith: .success) { try await Self.pressRemoteControls() }
    }

    private static func pressRemoteControls() async throws {
        try StubPi.installAsEngine()
        AccessibilityNode.enable()
        let app = try AppHarness()
        let remote = try ScratchServer()
        defer { remote.stop(); app.stop() }
        try remote.server.start()
        let local = app.scratch
        let vm = try await app.start()
        let localRoot = local.dir.appendingPathComponent("local-project")
        let remoteRoot = remote.dir.appendingPathComponent("remote-project")
        try FileManager.default.createDirectory(at: localRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: remoteRoot, withIntermediateDirectories: true)
        try "Local instructions\n".write(to: localRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        try "Host instructions\n".write(to: remoteRoot.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let localMCP = localRoot.appendingPathComponent(".shepherd/mcp.json")
        try FileManager.default.createDirectory(at: localMCP.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"mcpServers":{"local-tools":{"command":"local-server","future":"keep"}}}"#
            .write(to: localMCP, atomically: true, encoding: .utf8)
        try await local.server.addSpace(Space(name: "Local project", path: localRoot.path), first: false)
        try await eventuallyOnMain("the app to adopt the space") { vm.state.spaces.contains { $0.name == "Local project" } }
        try await remote.server.addSpace(Space(name: "Remote project", path: remoteRoot.path), first: false)
        let tokenURL = remote.dir.appendingPathComponent("token")
        let port = try remote.server.startRemoteListener(port: 0, tokenURL: tokenURL)
        let token = try String(contentsOf: tokenURL, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let hosts = app.remoteHosts
        hosts.addHost(name: "mac-mini", host: "127.0.0.1", port: port, token: token, fleetManaged: true)
        try await eventuallyOnMain("the authenticated Projects host") { hosts.connections.first?.phase == .connected }
        vm.showSettings = true; vm.settingsSection = .projects
        let model = vm.projects
        await model.load(vm.projectsSources)
        let window = OffscreenWindow(size: CGSize(width: 1440, height: 900), dark: true, SettingsView(vm: vm))
        defer { window.close() }
        // Spaces are the fleet's, so the screen has no per-host filter and lists this Mac's spaces whatever hosts are connected.
        try await eventuallyOnMain("this Mac's space row") {
            window.layout()
            return window.element("Open Local project") != nil
        }
        #expect(model.visible.allSatisfy { $0.host.id == "local" } && !model.visible.isEmpty)
        #expect(window.element("Open Remote project") == nil)
        #expect(!AccessibilityNode.all(under: window.host).contains { $0.label == "mac-mini" && $0.role == ControlRole.radioButton })
        try ControlPress.press("Open Local project", under: window.host)
        try await eventuallyOnMain("the project's instructions") { model.fileLoaded }
        #expect(model.draft == "Local instructions\n")
        window.layout()
        func editor(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView { return text }
            return view.subviews.compactMap { editor(in: $0) }.first
        }
        let textView = try #require(editor(in: window.host))
        let text = "Only this Mac's project changed\n"
        textView.string = text; textView.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: textView))
        try await eventuallyOnMain("the project edit") { model.dirty }
        window.layout()
        try ControlPress.press("Save", under: window.host)
        try await eventuallyOnMain("the save") { !model.saving && !model.dirty && model.notice != nil }
        #expect(try String(contentsOf: localRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8) == text)
        #expect(try String(contentsOf: remoteRoot.appendingPathComponent("AGENTS.md"), encoding: .utf8) == "Host instructions\n")
        try window.press("Space category MCP servers")
        try await eventuallyOnMain("project MCP cards") {
            window.layout()
            return model.fileLoaded && window.element("local-tools, Not checked yet") != nil
        }
        try window.press("local-tools", role: ControlRole.checkBox)
        try await eventuallyOnMain("MCP save") { !model.saving && model.mcp.rows.first?.status == .off }
        let result = ProjectMCPConfiguration(text: try String(contentsOf: localMCP, encoding: .utf8), path: ".shepherd/mcp.json")
        #expect(result.entries.first?.json["enabled"] == .bool(false))
        #expect(result.entries.first?.json["future"] == .string("keep"))
        #expect(!FileManager.default.fileExists(atPath: remoteRoot.appendingPathComponent(".shepherd/mcp.json").path))
        try window.press(".mcp.json")
        try await eventuallyOnMain("missing shared project MCP file") { model.fileLoaded && model.selectedFile?.path == ".mcp.json" }
        #expect(model.mcp.entries.isEmpty && !model.mcp.native)
        try window.press(".shepherd/mcp.json")
        try await eventuallyOnMain("native project MCP restored") { model.fileLoaded && model.mcp.entries.first?.name == "local-tools" }
    }
}
