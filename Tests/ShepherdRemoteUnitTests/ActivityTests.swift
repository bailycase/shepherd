import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Tool calls as activity lines: classification, merging, words, and the changes card.
@Suite("Activity lines")
struct ActivityTests {
    typealias F = Fixture

    private static func json(_ object: [String: Any]) -> String {
        String(data: try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), encoding: .utf8)!
    }

    private func call(_ name: String, _ args: [String: Any] = [:], output: String = "", error: Bool = false, status: String = "complete",
                      id: String = UUID().uuidString, start: Double? = nil, end: Double? = nil) -> NativeActivityCall {
        NativeActivityCall(F.tool(name, args: Self.json(args), output: output, error: error, status: status, id: "e-\(id)", callID: id,
                                  startedAt: start, timestamp: end))
    }

    private func bash(_ command: String, output: String = "", error: Bool = false, start: Double? = nil, end: Double? = nil) -> NativeActivityCall {
        call("bash", ["command": command], output: output, error: error, start: start, end: end)
    }

    private func edit(_ path: String, added: Int, removed: Int) -> NativeActivityCall {
        let old = (0..<removed).map { "old \($0)" }.joined(separator: "\n"), new = (0..<added).map { "new \($0)" }.joined(separator: "\n")
        return call("edit", ["path": path, "edits": [["oldText": old, "newText": new]]])
    }

    // MARK: Commands

    @Test(arguments: [
        ("swift test --filter ToolPreview", [NativeCommandClass.tests]),
        ("cd Sources && swift build && swift test 2>&1 | tail -20", [.tests]),
        ("xcodebuild -scheme 'Shepherd (Dev)' -destination 'platform=macOS' build", [.build]),
        ("xcodebuild test -scheme App", [.tests]),
        ("git add -A && git commit -m 'Fix; it' && git push origin main", [.commit, .push]),
        ("git -C repo push", [.push]),
        ("npm run build", [.build]),
        ("pnpm test", [.tests]),
        ("FOO=1 nice -n 10 go test ./...", [.tests]),
        ("python3 -m pytest -q", [.tests]),
        ("cargo build --release", [.build]),
        ("make", [.build]),
        ("ls -la && cat Package.swift", [.other]),
        ("git status", [.other]),
    ] as [(String, [NativeCommandClass])])
    func commandsAreClassifiedByWhatTheyRun(command: String, classes: [NativeCommandClass]) {
        #expect(nativeCommandClasses(command) == classes)
    }

    @Test(arguments: [
        ("swift test --filter X", "swift test"),
        ("cd a && xcodebuild -scheme S build | xcpretty", "xcodebuild"),
        ("git push origin main", "git push"),
        ("npm run build -- --prod", "npm run build"),
        ("python -m pytest tests/", "python -m pytest"),
        ("ls -la", "ls"),
    ])
    func aCommandsHeadNamesTheToolThatDecidedIt(command: String, head: String) {
        #expect(nativeCommandHead(command) == head)
    }

    @Test(arguments: [
        ("✔ Test run with 17 tests in 4 suites passed after 3.1 seconds.", 17, nil),
        ("✘ Test a() failed after 0.1 seconds with 1 issue.\n✘ Test b() failed after 0.1 seconds with 1 issue.\n✘ Test run with 20 tests in 3 suites failed after 8.4 seconds with 2 issues.", 18, 2),
        ("Executed 12 tests, with 0 failures (0 unexpected) in 0.5 seconds\nExecuted 30 tests, with 2 failures (0 unexpected) in 1.0 seconds", 28, 2),
        ("===== 3 failed, 17 passed in 1.2s =====", 17, 3),
        ("Tests:       1 failed, 9 passed, 10 total", 9, 1),
        ("test result: ok. 17 passed; 0 failed; 0 ignored", 17, nil),
        ("nothing to see", nil, nil),
    ] as [(String, Int?, Int?)])
    func testCountsComeFromTheRunnersSummary(output: String, passed: Int?, failed: Int?) {
        let counts = nativeTestCounts(output)
        #expect(counts.passed == passed && counts.failed == failed)
    }

    @Test func aLongLogIsSummarisedFromItsTailEvenWhenTheCutSplitsACharacter() {
        let lines = String(repeating: "✔ Test passed\n", count: 6_000)
        #expect(lines.utf8.count > 64 * 1024)
        let counts = nativeTestCounts("x" + lines + "✔ Test run with 6000 tests in 9 suites passed after 3.1 seconds.")
        #expect(counts.passed == 6_000 && counts.failed == nil)
    }

    // MARK: Calls

    @Test func aCallIsIdentifiedByItsCallIDSoTheLiveAndSavedCopiesMatch() {
        let live = NativeActivityCall(F.tool("bash", status: "running", id: "provisional:tool:c1", callID: "c1"))
        let saved = NativeActivityCall(F.tool("bash", id: "entry-9", callID: "c1"))
        #expect(live.id == saved.id)
    }

    @Test func callsCarryTheirKindColumnDetailAndStat() {
        let read = call("read", ["path": "Sources/A.swift"], output: "a\nb\nc")
        #expect((read.kind, read.explore, read.label, read.detail, read.isPath, read.stat) == (.explore, .read, "read", "Sources/A.swift", true, "3 lines"))
        let grep = call("grep", ["pattern": "label", "path": "Sources/"], output: "x\ny")
        #expect((grep.explore, grep.detail, grep.stat) == (.search, "\"label\" in Sources/", "2 matches"))
        let edited = edit("App/View.swift", added: 58, removed: 41)
        #expect((edited.kind, edited.path, edited.stat) == (.edit, "App/View.swift", "+58 \u{2212}41"))
        let written = call("write", ["path": "New.swift", "content": "a\nb\nc\n"])
        #expect((written.added, written.removed) == (3, 0))
    }

    @Test func aRunningCallKeepsItsLastThreeOutputLines() {
        let running = call("bash", ["command": "git push"], output: "one\ntwo\n\nthree\nfour\n", status: "running")
        #expect(running.running && running.tail == ["two", "three", "four"])
        #expect(running.outputHead.isEmpty)
    }

    @Test func aFinishedCallExpandsToItsFirstTwelveLines() {
        let output = (1...40).map(String.init).joined(separator: "\n")
        let done = bash("ls", output: output)
        #expect(done.outputHead == (1...12).map(String.init) && done.outputLineCount == 40 && done.expandable)
    }

    @Test(arguments: [
        ("✔ Test run with 17 tests in 4 suites passed after 3.1 seconds.", false, "17 passed"),
        ("✘ Test a() failed after 0.1 seconds with 1 issue.\n✘ Test run with 5 tests failed after 1 seconds with 1 issue.\nCommand exited with code 1", true, "1 failed"),
        ("error: build failed\nCommand exited with code 65", true, "exit 65"),
        ("killed", true, "failed"),
    ] as [(String, Bool, String)])
    func testRunsStateTheirOutcome(output: String, error: Bool, stat: String) {
        #expect(bash("swift test", output: output, error: error).stat == stat)
    }

    @Test func failingTestsFailTheCallEvenWhenAPipeHidTheExitCode() {
        let piped = bash("swift test 2>&1 | tail -5", output: "✘ Test a() failed after 1 seconds with 1 issue.\n✘ Test run with 4 tests failed after 2 seconds with 1 issue.")
        #expect(piped.failed && piped.stat == "1 failed")
    }

    @Test func buildsAndCommitsStateTheirOutcome() {
        #expect(bash("xcodebuild build", output: "** BUILD SUCCEEDED **").stat == "build ok")
        #expect(bash("git commit -m x", output: "[main 1a2b] x\n 3 files changed, 5 insertions(+)").stat == "3 files changed")
    }

    // MARK: Bursts

    @Test func consecutiveCallsOfOneKindMergeIntoOneLine() {
        let bursts = nativeActivityBursts([call("read", ["path": "a"]), call("grep", ["pattern": "x"]), call("ls"),
                                           edit("a", added: 1, removed: 0), edit("b", added: 2, removed: 1),
                                           bash("swift test"), bash("swift build")])
        #expect(bursts.map(\.kind) == [.explore, .edit, .run])
        #expect(bursts.map(\.calls.count) == [3, 2, 2])
    }

    @Test func otherToolsMergeOnlyWithTheSameTool() {
        let bursts = nativeActivityBursts([call("web_fetch", ["url": "a"]), call("web_fetch", ["url": "b"]), call("notify", ["message": "hi"])])
        #expect(bursts.map(\.calls.count) == [2, 1])
        #expect(bursts.map(\.label) == ["Used web_fetch 2 times", "Used notify"])
    }

    @Test func aFailedCallStandsAloneAndEndsTheBurst() {
        let bursts = nativeActivityBursts([bash("swift test"), bash("swift test", output: "Command exited with code 1", error: true),
                                           bash("swift test", output: "Command exited with code 1", error: true), bash("swift build")])
        #expect(bursts.map(\.state) == [.done, .failed, .failed, .done])
    }

    /// A call the user's Stop interrupted (the host's `aborted`) reads as stopped, not failed,
    /// and stands alone so its word stays visible.
    @Test func aStoppedCallReadsStoppedNotFailed() {
        let stopped = call("bash", ["command": "sleep 40"], output: "Command aborted", error: true, status: "aborted", start: 1_000, end: 8_500)
        #expect(!stopped.failed && stopped.stopped && stopped.stat == "stopped")
        let bursts = nativeActivityBursts([bash("ls"), stopped])
        #expect(bursts.map(\.state) == [.done, .done])
        #expect(bursts.map(\.calls.count) == [1, 1])
        #expect((bursts[1].label, bursts[1].meta) == ("Ran a command", "sleep 40 · stopped · 7.5s"))
        #expect(bursts[1].accessibilityLabel.hasSuffix("stopped"))
    }

    /// A stopped build or edit claims nothing it may not have done.
    @Test func aStoppedCallClaimsNoResult() {
        let build = call("bash", ["command": "swift build"], output: "Command aborted", error: true, status: "aborted")
        #expect(build.stat == "stopped")
        let write = call("write", ["path": "a.swift", "content": "x\n"], error: true, status: "aborted")
        #expect(write.path == nil && nativeActivityBurst([write]).label == "Write stopped")
        #expect(nativeTurnChanges([write]) == nil)
    }

    @Test func onlyTheRunningCallIsLiveAndItNamesItsCommand() {
        let bursts = nativeActivityBursts([bash("git commit -m x"), call("bash", ["command": "git push origin main"], output: "a\nb", status: "running", start: 1_000)])
        #expect(bursts.map(\.state) == [.done, .running])
        let live = bursts[1]
        #expect((live.label, live.meta, live.startedAt, live.tail) == ("Pushing", "git push origin main", 1_000, ["a", "b"]))
        #expect(!live.expandable)
    }

    @Test(arguments: [
        ("swift test", "Running tests"), ("xcodebuild build", "Building"), ("git commit -m x", "Committing"),
        ("git push", "Pushing"), ("ls", "Running"),
    ])
    func liveCommandsTakeAProgressiveVerb(command: String, label: String) {
        #expect(nativeActivityBurst([call("bash", ["command": command], status: "running")]).label == label)
    }

    @Test func anExploreLineCountsFilesAndSearchesWithItsWallTime() {
        let reads = (0..<5).map { call("read", ["path": "f\($0)"], start: 1_000 + Double($0) * 100, end: 1_050 + Double($0) * 100) }
        let searches = [call("grep", ["pattern": "a"], start: 1_600, end: 1_700), call("find", ["pattern": "*.swift"], start: 1_800, end: 1_900)]
        let burst = nativeActivityBurst(reads + searches)
        #expect(burst.label == "Explored 7 files" && burst.meta == "read 5 · search 2 · 0.9s")
        #expect(burst.accessibilityLabel == "Explored 7 files, read 5, search 2, 0.9s, done")
    }

    @Test func rereadingAFileCountsItOnce() {
        #expect(nativeActivityBurst([call("read", ["path": "a"]), call("read", ["path": "a"])]).label == "Explored 1 file")
    }

    @Test func anEditLineCountsDistinctFilesAndSumsTheirDiffs() {
        let burst = nativeActivityBurst([edit("a", added: 58, removed: 41), edit("b", added: 12, removed: 4), edit("a", added: 79, removed: 18)])
        #expect(burst.label == "Edited 2 files" && burst.meta == "+149 \u{2212}63")
    }

    @Test func aRunLineComposesItsCommandsAndOutcomes() {
        let tests = bash("swift test", output: "✔ Test run with 17 tests passed after 1 seconds.", start: 0, end: 20_000)
        let build = bash("xcodebuild build", output: "** BUILD SUCCEEDED **", start: 20_000, end: 62_000)
        let burst = nativeActivityBurst([tests, build])
        #expect(burst.label == "Ran tests and a build" && burst.meta == "17 passed · build ok · 1m 02s")
        #expect(nativeActivityBurst([bash("git commit -m x", output: " 3 files changed"), bash("git push")]).label == "Committed and pushed")
        #expect(nativeActivityBurst([bash("git status"), bash("git diff")]).label == "Ran 2 commands")
        #expect(nativeActivityBurst([bash("git status")]).meta == "git status")
    }

    @Test func instantWorkShowsNoDuration() {
        #expect(nativeActivityBurst([bash("git commit -m x", output: " 3 files changed", start: 0, end: 400)]).meta == "3 files changed")
    }

    @Test func aFailedRunNamesItsCommandAndWhyItFailed() {
        let failed = nativeActivityBurst([bash("swift test --filter X", output: "Command exited with code 1", error: true, start: 0, end: 8_400)])
        #expect(failed.state == .failed && failed.label == "Ran tests" && failed.meta == "swift test · exit 1 · 8.4s")
        let counted = nativeActivityBurst([bash("swift test", output: "✘ Test a() failed after 1 seconds with 1 issue.\n✘ Test b() failed after 1 seconds with 1 issue.\n✘ Test c() failed after 1 seconds with 1 issue.\n✘ Test run with 9 tests failed after 2 seconds with 3 issues.", error: true)])
        #expect(counted.meta == "swift test · 3 failed")
        #expect(nativeActivityBurst([bash("git push", error: true)]).label == "Push failed")
    }

    @Test func aFailedEditSaysSoAndNamesItsFile() {
        let failed = nativeActivityBurst([call("edit", ["path": "Sources/A.swift", "oldText": "x", "newText": "y"], output: "Could not find the text", error: true)])
        #expect(failed.label == "Edit failed" && failed.meta == "A.swift · Could not find the text")
    }

    @Test func spawnsWithoutCardsReadAsStartedSubagents() {
        let burst = nativeActivityBurst([call("subagent", ["agent": "reviewer", "task": "check"]), call("subagent", ["agent": "tests", "task": "run"])])
        #expect(burst.kind == .subagents && burst.label == "Started 2 subagents" && burst.meta == "reviewer · tests")
    }

    // MARK: Work groups

    @Test func twoOrMoreLinesFoldIntoOneSummaryOfWhatTheStretchDid() throws {
        let group = try #require(nativeWorkGroup([
            call("read", ["path": "a"], start: 1_000, end: 1_100), call("read", ["path": "b"]), call("grep", ["pattern": "x"]),
            edit("a", added: 3, removed: 1),
            bash("swift test", output: "✔ Test run with 17 tests passed after 1 seconds.", start: 2_000, end: 20_000), bash("git status", end: 63_000),
        ]))
        #expect(group.finished.map(\.kind) == [.explore, .edit, .run] && group.running.isEmpty)
        let summary = try #require(group.summary)
        #expect(summary.label == "Worked for 1m 02s")
        #expect(summary.meta == "explored 3 files · edited 1 file · ran 2 commands · 17 tests passed")
        #expect(!summary.failed)
        #expect(summary.accessibilityLabel == "Worked for 1m 02s, explored 3 files, edited 1 file, ran 2 commands, 17 tests passed, done")
    }

    @Test func oneLineStaysItself() throws {
        let group = try #require(nativeWorkGroup([call("read", ["path": "a"]), call("read", ["path": "b"])]))
        #expect(group.summary == nil && group.finished.count == 1)
        #expect(nativeWorkGroup([]) == nil)
    }

    @Test func failuresAreCountedAndTurnTheSummaryRedOnlyWhenTheWorkEndedOnOne() throws {
        let failing = { bash("ssh host uptime", output: "Command exited with code 255", error: true) }
        let recovered = try #require(nativeWorkGroup([call("read", ["path": "a"]), failing(), failing(), bash("ssh host -v uptime")])?.summary)
        #expect(!recovered.failed && recovered.meta == "explored 1 file · ran 3 commands · 2 failed")
        let ended = try #require(nativeWorkGroup([call("read", ["path": "a"]), bash("ls"), failing()])?.summary)
        #expect(ended.failed && ended.accessibilityLabel.hasSuffix("1 failed, failed"))
    }

    @Test func runningCallsStandBelowTheSummaryWhichNeverFailsWhileTheyRun() throws {
        let group = try #require(nativeWorkGroup([
            call("read", ["path": "a"]), edit("a", added: 1, removed: 0), bash("ls", output: "Command exited with code 1", error: true),
            call("bash", ["command": "git push"], status: "running", start: 1_000),
        ]))
        #expect(group.isLive && group.running.map(\.label) == ["Pushing"])
        let summary = try #require(group.summary)
        #expect(!summary.failed && summary.meta.hasSuffix("1 failed"))
    }

    @Test(arguments: [
        (["ask_user", "ask_user"], "used ask_user 2 times"),
        (["ask_user"], "used ask_user"),
        (["ask_user", "review_diff", "ask_user"], "used 2 tools"),
    ])
    func otherToolsReadByName(names: [String], words: String) throws {
        let summary = try #require(nativeWorkGroup([call("read", ["path": "a"])] + names.map { call($0) })?.summary)
        #expect(summary.meta == "explored 1 file · " + words)
    }

    @Test func theSummaryNamesKindsInOneOrderWhateverOrderTheWorkTook() throws {
        let summary = try #require(nativeWorkGroup([call("ask_user"), bash("ls"), edit("a", added: 1, removed: 0), call("read", ["path": "a"])])?.summary)
        #expect(summary.meta == "explored 1 file · edited 1 file · ran 1 command · used ask_user")
    }

    @Test func untimedWorkSaysOnlyThatItWorked() throws {
        #expect(try #require(nativeWorkGroup([call("read", ["path": "a"]), bash("ls")])?.summary).label == "Worked")
    }

    // MARK: Changes card

    @Test func theChangesCardSumsEachFileInFirstTouchedOrder() throws {
        let calls = [call("read", ["path": "Sources/A.swift"]), edit("Sources/A.swift", added: 58, removed: 41),
                     call("write", ["path": "Tests/New.swift", "content": "a\nb"]), edit("B.swift", added: 1, removed: 1),
                     edit("Sources/A.swift", added: 2, removed: 0),
                     call("edit", ["path": "C.swift", "oldText": "a", "newText": "b"], error: true)]
        let changes = try #require(nativeTurnChanges(calls))
        #expect(changes.files.map(\.path) == ["Sources/A.swift", "Tests/New.swift", "B.swift"])
        #expect(changes.files.map(\.status) == [.modified, .added, .modified])
        #expect(changes.files.map(\.added) == [60, 2, 1] && changes.added == 63 && changes.removed == 42)
        #expect(changes.title == "3 files changed")
        #expect((changes.files[0].directory, changes.files[0].name) == ("Sources/", "A.swift"))
        #expect((changes.files[2].directory, changes.files[2].name) == ("", "B.swift"))
    }

    @Test func aWriteOverAFileTheTurnReadIsAModification() throws {
        let changes = try #require(nativeTurnChanges([call("read", ["path": "a"]), call("write", ["path": "a", "content": "x"])]))
        #expect(changes.files.map(\.status) == [.modified])
    }

    @Test func aTurnThatEditedNothingHasNoChangesCard() {
        #expect(nativeTurnChanges([call("read", ["path": "a"]), bash("ls")]) == nil)
    }

    @Test(arguments: [(0, "0 files"), (1, "1 file"), (7, "7 files")])
    func countsUseTheirPluralForm(count: Int, text: String) {
        #expect(nativeCount(count, "file") == text)
        #expect(nativeCount(2, "match", "matches") == "2 matches")
    }
}

