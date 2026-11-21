import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// How the server keeps each automation's runs: a run opens when its automation gains an agent,
/// follows the agent's status, and closes when the agent goes. The unit under test is the file.
@Suite("Automation run log")
struct AutomationRunLogTests {
    static let space = Space(name: "Automations", path: "~", hidden: true)
    static let automation = Automation(id: AutomationID(rawValue: "a"), name: "watch", prompt: "watch", cwd: "/tmp")
    static let start = Date(timeIntervalSince1970: 1_000)

    static func state(agent status: AgentStatus?, id: AgentID = AgentID(rawValue: "run")) -> ShepherdState {
        guard let status else { return ShepherdState(spaces: [space], automations: [automation]) }
        let pane = LeafPane(cwd: "/tmp", agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var automation = automation
        automation.agentID = id
        return ShepherdState(spaces: [space], tabs: [tab],
                             agents: [Agent(id: id, name: "watch", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status)],
                             automations: [automation])
    }

    /// The same run through a sequence of states, one second apart.
    static func replay(_ states: [ShepherdState], log: AutomationRunLog) {
        for (index, pair) in zip(states, states.dropFirst()).enumerated() {
            log.record(from: pair.0, to: pair.1, now: start.addingTimeInterval(Double(index)))
        }
    }

    @Test(arguments: [
        ([nil, .idle] as [AgentStatus?], AutomationRunResult.running, false),
        ([nil, .working, .blocked], .needsYou, false),
        ([nil, .working, .done], .finished, true),
        ([nil, .working, .done, .working], .running, true),
        ([nil, .working, .done, nil], .finished, true),
        ([nil, .working, nil], .stopped, false),
        ([nil, .working, .blocked, nil], .stopped, false),
        ([nil, .idle, nil], .stopped, false),
    ])
    func aRunFollowsItsAgent(_ statuses: [AgentStatus?], result: AutomationRunResult, settled: Bool) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        // Writes go to disk off the caller; let them land before the directory goes.
        defer { log.flush() }

        Self.replay(statuses.map { Self.state(agent: $0) }, log: log)

        let run = try #require(log.runs[Self.automation.id]?.last)
        #expect(log.runs[Self.automation.id]?.count == 1)
        #expect(run.result == result)
        #expect((run.settledAt != nil) == settled)
        #expect(run.startedAt == Self.start.timeIntervalSince1970)
        #expect((run.endedAt == nil) == (statuses.last! != nil))
        #expect((run.agentID != nil) == (statuses.last! != nil))
        // The GUI reads a run still open without the server queue.
        #expect(log.openRuns[Self.automation.id] == (statuses.last! != nil ? run : nil))
    }

    /// The result the log keeps and the rule Run now follows (`AutomationRun.isLive`) agree, so
    /// a run that reads finished can always be run again and a live one never is.
    @Test(arguments: [AgentStatus.idle, .working, .blocked, .done], [false, true])
    func aKeptRunIsLiveExactlyWhenRunNowWaits(_ status: AgentStatus, settled: Bool) {
        let open = AutomationRun(startedAt: 0, settledAt: settled ? 5 : nil, result: .running)
        let followed = AutomationRunLog.following(open, status: status, at: 10)
        #expect(followed.result.isLive == AutomationRun.isLive(agentStatus: status, run: followed))
    }

    /// An agent whose run never settled and whose pi stops on its own stays, idle: its run is over,
    /// and neither Run now nor a trigger waits on it.
    @Test func aRunWhosePiStopsOnItsOwnEndsFailedAndKeepsItsAgent() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        let id = AgentID(rawValue: "run")
        Self.replay([Self.state(agent: nil), Self.state(agent: .working)], log: log)
        #expect(log.openRuns[Self.automation.id]?.result == .running)

        // The server's order: the agent goes idle, then its run ends.
        let stopped = Self.start.addingTimeInterval(30)
        log.record(from: Self.state(agent: .working), to: Self.state(agent: .idle), now: stopped)
        log.agentStopped(id, failure: "The agent stopped unexpectedly (signal 9).", now: stopped)
        let run = try #require(log.runs[Self.automation.id]?.last)
        #expect(run.result == .failed && run.failure == "The agent stopped unexpectedly (signal 9).")
        #expect(run.endedAt == stopped.timeIntervalSince1970 && run.settledAt == nil)
        #expect(run.unread && run.agentID == id, "the run still opens its thread")
        #expect(log.runs[Self.automation.id]?.count == 1)
        // The ended run stays published while its agent exists, so a GUI reading it there sees
        // it is over rather than finding no run and taking the idle thread for a starting one.
        #expect(log.openRuns[Self.automation.id] == run)
        #expect(!AutomationRun.isLive(agentStatus: .idle, run: run))
        #expect(run.result.isLive == AutomationRun.isLive(agentStatus: .idle, run: run))

