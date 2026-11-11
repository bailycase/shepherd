import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestSupport

/// Last turn and the "Edited N files" card with a real server and the stub pi working in a
/// scratch repository: the host snapshots the working tree when pi starts a run and when it
/// settles, and Undo puts back exactly what the turn changed.
@Suite("Changes turns", .integrationTimeLimit)
struct ChangesTurnTests {
    struct Turn {
        let host: ScratchServer
        let pi: PiAgent
        let repo: ChangesRepo
        var changes: ChangesService { host.server.changes }
        var agent: AgentID { pi.agent.id }

        func turns() -> [ChangesTurn] { changes.turns(agentID: agent) }
    }

    /// A repository with the user's own uncommitted edit, an agent in it, and one turn in which
    /// the agent modifies a.txt, deletes d.txt, renames c.txt to e.txt and creates new.txt.
    static func agentTurn() async throws -> Turn {
        let repo = try ChangesRepo(files: ["a.txt": "one\n", "b.txt": "bee\n", "c.txt": "a file that moves\nwith its lines\n", "d.txt": "dee\n"])
        // The stub's gates appear in its cwd; they are not the agent's work.
        try "tool-*\nsettle\ncontinue-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        try repo.write("stash-me.txt", "x\n")
        try repo.git("stash", "-u")
        try repo.write("b.txt", "bee, edited by the user\n")
        let host = try ScratchServer.fresh()
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let turn = Turn(host: host, pi: pi, repo: repo)
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:1 refactor the ledger", from: idle).failureCode == nil)
        try await eventually("the turn's baseline") { turn.changes.turnStore.latest(turn.agent)?.startTree != nil }

        try repo.write("a.txt", "one\ntwo\n")
        try repo.remove("d.txt")
        try repo.move("c.txt", "e.txt")
        try repo.write("new.txt", "brand new\n")
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        try await eventually("the turn to end") { turn.turns().last?.state == .ready }
        return turn
    }

    @Test func lastTurnIsWhatTheAgentChanged() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        #expect(turn.title == "Edited 4 files" && turn.canUndo && !turn.canRedo)
        #expect(turn.prompt == "tools:1 refactor the ledger")
        #expect(Set(turn.files.map(\.path)) == ["a.txt", "d.txt", "e.txt", "new.txt"])

        let list = try await t.changes.list(agentID: t.agent, scope: .lastTurn)
        #expect(list.summary == ["A new.txt", "D d.txt", "M a.txt", "R c.txt→e.txt"], "the user's own b.txt edit is not the turn's")
        #expect(list.comparison.turn?.id == turn.id && list.title == "Last turn")
        #expect(try await t.changes.list(agentID: t.agent, scope: .turn(id: turn.id)).summary == list.summary)

