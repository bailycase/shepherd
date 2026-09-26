import Foundation
import Testing
import ShepherdTestKit
import ShepherdProtocol
@testable import ShepherdApp

/// "Found in conversations" matches only what was said: user and assistant text, never pi's
/// session header, system prompt, tool definitions, thinking, tool calls or results, or JSON keys.
@Suite("Palette content search")
struct PaletteContentSearchTests {
    /// A session as pi writes it (format 3): header, model and thinking changes, the system
    /// prompt with its sections and tools, then one turn with a tool call and its result.
    static let session = [
        #"{"type":"session","version":3,"id":"4b126b80","timestamp":"2026-09-25T09:14:43.634Z","cwd":"/tmp/project"}"#,
        #"{"type":"model_change","id":"b4fcc013","parentId":null,"timestamp":"2026-09-25T09:14:44.107Z","provider":"qa","modelId":"gemini-3.1-flash-lite"}"#,
        #"{"type":"thinking_level_change","id":"32f94e54","parentId":"b4fcc013","timestamp":"2026-09-25T09:14:44.107Z","thinkingLevel":"off"}"#,
        #"{"type":"message","id":"7b179801","parentId":"32f94e54","timestamp":"2026-09-25T09:14:44.141Z","message":{"role":"system","content":"","sections":{"preamble":"You are an expert coding assistant operating inside pi. You help users by reading files, executing commands, editing code, and writing new files.","tools":"<tools>\n- read: Read file contents\n- bash: Execute bash commands\n- edit: Make surgical edits to files\n</tools>"},"timestamp":1790327684119,"toolsAdded":[{"name":"read","description":"Read the contents of a file.","parameters":{"type":"object","required":["path"],"properties":{"path":{"type":"string","description":"Path to the file to read"}}}}]}}"#,
        #"{"type":"message","id":"3e4cd1f2","parentId":"7b179801","timestamp":"2026-09-25T09:14:44.142Z","message":{"role":"user","content":[{"type":"text","text":"Which marmalade recipe uses the zebra oranges?"}],"timestamp":1790327684119}}"#,
        #"{"type":"message","id":"36484b37","parentId":"3e4cd1f2","timestamp":"2026-09-25T09:14:45.708Z","message":{"role":"assistant","content":[{"type":"thinking","thinking":"Pondering the pantry inventory first."},{"type":"toolCall","id":"bash-1","name":"bash","arguments":{"command":"grep -ri cupboard recipes"}}],"api":"openai-completions","provider":"qa","model":"gemini-3.1-flash-lite","usage":{"input":4715,"output":18,"totalTokens":8747},"stopReason":"toolUse","timestamp":1790327684148}}"#,
        #"{"type":"message","id":"4b5a76c7","parentId":"36484b37","timestamp":"2026-09-25T09:16:26.871Z","message":{"role":"toolResult","toolCallId":"bash-1","toolName":"bash","content":[{"type":"text","text":"recipes/breakfast.md: seville cupboard jar"}],"details":{},"isError":false,"timestamp":1790327786871}}"#,
        #"{"type":"custom_message","id":"5c6d7e8f","parentId":"4b5a76c7","timestamp":"2026-09-25T09:16:27.000Z","customType":"shepherd-status","content":"widget refresh","display":false}"#,
        #"{"type":"message","id":"9a2c44c1","parentId":"5c6d7e8f","timestamp":"2026-09-25T09:16:26.882Z","message":{"role":"assistant","content":[{"type":"text","text":"The Seville marmalade in breakfast.md uses them; it needs a long, slow boil."}],"api":"openai-completions","provider":"qa","model":"gemini-3.1-flash-lite","stopReason":"stop","timestamp":1790327786882}}"#,
        #"{"type":"message","id":"a1b2c3d4","parentId":"9a2c44c1","timestamp":"2026-09-25T09:17:00.000Z","message":{"role":"user","content":"Thanks! Say \"hi there\" to the kitchen.","timestamp":1790327820000}}"#,
    ].joined(separator: "\n") + "\n"

