import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// Which files of a turn are its own when other agents wrote in the same working tree: the
/// pure rule, the writer log it reads, and the paths it matches.
@Suite("Turn attribution")
struct TurnAttributionTests {
    typealias Interval = TurnAttribution.Interval

    static let a = AgentID(), b = AgentID()
    static let root = "/work/app"

    /// The log's evidence for agent `a`'s turn in `/work/app`, every directory in that tree.
    static func evidence(_ turn: UUID, _ log: WriterLog, now: Double = 10_000_000, tree: @escaping (String) -> Bool = { $0.hasPrefix("/work/app") }) -> TurnAttribution.Evidence {
        let window = log.windows.first { $0.turn == turn }!
        return TurnAttribution.evidence(window: window, log: log, now: now, sameTree: tree,
                                        relative: { path, cwd in TurnAttribution.relativePath(path, cwd: cwd, home: "/Users/me", root: root) { $0 } },
                                        savedPath: { $0.hasPrefix(root + "/") ? String($0.dropFirst(root.count + 1)) : nil })
    }

    static func change(_ path: String, from old: String? = nil) -> TurnAttribution.Change { .init(path: path, oldPath: old) }

    /// Agent `a`'s settled turn over [1_000_000, 2_000_000] and what it did.
    static func log(prompted: Double? = 1_000_000, _ build: (inout WriterLog, UUID) -> Void) -> (WriterLog, UUID) {
        var log = WriterLog()
        let turn = UUID()
        if let prompted { log.promptSent(a, at: prompted) }
        _ = log.openWindow(agent: a, turn: turn, cwd: root, receivedAt: 1_000_100)
        build(&log, turn)
        log.closeWindow(turn: turn, at: 2_000_000)
        return (log, turn)
    }

    // MARK: Shared

    @Test func aTurnIsSharedOnlyWhileAnotherAgentsTurnOverlapsItsWindow() {
        let window = Interval(start: 1_000, end: 2_000)
        func shared(_ other: Interval) -> Bool { TurnAttribution.isShared(window: window, writers: [other], now: 9_000) }
        #expect(!shared(Interval(start: 100, end: 900)), "ended before")
        #expect(!shared(Interval(start: 2_000, end: 3_000)), "began as this one ended")
        #expect(shared(Interval(start: 1_500, end: nil)), "still running")
        #expect(shared(Interval(start: 500, end: 1_500)))
        #expect(!TurnAttribution.isShared(window: window, writers: [], now: 9_000))

        // A turn the person prompted just after this one ended starts at the prompt, not before it.
        let prompted = TurnAttribution.windowStart(promptedAt: 2_100, receivedAt: 2_150)
        #expect(!shared(Interval(start: prompted, end: nil)))
        // One pi started itself is read late: its window starts a lead before the event.
        let started = TurnAttribution.windowStart(promptedAt: nil, receivedAt: 2_150)
        #expect(started == 2_150 - TurnAttribution.lead)
        #expect(shared(Interval(start: started, end: nil)))
    }

    @Test func aWindowTakesThePromptTimeOnceAndAHostPromptNeverLeaks() {
        var log = WriterLog()
        let first = log.openWindow(agent: Self.a, turn: UUID(), cwd: Self.root, receivedAt: 50_000)
        #expect(first.start == 50_000 - TurnAttribution.lead, "pi started it")
        log.promptSent(Self.a, at: 70_000)
        let second = log.openWindow(agent: Self.a, turn: UUID(), cwd: Self.root, receivedAt: 70_400)
        #expect(second.start == 70_000)
        let third = log.openWindow(agent: Self.a, turn: UUID(), cwd: Self.root, receivedAt: 90_000)
        #expect(third.start == 90_000 - TurnAttribution.lead, "the prompt time was used up")
        log.promptSent(Self.a, at: 95_000)
        log.promptDiscarded(Self.a)
        #expect(log.openWindow(agent: Self.a, turn: UUID(), cwd: Self.root, receivedAt: 99_000).start == 99_000 - TurnAttribution.lead)
    }

    // MARK: The rule

