import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Tool rows")
struct ToolRowTests {
    private func row(_ name: String, _ args: String? = nil, output: String = "", error: Bool = false, status: String = "complete") -> NativeToolRow {
        NativeToolRow(Fixture.tool(name, args: args, output: output, error: error, status: status))
    }

    private static let lines160 = Array(repeating: "x", count: 160).joined(separator: "\n")

    @Test func readShowsThePathItsLineRangeAndLineCount() {
        let read = row("read", #"{"path":"Sources/A.swift","offset":237,"limit":160}"#, output: Self.lines160)
        #expect(read.preview == "Sources/A.swift" && read.previewSuffix == ":237–396")
        #expect(read.results == [.init("160 lines", tone: .muted)])
        #expect(read.accessibilityLabel == "read, Sources/A.swift:237–396, 160 lines, done")
    }

    @Test func readWithAnOffsetButNoLimitShowsAnOpenRange() {
        #expect(row("read", #"{"path":"a","offset":10}"#, output: "x").previewSuffix == ":10–")
    }

    @Test func aSingleLineReadIsSingular() {
        #expect(row("read", #"{"path":"a"}"#, output: "x").results.map(\.text) == ["1 line"])
    }

    @Test func editCountsItsDiffAndBlocks() {
        let edit = row("edit", #"{"path":"App/View.swift","edits":[{"oldText":"a\nb\nc","newText":"a\nB"},{"oldText":"x","newText":"y"}]}"#)
        #expect(edit.preview == "App/View.swift")
        #expect(edit.diff == NativeDiffStat(added: 2, removed: 3, blocks: 2))
        #expect(edit.results.map(\.text) == ["2 blocks"])
        #expect(edit.reviewPath == "App/View.swift")
    }

    @Test func aSingleOldTextNewTextEditIsOneBlock() {
        let edit = row("edit", #"{"path":"a","oldText":"x","newText":"y"}"#)
        #expect(edit.diff == NativeDiffStat(added: 1, removed: 1, blocks: 1) && edit.results.map(\.text) == ["1 block"])
    }

    @Test func aFailedEditHasNoDiffAndNoReviewLink() {
        let edit = row("edit", #"{"path":"a","oldText":"x","newText":"y"}"#, output: "not found", error: true)
        #expect(edit.diff == nil && edit.reviewPath == nil)
        #expect(edit.results == [.init("failed", tone: .danger)] && edit.state == .failed)
    }

    @Test func writeLinksToReviewButReadDoesNot() {
        #expect(row("write", #"{"path":"new.swift","content":"x"}"#).reviewPath == "new.swift")
        #expect(row("read", #"{"path":"a.swift"}"#).reviewPath == nil)
    }

    static let bashResults: [(output: String, error: Bool, expected: [NativeToolRow.Result])] = [
        ("lots\n** BUILD SUCCEEDED **", false, [.init("BUILD SUCCEEDED", tone: .success)]),
        ("Test run with 3 tests in 1 suite passed after 0.1s\n12 tests passed", false, [.init("12 passed", tone: .success)]),
        ("4 checks passed", false, [.init("4 passed", tone: .success)]),
        (" 1 file changed, 2 insertions(+)", false, [.init("1 file changed", tone: .success)]),
        (" 3 files changed", false, [.init("3 files changed", tone: .success)]),
        ("a\nb", false, []),
        ("error: cannot find X\n\nCommand exited with code 2", true, [.init("exit 2", tone: .danger)]),
        ("killed", true, [.init("failed", tone: .danger)]),
    ]

    @Test(arguments: bashResults)
    func bashSummarizesItsOutcome(output: String, error: Bool, expected: [NativeToolRow.Result]) {
        #expect(row("bash", #"{"command":"make"}"#, output: output, error: error).results == expected)
    }

    @Test func bashPreviewIsTheFirstCommandLine() {
        #expect(row("bash", #"{"command":"xcodebuild -scheme X build\necho done"}"#).preview == "xcodebuild -scheme X build")
        #expect(row("powershell", #"{"command":"Get-ChildItem"}"#).preview == "Get-ChildItem")
    }

    @Test(arguments: ["running", "streaming"])
    func inFlightCallsAreRunningWithNoResultAndNoEndTime(_ status: String) {
        let running = NativeToolRow(Fixture.tool("bash", args: #"{"command":"sleep 5"}"#, status: status, timestamp: 99))
        #expect(running.state == .running && running.results.isEmpty && !running.expandable && running.endedAt == nil)
    }

    @Test func grepQuotesThePatternAndCountsMatches() {
        let grep = row("grep", #"{"pattern":"speakerLabel","path":"Sources/"}"#, output: "a:1\nb:2\nc:3")
        #expect(grep.preview == "\"speakerLabel\"" && grep.previewSuffix == " in Sources/")
        #expect(grep.results.map(\.text) == ["3 matches"])
        #expect(row("grep", #"{"pattern":"zzz"}"#, output: "No matches found").results.map(\.text) == ["0 matches"])
        #expect(row("grep", #"{"pattern":"z"}"#, output: "a:1").results.map(\.text) == ["1 match"])
        #expect(row("grep", #"{"pattern":"z"}"#).previewSuffix == " in .")
    }

    @Test(arguments: ["find", "glob"])
    func fileSearchesCountFiles(_ name: String) {
        let found = row(name, #"{"pattern":"*.swift","path":"Sources"}"#, output: "a.swift\nb.swift")
        #expect(found.preview == "*.swift" && found.previewSuffix == " in Sources" && found.results.map(\.text) == ["2 files"])
    }

    @Test func lsDefaultsToTheCurrentDirectory() {
        #expect(row("ls").preview == ".")
        #expect(row("ls", #"{"path":"src"}"#).preview == "src")
    }

    @Test func aChildsParentMessageShowsTheQuestionUnderAReadableName() {
        let ask = row("shepherd_parent_message", #"{"message":"Rename or replace?","needsReply":true}"#,
                      output: #"{"shepherdParentMessage":"Rename or replace?"}"#)
        #expect(ask.name == "to parent" && ask.preview == "Rename or replace?" && ask.results.map(\.text) == ["asked"])
        #expect(row("shepherd_parent_message", #"{"message":"FYI"}"#).results.isEmpty)
    }

    @Test func subagentCallsNameTheAgentNotTheLaunchBoilerplate() {
        let boiler = "Run fan-out: 0/32 used, 32 remaining\nAsync workflow [x]"
        #expect(row("subagent", #"{"agent":"delegate","task":"Say hello\nmore"}"#, output: boiler).preview == "delegate · Say hello")
        #expect(row("subagent", #"{"agent":"delegate"}"#, output: boiler).preview == "delegate")
        #expect(row("subagent", #"{"workflowScript":"return 1"}"#, output: boiler).preview == "workflow")
        #expect(row("subagent", #"{"action":"status"}"#, output: boiler).preview == "status")
    }

    @Test func unknownToolsPreferAnActionFieldThenTheFirstOutputLine() {
        #expect(row("web_fetch", #"{"url":"https://example.com"}"#, output: "<html>").preview == "https://example.com")
        #expect(row("custom", output: "\n  \nfirst useful line\nsecond").preview == "first useful line")
        #expect(row("custom", #"{"path":""}"#, output: "fallback").preview == "fallback", "empty fields don't count")
    }

    @Test func previewsCapAt120Characters() {
        #expect(row("custom", output: String(repeating: "y", count: 300)).preview.count == 120)
        #expect(row("read", #"{"path":"\#(String(repeating: "p", count: 200))"}"#).preview.count == 120)
    }

    @Test func aMessageWithoutAToolNameIsAResult() {
        let message = NativeThreadMessage(entryID: "e", role: "toolResult", blocks: [])
        #expect(NativeToolRow(message).name == "result")
    }

    @Test func outputJoinsTextBlocksAndMakesTheRowExpandable() {
        let message = NativeThreadMessage(entryID: "e", role: "toolResult", blocks: [
            NativeThreadBlock(kind: .text, text: "a"), NativeThreadBlock(kind: .thinking, text: "skip"), NativeThreadBlock(kind: .text, text: "b"),
        ], toolName: "custom", argumentsText: #"{"k":1}"#, truncated: true)
        let row = NativeToolRow(message)
        #expect(row.output == "a\nb" && row.expandable && row.truncated && row.arguments == #"{"k":1}"#)
    }

    @Test func accessibilityLabelIncludesTheDiffAndSkipsEmptyParts() {
        let edit = row("edit", #"{"path":"a","oldText":"x","newText":"y\nz"}"#)
        #expect(edit.accessibilityLabel == "edit, a, +2 \u{2212}1, 1 block, done")
        #expect(row("custom", status: "running").accessibilityLabel == "custom, running")
    }
}

@Suite("DiffStat")
struct DiffStatTests {
    @Test(arguments: [
        ([("a\nb", "b\na")], 0, 0, 1),
        ([("a", "a\nb\nc"), ("x\ny", "")], 2, 2, 2),
        ([("one\ntwo\nthree", "one\n2\nthree\nfour")], 2, 1, 1),
        ([("", "")], 0, 0, 1),
        ([("dup\ndup", "dup")], 0, 1, 1),
    ] as [([(String, String)], Int, Int, Int)])
    func countsLinesAsAMultisetDifference(edits: [(String, String)], added: Int, removed: Int, blocks: Int) {
        #expect(NativeDiffStat(edits: edits.map { (old: $0.0, new: $0.1) }) == NativeDiffStat(added: added, removed: removed, blocks: blocks))
    }

    @Test func diffTextUsesATrueMinusSign() {
        #expect(nativeDiffText(added: 58, removed: 41) == "+58 \u{2212}41")
    }
}