        // The agent then goes away: the run is closed with its agent cleared, and no longer published.
        log.record(from: Self.state(agent: .idle), to: Self.state(agent: nil), now: stopped.addingTimeInterval(5))
        #expect(log.openRuns[Self.automation.id] == nil)
    }

    @Test func aRunThatAlreadySettledStaysSettledWhenItsPiStopsLater() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        Self.replay([Self.state(agent: nil), Self.state(agent: .working), Self.state(agent: .done)], log: log)
        let settled = try #require(log.runs[Self.automation.id]?.last)
        #expect(settled.result == .finished)

        log.agentStopped(AgentID(rawValue: "run"), failure: "The agent stopped unexpectedly (signal 9).", now: Self.start.addingTimeInterval(60))
        #expect(log.runs[Self.automation.id] == [settled])
        #expect(!AutomationRun.isLive(agentStatus: .idle, run: settled))
    }

    @Test func aStoppedRunKeepsAtMostFiveHundredCharactersOfItsReason() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        Self.replay([Self.state(agent: nil), Self.state(agent: .working)], log: log)
        log.agentStopped(AgentID(rawValue: "run"), failure: String(repeating: "x", count: 900), now: Self.start)
        #expect(log.runs[Self.automation.id]?.last?.failure?.count == 500)
    }

    @Test func anotherAgentsPiStoppingLeavesTheRunAlone() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        Self.replay([Self.state(agent: nil), Self.state(agent: .working)], log: log)
        let running = log.runs[Self.automation.id]
        log.agentStopped(AgentID(rawValue: "someone-else"), failure: "stopped", now: Self.start)
        #expect(log.runs[Self.automation.id] == running)
    }

    /// A run that ended while its agent stays idle is not live; one that has not, or that no one
    /// knows, is.
    @Test(arguments: [
        (AgentStatus.idle, 5.0 as Double?, nil as Double?, false), (.idle, nil, 9, false), (.idle, nil, nil, true),
        (.working, nil, 9, true), (.blocked, nil, 9, true), (.done, nil, nil, false),
    ])
    func anIdleRunIsLiveOnlyWhileItHasNeitherSettledNorEnded(_ status: AgentStatus, settled: Double?, ended: Double?, live: Bool) {
        let run = AutomationRun(startedAt: 0, settledAt: settled, endedAt: ended, result: .running)
        #expect(AutomationRun.isLive(agentStatus: status, run: run) == live)
        if status == .idle { #expect(AutomationRun.isLive(agentStatus: .idle, run: nil)) }
    }

    @Test func aNewAgentStartsANewRunAndTheLogKeepsTheNewest() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        var states = [Self.state(agent: nil)]
        for index in 0..<(AutomationRunLog.limit + 2) {
            states.append(Self.state(agent: .working, id: AgentID(rawValue: "run\(index)")))
        }
        Self.replay(states, log: log)

        let runs = try #require(log.runs[Self.automation.id])
        #expect(runs.count == AutomationRunLog.limit)
        #expect(runs.dropLast().allSatisfy { $0.result == .stopped && $0.agentID == nil })
        #expect(runs.last?.agentID == AgentID(rawValue: "run\(AutomationRunLog.limit + 1)"))
    }

    /// A client sees a run's agent only while it exists in the host's state.
    @Test func aClientIsOfferedOnlyAnAgentThatStillExists() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        let live = Self.state(agent: .done)
        log.record(from: Self.state(agent: nil), to: live)

        #expect(log.runs(for: Self.automation.id, in: live).map(\.agentID) == [AgentID(rawValue: "run")])
        #expect(log.runs(for: Self.automation.id, in: ShepherdState()).map(\.agentID) == [nil])
    }

    /// Written to disk and read back by the next launch, which closes what was still open.
    @Test func runsSurviveALaunchAndOpenOnesClose() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automation-runs.json")
        let first = AutomationRunLog(url: url)
        Self.replay([Self.state(agent: nil), Self.state(agent: .working)], log: first)
        first.flush()

        let second = AutomationRunLog(url: url)
        defer { second.flush() }
        #expect(second.runs == first.runs)
        #expect(second.openRuns == first.openRuns)
        second.closeOpenRuns(now: Self.start.addingTimeInterval(60))
        let run = try #require(second.runs[Self.automation.id]?.first)
        #expect(run.result == .interrupted && run.endedAt == Self.start.timeIntervalSince1970 + 60 && run.agentID == nil)
        #expect(second.openRuns.isEmpty)
    }

    @Test func aRemovedAutomationTakesItsRunsAlong() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        defer { log.flush() }
        Self.replay([Self.state(agent: nil), Self.state(agent: .done), ShepherdState(spaces: [Self.space])], log: log)
        #expect(log.runs.isEmpty)
    }
}