/// A turn as the thread draws it: items in order, thinking folded per stretch, cards, errors.
@Suite("Turn presentation")
struct TurnPresentationTests {
    typealias F = Fixture

    private func tool(_ name: String, _ callID: String, status: String = "complete", error: Bool = false) -> NativeThreadMessage {
        F.tool(name, args: #"{"path":"\#(callID).swift","command":"ls"}"#, error: error, status: status, id: "e-\(callID)", callID: callID)
    }

    private func kinds(_ presentation: NativeTurnPresentation) -> [String] {
        presentation.items.map { item in
            switch item {
            case .thinking(_, _, _, let live, _): live ? "live-thinking" : "thinking"
            case .prose: "prose"
            case .work(let group): "work:" + (group.finished + group.running).map { "\($0.calls.count)" }.joined(separator: "+")
            case .subagents(_, let ids, let all): all ? "cards:all" : "cards:\(ids.joined(separator: ","))"
            case .note: "note"
            case .error(_, _, _, let final): final ? "error:final" : "error"
            case .steer(_, let text, _, _): "steer:" + text
            }
        }
    }

    @Test func proseSplitsActivityAndThinkingFoldsIntoItsStretch() {
        let messages = [
            F.assistant("Looking.", thinking: "plan"),
            tool("read", "r1"), F.assistant("", thinking: "next"), tool("read", "r2"), F.assistant("", thinking: "then"), tool("edit", "e1"),
            F.assistant("Done."),
        ]
        let presentation = nativeTurnPresentation(messages, live: false)
        #expect(kinds(presentation) == ["thinking", "prose", "thinking", "work:2+1", "prose"])
        guard case .thinking(_, let text, _, _, _) = presentation.items[2] else { Issue.record("no folded thinking"); return }
        #expect(text == "next\n\nthen")
    }

    /// A steer is drawn where pi read it, splitting the work before it from the work after, and
    /// it is not the turn's prose (Copy leaves it out).
    @Test func aSteerSitsBetweenTheWorkBeforeAndAfterIt() {
        var steer = F.user("use tables", id: "s")
        steer.origin = .steered
        steer.timestamp = 7
        steer.blocks.append(NativeThreadBlock(kind: .unsupportedImage, text: ""))
        let presentation = nativeTurnPresentation([tool("read", "r1"), steer, F.assistant("Switching."), tool("edit", "e1")], live: false)
        #expect(kinds(presentation) == ["work:1", "steer:use tables", "prose", "work:1"])
        #expect(presentation.copyText == "Switching." && presentation.toolCalls == 2)
        guard case .steer(_, _, let sentAt, let images) = presentation.items[1] else { Issue.record("no steer"); return }
        #expect(sentAt == 7 && images == 1)
    }

    @Test func foldedThinkingSumsEachMessagesSecondsOnce() {
        var first = F.assistant("", thinking: "a")
        first.thinkingSeconds = 3
        var second = F.assistant("", thinking: "b")
        second.thinkingSeconds = 1.5
        let presentation = nativeTurnPresentation([first, tool("read", "r"), second, tool("read", "s")], live: false)
        guard case .thinking(_, _, let seconds, _, _) = presentation.items.first else { Issue.record("no thinking"); return }
        #expect(seconds == 4.5)
    }

    /// A turn the user stopped says so quietly: a note, never an error with Retry.
    @Test func aStoppedTurnEndsInAQuietNote() {
        let messages = [F.assistant("Sleeping."), tool("bash", "b", status: "aborted", error: true),
                        F.assistant("", status: "aborted")]
        let presentation = nativeTurnPresentation(messages, live: false)
        #expect(kinds(presentation) == ["prose", "work:1", "note"])
        guard case .note(_, let text) = presentation.items.last else { Issue.record("no note"); return }
        #expect(text == "Stopped")
    }

    /// pi's reply to a Stop carries no text, and still ends the turn it stopped.
    @Test func aStoppedReplyWithNothingToReadStaysInItsTurn() throws {
        let turns = nativeTurns([F.user("go"), tool("bash", "b", status: "aborted", error: true), F.assistant("", status: "aborted")])
        #expect(turns.map(\.messages.count) == [1, 2])
    }

    @Test func theThinkingStillStreamingStaysLastAndLive() {
        var streaming = F.assistant("", thinking: "hmm", status: "streaming")
        streaming.timestamp = 5_000
        let presentation = nativeTurnPresentation([F.assistant("Going."), tool("read", "r"), streaming], live: true)
        #expect(kinds(presentation) == ["prose", "work:1", "live-thinking"])
        #expect(presentation.endsInLiveThinking)
        guard case .thinking(_, _, _, _, let since) = presentation.items.last else { return }
        #expect(since == 5_000)
    }

    @Test func aRunningCallEndsTheLiveTurn() {
        let presentation = nativeTurnPresentation([tool("read", "r"), tool("bash", "b", status: "running")], live: true)
        #expect(presentation.endsInLiveActivity && presentation.changes == nil)
    }

    @Test func cardsTakeTheirSpawnCallsPlaceAndBookkeepingCallsHide() {
        let messages = [tool("read", "r"), tool("shepherd_child_start", "s1"), tool("shepherd_child_wait", "w"), tool("shepherd_child_start", "s2")]
        let separate = nativeTurnPresentation(messages, live: false, cards: NativeCardLayout(callIDs: ["s1", "s2"], folds: false))
        #expect(kinds(separate) == ["work:1", "cards:s1", "cards:s2"])
        #expect(separate.toolCalls == 2, "spawn calls a card replaced are not counted")
        let folded = nativeTurnPresentation(messages, live: false, cards: NativeCardLayout(callIDs: ["s1", "s2"], folds: true))
        #expect(kinds(folded) == ["work:1", "cards:all"])
    }

    @Test func spawnsAfterAFoldedStackLeaveTheWorkAroundThemWhole() {
        let messages = [tool("read", "r1"), tool("shepherd_child_start", "s1"), tool("read", "r2"), tool("shepherd_child_start", "s2"), tool("read", "r3")]
        let folded = nativeTurnPresentation(messages, live: false, cards: NativeCardLayout(callIDs: ["s1", "s2"], folds: true))
        #expect(kinds(folded) == ["work:1", "cards:all", "work:2"])
    }

    @Test func aCardLayoutFoldsPastTheStripThresholdOrOnceEveryRunFinished() {
        let live = (0..<2).map { F.run("r\($0)", toolCallID: "s\($0)") }
        #expect(NativeCardLayout(NativeSubagentPlacement(byToolCall: ["s0": [live[0]], "s1": [live[1]]])).folds == false)
        let done = (0..<2).map { F.run("d\($0)", state: "complete", toolCallID: "s\($0)") }
        #expect(NativeCardLayout(NativeSubagentPlacement(byToolCall: ["s0": [done[0]], "s1": [done[1]]])) == NativeCardLayout(callIDs: ["s0", "s1"], folds: true))
        #expect(NativeCardLayout(nil) == .none)
    }

    @Test func anErrorThatEndsAFinishedTurnOffersRetry() {
        let failed = { F.assistant("Model overloaded", status: "error") }
        let finished = nativeTurnPresentation([tool("read", "r"), failed(), failed()], live: false)
        #expect(kinds(finished) == ["work:1", "error:final"])
        guard case .error(_, let text, let count, _) = finished.items.last else { return }
        #expect(text == "Model overloaded" && count == 2)
        #expect(nativeTurnErrorText(text, toolCalls: finished.toolCalls) == "Model overloaded — the turn stopped after 1 tool call.")
        #expect(kinds(nativeTurnPresentation([failed(), F.assistant("Recovered.")], live: false)) == ["error", "prose"])
        #expect(kinds(nativeTurnPresentation([failed()], live: true)) == ["error"])
    }

    @Test func itemIDsAreStableAsTheTurnGrows() {
        let first = nativeTurnPresentation([F.assistant("One."), tool("read", "r")], live: true)
        let later = nativeTurnPresentation([F.assistant("One."), tool("read", "r"), tool("read", "s"), F.assistant("Two.")], live: false)
        #expect(later.items.prefix(2).map(\.id) == first.items.map(\.id))
    }

    @Test func theChangesCardAndCopyTextComeWithAFinishedTurn() {
        let edit = F.tool("edit", args: #"{"path":"a.swift","oldText":"x","newText":"y"}"#, callID: "e")
        let presentation = nativeTurnPresentation([F.assistant("First."), edit, F.assistant("Second.")], live: false)
        #expect(presentation.changes?.files.map(\.path) == ["a.swift"])
        #expect(presentation.copyText == "First.\n\nSecond.")
        #expect(presentation.toolCalls == 1)
    }

    @Test func proseIsParsedOnceIntoBlocks() {
        let presentation = nativeTurnPresentation([F.assistant("# Title\n\n- a\n- b")], live: false)
        guard case .prose(_, _, let blocks, _) = presentation.items.first else { Issue.record("no prose"); return }
        #expect(blocks.count == 2)
    }

    @Test(arguments: [(nil, "Thought"), (0.3, "Thought"), (4.4, "Thought for 4s"), (64, "Thought for 1m 04s")] as [(Double?, String)])
    func thoughtTextNamesItsDuration(seconds: Double?, text: String) {
        #expect(nativeThoughtText(seconds) == text)
    }
}
