import AppKit
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("MCP argument controls", .mainActorExclusive)
@MainActor
struct MCPArgumentsControlTests {
    @Test func localArgumentsAreLiteralAndCanBeAddedEditedAndRemoved() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.checkArguments() }
        }
        expectScenarioCompleted(result)
    }

    private static func checkArguments() async throws {
        AccessibilityNode.enable()
        let store = try MCPSettingsControlTests.store(config: "{}", cli: MCPSettingsControlTests.RecordingCLI(),
                                                      pasteboard: MCPSettingsControlTests.Pasteboard())
        let executable = "/Applications/Bear.app/Contents/MacOS/bearcli"
        var closed = false
        let draft = AddMCPServerSheet.Draft(name: "bear", command: executable, checkedAt: Date())
        var window = OffscreenWindow(size: CGSize(width: 760, height: 900), dark: false,
                                     AddMCPServerSheet(store: store, initialKind: .local, editing: nil, draft: draft) { closed = true })
        try await eventuallyOnMain("local argument controls") { window.element("Add argument") != nil }
        #expect(fields("Command", in: window).first?.value == executable)
        try window.press("Add argument")
        try await eventuallyOnMain("first argument row") { fields("Argument", in: window).count == 1 }
        try setArgument("mcp-server", in: window)
        try window.press("Add and start")
        try await eventuallyOnMain("Bear configuration saved") { closed }
        window.close()
        let bear = try #require(store.entry("bear"))
        #expect(bear.command == executable && bear.args == ["mcp-server"])

        // Open an existing standard command/args configuration without joining or reparsing it.
        let literalCommand = "/tmp/MCP tools/server's executable"
        let literals = ["two words", "\"double\" and 'single' quotes", "", "  padded  ", #"C:\tools\server"#, "${VALUE}", "first\nsecond"]
        var entry = MCPServerEntry(name: "literal", json: ["command": .string(literalCommand), "future": .bool(true)])
        entry.args = literals
        try store.save(entry, secrets: [:], replacing: nil)
        closed = false
        // Skip executable discovery. This scenario tests the editor, not the host's PATH.
        let checked = AddMCPServerSheet.Draft(command: literalCommand, checkedAt: Date())
        window = OffscreenWindow(size: CGSize(width: 760, height: 1100), dark: true,
                                 AddMCPServerSheet(store: store, initialKind: nil, editing: entry, draft: checked) { closed = true })
        try await eventuallyOnMain("existing arguments loaded") { fields("Argument", in: window).count == literals.count }
        #expect(fields("Command", in: window).first?.value == literalCommand)
        #expect(fields("Argument", in: window).map { $0.value ?? "" } == literals)
        try window.press("Save")
        try await eventuallyOnMain("unchanged arguments saved") { closed }
        window.close()
        let unchanged = try #require(store.entry("literal"))
        #expect(unchanged.command == literalCommand && unchanged.args == literals)
        #expect(unchanged.json["future"] == .bool(true))

        closed = false
        window = OffscreenWindow(size: CGSize(width: 760, height: 1100), dark: false,
                                 AddMCPServerSheet(store: store, initialKind: nil, editing: unchanged, draft: checked) { closed = true })
        defer { window.close() }
        try await eventuallyOnMain("arguments ready to edit") { fields("Argument", in: window).count == literals.count }
        try setArgument("changed 'value' with spaces", in: window)
        try window.press("Remove argument", nth: 1)
        try window.press("Add argument")
        try await eventuallyOnMain("argument rows updated") {
            fields("Argument", in: window).count == literals.count && fields("Argument", in: window).last?.value == ""
        }
        #expect(ControlPress.undersized(window.controls(), minimum: .desktop).isEmpty)
        try window.press("Save")
        try await eventuallyOnMain("edited arguments saved") { closed }
        let saved = try #require(store.entry("literal"))
        #expect(saved.command == literalCommand)
        #expect(saved.args == ["changed 'value' with spaces"] + Array(literals.dropFirst(2)) + [""])
        guard case .document(let document) = store.dependencies.file.read() else { throw MCPSettingsControlTests.Failure("unreadable") }
        #expect(document.server("literal")?.args == saved.args, "the values reach the standard MCP file")
    }

    private static func fields(_ label: String, in window: OffscreenWindow) -> [AccessibilityNode] {
        AccessibilityNode.all(under: window.host).filter { $0.label == label && $0.role == "AXTextField" }
    }

    private static func setArgument(_ value: String, in window: OffscreenWindow) throws {
        let field = try #require(fields("Argument", in: window).first)
        let setter = NSSelectorFromString("setAccessibilityValue:")
        try #require(field.object.responds(to: setter))
        field.object.perform(setter, with: value)
        func nativeField(_ view: NSView) -> NSTextField? {
            if let text = view as? NSTextField, text.stringValue == value { return text }
            return view.subviews.compactMap(nativeField).first
        }
        let text = field.object as? NSTextField ?? (field.object as? NSCell)?.controlView as? NSTextField ?? nativeField(window.host)
        text?.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: text))
        window.layout()
    }
}