/// A run history file that can't be read is never replaced by an empty one: the log refuses every
/// change, says why, and takes the file back once it reads cleanly.
@Suite("Automation run log: damaged file")
struct AutomationRunLogDamageTests {
    static let run = #"{"id":"00000000-0000-4000-8000-000000000010","startedAt":12,"endedAt":13,"result":"finished"}"#
    static let legacy = #"{"version":1,"runs":{"a":["# + run + "]}}"
    static let otherRun = #"{"id":"00000000-0000-4000-8000-000000000011","startedAt":14,"endedAt":15,"result":"finished"}"#
    static let otherBackup = #"{"version":1,"runs":{"a":["# + otherRun + "]}}"

    /// The run ids on disk for automation "a".
    private static func ids(at url: URL) throws -> Set<String> {
        let file = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let runs = try #require((file["runs"] as? [String: [[String: Any]]])?["a"])
        return Set(runs.compactMap { ($0["id"] as? String)?.lowercased() })
    }
    static let newRun = Date(timeIntervalSince1970: 1_000)

    private static func scratch() throws -> (dir: URL, url: URL) {
        let dir = try makeTempDirectory()
        return (dir, dir.appendingPathComponent("automation-runs.json"))
    }

    @Test(arguments: ["{", "", "null", "[]", #"{"runs":[]}"#, #"{"version":1,"runs":null}"#, #"{"runs":{"a":[null]}}"#,
                      #"{"runs":{"a":[{"startedAt":1}]}}"#, #"{"version":1,"value":null}"#, #"{"version":2,"value":{"runs":{}}}"#,
                      #"{"records":{}}"#, "{}", #"{"runs":{"a":[{"id":"00000000-0000-4000-8000-000000000010","startedAt":12,"result":"finished","unread":null}]}}"#,
                      "unreadable"])
    func aDamagedFileIsNeverRewrittenAndNothingIsRecorded(input: String) throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let target = dir.appendingPathComponent("missing-target")
        if input == "unreadable" {
            try FileManager.default.createSymbolicLink(at: url, withDestinationURL: target)
        } else {
            try Data(input.utf8).write(to: url)
        }
        let log = AutomationRunLog(url: url)
        let problem = try #require(log.problem)
        #expect(problem.contains(url.path) && problem.contains("left the file as it is") && problem.contains("move the file aside"))

        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.openThreadRun(AutomationRunLogTests.automation.id, agentID: AgentID(rawValue: "x"), trigger: nil, triggerURL: nil)
        AutomationRunLogTests.replay([AutomationRunLogTests.state(agent: nil), AutomationRunLogTests.state(agent: .working)], log: log)
        log.closeOpenRuns()
        #expect(!log.markRead(runID: UUID()) && !log.agentStopped(AgentID(rawValue: "x"), failure: "stopped"))
        log.flush()