    @Test func aSoloTurnOwnsEveryChangedFileButShepherdsWrites() {
        let changed = [Self.change("a.txt"), Self.change("notes/made-by-bash.md"), Self.change("saved.txt")]
        let result = TurnAttribution.classify(changed: changed, shared: false, named: ["a.txt"], foreign: [], saved: ["saved.txt"])
        #expect(result.own == ["a.txt", "notes/made-by-bash.md"])
        #expect(result.other == ["saved.txt"])
    }

    @Test func aShepherdWriteSpanThatOutlastsAnotherTurnsStartStaysOutOfIt() {
        // Shepherd's Undo of another agent's turn begins at 1_900_000 and ends at 2_600_000,
        // after this turn (1_000_000 to 2_000_000) began, and before it ended: those files are saved.
        let (log, turn) = Self.log { log, _ in
            let id = UUID()
            _ = log.beginSpan(id, paths: [Self.root + "/restored.txt", "/elsewhere/other.txt"], at: 1_900_000)
            log.endSpan(id, at: 2_600_000)
        }
        let evidence = Self.evidence(turn, log)
        #expect(evidence.saved == ["restored.txt"])
        #expect(!evidence.shared, "Shepherd is not another agent")
        let result = TurnAttribution.classify(changed: [Self.change("restored.txt"), Self.change("mine.txt")], evidence: evidence)
        #expect(result.own == ["mine.txt"] && result.other == ["restored.txt"])
        // A write that finished before the turn began is not part of it.
        let (earlier, later) = Self.log { log, _ in
            let id = UUID()
            _ = log.beginSpan(id, paths: [Self.root + "/restored.txt"], at: 500_000)
            log.endSpan(id, at: 900_000)
        }
        #expect(Self.evidence(later, earlier).saved.isEmpty)
    }

    @Test func aTreeEventMakesATurnSharedOnlyInTheWorkingTreeItRewrote() {
        func evidence(rewriting tree: String, during span: Interval) -> TurnAttribution.Evidence {
            let (log, turn) = Self.log { log, _ in
                let id = UUID()
                _ = log.beginSpan(id, paths: [], tree: tree, at: span.start)
                if let end = span.end { log.endSpan(id, at: end) }
            }
            return Self.evidence(turn, log)
        }
        let here = evidence(rewriting: Self.root, during: Interval(start: 1_500_000, end: 1_600_000))
        #expect(here.shared && here.partner == nil && here.saved.isEmpty, "a person's operation is no other agent, and names no file")
        #expect(evidence(rewriting: Self.root, during: Interval(start: 1_900_000, end: nil)).shared, "still running when the turn ended")
        #expect(!evidence(rewriting: "/work/elsewhere", during: Interval(start: 1_500_000, end: 1_600_000)).shared)
        #expect(!evidence(rewriting: Self.root, during: Interval(start: 500_000, end: 900_000)).shared, "over before the turn began")

        let result = TurnAttribution.classify(changed: [Self.change("named.txt"), Self.change("rewritten.txt")], shared: here.shared,
                                              named: ["named.txt"], foreign: [], saved: [])
        #expect(result.own == ["named.txt"] && result.other == ["rewritten.txt"])
    }

    @Test func aSharedTurnOwnsOnlyNamedFilesNoOtherWriterNamed() {
        let changed = [Self.change("a.txt"), Self.change("both.txt"), Self.change("bash.txt"), Self.change("theirs.txt")]
        let result = TurnAttribution.classify(changed: changed, shared: true, named: ["a.txt", "both.txt"], foreign: ["both.txt", "theirs.txt"], saved: [])
        #expect(result.own == ["a.txt"])
        #expect(result.other == ["both.txt", "bash.txt", "theirs.txt"])

        let (log, turn) = Self.log { log, _ in
            _ = log.startCall(id: "mine", agent: Self.a, cwd: Self.root, path: "a.txt", receivedAt: 1_100_000)
            log.endCall(id: "mine", agent: Self.a, ok: true, at: 1_100_050)
            _ = log.startCall(id: "failed", agent: Self.a, cwd: Self.root, path: "never-written.txt", receivedAt: 1_200_000)
            log.endCall(id: "failed", agent: Self.a, ok: false, at: 1_200_050)
            _ = log.startCall(id: "theirs", agent: Self.b, cwd: Self.root, path: "src/b.txt", receivedAt: 1_300_000)
            log.endCall(id: "theirs", agent: Self.b, ok: true, at: 1_300_050)
        }
        let evidence = Self.evidence(turn, log)
        #expect(evidence.shared && evidence.partner == Self.b)
        #expect(evidence.named == ["a.txt"], "a call that failed named nothing it wrote")
        #expect(evidence.foreign == ["src/b.txt": Self.b])
    }

