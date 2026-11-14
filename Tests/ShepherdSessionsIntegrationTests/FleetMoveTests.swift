import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// A thread moves from one Mac to another (`fleet.move.v1`) between two real scratch hosts that share an origin, each with its own pi home
/// and a stub pi: the conversation and the worktree arrive intact, the thread resumes on the other Mac with its own id, the Mac it left keeps
/// a tombstone nothing resumes, and a move that doesn't finish leaves exactly one live copy.
@Suite("Fleet move", .mainActorExclusive)
@MainActor
struct FleetMoveTests {
    typealias Mac = FleetDispatchTests.Mac
    static let branch = "perf/checkout-ci"

    // MARK: Fixtures

    /// A thread of `mac` working in a worktree on `branch`, with a conversation of `messages` entries in its pi session.
    static func thread(on mac: Mac, branch: String = FleetMoveTests.branch, name: String = "Speed up checkout CI", messages: Int = 4) async throws -> (agent: Agent, worktree: URL) {
        let path = try GitWorktree.add(repo: mac.folder.path, branch: branch, from: "HEAD")
        let id = AgentID()
        let pane = LeafPane(cwd: path, agentID: id)
        let tab = ShepherdCore.Tab(spaceID: mac.space.id, order: 0, layout: .leaf(pane))
        let agent = Agent(id: id, name: name, spaceID: mac.space.id, tabID: tab.id, paneID: pane.id, status: .idle, nameIsFinal: true,
                          worktreeBranch: branch, worktreeBase: "origin/main", worktreePath: path)
        try await mac.server.addAgent(agent, withTab: tab)
        try converse(id.rawValue, cwd: path, on: mac, messages: messages)
        return (agent, URL(fileURLWithPath: path))
    }

    /// Writes `messages` entries into the session pi would keep for `sessionID` in `cwd`.
    static func converse(_ sessionID: String, cwd: String, on mac: Mac, messages: Int) throws {
        let root = mac.server.pi.sessionsRoot
        PiSessionFile.seedIfMissing(sessionID: sessionID, cwd: cwd, sessionsRoot: root)
        let file = try #require(PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: root))
        var text = try String(contentsOf: file, encoding: .utf8)
        var parent = "null"
        for index in 0..<messages {
            let role = index % 2 == 0 ? "user" : "assistant"
            let id = "m\(index)"
            let words = index % 2 == 0 ? "Checkout CI takes 14 minutes, find what is slow (\(index))." : "Two thirds of it is fixtures rebuilt per file (\(index))."
            text += #"{"type":"message","id":"\#(id)","parentId":\#(parent == "null" ? "null" : "\"\(parent)\""),"timestamp":"2026-11-07T10:0\#(index):00.000Z","message":{"role":"\#(role)","content":[{"type":"text","text":"\#(words)"}],"timestamp":\#(1_000 + index)}}"# + "\n"
            parent = id
        }
        try text.write(to: file, atomically: true, encoding: .utf8)
    }

    /// The conversation file pi keeps for `sessionID` in `cwd` on `mac`, as lines.
    static func conversation(_ sessionID: String, cwd: String, on mac: Mac) throws -> [String] {
        let file = try #require(PiSessionFile.file(sessionID: sessionID, cwd: cwd, sessionsRoot: mac.server.pi.sessionsRoot), "no session file for \(sessionID) in \(cwd)")
        return try String(contentsOf: file, encoding: .utf8).split(separator: "\n").map(String.init)
    }

    /// Changes of every kind in a worktree: an unpushed commit, an edit, an untracked file, an ignored one.
    static func work(in folder: URL) throws {
        try FleetSnapshotTransferTests.write("# The guide\n", to: "docs/guide.md", in: folder)
        try git(["add", "docs/guide.md"], in: folder)
        try git(["commit", "-qm", "guide"], in: folder)
        try FleetSnapshotTransferTests.write("# acme-web\nedited after the commit\n", to: "README.md", in: folder)
        try FleetSnapshotTransferTests.write("take notes\n", to: "NOTES.md", in: folder)
        try FleetSnapshotTransferTests.write("API_KEY=made-up-value\n", to: ".env", in: folder)
    }

    static let ignores = FleetSnapshotTransferTests.ignores

