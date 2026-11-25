import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Every tool Shepherd gives an agent reads as what it did (ToolFeed › A · every tool, live and done), and the computer use tools
/// read as actions in an app.
@Suite("Tool words")
struct ToolWordsTests {
    typealias F = Fixture

    private static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func call(_ name: String, _ args: [String: Any] = [:], output: String = "", error: Bool = false, status: String = "complete",
                      id: String = UUID().uuidString) -> NativeActivityCall {
        NativeActivityCall(F.tool(name, args: Self.json(args), output: output, error: error, status: status, id: "e-\(id)", callID: id))
    }

    /// The names the bundled extensions register as tools, read from their sources; the namespace records that group tools
    /// for tool_search are not tools.
    private static var registeredTools: [String] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let folder = root.appendingPathComponent("Extensions")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let pattern = try! NSRegularExpression(pattern: #"name: "([a-z_]+)""#)
        var names: Set<String> = []
        for file in files where file.pathExtension == "ts" {
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
            for match in pattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let range = Range(match.range(at: 1), in: text) { names.insert(String(text[range])) }
            }
        }
        return names.filter { $0 != "shepherd" && !($0.hasPrefix("shepherd_") && !$0.hasPrefix("shepherd_child_")
            && !["shepherd_workflow", "shepherd_parent_message"].contains($0)) }.sorted()
    }

    @Test func everyRegisteredToolReadsAsWhatItDidNeverUsed() {
        let names = Self.registeredTools
        #expect(names.count > 80, "found the extensions' tools")
        for name in names {
            let done = nativeActivityBurst([call(name, output: "ok")]).label
            let running = nativeActivityBurst([call(name, status: "running")]).label
            let failed = nativeActivityBurst([call(name, output: "no", error: true)]).label
            #expect(!done.hasPrefix("Used ") && !running.hasPrefix("Running \(name)") && !failed.hasPrefix("\(name) failed"),
                    "\(name): \(done) / \(running) / \(failed)")
        }
    }

    @Test func shepherdToolsNameTheirSubject() {
        #expect(nativeActivityBurst([call("board_render", ["path": "A-phone.dc.html"], output: "ok")]).label == "Rendered A · phone")
        #expect(nativeActivityBurst([call("board_render", ["path": "A.dc.html"], output: "ok"), call("board_render", ["path": "B.dc.html"], output: "ok")]).label
                == "Rendered 2 boards")
        #expect(nativeActivityBurst([call("terminal_open", ["command": "pnpm dev"], output: "ok")]).label == "Opened a terminal for pnpm dev")
        #expect(nativeActivityBurst([call("WebSearch", ["query": "swift testing"], status: "running")]).label == "Searching the web for “swift testing”")
        #expect(nativeActivityBurst([call("WebFetch", ["url": "https://www.example.com/docs"], output: "ok")]).label == "Read example.com")
        #expect(nativeActivityBurst([call("checkpoint_create", ["name": "before chip move"], output: "ok")]).label == "Saved checkpoint “before chip move”")
    }

    @Test func aComputerUseCallNamesWhatItActedOn() {
        let click = call("click", ["element_token": "s0000001:137"],
                         output: "Sent, effect not verified: Performed AXPress on [137] AXPopUpButton \"More options\".")
        #expect(click.kind == .computer)
        #expect(nativeActivityBurst([click]).label == "Clicked “More options”")
        #expect(nativeActivityBurst([call("get_window_state", ["pid": 836, "window_id": 1], output: "window_id=1 pid=836")]).label == "Read the window")
        #expect(nativeActivityBurst([call("hotkey", ["keys": ["cmd", "s"]], status: "running")]).label == "Pressing cmd+s")
        #expect(nativeActivityBurst([call("invoke_menu", ["path": ["File", "Save As…"]], output: "ok")]).label == "Chose File › Save As…")
        #expect(nativeActivityBurst([call("launch_app", ["name": "Safari"], output: "ok")]).label == "Opened Safari")
        let typed = nativeActivityBurst([call("type_text", ["text": "hunter2"], output: "Inserted \"hunter2\".")])
        #expect(typed.label == "Typed in a field" && !typed.meta.contains("hunter2"), "what was typed is never in a line")
        #expect(nativeActivityBurst([call("run_steps", ["steps": [[:]]], output: "step 1 of 1 failed", error: true)]).label == "Couldn’t run the steps")
    }

    @Test func aRunOfComputerUseCallsIsActionsInItsApp() {
        let calls = [
            call("list_windows", ["app": "Safari"], output: "Found 6 window(s)."),
            call("get_window_state", ["pid": 1, "window_id": 2], output: "window_id=2"),
            call("click", ["element_token": "s:1"], output: "Performed AXPress on [1] AXButton \"Delete\"."),
        ]
        let burst = nativeActivityBurst(calls)
        #expect(burst.kind == .computer)
        #expect(burst.label == "3 actions in Safari" && burst.meta == "last “Delete”")
    }
}