        #expect(log.runs.isEmpty)
        if input == "unreadable" {
            #expect(try FileManager.default.destinationOfSymbolicLink(atPath: url.path) == target.path)
            #expect(!FileManager.default.fileExists(atPath: target.path))
        } else {
            #expect(try Data(contentsOf: url) == Data(input.utf8))
        }
    }

    @Test func aMissingFileIsNoHistoryAndIsWritable() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        #expect(log.problem == nil && log.runs.isEmpty)
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        #expect(try Data(contentsOf: url).count > 0)
    }

    @Test(arguments: [false, true])
    func readsEitherShapeAndWritesTheLegacyOne(enveloped: Bool) throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data((enveloped ? #"{"version":1,"value":"# + Self.legacy + "}" : Self.legacy).utf8).write(to: url)
        let log = AutomationRunLog(url: url)
        #expect(log.problem == nil)
        #expect(log.runs[AutomationRunLogTests.automation.id]?.map(\.result) == [.finished])
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect(written["version"] as? Int == 1 && written["value"] == nil)
        #expect((written["runs"] as? [String: [Any]])?["a"]?.count == 2)
    }

    /// Fixing the file (by hand, or restoring a backup) is enough: the next access reads it again.
    @Test func aRepairedFileIsPickedUpAndWritableAgain() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{".utf8).write(to: url)
        let log = AutomationRunLog(url: url)
        var changes = 0
        log.changed = { changes += 1 }
        #expect(log.recheck() != nil)

        try Data(Self.legacy.utf8).write(to: url)
        #expect(log.recheck() == nil && log.problem == nil)
        #expect(log.runs[AutomationRunLogTests.automation.id]?.count == 1)
        #expect(changes > 0, "the app reads the runs again")
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        #expect(log.runs[AutomationRunLogTests.automation.id]?.count == 2)
    }

    /// Damage that arrives while the host runs: the in-memory history is not saved over it, and
    /// removing the file puts that history back.
    @Test func damageWhileRunningRefusesTheWriteAndRemovingTheFileRestoresTheHistory() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        log.flush()
        let healthy = try Data(contentsOf: url)

        try Data("{".utf8).write(to: url)
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Second", now: Self.newRun)
        log.flush()
        #expect(try Data(contentsOf: url) == Data("{".utf8))
        #expect(log.problem?.contains(url.path) == true)
        #expect(log.runs[id]?.count == 1, "memory keeps the last good history")

        try FileManager.default.removeItem(at: url)
        #expect(log.recheck() == nil)
        log.flush()
        #expect(try Data(contentsOf: url) == healthy)
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Third", now: Self.newRun)
        #expect(log.runs[id]?.count == 2)
        log.flush()
    }

    /// The file goes bad after a change was accepted and before its queued write runs.
    @Test func aQueuedWriteDoesNotOverwriteDamageThatArrivedBeforeIt() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        log.changed = { try? Data("{".utf8).write(to: url) }
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        #expect(try Data(contentsOf: url) == Data("{".utf8))
        // Only the writer saw the damage. A backup restored now must survive the next change.
        log.changed = {}
        try Data(Self.legacy.utf8).write(to: url)
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Appended", now: Self.newRun)
        log.flush()
        let appended = try #require(log.runs[AutomationRunLogTests.automation.id]?.first { $0.failure == "Appended" })
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010", appended.id.uuidString.lowercased()])
    }

    /// The writer reports damage after a change was built, and the backup is restored: the change
    /// is applied to the restored history instead of replacing it.
    @Test func aChangeBuiltBeforeTheWriterFoundDamageIsAppliedToTheRestoredHistory() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = AutomationRunLogTests.automation.id
        try Data("{".utf8).write(to: url)
        let log = AutomationRunLog(url: url)
        try Data(Self.legacy.utf8).write(to: url)
        // The change below recovers the file first; its `changed` call is the one point where
        // the writer can find new damage and a different backup be restored before it commits.
        var once = true
        log.changed = {
            guard once else { return }
            once = false
            log.changed = { log.changed = {}; try? Data("{".utf8).write(to: url) }
            log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Inner", now: Self.newRun)
            log.flush()
            try? Data(Self.otherBackup.utf8).write(to: url)
        }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Outer", now: Self.newRun)
        log.flush()
        let outer = try #require(log.runs[id]?.first { $0.failure == "Outer" })
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000011", outer.id.uuidString.lowercased()])
    }

    /// A second change is already queued behind the write that finds damage: it was built before
    /// the damage was known, so it must not replace the backup restored after.
    @Test func aWriteQueuedBehindOneThatFoundDamageDoesNotOverwriteTheRestoredBackup() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        let open = DispatchSemaphore(value: 0), reached = DispatchSemaphore(value: 0), restored = DispatchSemaphore(value: 0)
        log.writes.async { open.wait() }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        log.writes.async { reached.signal(); restored.wait() }
        log.changed = { log.changed = {}; try? Data("{".utf8).write(to: url) }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Second", now: Self.newRun)
        // The queue now holds: the first write, a pause, the second write. The file is damaged.
        open.signal()
        reached.wait()
        try Data(Self.legacy.utf8).write(to: url)
        restored.signal()
        log.flush()
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010"])
        #expect(log.recheck() == nil)
        #expect(log.runs[id]?.map { $0.id.uuidString.lowercased() } == ["00000000-0000-4000-8000-000000000010"])
    }

    /// The writer finds damage after a change was accepted but before its write is queued, and the
    /// backup is restored: the write was built before that, so it must not replace the backup.
    @Test func aChangeWhoseWriteIsQueuedAfterTheWriterFoundDamageDoesNotOverwriteTheRestoredBackup() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        let open = DispatchSemaphore(value: 0)
        log.writes.async { open.wait() }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        // The first write is still queued; the second change finds the file healthy, then, as it saves, the
        // first write runs against a damaged file and a backup is restored.
        log.changed = {
            log.changed = {}
            try? Data("{".utf8).write(to: url)
            open.signal()
            log.flush()
            try? Data(Self.legacy.utf8).write(to: url)
        }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Second", now: Self.newRun)
        log.flush()
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010"])
        #expect(log.recheck() == nil)
        #expect(log.runs[id]?.map { $0.id.uuidString.lowercased() } == ["00000000-0000-4000-8000-000000000010"])
    }

    /// The server itself finds damage while a write is queued, and the backup is restored: the queued
    /// write predates the damage, so it must not replace the backup.
    @Test func damageFoundByTheServerDropsWritesAlreadyQueued() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        let open = DispatchSemaphore(value: 0)
        log.writes.async { open.wait() }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        try Data("{".utf8).write(to: url)
        #expect(log.recheck() != nil)
        try Data(Self.legacy.utf8).write(to: url)
        open.signal()
        log.flush()
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010"])
        #expect(log.recheck() == nil)
        #expect(log.runs[id]?.map { $0.id.uuidString.lowercased() } == ["00000000-0000-4000-8000-000000000010"])
    }

    /// A writer paused after its generation check: the server then finds damage and a backup is restored.
    /// The writer's snapshot was built before that, so it must not replace the backup it reads.
    @Test func aWriterPausedAfterItsCheckDoesNotOverwriteABackupRestoredAfterTheServerFoundDamage() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        log.flush()
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        log.writerPaused = { point in
            guard point == .checked else { return }
            reached.signal()
            resume.wait()
        }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Second", now: Self.newRun)
        reached.wait()
        try Data("{".utf8).write(to: url)
        #expect(log.recheck() != nil)
        try Data(Self.legacy.utf8).write(to: url)
        resume.signal()
        log.flush()
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010"])
        #expect(log.recheck() == nil)
        #expect(log.runs[id]?.map { $0.id.uuidString.lowercased() } == ["00000000-0000-4000-8000-000000000010"])
    }

    /// A writer reads damage and pauses before reporting it; the server finds the same damage, recovers the
    /// backup and accepts a change. The late report is about an older generation and must not drop that change.
    @Test func aWriterReportingDamageLateDoesNotDropAChangeAcceptedAfterTheServerRecovered() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        log.flush()
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0)
        log.writerPaused = { point in
            guard point == .readDamage else { return }
            reached.signal()
            resume.wait()
        }
        // The file goes bad as the change is saved, so the queued write reads damage.
        log.changed = { log.changed = {}; try? Data("{".utf8).write(to: url) }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Second", now: Self.newRun)
        reached.wait()
        #expect(log.recheck() != nil)
        try Data(Self.legacy.utf8).write(to: url)
        #expect(log.recheck() == nil)
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "Third", now: Self.newRun)
        resume.signal()
        log.flush()
        let third = try #require(log.runs[id]?.first { $0.failure == "Third" })
        #expect(try Self.ids(at: url) == ["00000000-0000-4000-8000-000000000010", third.id.uuidString.lowercased()])
    }

    /// A change with nothing to do (here, no unread run) must not read the history file: the damage written
    /// behind the log's back stays unseen.
    @Test func anUpdateThatChangesNothingDoesNotReadTheHistoryFile() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        log.markRead()
        log.flush()
        try Data("{".utf8).write(to: url)
        #expect(!log.markRead())
        #expect(log.problem == nil)
    }

    /// The server's recheck waits only for the writer's short commit, not for it to stage its replacement.
    @Test func aRecheckDoesNotWaitForAWriterThatHasStagedItsReplacement() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: url)
        let id = AutomationRunLogTests.automation.id
        let reached = DispatchSemaphore(value: 0), resume = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        log.writerPaused = { point in
            guard point == .staged else { return }
            reached.signal()
            resume.wait()
        }
        log.recordFailure(id, trigger: nil, triggerURL: nil, message: "First", now: Self.newRun)
        reached.wait()
        DispatchQueue.global().async { _ = log.recheck(); done.signal() }
        let finished = done.wait(timeout: .now() + 5) == .success
        resume.signal()
        log.flush()
        #expect(finished)
        #expect(try Self.ids(at: url).count == 1)
    }

    /// A backup restored while the log still shows the damage: the first change builds on it, not on what was in memory.
    @Test func theFirstChangeAfterARepairKeepsTheRestoredHistory() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{".utf8).write(to: url)
        let log = AutomationRunLog(url: url)
        try Data(Self.legacy.utf8).write(to: url)
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        #expect(log.runs[AutomationRunLogTests.automation.id]?.count == 2)
        let written = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        #expect((written["runs"] as? [String: [Any]])?["a"]?.count == 2)
    }

    @Test func removingAFileThatWasDamagedAtStartupMeansNoHistory() throws {
        let (dir, url) = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: dir) }
        try Data("{".utf8).write(to: url)
        let log = AutomationRunLog(url: url)
        try FileManager.default.removeItem(at: url)
        #expect(log.recheck() == nil && log.runs.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        log.recordFailure(AutomationRunLogTests.automation.id, trigger: nil, triggerURL: nil, message: "Sample", now: Self.newRun)
        log.flush()
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}