    @Test(arguments: [false, true])
    func anotherWritersFailedOrStoppedCallStillMixesAFile(ok: Bool) {
        // pi writes the file and only then reports "Operation aborted": the file changed anyway.
        let (log, turn) = Self.log { log, _ in
            _ = log.startCall(id: "mine", agent: Self.a, cwd: Self.root, path: "a.txt", receivedAt: 1_100_000)
            log.endCall(id: "mine", agent: Self.a, ok: true, at: 1_100_050)
            _ = log.startCall(id: "stopped", agent: Self.b, cwd: Self.root, path: "a.txt", receivedAt: 1_500_000)
            log.endCall(id: "stopped", agent: Self.b, ok: ok, at: 1_500_050)
        }
        let result = TurnAttribution.classify(changed: [Self.change("a.txt")], evidence: Self.evidence(turn, log))
        #expect(result.own.isEmpty && result.other == ["a.txt"])
    }

    @Test func anotherWritersCallOutsideTheWindowAndLeadDoesNotMixAFile() {
        let (log, turn) = Self.log { log, _ in
            _ = log.startCall(id: "mine", agent: Self.a, cwd: Self.root, path: "a.txt", receivedAt: 1_100_000)
            log.endCall(id: "mine", agent: Self.a, ok: true, at: 1_100_050)
            // Ended before the window began, and began a full lead after it ended.
            _ = log.startCall(id: "before", agent: Self.b, cwd: Self.root, path: "a.txt", receivedAt: 500_000)
            log.endCall(id: "before", agent: Self.b, ok: true, at: 500_100)
            _ = log.startCall(id: "after", agent: Self.b, cwd: Self.root, path: "a.txt", receivedAt: 2_000_000 + TurnAttribution.lead)
            log.endCall(id: "after", agent: Self.b, ok: true, at: 2_004_000)
        }
        let evidence = Self.evidence(turn, log)
        #expect(!evidence.shared && evidence.foreign.isEmpty)
        #expect(TurnAttribution.classify(changed: [Self.change("a.txt")], evidence: evidence).own == ["a.txt"])

        // A call read a moment late (it began within the lead of the window's end) still counts.
        let (late, lateTurn) = Self.log { log, _ in
            _ = log.startCall(id: "late", agent: Self.b, cwd: Self.root, path: "a.txt", receivedAt: 2_000_000 + TurnAttribution.lead - 1)
        }
        #expect(Self.evidence(lateTurn, late).foreign == ["a.txt": Self.b])
    }

    @Test func aCallInAnotherCheckoutThatLandsHereMakesTheTurnShared() {
        let (log, turn) = Self.log { log, _ in
            _ = log.startCall(id: "far", agent: Self.b, cwd: "/work/other", path: "/work/app/x.txt", receivedAt: 1_500_000)
            // In another checkout, landing there: not this tree's business.
            _ = log.startCall(id: "home", agent: Self.b, cwd: "/work/other", path: "y.txt", receivedAt: 1_600_000)
        }
        let evidence = Self.evidence(turn, log)
        #expect(evidence.shared && evidence.foreign == ["x.txt": Self.b])
    }