    static func pair(checkoutB: Bool = true) async throws -> (a: Mac, b: Mac, origin: FleetDispatchTests.Origin) {
        try await FleetDispatchTests.pair(originExtra: [".gitignore": ignores], checkoutB: checkoutB, isolatedPi: true)
    }

    /// Asks `mac` to move `agent` to the Mac named `name`; answers the record it made.
    @discardableResult
    static func move(_ agent: AgentID, from mac: Mac, to name: String, when: FleetMoveRequest.When = .now, id: UUID = UUID()) async throws -> FleetDispatchRecord {
        try #require(try await mac.local.fleetAction(.moveThread(FleetMoveRequest(moveID: id, agentID: agent, host: name, when: when))).dispatch)
    }

    static func moves(_ mac: Mac) -> [FleetDispatchRecord] { mac.sent().filter { $0.kind == .move } }
    static func copy(of agent: AgentID, on mac: Mac) -> Agent? { mac.server.state.agents.first { $0.id == agent } }

    /// Waits until the thread runs on `to`, as its record on `from` says.
    static func finish(_ id: UUID? = nil, from: Mac, timeout: Duration = .seconds(90)) async throws {
        func record() -> FleetDispatchRecord? { id.flatMap { id in from.sent().first { $0.id == id } } ?? moves(from).first }
        do {
            try await FleetDispatchTests.wait("the move to finish", timeout: timeout) {
                if record()?.state == .failed { throw WireError("the move failed: \(String(describing: record()?.failure)) \(String(describing: record()?.failureDetail))") }
                return record()?.state == .done && record()?.move?.stage == .moved
            }
        } catch {
            throw WireError("\(error); the record: \(String(describing: record().map { ($0.state, $0.move?.stage, $0.failure, $0.failureDetail, $0.snapshotProgress, $0.snapshotBytes) }))")
        }
    }

    /// Stub pi launches for `agent` in `cwd`.
    static func launches(of agent: AgentID, in cwd: String? = nil) -> [StubPi.Launch] {
        StubPi.launches().filter { $0.env["SHEPHERD_AGENT_ID"] == agent.rawValue && (cwd == nil || URL(fileURLWithPath: $0.cwd).resolvingSymlinksInPath().path == URL(fileURLWithPath: cwd ?? "").resolvingSymlinksInPath().path) }
    }

    // MARK: The headline

    @Test func anIdleThreadMovesWithItsConversationAndItsWorktreeAndResumesOnTheOtherMac() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let (agent, worktree) = try await Self.thread(on: a, messages: 6)
        try Self.work(in: worktree)
        let expected = try FleetSnapshotTransferTests.tree(of: worktree)
        let before = try Self.conversation(agent.id.rawValue, cwd: worktree.path, on: a)
        let aID = try await a.hostID()

        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        #expect(started.kind == .move && started.move?.agentID == agent.id)
        try await Self.finish(started.id, from: a)

