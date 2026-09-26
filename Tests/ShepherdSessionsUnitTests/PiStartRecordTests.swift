import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdSessions

/// How a pi that stopped before it served is read (DESIGN.md › Thread › Can't start): pi's own
/// stderr lines, as chalk colours them, and its exit code, to a cause.
@Suite("pi start records")
struct PiStartRecordTests {
    static let red = "\u{1B}[31m", yellow = "\u{1B}[33m", reset = "\u{1B}[39m"

    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let stderr: [String]
        let exitCode: Int32?
        let kind: NativeStartProblem.Kind
        var testDescription: String { name }
    }

    static let cases: [Case] = [
        Case(name: "not signed in", stderr: [
            "\(red)No models available. Use /login to log into a provider via OAuth or API key. See:",
            "  /pi/docs/providers.md",
            "  /pi/docs/models.md\(reset)",
        ], exitCode: 1, kind: .notSignedIn),
        Case(name: "no key for the chosen model", stderr: ["\(red)No API key found for anthropic.\(reset)"], exitCode: 1, kind: .notSignedIn),
        Case(name: "an extension failed to load", stderr: [
            "\(red)Error: Failed to load extension \"/x/broken.ts\": SyntaxError: Unexpected token\(reset)",
            "\(yellow)Hint: Start without extensions using \"pi -ne\".\(reset)",
        ], exitCode: 1, kind: .extensionFailed),
        Case(name: "an extension failure wins over no model", stderr: [
            "Error: Failed to load extension \"/x/broken.ts\": boom", "No models available.",
        ], exitCode: 1, kind: .extensionFailed),
        Case(name: "pi not on PATH", stderr: ["zsh:1: command not found: pi"], exitCode: 127, kind: .engineMissing),
        Case(name: "an engine that isn't there", stderr: ["zsh:1: no such file or directory: /Apps/pi-engine"], exitCode: 127, kind: .engineMissing),
        Case(name: "an engine it may not run", stderr: ["zsh:1: permission denied: /Apps/pi-engine"], exitCode: 126, kind: .engineMissing),
        Case(name: "anything else", stderr: ["TypeError: cannot read properties of undefined"], exitCode: 1, kind: .exited),
        Case(name: "a signal", stderr: [], exitCode: nil, kind: .exited),
    ]

    @Test(arguments: cases)
    func stderrAndTheExitNameTheCause(_ c: Case) {
        var record = PiStartRecord()
        for line in c.stderr { _ = record.note(stderr: line) }
        let problem = record.problem(exitCode: c.exitCode)
        #expect(problem?.kind == c.kind)
        #expect(problem?.exitCode == c.exitCode)
        #expect(problem?.lines.allSatisfy { !$0.contains("\u{1B}") && !$0.isEmpty } == true)
        #expect(record.keepsAgent)
    }

    @Test func aProblemCarriesOnlyTheNewestLines() {
        var record = PiStartRecord()
        for n in 1...(PiStartRecord.keptLines + 5) { _ = record.note(stderr: "line \(n)") }
        #expect(record.lines.count == PiStartRecord.keptLines)
        let problem = record.problem(exitCode: 1)
        #expect(problem?.lines == (PiStartRecord.keptLines + 6 - NativeStartProblem.maxLines...PiStartRecord.keptLines + 5).map { "line \($0)" })
    }

    @Test(arguments: [
        ("\u{1B}[31mError\u{1B}[39m", "Error"),
        ("\u{1B}[1;38;5;196mbold\u{1B}[0m text", "bold text"),
        ("\u{1B}]8;;https://pi.dev\u{07}link\u{1B}]8;;\u{1B}\\", "link"),
        ("progress\r", "progress"),
        ("  indented  ", "indented"),
        ("", ""),
    ])
    func escapesAreRemoved(_ raw: String, _ plain: String) {
        #expect(PiStartRecord.plain(raw) == plain)
    }

    /// Once pi serves, its exit is a lost connection and its stderr is no longer kept.
    @Test func aPiThatServedLetsItsAgentRetire() {
        var record = PiStartRecord()
        _ = record.note(stderr: "starting")
        record.served()
        _ = record.note(stderr: "later")
        #expect(!record.keepsAgent && record.lines.isEmpty)
    }

    static let warning = "\u{1B}[33mWarning: No project session found with id 'abc-123'; creating a new session with that id.\u{1B}[39m"

    /// pi's warning for the id it was launched to resume stops it, before or after it serves (its
    /// stderr and stdout race); another id's, or a fresh pi's, does not.
    @Test(arguments: [(true, false), (true, true), (false, false)])
    func aResumedPiStartingANewConversationIsStopped(resuming: Bool, servedFirst: Bool) {
        var record = PiStartRecord(resuming: resuming ? "abc-123" : nil)
        if servedFirst { record.served() }
        let stops = record.note(stderr: Self.warning)
        #expect(stops == resuming)
        #expect(record.keepsAgent == (resuming || !servedFirst))
        if resuming {
            let problem = record.problem(exitCode: 143)
            #expect(problem?.kind == .resumedAsNew && problem?.exitCode == nil)
            #expect(problem?.lines == ["Warning: No project session found with id 'abc-123'; creating a new session with that id."])
            let again = record.note(stderr: Self.warning)
            #expect(!again, "it stops pi once")
        }
    }

    @Test func anotherSessionsWarningIsNotThisOnes() {
        var record = PiStartRecord(resuming: "other")
        let stops = record.note(stderr: Self.warning)
        #expect(!stops)
        #expect(record.problem(exitCode: 1)?.kind == .exited)
    }

    /// A stop Shepherd asks for keeps the agent, served or not, with nothing to report.
    @Test(arguments: [false, true])
    func aRequestedStopKeepsTheAgentWithoutAProblem(served: Bool) {
        var record = PiStartRecord()
        if served { record.served() }
        record.requestStop()
        #expect(record.keepsAgent)
        #expect(record.problem(exitCode: nil) == nil)
    }
}
