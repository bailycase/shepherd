import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// A tool call's arguments as pi streams them (`toolcall_delta`): fragments of the JSON text,
/// cut anywhere, reduced to the few fields an activity line names.
@Suite("Streaming tool call arguments")
struct StreamingToolArgumentsTests {
    private static func read(_ fragments: [String]) -> [String: String] {
        var arguments = StreamingToolArguments()
        for fragment in fragments { _ = arguments.append(fragment) }
        return arguments.values
    }

    /// One JSON text, and the fields kept out of it.
    struct Case: Sendable, CustomTestStringConvertible {
        let what: String
        let json: String
        let kept: [String: String]
        var testDescription: String { what }

        init(_ what: String, _ json: String, _ kept: [String: String]) {
            self.what = what
            self.json = json
            self.kept = kept
        }
    }

    static let cases: [Case] = [
        Case("a write", #"{"path":"src/big.txt","content":"line one\nline two\nline three"}"#, ["path": "src/big.txt"]),
        Case("a call whose content comes first", #"{"content":"x\"y{[]}, \"path\": \"no\"","path":"a.swift"}"#, ["path": "a.swift"]),
        Case("fields inside a nested value", #"{"edits":[{"path":"nested.swift","oldText":"a"}],"path":"top.swift"}"#, ["path": "top.swift"]),
        Case("a bash command", #"{"command":"swift test --filter X","timeout":120}"#, ["command": "swift test --filter X"]),
        Case("a search", #"{"pattern":"TODO","path":"Sources","glob":"*.swift"}"#, ["pattern": "TODO", "path": "Sources"]),
        Case("escapes", #"{"command":"echo \"hi\" \\n \/ \u00e9 \ud83d\ude00 \t"}"#, ["command": "echo \"hi\" \\n / é 😀 \t"]),
        Case("values that are not strings", #"{"path":12,"command":null,"pattern":"x","query":true,"url":{"a":1}}"#, ["pattern": "x"]),
        Case("a field the line does not name", #"{"file_path":"a","content":"b"}"#, [:]),
        Case("whitespace between tokens", "{ \"path\" :\n \"a b\" ,\t\"command\" : \"c\" }", ["path": "a b", "command": "c"]),
        Case("a top-level array", #"["path","command"]"#, [:]),
        Case("no arguments", "{}", [:]),
        Case("nothing at all", "", [:]),
        Case("a repeated field", #"{"path":"first","path":"second"}"#, ["path": "second"]),
        Case("a value that never closes", #"{"path":"ok","command":"swift te"#, ["path": "ok", "command": "swift te"]),
        Case("a half-written escape", #"{"command":"a\"#, ["command": "a"]),
        Case("half of a unicode escape", #"{"path":"caf\u00"#, ["path": "caf"]),
        Case("half of a surrogate pair", #"{"path":"a\ud83d"#, ["path": "a"]),
        Case("a lone surrogate", #"{"path":"a\ude00b"}"#, ["path": "a\u{FFFD}b"]),
        Case("text where a value should be", #"{"path": src/big.txt, "command": "ls"}"#, ["command": "ls"]),
        Case("an object that never opens right", #"{path":"x","command":"ls"}"#, [:]),
    ]

    @Test(arguments: cases)
    func onlyTheNamedFieldsAreKept(_ c: Case) {
        #expect(Self.read([c.json]) == c.kept, "\(c.what)")
    }

    /// pi cuts the text wherever the provider did, so a split anywhere, and one character at a
    /// time, reads the same as the whole.
    @Test(arguments: cases)
    func theFragmentsCanBeCutAnywhere(_ c: Case) {
        let characters = Array(c.json)
        for cut in 0...characters.count {
            let fragments = [String(characters[..<cut]), String(characters[cut...])]
            #expect(Self.read(fragments) == c.kept, "\(c.what), cut at \(cut)")
        }
        #expect(Self.read(characters.map(String.init)) == c.kept, "\(c.what), a character at a time")
    }

    /// The row moves only when a kept field grew: a big write's content streams past unheld.
    @Test func aFragmentReportsAChangeOnlyWhenAKeptFieldGrew() {
        var arguments = StreamingToolArguments()
        func grew(_ fragment: String) -> Bool { arguments.append(fragment) }
        #expect(!grew(""))
        #expect(!grew(#"{"pa"#))
        #expect(grew(#"th":"src/"#))
        #expect(grew(#"big.txt"#))
        #expect(!grew(#"","content":"#))
        #expect(!grew(#""line one\nline two"#))
        #expect(!grew(String(repeating: "x", count: 100_000)))
        #expect(!grew(#"","command":"#))
        #expect(grew(#""ls"#))
        #expect(arguments.values == ["path": "src/big.txt", "command": "ls"])
    }

    @Test func aFieldStopsGrowingAtItsCap() {
        var arguments = StreamingToolArguments()
        func grew(_ fragment: String) -> Bool { arguments.append(fragment) }
        _ = grew(#"{"command":""#)
        #expect(grew(String(repeating: "é", count: StreamingToolArguments.fieldBytes)))
        #expect(arguments.values["command"]?.utf8.count == StreamingToolArguments.fieldBytes)
        #expect(!grew("more"), "nothing more is kept, so the row stops changing")
        _ = grew(#"","path":"a"}"#)
        #expect(arguments.values["path"] == "a", "the fields after it are still read")
    }

    @Test func theKeptFieldsAreTheCallsArguments() {
        var arguments = StreamingToolArguments()
        #expect(arguments.arguments == nil)
        _ = arguments.append(#"{"path":"a.swift","content":"b"}"#)
        #expect(arguments.arguments == .object(["path": .string("a.swift")]))
    }

    @Test func aFinishedCallKeepsTheSameFields() {
        let complete = JSONValue.object(["path": .string("a.swift"), "content": .string("body"), "command": .string(""), "timeout": .number(3)])
        #expect(StreamingToolArguments.named(in: complete) == .object(["path": .string("a.swift")]))
        #expect(StreamingToolArguments.named(in: .object(["content": .string("body")])) == nil)
        #expect(StreamingToolArguments.named(in: .string("x")) == nil)
        let long = JSONValue.object(["command": .string(String(repeating: "é", count: StreamingToolArguments.fieldBytes))])
        #expect(StreamingToolArguments.named(in: long)?["command"]?.stringValue?.utf8.count == StreamingToolArguments.fieldBytes)
    }
}