/// A Project automation's run follows its Project task, whose worker may not exist yet.
@Suite("Automation run log: Project runs")
struct AutomationProjectRunLogTests {
    @Test func followsTheTask() {
        let project = ProjectID()
        let automation = Automation(id: AutomationID(rawValue: "p"), name: "loop", prompt: "p", cwd: "/tmp", projectID: project,
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY")))
        var task = ProjectTask(operationID: UUID(), spaceID: SpaceID(), title: "t", prompt: "p", phase: .queued)
        func state() -> ShepherdState {
            var p = Project(id: project, name: "P")
            p.tasks = [task]
            return ShepherdState(automations: [automation], projects: [p])
        }
        let log = AutomationRunLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID()).json"))
        log.openThreadRun(automation.id, agentID: task.workerAgentID, trigger: "Scheduled run", triggerURL: nil)
        log.record(from: state(), to: state())
        #expect(log.runs[automation.id]?.last?.endedAt == nil, "a queued task's missing worker doesn't end the run")
        let before = state()
        task.phase = .waiting
        log.record(from: before, to: state())
        #expect(log.runs[automation.id]?.last?.result == .needsYou)
        let asking = state()
        task.phase = .settled
        log.record(from: asking, to: state())
        let run = log.runs[automation.id]?.last
        #expect(run?.result == .finished && run?.endedAt != nil && run?.unread == true)
    }
}