        // The thread carries the turn, keyed by the message that started it.
        let snapshot = try await t.pi.snapshot("the turn in the thread") { $0.turnChanges?.last?.state == .ready }
        let user = try #require(snapshot.messages.last { $0.role == "user" })
        #expect(changesTurn(forMessageAt: user.timestamp, in: snapshot.turnChanges)?.id == turn.id)
    }

    /// Undo restores the modified, deleted and renamed files and trashes the created ones; the
    /// user's own edit, the index, HEAD, refs and the stash stay as they were. Redo reapplies it.
    @Test func undoPutsBackExactlyTheTurnAndRedoReappliesIt() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        let before = try t.repo.state()

        let undone = try await t.changes.undoTurn(agentID: t.agent, turnID: turn.id)
        #expect(undone.state == .undone && undone.canRedo && !undone.canUndo)
        #expect(undone.title == "Undid the agent’s edits to 4 files")
        #expect(t.repo.read("a.txt") == "one\n")
        #expect(t.repo.read("d.txt") == "dee\n")
        #expect(t.repo.read("c.txt") == "a file that moves\nwith its lines\n")
        #expect(t.repo.read("e.txt") == nil && t.repo.read("new.txt") == nil)
        #expect(t.repo.read("b.txt") == "bee, edited by the user\n")
        let trashed = try FileManager.default.contentsOfDirectory(atPath: t.host.trash.path).map { String($0.split(separator: "-").last ?? "") }
        #expect(Set(trashed) == ["e.txt", "new.txt"])
        let after = try t.repo.state()
        #expect(after.index == before.index && after.indexModified == before.indexModified)
        #expect(after.head == before.head && after.refs == before.refs && after.stash == before.stash && after.gitEntries == before.gitEntries)
        _ = try await t.pi.snapshot("the undone turn in the thread") { $0.turnChanges?.last?.state == .undone }

        let redone = try await t.changes.redoTurn(agentID: t.agent, turnID: turn.id)
        #expect(redone.state == .ready && redone.canUndo)
        #expect(t.repo.read("a.txt") == "one\ntwo\n" && t.repo.read("new.txt") == "brand new\n")
        #expect(t.repo.read("e.txt") == "a file that moves\nwith its lines\n")
        #expect(t.repo.read("c.txt") == nil && t.repo.read("d.txt") == nil)
        try t.repo.expectUnchanged(since: before)
    }

    /// A file the turn touched that changed afterwards is never overwritten: Undo refuses, naming
    /// it, and leaves every file as it is.
    @Test func undoRefusesWhenAFileChangedSinceTheTurn() async throws {
        let t = try await Self.agentTurn()
        defer { t.host.stop() }
        let turn = try #require(t.turns().last)
        try t.repo.write("a.txt", "one\ntwo\nthree, by the user\n")
        let before = try t.repo.state()

        let error = await #expect(throws: ChangesError.self) { _ = try await t.changes.undoTurn(agentID: t.agent, turnID: turn.id) }
        #expect(error?.code == ChangesError.changedSince && error?.files == ["a.txt"])
        try t.repo.expectUnchanged(since: before)
        #expect(t.turns().last?.state == .ready)
        #expect(!FileManager.default.fileExists(atPath: t.host.trash.path))
    }

    @Test func nextPromptWaitsForTheSettledSnapshotWithoutBlockingOtherAgents() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "original\n"])
        try "tool-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let other = try await PiAgent.launch(on: host)
        let idle = try await pi.ready()
        let otherIdle = try await other.ready()
        #expect(try await pi.send("tools:1 first", from: idle).failureCode == nil)
        let changes = host.server.changes
        try await eventually("first baseline") { changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        try repo.write("a.txt", "first turn\n")
        let running = try await pi.snapshot { $0.running }
        #expect(try await pi.send("tools:1 second", from: running).failureCode == nil)
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        let settled = try await pi.snapshot("settled while capture waits") { !$0.running }
        #expect(try await pi.send("tools:0 third", from: settled).failureCode == nil)
        // Send now while busy accepts/reorders, but must not bypass the capture gate.
        #expect(try await pi.queue(.sendNow(ids: settled.queue?.items.map(\.id) ?? []), from: settled).failureCode == nil)
        #expect(try await other.send("tools:0 unrelated", from: otherIdle).failureCode == nil)
        _ = try await other.snapshot("unrelated agent completes") { !$0.running && $0.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text.contains("unrelated") } } }
        #expect(pi.stdin("prompt").count == 1, "neither queued nor fresh sends may reach pi during capture")
        release.signal()
        _ = try await pi.waitForStdin("prompt", count: 2)
        try await eventually("second baseline") { changes.turnStore.all(pi.agent.id).count == 2 && changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        let records = changes.turnStore.all(pi.agent.id)
        #expect(records.first?.endTree == records.last?.startTree)
        try repo.write("a.txt", "second turn\n")
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-2").path, contents: nil)
        try await eventually("both captures finish") { changes.turns(agentID: pi.agent.id).last?.state == .ready }
        #expect(changes.turns(agentID: pi.agent.id).map(\.fileCount) == [1, 1])
    }

    @Test func promptBaselineFinishesBeforePiReceivesThePromptAndCaptureFailureDoesNotStallIt() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "original\n"])
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let idle = try await pi.ready()
        let changes = host.server.changes
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        let sending = Task { try await pi.send("tools:0 capture failure", from: idle) }
        _ = try await pi.snapshot("pending send while baseline is held") { $0.provisional.contains { $0.status == "pending" && $0.blocks.first?.text == "tools:0 capture failure" } }
        #expect(pi.stdin("prompt").isEmpty)
        let file = repo.url.appendingPathComponent("a.txt")
        // Git can reuse a clean index entry without opening the working file. Change its
        // size first so capture must read it, regardless of filesystem timestamp granularity.
        try repo.write("a.txt", "changed and unreadable during baseline capture\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: file.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: file.path) }
        try #require(!FileManager.default.isReadableFile(atPath: file.path))
        release.signal()
        #expect(try await sending.value.failureCode == nil)
        _ = try await pi.waitForStdin("prompt")
        try await eventually("failed baseline reported") { changes.turns(agentID: pi.agent.id).last?.state == .unavailable }
        _ = try await pi.snapshot("capture failure does not stall settlement") { !$0.running }
    }

    @Test func aHangingCleanFilterCannotHoldTheFirstPromptForever() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "original\n"])
        try repo.write(".gitattributes", "a.txt filter=hang\n")
        try repo.git("config", "filter.hang.clean", "/bin/sleep 60")
        try repo.git("config", "filter.hang.required", "true")
        try repo.write("a.txt", "changed\n")
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let idle = try await pi.ready()

        #expect(try await pi.send("tools:0 capture times out", from: idle).failureCode == nil)

        #expect(pi.stdin("prompt").count == 1)
        try await eventually("timeout makes the baseline unavailable") {
            host.server.changes.turns(agentID: pi.agent.id).last?.state == .unavailable
        }
        #expect(host.server.changes.turns(agentID: pi.agent.id).last?.reason?.contains("timed out") == true)
        // The failed command released its owned index lock as well as the prompt.
        try repo.git("config", "filter.hang.clean", "/bin/cat")
        _ = try await host.server.changes.list(agentID: pi.agent.id, scope: .uncommitted)
        #expect(repo.read("a.txt") == "changed\n")
    }

    @Test func stoppingAHeldPromptAnswersItBeforeCaptureCompletesAndNeverSendsItLater() async throws {
        let repo = try ChangesRepo()
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let idle = try await pi.ready()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            host.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        let send = Task { try await pi.send("tools:0 cancelled", from: idle) }
        _ = try await pi.snapshot("the held pending prompt") { $0.provisional.contains { $0.status == "pending" } }

        #expect(try await pi.request(.abort(expectedSessionID: idle.piSessionID, generation: idle.generation,
                                           operationID: UUID())).failureCode == nil)
        #expect(try await send.value.failureCode == "send_cancelled")
        #expect(pi.stdin("prompt").isEmpty)
        release.signal()
        await drain(host.server.changes, pi.agent.id)
        #expect(try await pi.send("tools:0 new request", from: idle).failureCode == nil)
        #expect(pi.stdin("prompt").compactMap { $0["message"] as? String } == ["tools:0 new request"])
    }

    @Test func serverShutdownAnswersAHeldPromptBeforeCaptureCompletes() async throws {
        let repo = try ChangesRepo()
        let host = try ScratchServer.fresh()
        defer { host.stop() }
        let pi = try await PiAgent.launch(on: host, cwd: repo.url)
        let idle = try await pi.ready()
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            host.server.changes.captureQueue(pi.agent.id).async { continuation.resume(); release.wait() }
        }
        let send = Task { try await pi.send("tools:0 cancelled by shutdown", from: idle) }
        _ = try await pi.snapshot("held prompt before shutdown") { $0.provisional.contains { $0.status == "pending" } }
        host.stop()
        #expect(try await send.value.failureCode == "send_cancelled")
        #expect(pi.stdin("prompt").isEmpty)
        release.signal()
        await drain(host.server.changes, pi.agent.id)
        #expect(pi.stdin("prompt").isEmpty)
    }

    private func drain(_ service: ChangesService, _ agent: AgentID) async {
        await Self.drain(service, agent)
    }

    static func drain(_ service: ChangesService, _ agent: AgentID) async {
        await withCheckedContinuation { continuation in
            service.captureQueue(agent).async { continuation.resume() }
        }
    }

    @Test func aNewTurnStartsWhileThePreviousEndCaptureIsPending() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "start\n"])
        let h = try ChangesHarness(repo: repo)
        h.service.turnStarted(agentID: h.agent, at: 1)
        await drain(h.service, h.agent)
        try repo.write("a.txt", "first turn\n")
        let release = DispatchSemaphore(value: 0)
        defer { release.signal() }
        await withCheckedContinuation { continuation in
            h.service.captureQueue(h.agent).async {
                continuation.resume()
                release.wait()
            }
        }
        h.service.turnSettled(agentID: h.agent, at: 2)
        h.service.turnSettled(agentID: h.agent, at: 99) // duplicate settle cannot replace the end
        h.service.turnStarted(agentID: h.agent, at: 3)
        h.service.turnStarted(agentID: h.agent, at: 4) // a retry still belongs to that run
        h.service.turnMessage(agentID: h.agent, timestamp: 3, text: "second turn")
        let pending = h.service.turnStore.all(h.agent)
        #expect(pending.count == 2)
        #expect(pending.first?.turn.endedAt == 2)
        #expect(pending.last?.turn.prompt == "second turn")
        release.signal()
        await drain(h.service, h.agent)
        let captured = h.service.turnStore.all(h.agent)
        #expect(captured.first?.endTree == captured.last?.startTree)
        try repo.write("a.txt", "second turn\n")
        h.service.turnSettled(agentID: h.agent, at: 5)
        await drain(h.service, h.agent)
        #expect(h.service.turns(agentID: h.agent).map(\.fileCount) == [1, 1])
        let last = try await h.list(.lastTurn)
        let diff = try await h.service.file(agentID: h.agent, revision: last.revision, path: "a.txt")
        #expect(diff.file.hunks.flatMap(\.lines).filter { $0.kind == .removed }.map(\.text) == ["first turn"])
    }

    @Test func concurrentUndosForDisjointAgentsKeepBothEditsAndTheUserIndexSafe() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let h = try ChangesHarness(repo: repo)
        let second = AgentID()
        h.service.agentContext = { _ in ChangesService.AgentContext(cwd: repo.path) }
        h.service.turnStarted(agentID: h.agent)
        await drain(h.service, h.agent)
        try repo.write("a.txt", "changed a\n")
        h.service.turnSettled(agentID: h.agent)
        await drain(h.service, h.agent)
        // The person prompts the second agent after the first turn ended: its turn begins at the prompt.
        await withCheckedContinuation { continuation in h.service.prepareTurn(agentID: second) { continuation.resume() } }
        h.service.turnStarted(agentID: second)
        await drain(h.service, second)
        try repo.write("b.txt", "changed b\n")
        h.service.turnSettled(agentID: second)
        await drain(h.service, second)
        let firstTurn = try #require(h.service.turns(agentID: h.agent).last)
        let secondTurn = try #require(h.service.turns(agentID: second).last)
        let index = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))

        async let firstUndo = h.service.undoTurn(agentID: h.agent, turnID: firstTurn.id)
        async let secondUndo = h.service.undoTurn(agentID: second, turnID: secondTurn.id)
        let results = try await [firstUndo, secondUndo]

        #expect(results.allSatisfy { $0.state == .undone })
        #expect(repo.read("a.txt") == "a\n" && repo.read("b.txt") == "b\n")
        #expect(try Data(contentsOf: repo.url.appendingPathComponent(".git/index")) == index)
    }

    @Test func undoAndRedoWriteEachCheckpointOnceWithUnrelatedTurnsRetained() async throws {
        let paths = ["a.txt", "b.txt", "c.txt"]
        let repo = try ChangesRepo(files: Dictionary(uniqueKeysWithValues: paths.map { ($0, "original \($0)\n") }))
        let h = try ChangesHarness(repo: repo)
        defer {
            h.service.turnStore.flush()
            try? FileManager.default.removeItem(at: repo.url)
            try? FileManager.default.removeItem(at: h.directory)
        }
        let writes = Locked(0)
        h.service.turnStore.beforeWrite = { _ in writes.withValue { $0 += 1 } }
        var unrelated: [String: [TurnRecord]] = [:]
        for _ in 0..<50 {
            let agent = AgentID()
            let records = (0..<20).map { index in
                TurnRecord(turn: ChangesTurn(startedAt: Double(index), endedAt: Double(index + 1), state: .ready), cwd: repo.path)
            }
            unrelated[agent.rawValue] = records
            h.service.turnStore.update(agent) { $0 = records }
        }
        h.service.turnStarted(agentID: h.agent)
        await drain(h.service, h.agent)
        for path in paths { try repo.write(path, "changed \(path)\n") }
        h.service.turnSettled(agentID: h.agent)
        await drain(h.service, h.agent)
        h.service.turnStore.flush()
        let turn = try #require(h.service.turns(agentID: h.agent).last)
        let before = try repo.state()
        writes.withValue { $0 = 0 }

        _ = try await h.service.undoTurn(agentID: h.agent, turnID: turn.id)
        h.service.turnStore.flush()
        #expect(writes.current == 2 * paths.count + 1, "one before/after each file, then one final checkpoint")
        for path in paths { #expect(repo.read(path) == "original \(path)\n") }
        _ = try await h.service.redoTurn(agentID: h.agent, turnID: turn.id)
        h.service.turnStore.flush()
        #expect(writes.current == 2 * (2 * paths.count + 1))
        try repo.expectUnchanged(since: before)
        let persisted = try JSONDecoder().decode([String: [TurnRecord]].self,
            from: Data(contentsOf: h.service.directory.appendingPathComponent("turns.json")))
        #expect(persisted.filter { $0.key != h.agent.rawValue } == unrelated)
        #expect(persisted[h.agent.rawValue]?.last?.turn.state == .ready)
        #expect(persisted[h.agent.rawValue]?.last?.recovery == nil)
    }

    @Test func aCheckpointWaitsForPendingSavesWithoutHoldingTheRecordLock() async throws {
        let root = try makeScratchDirectory("turn-checkpoint-order")
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("turns.json")
        let store = TurnStore(url: url)
        let first = AgentID(), second = AgentID()
        let firstRecord = TurnRecord(turn: ChangesTurn(startedAt: 1, state: .ready), cwd: root.path)
        let secondRecord = TurnRecord(turn: ChangesTurn(startedAt: 2, state: .ready), cwd: root.path)
        let writes = Locked<[[String: [TurnRecord]]]>([])
        let (started, signal) = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        store.beforeWrite = { snapshot in
            let first = writes.withValue { $0.append(snapshot); return $0.count == 1 }
            if first { signal.yield(()); release.wait() }
        }
        defer { release.signal(); signal.finish(); store.flush() }
        store.update(first) { $0 = [firstRecord] }
        var iterator = started.makeAsyncIterator()
        _ = await iterator.next()
        let completed = Locked(false)
        let checkpoint = Task.detached {
            try store.updateAndCheckpoint(second) { $0 = [secondRecord] }
            completed.withValue { $0 = true }
        }
        // This is a memory read while the older filesystem write is held, not a timing budget.
        try await eventually("checkpoint mutation visible before waiting for the pending save") { store.latest(second) == secondRecord }
        #expect(!completed.current && writes.current.count == 1)
        store.update(first) { $0[0].turn.prompt = "later asynchronous capture" }
        release.signal()
        try await checkpoint.value
        store.flush()
        #expect(writes.current.count == 3, "the older save, the checkpoint, and the later ordinary save all remain")
        #expect(writes.current.first == [first.rawValue: [firstRecord]])
        let persisted = try JSONDecoder().decode([String: [TurnRecord]].self, from: Data(contentsOf: url))
        #expect(persisted[first.rawValue] == store.all(first) && persisted[second.rawValue] == [secondRecord])
        let restarted = TurnStore(url: url)
        #expect(restarted.all(first) == store.all(first) && restarted.all(second) == [secondRecord])
    }

    @Test func aFailedCheckpointBlocksTheNextFileAndCanRetryFromTheLastWrittenJournal() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "original a\n", "b.txt": "original b\n"])
        let h = try ChangesHarness(repo: repo)
        defer {
            h.service.turnStore.flush()
            try? FileManager.default.removeItem(at: repo.url)
            try? FileManager.default.removeItem(at: h.directory)
        }
        let failing = Locked(true)
        let failures = Locked(0)
        let agent = h.agent
        h.service.turnStore.beforeWrite = { snapshot in
            if snapshot[agent.rawValue]?.last?.recovery?.inFlight == "b.txt", failing.current {
                failures.withValue { $0 += 1 }
                throw CocoaError(.fileWriteNoPermission)
            }
        }
        h.service.turnStarted(agentID: agent)
        await drain(h.service, agent)
        try repo.write("a.txt", "changed a\n")
        try repo.write("b.txt", "changed b\n")
        h.service.turnSettled(agentID: agent)
        await drain(h.service, agent)
        h.service.turnStore.flush()
        let turn = try #require(h.service.turns(agentID: agent).last)
        let index = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))

        let failure = await #expect(throws: ChangesError.self) { _ = try await h.service.undoTurn(agentID: agent, turnID: turn.id) }
        #expect(failure?.code == ChangesError.gitFailed && failure?.message.contains("partially applied") == true)
        #expect(failures.current == 2, "the pre-write checkpoint and attempted failure journal both report the write failure")
        #expect(repo.read("a.txt") == "original a\n" && repo.read("b.txt") == "changed b\n")
        h.service.turnStore.flush()
        let persisted = try JSONDecoder().decode([String: [TurnRecord]].self,
            from: Data(contentsOf: h.service.directory.appendingPathComponent("turns.json")))
        #expect(persisted[agent.rawValue]?.last?.recovery?.completed == ["a.txt"])
        #expect(persisted[agent.rawValue]?.last?.recovery?.inFlight == nil)

        failing.withValue { $0 = false }
        let restarted = ChangesService(directory: h.service.directory, trash: h.service.trash)
        restarted.agentContext = { _ in ChangesService.AgentContext(cwd: repo.path) }
        let retried = try await restarted.undoTurn(agentID: agent, turnID: turn.id)
        #expect(retried.state == .undone && repo.read("b.txt") == "original b\n")
        _ = try await restarted.redoTurn(agentID: agent, turnID: turn.id)
        #expect(repo.read("a.txt") == "changed a\n" && repo.read("b.txt") == "changed b\n")
        #expect(try Data(contentsOf: repo.url.appendingPathComponent(".git/index")) == index)
    }

    @Test func anUnreadableChangedFileCannotBeMistakenForTheTurnSnapshot() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "start\n"])
        let h = try ChangesHarness(repo: repo)
        h.service.turnStarted(agentID: h.agent)
        await drain(h.service, h.agent)
        try repo.write("a.txt", "turn edit\n")
        h.service.turnSettled(agentID: h.agent)
        await drain(h.service, h.agent)
        let turn = try #require(h.service.turns(agentID: h.agent).last)
        try repo.write("a.txt", "user edit that must survive\n")
        let before = try repo.state()
        let path = repo.url.appendingPathComponent("a.txt").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }
        try #require(!FileManager.default.isReadableFile(atPath: path), "requires an unprivileged test process")

        await #expect(throws: ChangesError.self) { _ = try await h.service.undoTurn(agentID: h.agent, turnID: turn.id) }

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        try repo.expectUnchanged(since: before)
        #expect(h.service.turns(agentID: h.agent).last?.state == .ready)
    }

    @Test(arguments: [false, true])
    func aPartialUndoSurvivesRestartAndRetriesWithoutAcceptingLaterEdits(changeAfterFailure: Bool) async throws {
        let repo = try ChangesRepo(files: ["a.txt": "original\n"])
        let directory = try makeScratchDirectory("recovery")
        let trash = directory.appendingPathComponent("Trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let fail = Locked(true)
        let move: ChangesService.Trash = { url in
            if url.lastPathComponent == "z2.txt", fail.withValue({ $0 }) { throw CommandFailure("trash", "injected failure") }
            try FileManager.default.moveItem(at: url, to: trash.appendingPathComponent(url.lastPathComponent))
        }
        let service = ChangesService(directory: directory, trash: move)
        let agent = AgentID()
        service.agentContext = { _ in ChangesService.AgentContext(cwd: repo.path) }
        service.turnStarted(agentID: agent)
        await drain(service, agent)
        try repo.write("a.txt", "turn edit\n")
        try repo.write("z1.txt", "new one\n")
        try repo.write("z2.txt", "new two\n")
        service.turnSettled(agentID: agent)
        await drain(service, agent)
        let turn = try #require(service.turns(agentID: agent).last)
        let index = try Data(contentsOf: repo.url.appendingPathComponent(".git/index"))

        let failure = await #expect(throws: ChangesError.self) { _ = try await service.undoTurn(agentID: agent, turnID: turn.id) }

        #expect(failure?.message.contains("partially applied") == true)
        #expect(repo.read("a.txt") == "original\n" && repo.read("z1.txt") == nil && repo.read("z2.txt") == "new two\n")
        service.turnStore.flush()
        let restarted = ChangesService(directory: directory, trash: move)
        #expect(restarted.turns(agentID: agent).last?.reason?.contains("partially applied") == true)
        fail.withValue { $0 = false }
        if changeAfterFailure {
            try repo.write("a.txt", "later user edit\n")
            let before = try repo.state()
            let error = await #expect(throws: ChangesError.self) { _ = try await restarted.undoTurn(agentID: agent, turnID: turn.id) }
            #expect(error?.code == ChangesError.changedSince && error?.files == ["a.txt"])
            try repo.expectUnchanged(since: before)
        } else {
            let result = try await restarted.undoTurn(agentID: agent, turnID: turn.id)
            #expect(result.state == .undone && result.reason == nil && result.canRedo)
            #expect(repo.read("a.txt") == "original\n" && repo.read("z2.txt") == nil)
            _ = try await restarted.redoTurn(agentID: agent, turnID: turn.id)
            #expect(repo.read("a.txt") == "turn edit\n" && repo.read("z1.txt") == "new one\n" && repo.read("z2.txt") == "new two\n")
        }
        #expect(try Data(contentsOf: repo.url.appendingPathComponent(".git/index")) == index)
    }

    /// The next turn ends the last one's Undo; the engine's turns and their Undo also reach a
    /// remote client, which falls back to nothing it does not know.
    @Test func turnsAndUndoTravelTheRemoteProtocol() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "one\n"])
        try "tool-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        let remote = try RemoteHost()
        defer { remote.stop() }
        let pi = try await PiAgent.launch(on: remote.host, cwd: repo.url)
        let idle = try await pi.ready()
        #expect(try await pi.send("tools:1 edit", from: idle).failureCode == nil)
        let changes = remote.server.changes
        try await eventually("the turn's baseline") { changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        try repo.write("a.txt", "one\ntwo\n")
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-1").path, contents: nil)
        try await eventually("the turn to end") { changes.turns(agentID: pi.agent.id).last?.state == .ready }

        let client = try await remote.typed()
        #expect(client.capabilities.contains(RemoteProtocol.changesCapability))
        guard case .changesOverview(let overview) = try await client.agentQuery(agentID: pi.agent.id, query: .changesOverview()) else {
            Issue.record("expected an overview"); return
        }
        #expect(overview.lastTurn?.fileCount == 1 && overview.entries.first?.files == 1)
        guard case .changesList(let list) = try await client.agentQuery(agentID: pi.agent.id, query: .changesList(scope: .lastTurn, options: ChangesOptions())) else {
            Issue.record("expected a list"); return
        }
        #expect(list.summary == ["M a.txt"])
        guard case .changesFile(let file) = try await client.agentQuery(
            agentID: pi.agent.id, query: .changesFile(revision: list.revision, path: "a.txt", oldPath: nil, options: ChangesOptions())) else {
            Issue.record("expected a file"); return
        }
        #expect(file.file.hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["two"])
        let turnID = try #require(list.comparison.turn?.id)
        guard case .changesTurn(let undone) = try await client.agentQuery(agentID: pi.agent.id, query: .changesUndoTurn(turnID: turnID)) else {
            Issue.record("expected the undone turn"); return
        }
        #expect(undone.state == .undone && repo.read("a.txt") == "one\n")
        await #expect(throws: RemoteHostClientError.self) {
            _ = try await client.agentQuery(agentID: pi.agent.id, query: .changesFile(revision: ChangesRevision(old: "HEAD", new: "HEAD"),
                                                                                     path: "a.txt", oldPath: nil, options: ChangesOptions()))
        }

        // The next turn ends the undone one's Redo.
        let settled = try await pi.snapshot("the first turn to settle") { !$0.running }
        #expect(try await pi.send("tools:1 again", from: settled).failureCode == nil)
        try await eventually("the second turn's baseline") { changes.turnStore.latest(pi.agent.id)?.turn.id != turnID && changes.turnStore.latest(pi.agent.id)?.startTree != nil }
        #expect(changes.turns(agentID: pi.agent.id).first { $0.id == turnID }?.canRedo == false)
        FileManager.default.createFile(atPath: repo.url.appendingPathComponent("tool-2").path, contents: nil)
    }

    // MARK: Agents sharing a checkout

    /// Two stub pis in one checkout, each playing a script held on gate files in the checkout.
    struct Shared {
        let host: ScratchServer
        let repo: ChangesRepo
        let a: PiAgent
        let b: PiAgent
        var changes: ChangesService { host.server.changes }

        func turns(_ pi: PiAgent) -> [ChangesTurn] { changes.turns(agentID: pi.agent.id) }

        func open(_ gate: String) {
            FileManager.default.createFile(atPath: repo.url.appendingPathComponent("gate-\(gate)").path, contents: nil)
        }

        /// Sends `prompt` and waits for the turn's baseline.
        func start(_ pi: PiAgent, _ prompt: String) async throws {
            let idle = try await pi.snapshot("the agent to bootstrap") { !$0.piSessionID.isEmpty && $0.supportedActions.contains("send") }
            let before = changes.turnStore.all(pi.agent.id).count
            #expect(try await pi.send(prompt, from: idle).failureCode == nil)
            try await eventually("the baseline of \(prompt)") {
                let records = changes.turnStore.all(pi.agent.id)
                return records.count == before + 1 && records.last?.startTree != nil
            }
        }

        /// Waits until the thread shows the `write` call as done: the engine has heard it.
        func calls(_ pi: PiAgent, _ count: Int) async throws {
            _ = try await pi.snapshot("\(count) write call(s) done") {
                ($0.provisional + $0.messages).filter { $0.toolName == "write" && $0.status == "complete" }.count >= count
            }
        }

        func settled(_ pi: PiAgent) async throws -> ChangesTurn {
            try await eventually("the turn to end") { turns(pi).last?.state == .ready }
            return try #require(turns(pi).last)
        }
    }

    static func write(_ path: String) -> [String: Any] {
        ["tool": ["toolName": "write", "arguments": ["path": path, "content": "x\n"], "content": [["type": "text", "text": "ok"]]]]
    }

    static func hold(_ gate: String) -> [String: Any] { ["wait": "gate-" + gate] }

    /// Two agents in a repository of `files`, playing `prompts` (the stub's `project-script.json`).
    static func sharedCheckout(files: [String: String], prompts: [String: [[String: Any]]]) async throws -> Shared {
        let repo = try ChangesRepo(files: files)
        try "project-script.json\ngate-*\n".write(to: repo.url.appendingPathComponent(".git/info/exclude"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["prompts": prompts]).write(to: repo.url.appendingPathComponent("project-script.json"))
        let host = try ScratchServer.fresh()
        let a = try await PiAgent.launch(on: host, cwd: repo.url)
        let b = try await PiAgent.launch(on: host, cwd: repo.url)
        return Shared(host: host, repo: repo, a: a, b: b)
    }

    /// Both agents write in one checkout at once, and so does the person (c.txt, which no agent
    /// names). Each turn lists, counts and undoes only the files its own calls named.
    @Test func twoAgentsInOneCheckoutEachRecordOnlyTheirOwnFilesAndUndoLeavesTheOthers() async throws {
        let t = try await Self.sharedCheckout(files: ["a.txt": "a\n", "b.txt": "b\n"], prompts: [
            "edit a": [Self.hold("a-edit"), Self.write("a.txt"), Self.hold("a-end")],
            "edit b": [Self.hold("b-edit"), Self.write("b.txt"), Self.hold("b-end")],
        ])
        defer { t.host.stop() }
        try await t.start(t.a, "edit a")
        try await t.start(t.b, "edit b")
        let index = try Data(contentsOf: t.repo.url.appendingPathComponent(".git/index"))
        try t.repo.write("a.txt", "a edited\n")
        try t.repo.write("b.txt", "b edited\n")
        try t.repo.write("c.txt", "nobody named me\n")
        t.open("a-edit")
        t.open("b-edit")
        try await t.calls(t.a, 1)
        try await t.calls(t.b, 1)

        t.open("a-end")
        let first = try await t.settled(t.a)
        #expect(first.files.map(\.path) == ["a.txt"] && first.fileCount == 1 && first.canUndo)
        let thread = try await t.a.snapshot("the turn in the thread") { $0.turnChanges?.last?.state == .ready }
        #expect(thread.turnChanges?.last?.files.map(\.path) == ["a.txt"] && thread.turnChanges?.last?.canUndo == true)
        #expect(try await t.changes.list(agentID: t.a.agent.id, scope: .lastTurn).summary == ["M a.txt"])

        let undone = try await t.changes.undoTurn(agentID: t.a.agent.id, turnID: first.id)
        #expect(undone.state == .undone && undone.title == "Undid the agent\u{2019}s edits to 1 file")
        #expect(t.repo.read("a.txt") == "a\n")
        #expect(t.repo.read("b.txt") == "b edited\n" && t.repo.read("c.txt") == "nobody named me\n")

        t.open("b-end")
        let second = try await t.settled(t.b)
        #expect(second.files.map(\.path) == ["b.txt"] && second.canUndo)
        let redone = try await t.changes.redoTurn(agentID: t.a.agent.id, turnID: first.id)
        #expect(redone.state == .ready)
        #expect(t.repo.read("a.txt") == "a edited\n" && t.repo.read("b.txt") == "b edited\n" && t.repo.read("c.txt") == "nobody named me\n")
        #expect(try Data(contentsOf: t.repo.url.appendingPathComponent(".git/index")) == index)
    }

    /// A file both agents named is on neither card, and neither Undo touches it.
    @Test func bothAgentsNamingOneFileLeaveItOutOfBothUndos() async throws {
        let t = try await Self.sharedCheckout(files: ["a.txt": "a\n", "b.txt": "b\n", "shared.txt": "s\n"], prompts: [
            "edit a": [Self.hold("a-edit"), Self.write("a.txt"), Self.write("shared.txt"), Self.hold("a-end")],
            "edit b": [Self.hold("b-edit"), Self.write("b.txt"), Self.write("shared.txt"), Self.hold("b-end")],
        ])
        defer { t.host.stop() }
        try await t.start(t.a, "edit a")
        try await t.start(t.b, "edit b")
        try t.repo.write("a.txt", "a edited\n")
        try t.repo.write("b.txt", "b edited\n")
        try t.repo.write("shared.txt", "s edited by both\n")
        t.open("a-edit")
        t.open("b-edit")
        try await t.calls(t.a, 2)
        try await t.calls(t.b, 2)

        t.open("a-end")
        let first = try await t.settled(t.a)
        #expect(first.files.map(\.path) == ["a.txt"])
        _ = try await t.changes.undoTurn(agentID: t.a.agent.id, turnID: first.id)
        #expect(t.repo.read("a.txt") == "a\n" && t.repo.read("shared.txt") == "s edited by both\n" && t.repo.read("b.txt") == "b edited\n")

        t.open("b-end")
        let second = try await t.settled(t.b)
        #expect(second.files.map(\.path) == ["b.txt"])
    }

    /// Undo puts files back while another agent's turn runs: that turn did not write them.
    @Test func anUndoDuringAnotherAgentsTurnIsNotPartOfThatTurn() async throws {
        let t = try await Self.sharedCheckout(files: ["a.txt": "a\n", "b.txt": "b\n"], prompts: [
            "edit a": [Self.hold("a-edit"), Self.write("a.txt")],
            "edit b": [Self.hold("b-edit"), Self.write("b.txt")],
        ])
        defer { t.host.stop() }
        try await t.start(t.a, "edit a")
        try t.repo.write("a.txt", "a edited\n")
        t.open("a-edit")
        let first = try await t.settled(t.a)
        #expect(first.files.map(\.path) == ["a.txt"])

        try await t.start(t.b, "edit b")
        _ = try await t.changes.undoTurn(agentID: t.a.agent.id, turnID: first.id)
        try t.repo.write("b.txt", "b edited\n")
        t.open("b-edit")
        let second = try await t.settled(t.b)
        #expect(second.files.map(\.path) == ["b.txt"], "A's Undo is not B's work")
        #expect(t.repo.read("a.txt") == "a\n")
    }

    // MARK: Writers the engine hears late or from elsewhere

    /// The engine on its own with a second agent, `other`, in the same checkout: it is named
    /// "Fix flaky tests" and hears its calls through the same entry points the server uses.
    struct Pair {
        let h: ChangesHarness
        let repo: ChangesRepo
        let other = AgentID()
        var service: ChangesService { h.service }
        var agent: AgentID { h.agent }

        init(files: [String: String]) throws {
            repo = try ChangesRepo(files: files)
            h = try ChangesHarness(repo: repo)
            let context = ChangesService.AgentContext(cwd: repo.path)
            let other = other
            h.service.agentContext = { _ in context }
            h.service.agentName = { $0 == other ? "Fix flaky tests" : nil }
        }

        /// `agent` edits `path` and names it, as pi reports a call.
        func edit(_ agent: AgentID, _ path: String, id: String, text: String, ok: Bool = true) throws {
            try repo.write(path, text)
            service.callStarted(agentID: agent, callID: id, path: path)
            service.callEnded(agentID: agent, callID: id, ok: ok)
        }

        func settle() async throws -> ChangesTurn {
            service.turnSettled(agentID: agent)
            await ChangesTurnTests.drain(service, agent)
            return try #require(service.turns(agentID: agent).last)
        }
    }

    /// A writer whose event reaches the engine after the card showed re-cuts the card, and an
    /// Undo that runs before the card has heard of it refuses, naming the thread, and writes nothing.
    @Test func aLateWriterCorrectsTheTurnAndUndoRefuses() async throws {
        let p = try Pair(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let started = ChangesService.nowMs()
        p.service.turnStarted(agentID: p.agent, at: started)
        await Self.drain(p.service, p.agent)
        try p.edit(p.agent, "a.txt", id: "mine", text: "a edited\n")
        try p.edit(p.agent, "b.txt", id: "mine-too", text: "b edited\n")
        let turn = try await p.settle()
        #expect(turn.files.map(\.path) == ["a.txt", "b.txt"] && turn.canUndo, "nobody else wrote: the turn is solo")
        let before = try p.repo.state()

        // The other thread's call lands in the log without the usual flag to re-cut: only Undo can notice.
        p.service.writers.withValue { _ = $0.startCall(id: "theirs", agent: p.other, cwd: p.repo.path, path: "a.txt", receivedAt: started + 100) }
        let error = await #expect(throws: ChangesError.self) { _ = try await p.service.undoTurn(agentID: p.agent, turnID: turn.id) }
        #expect(error?.code == ChangesError.invalid)
        #expect(error?.message == "Didn’t undo: “Fix flaky tests” also edited a.txt during this turn. Nothing was touched.")
        #expect(error?.files == ["a.txt"])
        try p.repo.expectUnchanged(since: before)
        let corrected = try #require(p.service.turns(agentID: p.agent).last)
        #expect(corrected.files.map(\.path) == ["b.txt"] && corrected.fileCount == 1 && corrected.canUndo && corrected.state == .ready)
        #expect(try await p.service.list(agentID: p.agent, scope: .lastTurn).summary == ["M b.txt"])

        _ = try await p.service.undoTurn(agentID: p.agent, turnID: turn.id)
        #expect(p.repo.read("b.txt") == "b\n" && p.repo.read("a.txt") == "a edited\n")
    }

    /// The same writer, announced the usual way, corrects the card without anyone asking.
    @Test func aWriterThatArrivesAfterTheCardShowedDropsTheFileItNamed() async throws {
        let p = try Pair(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let started = ChangesService.nowMs()
        p.service.turnStarted(agentID: p.agent, at: started)
        await Self.drain(p.service, p.agent)
        try p.edit(p.agent, "a.txt", id: "mine", text: "a edited\n")
        try p.edit(p.agent, "b.txt", id: "mine-too", text: "b edited\n")
        let published = Locked<[[ChangesTurn]]>([])
        p.service.onTurnsChanged = { _, turns in published.withValue { $0.append(turns) } }
        let turn = try await p.settle()
        #expect(turn.fileCount == 2)

        p.service.callStarted(agentID: p.other, callID: "theirs", path: "b.txt", at: started + 100)
        try await eventually("the card to drop b.txt") { p.service.turns(agentID: p.agent).last?.files.map(\.path) == ["a.txt"] }
        let after = try #require(p.service.turns(agentID: p.agent).last)
        #expect(after.fileCount == 1 && after.canUndo && published.current.last?.last?.files.map(\.path) == ["a.txt"])
        _ = try await p.service.undoTurn(agentID: p.agent, turnID: turn.id)
        #expect(p.repo.read("a.txt") == "a\n" && p.repo.read("b.txt") == "b edited\n")
    }

    /// A deleted agent's edits stay on record: the turn they overlapped keeps leaving them out.
    @Test func aDeletedAgentsLeftoverEditsKeepAnOverlappingTurnShared() async throws {
        let p = try Pair(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let started = ChangesService.nowMs()
        p.service.turnStarted(agentID: p.agent, at: started)
        await Self.drain(p.service, p.agent)
        try p.edit(p.agent, "a.txt", id: "mine", text: "a edited\n")
        try p.edit(p.agent, "b.txt", id: "mine-too", text: "b edited\n")
        p.service.callStarted(agentID: p.other, callID: "theirs", path: "b.txt", at: started + 100)
        p.service.agentEnded(p.other)
        let turn = try await p.settle()
        #expect(turn.files.map(\.path) == ["a.txt"])
    }

    /// pi resolves an absolute path wherever the agent works, so an agent in another checkout can
    /// write here: the turn it overlapped is shared, and the file it named is not that turn's.
    @Test func anotherAgentsEditFromOutsideTheCheckoutMakesTheTurnShared() async throws {
        let repo = try ChangesRepo(files: ["a.txt": "a\n", "x.txt": "x\n"])
        let elsewhere = try ChangesRepo()
        let h = try ChangesHarness(repo: repo)
        let other = AgentID()
        let inRepo = ChangesService.AgentContext(cwd: repo.path), inElsewhere = ChangesService.AgentContext(cwd: elsewhere.path)
        h.service.agentContext = { $0 == other ? inElsewhere : inRepo }
        h.service.turnStarted(agentID: h.agent)
        await Self.drain(h.service, h.agent)
        try repo.write("a.txt", "a edited\n")
        try repo.write("x.txt", "x edited by the other checkout's agent\n")
        h.service.callStarted(agentID: h.agent, callID: "mine", path: "a.txt")
        h.service.callEnded(agentID: h.agent, callID: "mine", ok: true)
        h.service.callStarted(agentID: other, callID: "theirs", path: repo.path + "/x.txt")
        h.service.callEnded(agentID: other, callID: "theirs", ok: true)
        h.service.turnSettled(agentID: h.agent)
        await Self.drain(h.service, h.agent)
        let turn = try #require(h.service.turns(agentID: h.agent).last)
        #expect(turn.files.map(\.path) == ["a.txt"] && turn.canUndo)

        _ = try await h.service.undoTurn(agentID: h.agent, turnID: turn.id)
        #expect(repo.read("a.txt") == "a\n" && repo.read("x.txt") == "x edited by the other checkout's agent\n")
    }

    /// A shared turn whose only changes came from bash, or from a call that failed, owns nothing:
    /// its card goes and Undo has nothing to take back.
    @Test func aSharedTurnWithNothingOfItsOwnIsRecordedWithNoFiles() async throws {
        let p = try Pair(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let started = ChangesService.nowMs()
        p.service.turnStarted(agentID: p.agent, at: started)
        p.service.turnStarted(agentID: p.other, at: started)
        await Self.drain(p.service, p.agent)
        try p.repo.write("a.txt", "a edited by bash\n")
        try p.edit(p.agent, "b.txt", id: "failed", text: "b edited\n", ok: false)
        let turn = try await p.settle()
        #expect(turn.state == .ready && turn.fileCount == 0 && turn.files.isEmpty && !turn.canUndo)
        #expect(try await p.service.list(agentID: p.agent, scope: .lastTurn).files.isEmpty)
        #expect(p.repo.read("a.txt") == "a edited by bash\n")
    }

    /// What Shepherd writes for the person while a turn runs is not that turn's, even when the
    /// turn is otherwise solo and owns what bash wrote.
    @Test func aTurnNeverOwnsWhatShepherdWroteForThePersonWhileItRan() async throws {
        let p = try Pair(files: ["a.txt": "a\n", "b.txt": "b\n"])
        let repository = try p.service.repository(p.repo.path)
        let span = p.service.beginWrite(repository, paths: ["a.txt"])
        p.service.turnStarted(agentID: p.agent)
        await Self.drain(p.service, p.agent)
        try p.repo.write("a.txt", "a put back by Shepherd\n")
        try p.repo.write("b.txt", "b edited by the agent\n")
        p.service.endWrite(span)
        let turn = try await p.settle()
        #expect(turn.files.map(\.path) == ["b.txt"], "a solo turn owns what bash wrote, but not what Shepherd wrote for the person")
    }
}
