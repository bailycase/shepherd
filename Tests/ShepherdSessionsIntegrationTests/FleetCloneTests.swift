import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions
import ShepherdTestKit
import ShepherdTestSupport

/// Work on any project from any Mac (slice 4f), between two real scratch hosts and scratch git repositories (a bare repository on disk is
/// "origin"). A Mac that already has a checkout of the repository binds to it; one that hasn't clones it with its own git, from origin
/// or, when origin can't be reached, from a bundle the sender makes; the snapshot then applies as for any dispatch. The clone goes only
/// at a folder that did not exist, and Stop leaves nothing behind.
@Suite("Fleet: any project on any Mac", .integrationTimeLimit, .mainActorExclusive)
@MainActor
struct FleetCloneTests {
    typealias D = FleetDispatchTests
    typealias Mac = FleetDispatchTests.Mac

    /// Two paired Macs, Mac mini without a checkout of acme/web. `edit` has the sender's uncommitted changes written before anything is sent.
    static func pair(uncommittedA: FleetUncommittedChanges = .sendThem) async throws -> (a: Mac, b: Mac, origin: D.Origin) {
        try await D.pair(originExtra: [".gitignore": FleetSnapshotTransferTests.ignores, "src/app.ts": "export const app = 1\n"], checkoutB: false, uncommittedA: uncommittedA)
    }

    static func cloneCount(_ mac: Mac) -> Int { mac.server.queue.sync { mac.server.fleet?.dispatch.cloneCount ?? 0 } }

    /// The dispatch this Mac holds as the receiver, with the folder a clone for it is being made in.
    static func inbound(_ mac: Mac) -> FleetDispatch.Inbound? { mac.server.queue.sync { mac.server.fleet?.dispatch.inbound.values.first } }

    static func send(_ parent: D.Parent, key: String = "clone", host: String = "Mac mini") async throws -> FleetDispatchInfo {
        try parent.info(try await parent.dispatch("Profile the orders import.", key: key, title: "Profile the orders import", host: host))
    }

    /// A space of `mac` for the repository (the one a clone or a finder bound), if any.
    static func space(_ mac: Mac, repoKey: String = D.repoKey) -> Space? { mac.server.state.spaces.first { $0.repoKey == repoKey } }

    static func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

    // MARK: Auto-binding

    @Test func aMacWithACheckoutUnderAnotherSpaceBindsToItAndRunsTheDispatchWithNoClone() async throws {
        // Mac mini's folder is a checkout of the repository, but nothing has given its space a key yet.
        let (a, b, _) = try await D.pair(repoKeyB: nil)
        defer { a.stop(); b.stop() }
        try git(["config", "remote.origin.pushurl", "https://github.com/acme/web.git"], in: b.folder)
        #expect(b.server.state.spaces.first?.repoKey == nil)
        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent, host: "Mac mini")
        try await D.wait("Mac mini to run the dispatched thread") { !b.dispatched.isEmpty }

