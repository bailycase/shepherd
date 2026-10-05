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

@Suite("Project MCP controls", .mainActorExclusive)
@MainActor
struct ProjectMCPControlTests {
    @Test func serverCardsEditOnlyTheProjectThroughAccessibleControls() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.checkCards() } }
    }

    @Test func addAndEditFormsSaveTheirFieldsWithoutGlobalCredentials() async {
        await #expect(processExitsWith: .success) { await recordingErrors { try await Self.checkForms() } }
    }

    private static func checkCards() async throws {
        AccessibilityNode.enable()
        let fixture = try await Fixture()
        defer { fixture.scratch.stop() }
        let model = fixture.model
        var copied = ""
        let window = OffscreenWindow(size: CGSize(width: 1000, height: 750), dark: true,
                                     ProjectMCPSettings(model: model, copyJSON: { copied = $0 }))
        defer { window.close() }
        try await eventuallyOnMain("project server cards") { window.element("docs, Not checked yet") != nil }
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty,
                "\(ControlPress.undersized(window.controls(), minimum: .desktop))")
        try window.press("docs", role: ControlRole.checkBox)
        try await eventuallyOnMain("project switch saved") { !model.saving && model.mcp.rows.first?.status == .off }
        #expect(try fixture.entry("docs").json["enabled"] == .bool(false))
        try window.press("docs", role: ControlRole.checkBox)
        try await eventuallyOnMain("project enabled") { !model.saving && model.mcp.rows.first?.enabled == true }
        try ControlPress.perform("Open", onLabelContaining: "docs,", under: window.host)
        try await eventuallyOnMain("project detail") { window.element("Edit…") != nil }
        try window.press("Edit…")
        let edit = try await sheet(window)
        try ControlPress.press("Cancel", under: edit)
        try await eventuallyOnMain("cancelled project edit") { window.window.attachedSheet == nil }
        try window.press("Direct")
        try await eventuallyOnMain("project direct tools saved") { !model.saving && model.mcp.details["docs"]?.direct == true }
        #expect(try fixture.entry("docs").json["exposure"] == .string("direct"))
        try window.press("Search")
        try await eventuallyOnMain("project search tools saved") { !model.saving && model.mcp.details["docs"]?.direct == false }
        try window.press("Copy JSON")
        #expect(copied.contains("future") && copied.contains("docs"))
        try set("Filter servers", to: "not-a-server", under: window.host)
        try await eventuallyOnMain("filtered project cards") {
            window.elements().contains { $0.label == "No servers match your search." || $0.value == "No servers match your search." }
        }
        try set("Filter servers", to: "", under: window.host)
        try window.press("Reload")
        try await eventuallyOnMain("reloaded project") { !model.fileLoading && model.fileLoaded }
        try window.press("Remove")
        var dialog = try await sheet(window)
        try ControlPress.press("Cancel", under: dialog)
        try await eventuallyOnMain("cancelled remove") { window.window.attachedSheet == nil }
        #expect(try fixture.entry("docs").json["future"] == .string("keep"))
        try window.press("Remove")
        dialog = try await sheet(window)
        try ControlPress.press("Remove", under: dialog)
        try await eventuallyOnMain("project server removed") { !model.saving && model.mcp.entries.isEmpty }
        #expect(try String(contentsOf: fixture.url, encoding: .utf8).contains("owner"))
        #expect(window.elements().contains { $0.label == "No servers in this file yet. Add a server to get started." || $0.value == "No servers in this file yet. Add a server to get started." })
        try await eventuallyOnMain("closed remove dialog") { window.window.attachedSheet == nil }
        try window.press("Add server")
        let add = try await sheet(window)
        try ControlPress.press("Cancel", under: add)
        try await eventuallyOnMain("cancelled project add") { window.window.attachedSheet == nil }
    }

    private static func checkForms() async throws {
        AccessibilityNode.enable()
        let fixture = try await Fixture(failFirstSave: true)
        defer { fixture.scratch.stop() }
        let model = fixture.model
        var dismissed = false
        var window = OffscreenWindow(size: CGSize(width: 570, height: 780), dark: false,
                                     AddMCPServerSheet(project: model, initialKind: .local, editing: nil) { dismissed = true })
        try await eventuallyOnMain("local form") { !window.controls().isEmpty }
        try set("Command", to: "project-server --read-only", under: window.host)
        try set("Name", to: "local-tools", under: window.host)
        try window.press("Add variable")
        try set("Name", to: "PROJECT_TOKEN", under: window.host, nth: 1)
        try set("Value", to: "${PROJECT_TOKEN}", under: window.host)
        try window.press("Show value")
        try window.press("Hide value")
        try window.press("Add variable")
        try set("Name", to: "TEMP", under: window.host, nth: 2)
        try window.press("Remove TEMP")
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty,
                "\(ControlPress.undersized(window.controls(), minimum: .desktop))")
        try window.press("Add")
        try await eventuallyOnMain("failed save leaves the form open") { model.fileError != nil && model.dirty }
        #expect(!dismissed)
        try window.press("Add")
        try await eventuallyOnMain("local project server saved") { dismissed }
        window.close()
        let local = try fixture.entry("local-tools")
        #expect(local.command == "project-server" && local.args == ["--read-only"])
        #expect(local.env == ["PROJECT_TOKEN": "${PROJECT_TOKEN}"])
        #expect(local.json["shepherd"] == nil && local.json["exposure"] == .string("deferred"))

        dismissed = false
        let docs = try fixture.entry("docs")
        window = OffscreenWindow(size: CGSize(width: 570, height: 780), dark: true,
                                 AddMCPServerSheet(project: model, initialKind: nil, editing: docs) { dismissed = true })
        defer { window.close() }
        try await eventuallyOnMain("remote edit form") { !window.controls().isEmpty }
        try set("URL", to: "https://updated.invalid/mcp", under: window.host)
        try window.press("Header", role: ControlRole.radioButton)
        try set("Value", to: "Bearer ${PROJECT_TOKEN}", under: window.host)
        try window.press("Save")
        try await eventuallyOnMain("remote project edit saved") { dismissed }
        let saved = try fixture.entry("docs")
        #expect(saved.url == "https://updated.invalid/mcp")
        #expect(saved.headers["Authorization"] == "Bearer ${PROJECT_TOKEN}")
        #expect(saved.json["future"] == .string("keep"))
        #expect(saved.json["timeout"] == .number(700.5))
        #expect(saved.json["shepherd"] == nil)
        window.close()

        dismissed = false
        window = OffscreenWindow(size: CGSize(width: 570, height: 780), dark: false,
                                 AddMCPServerSheet(project: model, initialKind: .remote, editing: nil) { dismissed = true })
        try await eventuallyOnMain("new server choices") { !window.controls().isEmpty }
        try window.press("Paste JSON", role: ControlRole.radioButton)
        try set("JSON", to: #"{"mcpServers":{"imported":{"command":"imported-server","future":true}}}"#, under: window.host)
        try window.press("Add")
        try await eventuallyOnMain("pasted project configuration saved") { dismissed }
        let imported = try fixture.entry("imported")
        #expect(imported.command == "imported-server" && imported.json["future"] == .bool(true))
        #expect(imported.json["exposure"] == .string("deferred"))
    }

    private static func sheet(_ window: OffscreenWindow) async throws -> NSView {
        try await eventuallyOnMain("project dialog") { window.layout(); return window.window.attachedSheet?.contentView != nil }
        let content = try #require(window.window.attachedSheet?.contentView)
        content.layoutSubtreeIfNeeded()
        #expect(!window.window.isKeyWindow && window.window.attachedSheet?.isKeyWindow != true)
        return content
    }

    private static func set(_ label: String, to value: String, under host: NSView, nth: Int = 0) throws {
        let fields = AccessibilityNode.all(under: host).filter { $0.label == label && ["AXTextField", "AXTextArea"].contains($0.role ?? "") }
        let field = try #require(fields.indices.contains(nth) ? fields[nth] : nil, "\(label): \(AccessibilityNode.all(under: host).compactMap(\.label))")
        let setter = NSSelectorFromString("setAccessibilityValue:")
        #expect(field.object.responds(to: setter))
        field.object.perform(setter, with: value)
        if field.role == "AXTextArea" {
            func editor(_ view: NSView) -> NSTextView? {
                if let text = view as? NSTextView { return text }
                return view.subviews.compactMap(editor).first
            }
            let text = try #require(editor(host))
            text.string = value
            text.delegate?.textDidChange?(Notification(name: NSText.didChangeNotification, object: text))
        }
        func nativeField(_ view: NSView) -> NSTextField? {
            if let field = view as? NSTextField, field.stringValue == value { return field }
            return view.subviews.compactMap(nativeField).first
        }
        let text = field.object as? NSTextField ?? (field.object as? NSCell)?.controlView as? NSTextField ?? nativeField(host)
        text?.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: text))
        host.layoutSubtreeIfNeeded()
    }

    @MainActor private final class Fixture {
        let scratch: ScratchServer
        let model: ProjectsModel
        let url: URL
        init(failFirstSave: Bool = false) async throws {
            let scratch = try ScratchServer()
            self.scratch = scratch
            let root = scratch.dir.appendingPathComponent("project")
            url = root.appendingPathComponent(".pi/mcp.json")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try #"{"owner":"keep","mcpServers":{"docs":{"url":"https://docs.invalid/mcp","exposure":"deferred","timeout":700.5,"future":"keep"}}}"#
                .write(to: url, atomically: true, encoding: .utf8)
            let state = ShepherdState(spaces: [Space(name: "project", path: root.path)])
            var fail = failFirstSave
            model = ProjectsModel { _, request in
                if case .save = request, fail {
                    fail = false
                    throw ProjectFileError("unavailable", "The host disconnected. Try saving again.")
                }
                return try await scratch.server.projects.request(request, state: state)
            }
            await model.load([ProjectsHost(id: "local", name: "This Mac", known: [])])
            await model.open(try #require(model.rows.first))
            await model.navigate(.category(.mcp))
        }
        func entry(_ name: String) throws -> MCPServerEntry {
            let config = ProjectMCPConfiguration(text: try String(contentsOf: url, encoding: .utf8), path: ".pi/mcp.json")
            return try #require(config.entries.first { $0.name == name })
        }
    }
}