/// A triggered run whose turn ended in an error reads as failed, with the error, not finished.
@Suite("Automation run log: failed turns")
struct AutomationFailedTurnRunLogTests {
    @Test func aFailedTurnIsAFailedRun() {
        let automation = Automation(id: AutomationID(rawValue: "t"), name: "loop", prompt: "p", cwd: "/tmp",
                                    trigger: .schedule(AutomationSchedule(rrule: "FREQ=DAILY")))
        let space = Space(name: "s", path: "/tmp")
        let pane = LeafPane(cwd: "/tmp")
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var agent = Agent(name: "#1 t", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: .working)
        agent.automationOrigin = AutomationOrigin(automationID: automation.id, trigger: "#1 t · issue opened")
        func state() -> ShepherdState { ShepherdState(spaces: [space], tabs: [tab], agents: [agent], automations: [automation]) }
        let log = AutomationRunLog(url: FileManager.default.temporaryDirectory.appendingPathComponent("runs-\(UUID()).json"))
        let empty = ShepherdState(spaces: [space], automations: [automation])
        log.record(from: empty, to: state())
        let working = state()
        agent.status = .done
        agent.lastFailure = "OAuth refresh failed"
        log.record(from: working, to: state())
        let run = log.runs[automation.id]?.last
        #expect(run?.result == .failed && run?.failure == "OAuth refresh failed" && run?.unread == true)
    }
}