    @Test func aRenameIsOwnOnlyWhenBothPathsAre() {
        let rename = Self.change("new.txt", from: "old.txt")
        func own(named: Set<String>, foreign: Set<String> = []) -> Bool {
            TurnAttribution.classify(changed: [rename], shared: true, named: named, foreign: foreign, saved: []).own == ["new.txt"]
        }
        #expect(own(named: ["old.txt", "new.txt"]))
        #expect(!own(named: ["new.txt"]), "git saw old.txt go, but the turn never named it")
        #expect(!own(named: ["old.txt"]))
        #expect(!own(named: ["old.txt", "new.txt"], foreign: ["old.txt"]))
        #expect(TurnAttribution.classify(changed: [rename], shared: true, named: ["old.txt", "new.txt"], foreign: [], saved: ["old.txt"]).other == ["new.txt"])
    }

    // MARK: The log

    @Test func windowsAndCallsEndWhenTheTurnDoesAndWhenTheAgentIsGone() {
        var log = WriterLog()
        let turn = UUID()
        _ = log.openWindow(agent: Self.a, turn: turn, cwd: Self.root, receivedAt: 10_000)
        _ = log.startCall(id: "c", agent: Self.a, cwd: Self.root, path: "a.txt", receivedAt: 10_500)
        #expect(log.calls.first?.turn == turn)
        log.closeWindow(turn: turn, at: 12_000)
        #expect(log.windows.first?.interval.end == 12_000 && log.calls.first?.interval.end == 12_000 && log.calls.first?.ok == nil)

        let other = UUID()
        _ = log.openWindow(agent: Self.b, turn: other, cwd: Self.root, receivedAt: 20_000)
        log.agentEnded(Self.b, at: 21_000)
        #expect(log.windows.count == 2 && log.windows.last?.interval.end == 21_000, "closed, never removed")
    }

    @Test func aWriterThatArrivesLateNamesTheSettledTurnsItOverlaps() {
        var log = WriterLog()
        let turn = UUID()
        _ = log.openWindow(agent: Self.a, turn: turn, cwd: Self.root, receivedAt: 10_000)
        let call = log.startCall(id: "c", agent: Self.b, cwd: Self.root, path: "a.txt", receivedAt: 11_000)
        #expect(log.affectedAgents(by: call, excluding: Self.b, now: 30_000).isEmpty, "not settled yet")
        log.closeWindow(turn: turn, at: 12_000)
        log.settle(turn: turn, .init(startTree: "s", realEnd: "e", own: ["a.txt"], sequence: log.sequence))
        #expect(log.affectedAgents(by: call, excluding: Self.b, now: 30_000) == [Self.a])
        #expect(log.affectedAgents(by: call, excluding: Self.a, now: 30_000).isEmpty, "a writer never re-cuts its own turn")
        #expect(log.affectedAgents(by: .init(start: 20_000), excluding: nil, now: 30_000).isEmpty, "after it ended")
    }

    @Test func evictionNeverTakesWhatAnOpenTurnCouldNeedAndOtherwiseFailsSafe() {
        var log = WriterLog()
        let turn = UUID()
        _ = log.openWindow(agent: Self.a, turn: turn, cwd: Self.root, receivedAt: 1_000_000)
        for i in 0..<(WriterLog.callCap + 10) {
            _ = log.startCall(id: "\(i)", agent: Self.b, cwd: Self.root, path: "f\(i).txt", receivedAt: 1_100_000 + Double(i))
        }
        #expect(log.calls.count == WriterLog.callCap, "over the cap, the oldest went")
        #expect(!log.lost.isEmpty, "every call overlapped the open turn: they were lost, not kept")
        log.closeWindow(turn: turn, at: 2_000_000)
        let evidence = Self.evidence(turn, log)
        #expect(evidence.lossy)
        #expect(TurnAttribution.classify(changed: [Self.change("a.txt")], evidence: evidence).own.isEmpty)

        // What no open or undoable turn overlaps is the first to go, and nothing is lost.
        var quiet = WriterLog()
        for i in 0..<(WriterLog.callCap + 10) {
            _ = quiet.startCall(id: "\(i)", agent: Self.b, cwd: Self.root, path: "f\(i).txt", receivedAt: 1_000 + Double(i) * 10)
        }
        #expect(quiet.calls.count == WriterLog.callCap && quiet.lost.isEmpty)
    }