        #expect(Self.cloneCount(b) == 0, "it had the repository: nothing was cloned")
        #expect(b.server.state.spaces.count == 1 && b.server.state.spaces[0].path == b.folder.path, "no second row for one folder")
        #expect(b.server.state.spaces[0].repoKey == D.repoKey, "its space is that repository now")
        let worktree = try #require(b.dispatched.first?.worktreePath)
        #expect(try git(["worktree", "list", "--porcelain"], in: b.folder).contains(URL(fileURLWithPath: worktree).lastPathComponent))
        #expect(!Self.exists(b.developer.path))
    }

    @Test func aSyncedSpaceWithNoFolderBindsItselfToACheckoutTheMacKeepsForAThread() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // Mac mini has a checkout of the repository that no space of its own uses: a thread's worktree was made from it.
        let main = b.host.dir.appendingPathComponent("code/web", isDirectory: true)
        try FileManager.default.createDirectory(at: main, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.name", "Tests"], ["config", "user.email", "tests@example.com"],
                     ["remote", "add", "origin", "git@github.com:Acme/Web.git"], ["commit", "-q", "--allow-empty", "-m", "first"]] { try git(args, in: main) }
        let worktree = b.host.dir.appendingPathComponent("worktrees/web-fix", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["worktree", "add", "-q", "-b", "fix", worktree.path], in: main)
        let elsewhere = Space(name: "scratch", path: b.host.dir.appendingPathComponent("scratch").path)
        try FileManager.default.createDirectory(atPath: elsewhere.path, withIntermediateDirectories: true)
        try await b.server.addSpace(elsewhere)
        var (agent, tab) = Fixture.agent(in: elsewhere, name: "Fix")
        agent.worktreePath = worktree.path
        try await b.server.addAgent(agent, withTab: tab)

        // The fleet's space for that repository (MacBook Pro's) has been arriving all along, and binds to it by itself.
        try await D.wait("Mac mini to bind the space to the checkout it already has") { b.server.state.spaces.contains { $0.id == a.space.id } }
        let bound = try #require(b.server.state.spaces.first { $0.id == a.space.id })
        #expect(bound.path == PiHome.canonical(main.path), "the main checkout of its thread's worktree, not the worktree: \(bound.path)")
        #expect(bound.name == a.space.name && bound.repoKey != nil)
        // The choice is recorded, with why.
        let choices = b.server.queue.sync { b.server.fleet?.dispatch.finder.choices ?? [:] }
        let choice = try #require(choices["github.com/acme/web"])
        #expect(choice.path == PiHome.canonical(main.path) && choice.how == "only")
    }

    @Test func severalCheckoutsOfOneRepoPreferTheOneASpaceUsesThenTheNewestAndTheChoiceIsKept() async throws {
        let base = try makeScratchDirectory("finder")
        func checkout(_ name: String, touched: Date) throws -> String {
            let folder = base.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for args in [["init", "-q", "-b", "main"], ["remote", "add", "origin", "git@github.com:Acme/Web.git"]] { try git(args, in: folder) }
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: folder.appendingPathComponent(".git/HEAD").path)
            return folder.path
        }
        let (old, newer, used) = (try checkout("old", touched: Date(timeIntervalSince1970: 1_000_000)), try checkout("newer", touched: Date(timeIntervalSince1970: 2_000_000)),
                                  try checkout("used", touched: Date(timeIntervalSince1970: 500_000)))
        let other = try checkout("other", touched: Date())
        try git(["remote", "set-url", "origin", "git@github.com:Acme/Other.git"], in: URL(fileURLWithPath: other))
        let finder = FleetRepoFinder(directory: base, clock: { Date(timeIntervalSince1970: 3_000_000) })

        // Without a space using one, the most recently touched wins; a folder that is another repository, or no repository, is never one.
        finder.refresh([.init(path: old, isSpace: false), .init(path: newer, isSpace: false), .init(path: other, isSpace: false), .init(path: base.path, isSpace: false)])
        #expect(finder.locate("github.com/acme/web")?.path == PiHome.canonical(newer))
        #expect(finder.choices["github.com/acme/web"]?.how == "recent")
        #expect(finder.locate("github.com/acme/other")?.path == PiHome.canonical(other) && finder.locate("github.com/acme/nowhere") == nil)
        // A space on this Mac already uses `used`: it wins even though it is the oldest.
        #expect(finder.refresh([.init(path: old, isSpace: false), .init(path: newer, isSpace: false), .init(path: used, isSpace: true)]))
        #expect(finder.locate("github.com/acme/web")?.path == PiHome.canonical(used) && finder.choices["github.com/acme/web"]?.how == "space")
        // The choice is on disk, so it reads the same after a restart.
        #expect(FleetRepoFinder(directory: base).choices["github.com/acme/web"]?.path == PiHome.canonical(used))
        // Nothing changed: nothing to say. A checkout that went away is not found.
        #expect(!finder.refresh([.init(path: old, isSpace: false), .init(path: newer, isSpace: false), .init(path: used, isSpace: true)]))
        try FileManager.default.removeItem(atPath: used)
        #expect(finder.locate("github.com/acme/web")?.path == PiHome.canonical(newer))
    }

    // MARK: Cloning

    @Test func aMacWithoutTheRepoClonesItFromOriginBindsTheSpaceAndTheSnapshotApplies() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try FileManager.default.createDirectory(at: b.developer, withIntermediateDirectories: false)
        // The sender's checkout has an edit, a new file and an ignored .env.
        try FleetSnapshotTransferTests.write("# acme-web\nedited, not committed\n", to: "README.md", in: a.folder)
        try FleetSnapshotTransferTests.write("take notes\n", to: "NOTES.md", in: a.folder)
        try FleetSnapshotTransferTests.write("API_KEY=made-up-value\n", to: ".env", in: a.folder)
        let expected = try FleetSnapshotTransferTests.tree(of: a.folder)

        let parent = try await a.parent()
        try parent.hello()
        let info = try await Self.send(parent)
        #expect(info.host == "Mac mini")
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }

        // Cloned once, into `<Developer>/web`, and bound to the sender's own space.
        #expect(Self.cloneCount(b) == 1)
        let space = try #require(Self.space(b))
        #expect(space.path == b.developer.appendingPathComponent("web").path && space.id == a.space.id && space.name == a.space.name)
        let (clonedFrom, sentFrom) = (try git(["remote", "get-url", "origin"], in: URL(fileURLWithPath: space.path)), try git(["remote", "get-url", "origin"], in: a.folder))
        #expect(clonedFrom == sentFrom, "it cloned from the sender's origin")
        // The agent sees the sender's uncommitted work, byte for byte, in its worktree.
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected)
        #expect(try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8) == "# acme-web\nedited, not committed\n")
        #expect(try String(contentsOf: worktree.appendingPathComponent(".env"), encoding: .utf8) == "API_KEY=made-up-value\n")
        #expect(try D.head(worktree) == D.head(a.folder))
        // The clone itself is clean: nothing was written into it but the worktree's registration.
        #expect(try FleetSnapshotTransferTests.porcelain(URL(fileURLWithPath: space.path)).isEmpty)
        // The records: nothing is cloning any more, and the sender saw it run.
        try await D.wait("A to follow the dispatch as running") { a.sent().first?.state == .running }
        #expect(a.sent().first?.clone == nil && b.taken().first?.clone == nil && a.sent().first?.failure == nil)
    }

    @Test func aSecondDispatchToTheSameMacReusesTheCloneAndClonesNothingAgain() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent, key: "first")
        try await D.wait("the first thread", timeout: .seconds(60)) { b.dispatched.count == 1 }
        let clone = try #require(Self.space(b)).path
        _ = try await Self.send(parent, key: "second")
        try await D.wait("the second thread", timeout: .seconds(60)) { b.dispatched.count == 2 }
        #expect(Self.cloneCount(b) == 1 && b.server.state.spaces.filter { $0.repoKey == D.repoKey }.count == 1 && Self.space(b)?.path == clone)
        #expect(try git(["worktree", "list", "--porcelain"], in: URL(fileURLWithPath: clone)).components(separatedBy: "worktree ").count == 4, "the clone and two worktrees")
    }

    @Test func aFolderAlreadyAtTheWouldBePathIsNeverTouchedTheCloneGoesUnderTheFleetsOwnFolder() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let mine = b.developer.appendingPathComponent("web", isDirectory: true)
        try FileManager.default.createDirectory(at: mine, withIntermediateDirectories: true)
        try Data("my own notes".utf8).write(to: mine.appendingPathComponent("notes.txt"))
        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent)
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }

        let space = try #require(Self.space(b))
        #expect(space.path.hasPrefix(b.host.dir.appendingPathComponent("fleet/repos").path), "under the fleet's own folder: \(space.path)")
        #expect(try FileManager.default.contentsOfDirectory(atPath: mine.path) == ["notes.txt"])
        #expect(try String(contentsOf: mine.appendingPathComponent("notes.txt"), encoding: .utf8) == "my own notes")
    }

    @Test func aThreadStartedInNewThreadOnANamedMacWithoutTheRepoClonesItThere() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let thread = FleetUserThread(spaceID: a.space.id, task: "Profile the orders import.", host: "Mac mini")
        let record = try #require(try await a.local.fleetAction(.sendThread(thread)).dispatch)
        #expect(record.kind == .userThread && record.reasonCodes.contains(FleetPlacementReason(.willClone)))
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        #expect(Self.cloneCount(b) == 1 && Self.space(b)?.id == a.space.id)
        #expect(b.dispatched.first?.dispatchedFrom?.agentID == nil, "sent by you")
    }

    // MARK: When origin can't be reached

    /// Points the sender's origin somewhere that doesn't exist, as an origin this Mac can't authenticate to is for the Mac that clones.
    static func breakOrigin(of mac: Mac) throws {
        try git(["remote", "set-url", "origin", "/no/such/place/acme-web.git"], in: mac.folder)
    }

    @Test func whenOriginCantBeReachedTheSenderSendsTheRepositoryItselfAndTheTargetClonesFromThat() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // The sender is ahead of origin, has an edit and an ignored file: all of it arrives with the repository.
        try FleetSnapshotTransferTests.write("# The guide\n", to: "docs/guide.md", in: a.folder)
        try git(["add", "docs/guide.md"], in: a.folder)
        try git(["commit", "-qm", "guide"], in: a.folder)
        try FleetSnapshotTransferTests.write("# acme-web\nedited, not committed\n", to: "README.md", in: a.folder)
        try FleetSnapshotTransferTests.write("API_KEY=made-up-value\n", to: ".env", in: a.folder)
        try Self.breakOrigin(of: a)
        let expected = try FleetSnapshotTransferTests.tree(of: a.folder)

        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent)
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }

        let space = try #require(Self.space(b))
        #expect(Self.cloneCount(b) == 2, "origin was tried first, then the bundle")
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected)
        #expect(try D.head(worktree) == D.head(a.folder))
        // The clone's origin is where the repository really is, not the bundle file it came from.
        #expect(try git(["remote", "get-url", "origin"], in: URL(fileURLWithPath: space.path)).trimmingCharacters(in: .whitespacesAndNewlines) == "/no/such/place/acme-web.git")
        #expect(try git(["log", "--format=%s", "-1", "main"], in: URL(fileURLWithPath: space.path)).trimmingCharacters(in: .whitespacesAndNewlines) == "guide")
        try await D.wait("A to follow it as running") { a.sent().first?.state == .running }
        #expect(a.sent().first?.failure == nil && a.sent().first?.clone == nil)
    }

    @Test func whenBothTheCloneAndTheBundleFailTheDispatchIsRefusedWithGitsOwnError() async throws {
        // No snapshot to carry a bundle (the setting leaves edits behind), so origin was the only way and it failed.
        let (a, b, _) = try await Self.pair(uncommittedA: .leaveBehind)
        defer { a.stop(); b.stop() }
        try Self.breakOrigin(of: a)
        let parent = try await a.parent()
        try parent.hello()
        let reply = try await parent.dispatch("Profile the orders import.", key: "both", title: "Profile the orders import", host: "Mac mini")
        _ = reply
        try await D.wait("the dispatch to end", timeout: .seconds(60)) { a.sent().first?.state == .failed }
        let record = try #require(a.sent().first)
        #expect(record.failure == FleetDispatchCode.repoMissing)
        #expect(record.failureDetail?.contains("fatal:") == true && record.failureDetail?.contains("acme-web.git") == true, "git's own words: \(record.failureDetail ?? "")")
        #expect(b.dispatched.isEmpty && Self.space(b) == nil && !Self.exists(b.developer.path))
        let repos = b.host.dir.appendingPathComponent("fleet/repos")
        #expect((try? FileManager.default.contentsOfDirectory(atPath: repos.path)) ?? [] == [], "no half checkout is left")
    }

    @Test func aSenderWithoutAnOriginNamedGetsTheCloneRefusedUnlessItCanSendTheRepository() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let aID = try await a.hostID()
        let viaA = try await b.connectAsPeer(a)
        defer { viaA.disconnect() }
        // An older sender names no repo source: the receiver has no checkout, so it refuses as it always did.
        do {
            _ = try await viaA.fleetDispatchCreate(FleetDispatchCreate(dispatchID: UUID(), task: "x", title: "x", repoKey: D.repoKey, commitSHA: origin.sha,
                                                                       from: FleetDispatchSender(hostID: aID, hostName: "MacBook Pro", agentTitle: "Ship")))
            Issue.record("a create with nothing to clone from was accepted")
        } catch RemoteHostClientError.rejected(let code, _) { #expect(code == FleetDispatchCode.repoMissing) }
    }

    // MARK: Stop

    @Test func stopDuringTheCloneEndsItAndLeavesNoHalfCheckoutAndNoSpace() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        // git, but slow: the clone is still running when Stop comes.
        let slow = try makeScratchDirectory("slow-git").appendingPathComponent("git")
        try """
        #!/bin/sh
        trap 'kill $pid 2>/dev/null; exit 143' TERM
        sleep 60 &
        pid=$!
        wait $pid
        exec /usr/bin/git "$@"
        """.write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        FleetRepoClone.git = slow.path
        defer { FleetRepoClone.git = "/usr/bin/git" }

        let parent = try await a.parent()
        try parent.hello()
        let info = try await Self.send(parent)
        var folder = ""
        try await D.wait("the clone to begin") {
            guard let entry = Self.inbound(b), let made = entry.cloneDirectory else { return false }
            folder = made
            return entry.record.clone != nil
        }
        #expect(Self.exists(folder) && b.dispatched.isEmpty)
        // The card the sender draws says it is cloning.
        try await D.wait("A to see the clone") { a.sent().first?.clone?.name == "web" }

        let stopped = try await parent.cancel(info)
        #expect(stopped.state == "cancelled")
        try await D.wait("the clone to end and its folder to go") { !Self.exists(folder) && Self.inbound(b)?.cloneDirectory == nil }
        #expect(Self.inbound(b)?.record.state == .cancelled && Self.space(b) == nil && b.dispatched.isEmpty)
        #expect(b.server.queue.sync { b.server.fleet?.dispatch.clones.isEmpty } == true)
        #expect(a.sent().first?.state == .cancelled && a.sent().first?.clone == nil)
        let repos = b.host.dir.appendingPathComponent("fleet/repos")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: repos.path)) ?? []).isEmpty)
    }

    @Test func aHostThatRestartsMidCloneRemovesTheFolderItMadeAndRegistersNothing() async throws {
        let (a, b, origin) = try await Self.pair()
        defer { a.stop() }
        let slow = try makeScratchDirectory("slow-git").appendingPathComponent("git")
        try "#!/bin/sh\nsleep 60\n".write(to: slow, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: slow.path)
        FleetRepoClone.git = slow.path
        defer { FleetRepoClone.git = "/usr/bin/git" }
        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent)
        var folder = ""
        try await D.wait("the clone to begin") {
            guard let made = Self.inbound(b)?.cloneDirectory else { return false }
            folder = made
            return true
        }
        let (dir, port) = (b.host.dir, b.port)
        b.stop(keepFiles: true)
        FleetRepoClone.git = "/usr/bin/git"
        let back = try await Mac("Mac mini", origin: origin, dir: dir, port: port, checkout: false)
        defer { back.stop() }
        try await D.wait("the host to clean up after the clone") { !Self.exists(folder) }
        #expect(Self.space(back) == nil && back.dispatched.isEmpty)
        #expect(Self.inbound(back)?.record.state == .failed && Self.inbound(back)?.cloneDirectory == nil, "nothing is resumed: the record ends")
    }
}
