import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A thread's latest exchange as the palette previews it.
@Suite("Thread preview")
struct ThreadPreviewTests {
    static func snapshot(_ messages: [NativeThreadMessage], running: Bool = false) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: running, model: "anthropic/claude-opus",
                             supportedActions: [], dialogsSupported: true, dialogs: [], messages: messages, provisional: [],
                             clipped: false)
    }

    @Test func thePreviewKeepsTheLastLinesNewestLast() {
        let preview = ThreadPreview(Self.snapshot([
            Fixture.user("first", id: "1"),
            Fixture.assistant("reply one", thinking: "hmm", id: "2"),
            Fixture.tool("bash", args: #"{"command":"swift test"}"#, output: "ok", id: "3"),
            Fixture.assistant("", thinking: "only thinking", id: "4"),
            Fixture.user("second\n\n  prompt", id: "5"),
        ], running: true), limit: 3)
        #expect(preview.lines.map(\.id) == ["2", "3", "5"])
        #expect(preview.lines.map(\.kind) == [.assistant, .activity, .user])
        #expect(preview.lines[0].text == "reply one")
        #expect(preview.lines[2].text == "second prompt")
        #expect(preview.running)
        #expect(preview.model == "anthropic/claude-opus")
    }

    @Test func aFailedCallIsMarked() {
        let preview = ThreadPreview(Self.snapshot([Fixture.tool("bash", args: #"{"command":"make"}"#, output: "boom", error: true, id: "1")]))
        #expect(preview.lines.count == 1)
        #expect(preview.lines[0].failed)
        #expect(preview.lines[0].text.hasPrefix("bash"))
    }

    @Test func longTextIsClippedWithAnEllipsis() {
        let long = String(repeating: "x", count: 1_000)
        let preview = ThreadPreview(Self.snapshot([Fixture.assistant(long, id: "1")]))
        #expect(preview.lines[0].text.count == ThreadPreview.textLimit + 1)
        #expect(preview.lines[0].text.hasSuffix("…"))
    }

    @Test func anEmptyThreadHasNoLines() {
        #expect(ThreadPreview(Self.snapshot([])).lines.isEmpty)
    }
}