    @Test func pruningKeepsWhatAnUndoableTurnCouldStillNeed() {
        var log = WriterLog()
        _ = log.startCall(id: "old", agent: Self.b, cwd: Self.root, path: "old.txt", receivedAt: 1_000)
        log.endCall(id: "old", agent: Self.b, ok: true, at: 1_100)
        let turn = UUID()
        _ = log.openWindow(agent: Self.a, turn: turn, cwd: Self.root, receivedAt: 5_000_000)
        _ = log.startCall(id: "inside", agent: Self.b, cwd: Self.root, path: "in.txt", receivedAt: 5_100_000)
        log.endCall(id: "inside", agent: Self.b, ok: true, at: 5_100_100)
        log.closeWindow(turn: turn, at: 5_200_000)
        log.prune(now: 5_300_000 + WriterLog.keep)
        #expect(log.calls.map(\.id) == ["inside"], "old went; the call inside the undoable turn stayed")
        #expect(log.windows.count == 1)
    }

    // MARK: Paths

    @Test func pathsResolveAsPiResolvesThem() {
        let cwd = "/work/app/sub"
        func rel(_ raw: String, real: @escaping (String) -> String = { $0 }) -> String? {
            TurnAttribution.relativePath(raw, cwd: cwd, home: "/Users/me", root: Self.root, realParent: real)
        }
        #expect(rel("a.txt") == "sub/a.txt")
        #expect(rel("../b/c.txt") == "b/c.txt")
        #expect(rel("./x/../y.txt") == "sub/y.txt")
        #expect(rel("/work/app/z.txt") == "z.txt")
        #expect(rel("@lib/z.txt") == "sub/lib/z.txt", "a leading @ is dropped")
        #expect(rel("notes\u{00A0}draft.txt") == "sub/notes draft.txt" && rel("a\u{3000}b.txt") == "sub/a b.txt", "unicode spaces become spaces")
        #expect(rel("file:///work/app/u%20v.txt") == "u v.txt")
        #expect(rel("~/elsewhere.txt") == nil, "the home folder is outside the root")
        #expect(TurnAttribution.relativePath("~/app/h.txt", cwd: cwd, home: "/work", root: Self.root, realParent: { $0 }) == "h.txt")
        #expect(TurnAttribution.relativePath("~", cwd: cwd, home: "/work/app", root: Self.root, realParent: { $0 }) == nil)
        #expect(rel("../../outside.txt") == nil && rel("/etc/hosts") == nil)
        #expect(rel("../../app-two/a.txt") == nil, "a sibling that shares a prefix is not under the root")
        #expect(rel("") == nil && rel("@") == nil)
        // The caller's realpath decides where a symlinked folder lands.
        #expect(rel("link/a.txt", real: { $0 == "/work/app/sub/link" ? "/work/app/real" : $0 }) == "real/a.txt")
        #expect(rel("link/a.txt", real: { $0 == "/work/app/sub/link" ? "/somewhere/else" : $0 }) == nil)
    }

    @Test func theOwnTreeTakesTheRawDiffsOwnPathsAtTheirEndState() {
        let zero = String(repeating: "0", count: 40), old = String(repeating: "a", count: 40), new = String(repeating: "b", count: 40)
        let raw = Data(([":100644 100644 \(old) \(new) M", "a.txt", ":000000 100755 \(zero) \(new) A", "bin/run.sh",
                         ":100644 000000 \(old) \(zero) D", "gone.txt", ":100644 100644 \(old) \(new) M", "theirs.txt"].joined(separator: "\0") + "\0").utf8)
        let info = String(decoding: TurnAttribution.indexInfo(rawDiff: raw, own: ["a.txt", "bin/run.sh", "gone.txt"]), as: UTF8.self)
        #expect(info == "100644 \(new)\ta.txt\0100755 \(new)\tbin/run.sh\0000000 \(zero)\tgone.txt\0")
        #expect(TurnAttribution.indexInfo(rawDiff: raw, own: []).isEmpty)
    }
}