    private func snippet(_ query: String, in lines: String = session) -> String? {
        PaletteContentSearch.snippet(for: query, inSessionLines: Data(lines.utf8))
    }

    @Test(arguments: [
        "new", "read", "edit", "file", "tools", "expert coding",   // system prompt and tool definitions
        "session", "gemini", "openai", "toolsAdded", "parentId",  // header, models, JSON keys
        "Pondering", "cupboard", "seville cupboard",              // thinking, a tool call, a tool result
        "widget refresh",                                         // an extension's hidden message
    ])
    func textPiWroteAroundTheConversationNeverMatches(query: String) {
        #expect(snippet(query) == nil)
    }

    @Test(arguments: [
        ("zebra", "…marmalade recipe uses the zebra oranges?"),
        ("SLOW BOIL", "…uses them; it needs a long, slow boil."),
        (#""hi there""#, #"Thanks! Say "hi there" to the kitchen."#),
    ])
    func userAndAssistantTextMatches(query: String, expected: String) {
        #expect(snippet(query) == expected)
    }

    @Test func theNewestMessageThatMatchesGivesTheSnippet() {
        #expect(snippet("marmalade") == "The Seville marmalade in breakfast.md uses them; it needs a…")
    }

    /// A design chat's message carries the viewer's screen fenced ahead of it for pi: only what
    /// they typed is searched.
    @Test func aDesignViewRecordFencedAheadOfAMessageNeverMatches() throws {
        let board = try #require(DesignElementID("A.dc.html#7:1/1/0"))
        let record = DesignViewRecord(visibleBoards: ["A.dc.html"], selectedBoards: ["A.dc.html"], selected: [board],
                                      selection: [.init(id: board, kind: .shape, label: "Checkout funnel")])
        let text = record.fenced(nonce: "0123456789ab") + "Make the funnel card taller"
        let message = #"{"type":"message","message":{"role":"user","content":[{"type":"text","text":\#(try jsonString(text))}]}}"#
        #expect(snippet("Checkout", in: message) == nil)
        #expect(snippet("design-data", in: message) == nil)
        #expect(snippet("funnel card", in: message) == "Make the funnel card taller")
    }

    @Test func aSnippetIsOneLineCutAtWordsAroundTheMatch() throws {
        let text = "The first line of a long reply\nthat keeps going well past what fits, and then mentions quokka habitats somewhere in the middle before it goes on and on until the end of the message."
        let message = #"{"type":"message","message":{"role":"assistant","content":[{"type":"text","text":\#(try jsonString(text))}]}}"#
        let result = try #require(snippet("quokka", in: message))
        #expect(result == "…what fits, and then mentions quokka habitats somewhere in the middle before…")
    }

    @Test func onlyTheTailIsReadAndItsPartialFirstLineIsDropped() throws {
        let directory = try makeScratchDirectory("palette-search")
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("session.jsonl")
        let old = #"{"type":"message","message":{"role":"user","content":"an armadillo from long ago"}}"#
        let recent = #"{"type":"message","message":{"role":"user","content":"a pangolin just now"}}"#
        try Data((old + "\n" + recent + "\n").utf8).write(to: file)
        // The tail starts inside the older line, past "armadillo".
        let budget = recent.utf8.count + 12
        #expect(PaletteContentSearch.snippet(for: "pangolin", inSessionAt: file, tailBudget: budget) == "a pangolin just now")
        #expect(PaletteContentSearch.snippet(for: "long ago", inSessionAt: file, tailBudget: budget) == nil)
        #expect(PaletteContentSearch.snippet(for: "armadillo", inSessionAt: file, tailBudget: budget) == nil)
        #expect(PaletteContentSearch.snippet(for: "armadillo", inSessionAt: file) == "an armadillo from long ago")
    }

    private func jsonString(_ text: String) throws -> String {
        String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
    }
}
