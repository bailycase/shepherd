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

    // MARK: Design verbs

    private func boardWrite(_ path: String, created: Bool) -> NativeActivityCall {
        call("board_write", ["path": path, "source": "<x-dc></x-dc>"], output: "\(created ? "Drew" : "Updated") \(path) · revision 3")
    }

    private func canvasUpdate() -> NativeActivityCall {
        call("canvas_update", ["changes": ["title": "Funnel"]], output: "Updated the canvas · revision 7 · 4 boards")
    }

    private func check(_ output: String, path: String? = nil) -> NativeActivityCall {
        call("design_check", path.map { ["path": $0] } ?? [:], output: output)
    }

    @Test func drawingNewBoardsReadsAsDrewWithTheirDirections() {
        let bursts = nativeActivityBursts([
            boardWrite("A.dc.html", created: true), boardWrite("B.dc.html", created: true), boardWrite("C.dc.html", created: true),
            boardWrite("A-phone.dc.html", created: true), canvasUpdate(),
        ])
        #expect(bursts.count == 1)
        #expect(bursts[0].kind == .drew && !bursts[0].isBoardUpdate)
        #expect(bursts[0].label == "Drew 4 boards")
        #expect(bursts[0].meta == "3 directions + phone")
        #expect(bursts[0].calls.map(\.stat) == ["new", "new", "new", "new", nil])
    }

    @Test func rewritingBoardsReadsAsAnUpdateOfThoseBoards() {
        let bursts = nativeActivityBursts([boardWrite("A.dc.html", created: false), boardWrite("A-phone.dc.html", created: false),
                                           boardWrite("A.dc.html", created: false)])
        #expect(bursts.map(\.label) == ["Updated A and A · phone"])
        #expect(bursts[0].meta.isEmpty)
        #expect(bursts[0].isBoardUpdate, "an update wears the edit glyph")
        let many = nativeActivityBursts(["A", "B", "C", "D"].map { boardWrite("\($0).dc.html", created: false) })
        #expect(many.map(\.label) == ["Updated 4 boards"])
    }

    @Test func aBurstThatDrawsAndUpdatesSaysBoth() {
        let bursts = nativeActivityBursts([boardWrite("B.dc.html", created: true), boardWrite("A.dc.html", created: false)])
        #expect(bursts.map(\.label) == ["Drew 1 board and updated A"])
        #expect(bursts[0].meta == "1 direction")
        #expect(!bursts[0].isBoardUpdate)
    }

    @Test func movingBoardsAloneArrangesTheCanvas() {
        let bursts = nativeActivityBursts([canvasUpdate()])
        #expect(bursts.map(\.label) == ["Arranged the canvas"])
        #expect(!bursts[0].isBoardUpdate)
    }

    @Test func checkingNamesTheSystemAndCountsWhatIsOffIt() {
        let clean = nativeActivityBursts([check("Checked against acme-web · 0 off-system values\n4 boards against 18 custom properties.")])
        #expect(clean.map(\.label) == ["Checked against acme-web"] && clean.map(\.meta) == ["0 off-system values"])
        #expect(clean[0].kind == .checked)
        let two = nativeActivityBursts([check("Checked against acme-web · 1 off-system value", path: "A.dc.html"),
                                        check("Checked against acme-web · 2 off-system values", path: "B.dc.html")])
        #expect(two.map(\.meta) == ["3 off-system values"])
        #expect(two[0].calls.map(\.detail) == ["A.dc.html", "B.dc.html"])
        let none = nativeActivityBursts([check("Checked without a design system · no tokens found")])
        #expect(none.map(\.label) == ["Checked the boards"] && none.map(\.meta) == ["no design system found"])
    }

    @Test func readingTheDesignIsExploring() {
        let bursts = nativeActivityBursts([call("design_read", output: "Design \"Funnel\" at revision 4."), call("design_read", ["path": "A.dc.html"]),
                                           call("read", ["path": "src/tokens.css"], output: "--accent: #4f46e5;")])
        #expect(bursts.map(\.label) == ["Explored 3 files"])
        #expect(bursts[0].calls.map(\.detail) == ["canvas.json", "A.dc.html", "src/tokens.css"])
    }

    @Test func readingADesignSystemIsExploringAndWritingOneNamesIt() {
        let read = nativeActivityBursts([call("system_read"), call("system_read", ["namespace": "acme-web"]),
                                         call("read", ["path": "web/static/tokens.css"])])
        #expect(read.map(\.label) == ["Explored 3 files"])
        #expect(read[0].calls.map(\.detail) == ["design systems", "ds/acme-web", "web/static/tokens.css"])
        let wrote = nativeActivityBursts([call("system_write", ["namespace": "acme-web"], output: "Wrote acme-web · revision 1")])
        #expect(wrote.map(\.label) == ["Used system"] && wrote[0].calls.map(\.detail) == ["acme-web"])
    }

    @Test func aRunningOrFailedDrawingSaysSo() {
        let running = nativeActivityBursts([call("board_write", ["path": "A.dc.html"], status: "running")])
        #expect(running.map(\.label) == ["Drawing"] && running.map(\.meta) == ["A.dc.html"])
        let failed = nativeActivityBursts([call("board_write", ["path": "A.dc.html"], output: "the root is 1280×800 but $preview says 390×844 (size_mismatch)",
                                                error: true)])
        #expect(failed.map(\.label) == ["Board write failed"])
        #expect(failed[0].meta.hasPrefix("A.dc.html · the root is 1280×800"))
        #expect(nativeActivityBursts([call("design_check", output: "boom", error: true)]).map(\.label) == ["Check failed"])
    }

    @Test(arguments: [
        ("A.dc.html", "A"), ("A-phone.dc.html", "A · phone"), ("B_tablet-wide.dc.html", "B · tablet wide"), ("flows/C.dc.html", "C"),
        ("Main.dc.html", "Main"), ("AB.dc.html", "AB"), ("a-phone.dc.html", "a-phone"),
    ])
    func boardsAreNamedByTheSkillsConvention(path: String, name: String) {
        #expect(nativeBoardName(path) == name)
    }

    @Test(arguments: [
        (["A.dc.html", "B.dc.html", "C.dc.html", "A-phone.dc.html"], "3 directions + phone"),
        (["A.dc.html", "A-phone.dc.html", "A-tablet.dc.html"], "1 direction + phone + tablet"),
        (["A-phone.dc.html"], "A · phone"),
        (["Main.dc.html", "Cart.dc.html"], "Main · Cart"),
        (["A.dc.html", "B.dc.html", "Cart.dc.html", "Pay.dc.html"], "A · B · Cart …"),
    ])
    func aDrawingsMetaCountsDirectionsAndSizes(paths: [String], summary: String) {
        #expect(nativeBoardSummary(paths) == summary)
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
        #expect(changes.title == "Edited 3 files")
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
            case .thinking(_, _, _, _, let live, _): live ? "live-thinking" : "thinking"
            case .prose: "prose"
            case .activity(_, let bursts): "lines:" + bursts.map { "\($0.calls.count)" }.joined(separator: "+")
            case .subagents(_, let lines): "record:" + lines.map(\.title).joined(separator: "|")
            case .note: "note"
            case .error(_, _, let final, let folded): final ? "error:final" : folded ? "error:folded" : "error"
            case .retrying: "retrying"
            case .steer(_, let text, _, _): "steer:" + text
            case .compaction(let row): "compaction:" + row.title
            case .question(let row): "question:" + row.question
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
        #expect(kinds(presentation) == ["thinking", "prose", "thinking", "lines:2+1", "prose"])
        guard case .thinking(_, let text, _, _, _, _) = presentation.items[2] else { Issue.record("no folded thinking"); return }
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
        #expect(kinds(presentation) == ["lines:1", "steer:use tables", "prose", "lines:1"])
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
        guard case .thinking(_, _, _, let seconds, _, _) = presentation.items.first else { Issue.record("no thinking"); return }
        #expect(seconds == 4.5)
    }

    /// A turn the user stopped says so quietly: a note, never an error with Retry.
    @Test func aStoppedTurnEndsInAQuietNote() {
        let messages = [F.assistant("Sleeping."), tool("bash", "b", status: "aborted", error: true),
                        F.assistant("", status: "aborted")]
        let presentation = nativeTurnPresentation(messages, live: false)
        #expect(kinds(presentation) == ["prose", "lines:1", "note"])
        guard case .note(_, let text) = presentation.items.last else { Issue.record("no note"); return }
        #expect(text == "Stopped")
    }

    /// pi's reply to a Stop carries no text, and still ends the turn it stopped.
    @Test func aStoppedReplyWithNothingToReadStaysInItsTurn() throws {
        let turns = nativeTurns([F.user("go"), tool("bash", "b", status: "aborted", error: true), F.assistant("", status: "aborted")])
        #expect(turns.map(\.messages.count) == [1, 2])
    }

    /// Only the text a reply is still writing holds back a table header waiting for its
    /// delimiter row; a finished reply, or an earlier message of the live turn, draws every line.
    @Test func onlyTheStreamingTextHoldsBackAPendingTable() {
        let header = "Here:\n\n| Area | Tools |\n"
        func paragraphs(_ presentation: NativeTurnPresentation) -> [String] {
            presentation.items.flatMap { item -> [String] in
                guard case .prose(_, _, let blocks, _) = item else { return [] }
                return blocks.compactMap { if case .paragraph(let text) = $0 { text } else { nil } }
            }
        }
        let streaming = F.assistant(header, status: "streaming")
        #expect(paragraphs(nativeTurnPresentation([streaming], live: true)) == ["Here:"])
        #expect(paragraphs(nativeTurnPresentation([F.assistant(header)], live: false)) == ["Here:", "| Area | Tools |"])
        #expect(paragraphs(nativeTurnPresentation([F.assistant(header), tool("read", "r"), F.assistant("Next", status: "streaming")], live: true))
            == ["Here:", "| Area | Tools |", "Next"])
    }

    @Test func theThinkingStillStreamingStaysLastAndLive() {
        var streaming = F.assistant("", thinking: "hmm", status: "streaming")
        streaming.timestamp = 5_000
        let presentation = nativeTurnPresentation([F.assistant("Going."), tool("read", "r"), streaming], live: true)
        #expect(kinds(presentation) == ["prose", "lines:1", "live-thinking"])
        #expect(!presentation.betweenTools, "the thinking is what moves")
        guard case .thinking(_, _, _, _, _, let since) = presentation.items.last else { return }
        #expect(since == 5_000)
    }

    @Test func aRunningCallEndsTheLiveTurnOnItsOwnLine() {
        let presentation = nativeTurnPresentation([tool("read", "r"), tool("bash", "b", status: "running")], live: true)
        #expect(kinds(presentation) == ["lines:1+1"] && presentation.changes == nil)
        guard case .activity(_, let bursts)? = presentation.items.last else { Issue.record("no lines"); return }
        #expect(bursts.map(\.state) == [.done, .running])
        #expect(!presentation.betweenTools, "the running call is what moves")
    }

    /// NWThread, ToolRows: one quiet line per burst, in the order the work took, with no line
    /// that folds them. A failure stays its own red line; the running call is live in place.
    @Test func aStretchIsItsBurstLinesInOrder() {
        let messages = [tool("read", "a"), tool("read", "b"), tool("edit", "c"),
                        F.tool("bash", args: #"{"command":"swift test"}"#, output: "Command exited with code 1", error: true, id: "e-t", callID: "t"),
                        tool("bash", "l"), tool("bash", "p", status: "running")]
        let presentation = nativeTurnPresentation(messages, live: true)
        #expect(kinds(presentation) == ["lines:2+1+1+1+1"])
        guard case .activity(_, let bursts)? = presentation.items.first else { Issue.record("no lines"); return }
        #expect(bursts.map(\.label) == ["Explored 2 files", "Edited 1 file", "Ran tests", "Ran a command", "Running"])
        #expect(bursts.map(\.state) == [.done, .done, .failed, .done, .running])
    }

    /// LiveText: only one thing moves. With no call running, no thinking streaming and no reply
    /// being written, pi is between tools and the live turn ends in "Thinking…".
    @Test(arguments: [
        ("after a finished call", ["read"], true, true),
        ("after a steer pi read", ["read", "steer"], true, true),
        ("while a call runs", ["read", "running"], true, false),
        ("while it thinks", ["read", "thinking"], true, false),
        ("while it writes its reply", ["read", "prose"], true, false),
        ("once the turn is over", ["read"], false, false),
    ])
    func theLiveTurnIsBetweenToolsOnlyWhenNothingElseMoves(_ what: String, parts: [String], live: Bool, between: Bool) {
        let messages: [NativeThreadMessage] = parts.enumerated().map { index, part in
            switch part {
            case "running": tool("bash", "b\(index)", status: "running")
            case "thinking": F.assistant("", thinking: "hm", status: "streaming")
            case "prose": F.assistant("Pushing now.", status: "streaming")
            case "steer": {
                var steer = F.user("also tests", id: "s\(index)")
                steer.origin = .steered
                return steer
            }()
            default: tool(part, "c\(index)")
            }
        }
        #expect(nativeTurnPresentation(messages, live: live).betweenTools == between, "\(what)")
    }

    /// A call the record stands for still runs: the parent waiting on its subagents is not
    /// thinking.
    @Test func aRunningCallTheRecordStandsForStillCountsAsMoving() {
        let messages = [tool("shepherd_child_start", "s1"), tool("shepherd_child_wait", "w", status: "running")]
        let presentation = nativeTurnPresentation(messages, live: true,
                                                  cards: NativeCardLayout(callIDs: ["s1"], record: NativeSubagentRecord(started: Self.record.started)))
        #expect(kinds(presentation) == ["record:Started 2 subagents"] && !presentation.betweenTools)
    }

    private static let record = NativeSubagentRecord(
        started: NativeSubagentRecordLine(title: "Started 2 subagents", meta: "a · b"),
        finished: NativeSubagentRecordLine(title: "2 subagents finished", meta: "4m"), finishedAt: 5)

    /// The record's first line takes the first spawn's place; later spawns and the parent's
    /// wait and result calls leave no line, and the work around them stays one line.
    @Test func theRecordTakesTheFirstSpawnsPlaceAndBookkeepingCallsHide() {
        let live = NativeSubagentRecord(started: Self.record.started)
        let messages = [tool("read", "r"), tool("shepherd_child_start", "s1"), tool("shepherd_child_wait", "w"), tool("shepherd_child_start", "s2")]
        let presentation = nativeTurnPresentation(messages, live: true, cards: NativeCardLayout(callIDs: ["s1", "s2"], record: live))
        #expect(kinds(presentation) == ["lines:1", "record:Started 2 subagents"])
        #expect(presentation.toolCalls == 2, "spawn calls the record stands for are not counted")
        let around = [tool("read", "r1"), tool("shepherd_child_start", "s1"), tool("read", "r2"), tool("shepherd_child_start", "s2"), tool("read", "r3")]
        #expect(kinds(nativeTurnPresentation(around, live: true, cards: NativeCardLayout(callIDs: ["s1", "s2"], record: live)))
                == ["lines:1", "record:Started 2 subagents", "lines:2"])
    }

    /// "finished" sits where they finished: before the first thing that landed after the last
    /// run ended, else at the end of the turn.
    @Test(arguments: [(5.0, ["record:Started 2 subagents", "prose", "record:2 subagents finished", "prose"]),
                      (50.0, ["record:Started 2 subagents", "prose", "prose", "record:2 subagents finished"])])
    func theFinishedLineSitsWhereTheyFinished(finishedAt: Double, expected: [String]) {
        var record = Self.record
        record.finishedAt = finishedAt
        var spawn = tool("shepherd_child_start", "s1")
        spawn.timestamp = 2
        var waiting = F.assistant("Waiting on them.")
        waiting.timestamp = 3
        var wrapUp = F.assistant("All done.")
        wrapUp.timestamp = 10
        let presentation = nativeTurnPresentation([spawn, waiting, wrapUp], live: false, cards: NativeCardLayout(callIDs: ["s1"], record: record))
        #expect(kinds(presentation) == expected)
    }

    /// Runs whose spawn call is not in the turn (paged out, an older host) are recorded at its end.
    @Test func runsWithNoSpawnCallAreRecordedAtTheEnd() {
        let presentation = nativeTurnPresentation([F.assistant("Done.")], live: false, cards: NativeCardLayout(record: Self.record))
        #expect(kinds(presentation) == ["prose", "record:Started 2 subagents|2 subagents finished"])
    }

    /// With nothing between them, both lines are one item, so they sit together as activity
    /// lines do (SubagentsDone), and the started line keeps its identity as the other joins it.
    @Test func adjacentRecordLinesShareOneItem() {
        var spawn = tool("shepherd_child_start", "s1")
        spawn.timestamp = 2
        var wrapUp = F.assistant("All three handed off.")
        wrapUp.timestamp = 10
        let presentation = nativeTurnPresentation([spawn, wrapUp], live: false, cards: NativeCardLayout(callIDs: ["s1"], record: Self.record))
        #expect(kinds(presentation) == ["record:Started 2 subagents|2 subagents finished", "prose"])
        #expect(presentation.items.first?.id == "subagents:started")
    }

    @Test func aCardLayoutRecordsItsRunsOnceTheyAllFinish() {
        let live = (0..<2).map { F.run("r\($0)", startedAt: Double($0), toolCallID: "s\($0)") }
        let layout = NativeCardLayout(NativeSubagentPlacement(byToolCall: ["s0": [live[0]], "s1": [live[1]]]))
        #expect(layout.callIDs == ["s0", "s1"])
        #expect(layout.record?.started == NativeSubagentRecordLine(title: "Started 2 subagents", meta: "r0 · r1"))
        #expect(layout.record?.finished == nil)
        let done = (0..<2).map { F.run("d\($0)", state: "complete", startedAt: 0, endedAt: 60_000 * Double($0 + 1), toolCallID: "s\($0)") }
        let finished = NativeCardLayout(NativeSubagentPlacement(byToolCall: ["s0": [done[0]], "s1": [done[1]]]))
        #expect(finished.record?.finished == NativeSubagentRecordLine(title: "2 subagents finished", meta: "2m"))
        #expect(finished.record?.finishedAt == 120_000)
        #expect(NativeCardLayout(nil) == .none)
    }

    @Test func anErrorThatEndsAFinishedTurnOffersRetry() {
        let failed = { F.assistant("Model overloaded", status: "error") }
        let finished = nativeTurnPresentation([tool("read", "r"), failed(), failed()], live: false)
        #expect(kinds(finished) == ["lines:1", "error:final"])
        guard case .error(_, let error, _, _) = finished.items.last else { return }
        #expect(error.title == "The provider is overloaded" && error.tries == "Tried 2 times")
        #expect(kinds(nativeTurnPresentation([failed(), F.assistant("Recovered.")], live: false)) == ["error:folded", "prose"])
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
