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
}