        // The same thread, with the same id, name and branch, runs on the Mac mini and says where it came from.
        let moved = try #require(Self.copy(of: agent.id, on: b))
        #expect(moved.name == "Speed up checkout CI" && moved.worktreeBranch == Self.branch && moved.movedTo == nil)
        #expect(moved.movedFrom?.hostID == aID && moved.movedFrom?.hostName == "MacBook Pro" && moved.movedFrom?.uncommittedFiles == 2)
        let there = URL(fileURLWithPath: try #require(moved.worktreePath))
        // The worktree is the one it was, byte for byte: the commit, the edit, the new file and the ignored one.
        let built = try FleetSnapshotTransferTests.tree(of: there)
        #expect(built == expected, "differs at \(FleetSnapshotTransferTests.difference(built, expected))")
        #expect(try FleetDispatchTests.head(there) == FleetDispatchTests.head(worktree))
        #expect(try FleetSnapshotTransferTests.porcelain(there) == FleetSnapshotTransferTests.porcelain(worktree))
        #expect(try git(["branch", "--show-current"], in: there).trimmingCharacters(in: .whitespacesAndNewlines) == Self.branch)
        // The whole conversation came, in pi's own file for that folder, followed by the line that says where it went.
        let after = try Self.conversation(agent.id.rawValue, cwd: there.path, on: b)
        #expect(Array(after.dropFirst().prefix(before.count - 1)) == Array(before.dropFirst()), "every entry, in order")
        let last = try #require(after.last)
        let note = try #require(try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any])
        let noted = ((note["content"] as? [[String: Any]])?.first?["text"] as? String) ?? ""
        #expect(note["customType"] as? String == "shepherd.move" && note["display"] as? Bool == true && note["parentId"] as? String == "m5")
        #expect(noted.hasPrefix("Moved to Mac mini · ") && noted.hasSuffix(" · branch \(Self.branch), 2 uncommitted files"), "the note: \(noted)")
        // pi resumes that session on the Mac mini.
        try await eventuallyOnMain("pi to resume the conversation there") { !Self.launches(of: agent.id, in: there.path).isEmpty }
        // The Mac it left holds the tombstone, and the record says what became of the move.
        let left = try #require(Self.copy(of: agent.id, on: a))
        #expect(left.movedTo?.hostName == "Mac mini" && left.movedTo?.moveID == started.id)
        #expect(a.server.state.withoutMoved.agents.contains { $0.id == agent.id } == false, "no client is sent it")
        let record = try #require(Self.moves(a).first)
        #expect(record.move?.messages == 6 && (record.move?.transcriptBytes ?? 0) > 0 && record.move?.unpushedCommits == 1)
        #expect(Self.moves(b).isEmpty && b.taken().first?.state == .done)
        // The worktree it left is left alone.
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected)
    }

    // MARK: A turn in the way

    @Test func moveWhenItsDoneWaitsForTheTurnAndGoesWhenItEnds() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let (agent, _) = try await Self.thread(on: a)
        try a.report(agent.id, .working)
        try await FleetDispatchTests.wait("the thread to be working") { Self.copy(of: agent.id, on: a)?.status == .working }

        let started = try await Self.move(agent.id, from: a, to: "Mac mini", when: .whenDone)
        #expect(started.state == .waitingTurn && started.move?.stage == .waitingTurn && started.move?.whenDone == true)
        // Nothing was stopped, sent or tombstoned: the thread is working here, and the other Mac has heard nothing.
        #expect(Self.copy(of: agent.id, on: a)?.movedTo == nil && Self.copy(of: agent.id, on: b) == nil && b.taken().isEmpty)
        #expect(a.sent().first { $0.id == started.id }?.state == .waitingTurn)

        try a.report(agent.id, .done)
        try await Self.finish(started.id, from: a)
        #expect(Self.copy(of: agent.id, on: b) != nil && Self.copy(of: agent.id, on: a)?.movedTo != nil)
    }

    @Test func stopAndMoveStopsARunningTurnAndItsPiAndMovesTheThread() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        _ = Self.engineOf(a) { $0.moveStopGrace = 0.2 }
        let (agent, worktree) = try await Self.thread(on: a)
        // The thread's pi is live and its turn is running.
        let spawned = try #require(try await a.server.respawnAgent(AgentSpawn(agent: agent, cwd: "", settings: AgentLaunchSettings())))
        try await FleetDispatchTests.wait("pi to start") { await a.server.sessionInfo(sessionID: spawned.id)?.isAlive == true }
        try a.report(agent.id, .working)
        try await FleetDispatchTests.wait("the thread to be working") { Self.copy(of: agent.id, on: a)?.status == .working }

        let started = try await Self.move(agent.id, from: a, to: "Mac mini", when: .now)
        try await Self.finish(started.id, from: a)
        // It didn't wait for the turn, its pi on this Mac is gone, and the thread runs on the other.
        let alive = await a.server.sessionInfo(sessionID: spawned.id)?.isAlive
        #expect(alive != true)
        #expect(Self.copy(of: agent.id, on: a)?.movedTo != nil && Self.copy(of: agent.id, on: b)?.status != .working)
        #expect(Self.copy(of: agent.id, on: b)?.worktreePath.map { URL(fileURLWithPath: $0).lastPathComponent } == worktree.lastPathComponent
                || Self.copy(of: agent.id, on: b)?.worktreeBranch == Self.branch)
    }

    // MARK: The other Mac has no checkout

    @Test func aMacWithoutTheRepositoryClonesItAndTheThreadStillMovesWithItsBranch() async throws {
        let (a, b, _) = try await Self.pair(checkoutB: false)
        defer { a.stop(); b.stop() }
        try FileManager.default.createDirectory(at: b.developer, withIntermediateDirectories: true)
        let (agent, worktree) = try await Self.thread(on: a)
        try Self.work(in: worktree)
        let expected = try FleetSnapshotTransferTests.tree(of: worktree)
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await Self.finish(started.id, from: a)
        let moved = try #require(Self.copy(of: agent.id, on: b))
        let there = URL(fileURLWithPath: try #require(moved.worktreePath))
        // The Mac cloned the repository first (into its own Developer folder), then built the worktree on the thread's branch.
        let cloned = (try? FileManager.default.contentsOfDirectory(atPath: b.developer.path)) ?? []
        #expect(cloned.count == 1, "the clone: \(cloned)")
        #expect(try FleetSnapshotTransferTests.tree(of: there) == expected)
        #expect(moved.worktreeBranch == Self.branch && moved.movedFrom?.hostName == "MacBook Pro")
        #expect(b.server.state.spaces.contains { $0.repoKey == FleetDispatchTests.repoKey && URL(fileURLWithPath: $0.path).resolvingSymlinksInPath().path.hasPrefix(b.developer.resolvingSymlinksInPath().path) })
    }

    // MARK: Exactly one live copy

    @Test func aSourceThatDiesBeforeItHandsOverLeavesItsCopyLiveAndTheOtherMacDropsWhatItBuilt() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { b.stop() }
        let (agent, worktree) = try await Self.thread(on: a)
        try Self.work(in: worktree)
        // The worktree is built on the other Mac and waits there; this Mac is held at the point it would hand over.
        _ = Self.engineOf(a) { $0.holdCommit = true }
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await FleetDispatchTests.wait("the worktree to wait on the Mac mini") { b.taken().first?.move?.stage == .staged }
        #expect(Self.copy(of: agent.id, on: b) == nil, "no thread exists there until this Mac hands over")
        #expect(try git(["worktree", "list", "--porcelain"], in: b.folder).contains("perf/checkout-ci") || (try git(["branch", "--list", Self.branch], in: b.folder)).contains(Self.branch))
        let (dir, port) = (a.host.dir, a.port)
        a.stop(keepFiles: true)

        let restarted = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port, isolatedPi: true)
        defer { restarted.stop() }
        // The restarted Mac's copy is the thread, as it was; the move ended and said so to the other Mac, which dropped what it held.
        let kept = try #require(Self.copy(of: agent.id, on: restarted))
        #expect(kept.movedTo == nil)
        let ended = try #require(restarted.sent().first { $0.id == started.id })
        #expect(ended.state == .failed && ended.failure == FleetDispatchCode.restarted)
        try await FleetDispatchTests.wait("the other Mac to drop the move") {
            b.taken().first { $0.id == started.id }?.state == .cancelled
        }
        #expect(Self.copy(of: agent.id, on: b) == nil)
        try await FleetDispatchTests.wait("the other Mac's worktree and branch to go") {
            try git(["branch", "--list", Self.branch], in: b.folder).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && git(["worktree", "list", "--porcelain"], in: b.folder).components(separatedBy: "worktree ").count == 2
        }
        // One live copy in the fleet: this one.
        let live = [restarted, b].filter { mac in mac.server.state.agents.contains { $0.id == agent.id && $0.movedTo == nil } }
        #expect(live.count == 1 && live.first === restarted)
        // And its pi may start again: nothing fences it.
        #expect(try await restarted.server.respawnAgent(AgentSpawn(agent: kept, cwd: "", settings: AgentLaunchSettings())) != nil)
    }

    @Test func aSourceThatDiesAfterItHandedOverRepeatsTheHandOverAndTheThreadStartsOnTheOtherMacOnce() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { b.stop() }
        let (agent, worktree) = try await Self.thread(on: a)
        try Self.work(in: worktree)
        let expected = try FleetSnapshotTransferTests.tree(of: worktree)
        // This Mac wrote its tombstone and has not told the other yet when it goes down.
        _ = Self.engineOf(a) { $0.holdHandover = true }
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await FleetDispatchTests.wait("the tombstone to be written") { Self.copy(of: agent.id, on: a)?.movedTo != nil }
        #expect(Self.copy(of: agent.id, on: b) == nil, "the other Mac has nothing to start from yet")
        let (dir, port) = (a.host.dir, a.port)
        a.stop(keepFiles: true)

        let restarted = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port, isolatedPi: true)
        defer { restarted.stop() }
        // The tombstone survived, the move is still going, and repeating the hand over starts the thread there.
        #expect(Self.copy(of: agent.id, on: restarted)?.movedTo?.moveID == started.id)
        try await Self.finish(started.id, from: restarted)
        let moved = try #require(Self.copy(of: agent.id, on: b))
        #expect(moved.movedTo == nil && b.server.state.agents.filter { $0.id == agent.id }.count == 1)
        #expect(try FleetSnapshotTransferTests.tree(of: URL(fileURLWithPath: try #require(moved.worktreePath))) == expected)
        let live = [restarted, b].filter { mac in mac.server.state.agents.contains { $0.id == agent.id && $0.movedTo == nil } }
        #expect(live.count == 1 && live.first === b)
    }

    @Test func aMacThatRestartsWhileItHoldsTheWorktreeStillStartsTheThreadWhenTheSourceHandsOver() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop() }
        let (agent, worktree) = try await Self.thread(on: a)
        try Self.work(in: worktree)
        let expected = try FleetSnapshotTransferTests.tree(of: worktree)
        _ = Self.engineOf(a) { $0.holdCommit = true }
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await FleetDispatchTests.wait("the worktree to wait on the Mac mini") { b.taken().first?.move?.stage == .staged }
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)

        let restarted = try await Mac("Mac mini", origin: origin, dir: dir, port: port, isolatedPi: true)
        defer { restarted.stop() }
        // It kept what it built, and made no thread of it by itself.
        #expect(restarted.taken().first { $0.id == started.id }?.move?.stage == .staged && Self.copy(of: agent.id, on: restarted) == nil)
        _ = Self.engineOf(a) { $0.holdCommit = false }
        try await FleetDispatchTests.waitForReports(a, restarted)
        _ = Self.engineOf(a) { $0.linkChanged() }
        try await Self.finish(started.id, from: a)
        let moved = try #require(Self.copy(of: agent.id, on: restarted))
        #expect(try FleetSnapshotTransferTests.tree(of: URL(fileURLWithPath: try #require(moved.worktreePath))) == expected)
        #expect(Self.copy(of: agent.id, on: a)?.movedTo != nil)
    }

    @Test func aMoveThatLosesItsLinkMidTransferLeavesTheThreadWhereItWasAndTheOtherMacHoldingNothing() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { b.stop() }
        let (agent, _) = try await Self.thread(on: a)
        // The first content waits on the wire, so the move is part way when this Mac goes down.
        let gate = FleetTestGate()
        await gate.close()
        _ = Self.engineOf(a) { engine in engine.wire = { chunk in await gate.pass(); return chunk } }
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await FleetDispatchTests.wait("the conversation to be on its way") { await gate.waiting > 0 }
        let (dir, port) = (a.host.dir, a.port)
        a.stop(keepFiles: true)
        await gate.open()

        let restarted = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port, isolatedPi: true)
        defer { restarted.stop() }
        #expect(Self.copy(of: agent.id, on: restarted)?.movedTo == nil)
        #expect(restarted.sent().first { $0.id == started.id }?.state == .failed)
        try await FleetDispatchTests.wait("the other Mac to drop the move") { b.taken().first { $0.id == started.id }?.state != .preparing }
        #expect(Self.copy(of: agent.id, on: b) == nil)
        #expect(try git(["branch", "--list", Self.branch], in: b.folder).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    @Test func neitherHostResurrectsTheCopyThatMovedAfterARestart() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { b.stop() }
        let (agent, worktree) = try await Self.thread(on: a)
        let started = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await Self.finish(started.id, from: a)
        let before = Self.launches(of: agent.id, in: worktree.path).count
        let (dir, port) = (a.host.dir, a.port)
        a.stop(keepFiles: true)

        // The Mac it left restarts: the tombstone is in its saved workspace, and nothing starts the thread there.
        let restarted = try await Mac("MacBook Pro", origin: origin, dir: dir, port: port, isolatedPi: true)
        defer { restarted.stop() }
        let saved = try restarted.host.persisted()
        #expect(saved.agents.first { $0.id == agent.id }?.movedTo?.moveID == started.id)
        let tombstone = try #require(Self.copy(of: agent.id, on: restarted))
        await #expect(throws: (any Error).self) {
            _ = try await restarted.server.respawnAgent(AgentSpawn(agent: tombstone, cwd: "", settings: AgentLaunchSettings()))
        }
        restarted.server.queue.sync { restarted.server.onNativeThreadDemand?(agent.id) }
        #expect(Self.launches(of: agent.id, in: worktree.path).count == before, "no pi started for the copy that moved")
        #expect(restarted.server.state.withoutMoved.agents.contains { $0.id == agent.id } == false)

        // The Mac it went to restarts too: its copy is the only live one, and it has no tombstone.
        let (bDir, bPort) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        let again = try await Mac("Mac mini", origin: origin, dir: bDir, port: bPort, isolatedPi: true)
        defer { again.stop() }
        let live = [restarted, again].filter { mac in mac.server.state.agents.contains { $0.id == agent.id && $0.movedTo == nil } }
        #expect(live.count == 1 && live.first === again)
    }

    // MARK: Back again

    @Test func aThreadMovesBackTheSameWayAndTakesItsOldPlaceAgain() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let (agent, worktree) = try await Self.thread(on: a, messages: 4)
        let tab = try #require(Self.copy(of: agent.id, on: a)).tabID
        let out = try await Self.move(agent.id, from: a, to: "Mac mini")
        try await Self.finish(out.id, from: a)
        // The Mac mini works on it: an edit and a commit there.
        let there = URL(fileURLWithPath: try #require(Self.copy(of: agent.id, on: b)?.worktreePath))
        try FleetSnapshotTransferTests.write("# worked on the Mac mini\n", to: "docs/mini.md", in: there)
        try git(["add", "docs/mini.md"], in: there)
        try git(["commit", "-qm", "mini"], in: there)
        try FleetSnapshotTransferTests.write("scratch\n", to: "NOTES.md", in: there)
        let expected = try FleetSnapshotTransferTests.tree(of: there)

        let back = try await Self.move(agent.id, from: b, to: "MacBook Pro")
        try await Self.finish(back.id, from: b)
        // Alive again on the Mac it first left: the same agent and tab, no tombstone; the other Mac holds the tombstone now.
        let home = try #require(Self.copy(of: agent.id, on: a))
        #expect(home.movedTo == nil && home.tabID == tab && home.movedFrom?.hostName == "Mac mini")
        #expect(Self.copy(of: agent.id, on: b)?.movedTo?.hostName == "MacBook Pro")
        // The worktree it comes back in is what it was on the Mac mini, on a branch of the same name (the old worktree still holds the name,
        // which is left as it is, so the branch carries a short suffix).
        let here = URL(fileURLWithPath: try #require(home.worktreePath))
        #expect(here.path != worktree.path)
        #expect(try FleetSnapshotTransferTests.tree(of: here) == expected)
        #expect(try #require(home.worktreeBranch).hasPrefix(Self.branch))
        // The conversation carries both notes, and pi resumes it here.
        let lines = try Self.conversation(agent.id.rawValue, cwd: here.path, on: a)
        #expect(lines.filter { $0.contains("shepherd.move") }.count == 2)
        try await eventuallyOnMain("pi to resume the conversation back here") { !Self.launches(of: agent.id, in: here.path).isEmpty }
    }

    // MARK: A thread that was sent work

    @Test func aDispatchedThreadMovesAndItsResultStillReturnsToItsSender() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let c = try await Mac("Mac Studio", origin: origin, isolatedPi: true)
        defer { c.stop() }
        try await c.pair(with: a)
        try await c.pair(with: b)
        try await FleetDispatchTests.waitForReports(a, c)
        try await FleetDispatchTests.waitForReports(b, c)
        let parent = try await a.parent("Ship checkout")
        try parent.hello()
        _ = try parent.info(try await parent.dispatch("Fix the flaky payment test.", key: "move-1", title: "Fix flaky payment test", host: "Mac mini"))
        try await FleetDispatchTests.wait("the Mac mini to run the dispatched thread") { !b.dispatched.isEmpty }
        let thread = try #require(b.dispatched.first)
        try await FleetDispatchTests.wait("the sender to follow it") { a.sent().first?.state == .running && a.sent().first?.remoteAgentID == thread.id }

        // The Mac mini moves it to the Mac Studio.
        let started = try await Self.move(thread.id, from: b, to: "Mac Studio")
        try await Self.finish(started.id, from: b)
        let moved = try #require(Self.copy(of: thread.id, on: c))
        #expect(moved.dispatchedFrom?.agentID == parent.agent.id && moved.dispatchedFrom?.hostName == "MacBook Pro", "it still says who sent it, so it nests under its sender")
        // The sender follows it there.
        try await FleetDispatchTests.wait("the sender to follow the thread to the Mac Studio") { a.sent().first?.targetHostName == "Mac Studio" }
        // It works there and settles: its result goes to the parent that sent it, from the Mac Studio.
        try c.report(thread.id, .working)
        try await FleetDispatchTests.wait("the Mac Studio to see it working") { c.server.queue.sync { c.server.fleet?.dispatch.inbound.values.first { $0.record.remoteAgentID == thread.id && $0.record.kind != .move }?.startedWorking } == true }
        try c.report(thread.id, .done)
        let result = try #require(await parent.nextMessage())
        #expect(result.delivery == .task && result.text.hasPrefix("[from: Fix flaky payment test on Mac Studio, an agent, not the user."))
        try await FleetDispatchTests.wait("the sender's record to finish") { a.sent().first?.state == .done }
    }

    // MARK: Refusals

    @Test func aMoveIsRefusedWhereItWouldBreakSomethingAndLeavesTheThreadAlone() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let (agent, _) = try await Self.thread(on: a)
        func refusal(_ host: String, _ id: AgentID) async -> String? {
            do { _ = try await Self.move(id, from: a, to: host); return nil }
            catch RemoteHostClientError.rejected(let code, _) { return code }
            catch { return "\(error)" }
        }
        #expect(await refusal("No Such Mac", agent.id) == FleetDispatchCode.noSuchHost)
        #expect(await refusal("MacBook Pro", agent.id) == FleetDispatchCode.moveRefused, "it is already here")
        #expect(await refusal("Mac mini", AgentID()) == FleetDispatchCode.moveRefused, "no such thread")
        // A Mac on an older Shepherd (it doesn't list fleet.move.v1) is never sent a move.
        _ = Self.engineOf(a) { engine in engine.capabilityOverride = { _ in [RemoteProtocol.fleetCapability, RemoteProtocol.fleetDispatchCapability] } }
        #expect(await refusal("Mac mini", agent.id) == FleetDispatchCode.targetOld)
        _ = Self.engineOf(a) { $0.capabilityOverride = nil }
        // Work this thread sent to other Macs would lose its parent.
        let parent = try await a.parent("Ship checkout")
        try parent.hello()
        _ = try parent.info(try await parent.dispatch("Fix it.", key: "away", host: "Mac mini"))
        #expect(await refusal("Mac mini", parent.agent.id) == FleetDispatchCode.hasDispatches)
        // Nothing was stopped, tombstoned or sent.
        #expect(Self.copy(of: agent.id, on: a)?.movedTo == nil && Self.moves(a).isEmpty)
    }

    @Test func aMoveIdIsOneMoveWhicheverWayItIsRepeated() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let (agent, _) = try await Self.thread(on: a)
        let id = UUID()
        let first = try await Self.move(agent.id, from: a, to: "Mac mini", id: id)
        let again = try await Self.move(agent.id, from: a, to: "Mac mini", id: id)
        #expect(first.id == again.id)
        try await Self.finish(id, from: a)
        let settled = try await Self.move(agent.id, from: a, to: "Mac mini", id: id)
        #expect(settled.id == id && settled.state == .done)
        #expect(Self.moves(a).count == 1 && b.taken().count == 1)
        #expect(b.server.state.agents.filter { $0.id == agent.id }.count == 1)
    }

    static func engineOf<T>(_ mac: Mac, _ body: (FleetDispatch) -> T) -> T? { FleetSnapshotTransferTests.engine(mac, body) }
}
