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

    /// A checkout of the repository on `mac` that no space of its own uses: a thread's worktree was made from it. Returns the main checkout and the
    /// worktree. (The space the thread lives in is another repository's.)
    static func hiddenCheckout(on mac: Mac, origin: D.Origin) async throws -> (main: URL, worktree: URL) {
        let main = mac.host.dir.appendingPathComponent("code/web", isDirectory: true)
        try FileManager.default.createDirectory(at: main.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["clone", "-q", origin.url.path, main.path], in: mac.host.dir)
        // The checkout's origin is a path on this disk; its push URL is what names the repository.
        try git(["config", "remote.origin.pushurl", "https://github.com/acme/web.git"], in: main)
        try git(["config", "user.name", "Tests"], in: main)
        try git(["config", "user.email", "tests@example.com"], in: main)
        let worktree = mac.host.dir.appendingPathComponent("worktrees/web-fix", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree.deletingLastPathComponent(), withIntermediateDirectories: true)
        try git(["worktree", "add", "-q", "-b", "fix", worktree.path], in: main)
        let elsewhere = Space(name: "scratch", path: mac.host.dir.appendingPathComponent("scratch").path, repoKey: "github.com/acme/scratch")
        try FileManager.default.createDirectory(atPath: elsewhere.path, withIntermediateDirectories: true)
        try await mac.server.addSpace(elsewhere)
        var (agent, tab) = Fixture.agent(in: elsewhere, name: "Fix")
        agent.worktreePath = worktree.path
        try await mac.server.addAgent(agent, withTab: tab)
        return (main, worktree)
    }

    @Test func aMacWithAnUnboundButFindableCheckoutRanksAsHavingTheRepoAndBindsToItWithoutCloning() async throws {
        try StubPi.installAsEngine()
        let origin = try D.makeOrigin(extra: [".gitignore": FleetSnapshotTransferTests.ignores])
        let a = try await Mac("MacBook Pro", origin: origin, busy: 90)
        let b = try await Mac("Mac mini", origin: origin, busy: 10, checkout: false)
        defer { a.stop(); b.stop() }
        let (main, _) = try await Self.hiddenCheckout(on: b, origin: origin)
        // The repository's key isn't one of Mac mini's spaces', but its finder knows the checkout, and that is what its readiness says.
        let key = D.repoKey
        try await D.wait("Mac mini's finder to know the checkout") { b.server.queue.sync { b.server.fleet?.dispatch.finder.knownKeys().contains(key) == true } }
        #expect(b.server.state.spaces.contains { $0.repoKey == key } == false, "no space of its own uses it")
        #expect(b.server.fleetLocalFacts().repoKeys.contains(key), "readiness lists what the finder can bind, not only the spaces")

        try await a.pair(with: b)
        try await D.waitForReports(a, b)
        let id = try await b.hostID()
        let held = try await a.local.fleetRead().snapshot.macs.first { $0.hostID == id }
        #expect(held?.readiness?.repoKeys.contains(key) == true, "the other Mac sees it as having the repository")

        // Auto: the Mac mini has the room, and nothing charges it for a clone.
        let parent = try await a.parent()
        try parent.hello()
        let info = try parent.info(try await parent.dispatch("Profile the orders import.", key: "findable", title: "Profile the orders import"))
        #expect(info.host == "Mac mini")
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let record = try #require(a.sent().first)
        #expect(!record.reasonCodes.contains(FleetPlacementReason(.willClone)), "no clone cost: \(record.reasonCodes)")
        #expect(Self.cloneCount(b) == 0 && b.taken().first?.clone == nil)
        // It bound to the checkout it had (its space is that folder), and the worktree is that repository's.
        let space = try #require(Self.space(b))
        #expect(space.path == PiHome.canonical(main.path) && space.id == a.space.id)
        let worktree = try #require(b.dispatched.first?.worktreePath)
        #expect(try git(["worktree", "list", "--porcelain"], in: main).contains(URL(fileURLWithPath: worktree).lastPathComponent))
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
        // A fresh clone is a plain repository: the worktree was written directly, with no `git worktree add`.
        let stats = b.server.queue.sync { b.server.fleet?.dispatch.applyStats.values.first }
        #expect(stats?.git.contains("worktree") == false, "git calls: \(stats?.git ?? [])")
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

    /// Points the sender's origin somewhere that doesn't exist, as an origin the Mac that clones can't authenticate to is for it. The push URL still
    /// names the repository, so the repository's key stays what it was.
    static func breakOrigin(of mac: Mac) throws {
        try git(["config", "remote.origin.pushurl", "https://github.com/acme/web.git"], in: mac.folder)
        try git(["remote", "set-url", "origin", "/no/such/place/acme-web.git"], in: mac.folder)
    }

    /// Takes the sender's origin away (a repository that never had a remote) and waits for the host to name it by its first commit.
    static func removeOrigin(of mac: Mac) async throws -> String {
        // The host has looked at the checkout once (that look is what a later change is measured against).
        let stamps = mac.host.dir.appendingPathComponent("fleet/repo-stamps.json")
        try await D.wait("the host to have looked at the checkout") { ((try? String(contentsOf: stamps, encoding: .utf8)) ?? "").contains(mac.space.id.rawValue) }
        try git(["remote", "remove", "origin"], in: mac.folder)
        try await D.wait("the repository to be named by its first commit") { mac.server.state.spaces.first?.repoKey.map(CanonicalRepoKey.isLocal) == true }
        return try #require(mac.server.state.spaces.first?.repoKey)
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
        try await D.wait("A to follow it as running", timeout: .seconds(90)) { a.sent().first?.state == .running }
        #expect(a.sent().first?.failure == nil && a.sent().first?.clone == nil)
    }

    @Test func aRepositoryWithNoRemoteAtAllIsSentToAMacThatHasNoCopyAndANewDispatchReusesIt() async throws {
        try StubPi.installAsEngine()
        let origin = try D.makeOrigin(extra: [".gitignore": FleetSnapshotTransferTests.ignores])
        // The sender's repository never had a remote: nothing to clone, no key from an origin.
        let a = try await Mac("MacBook Pro", origin: origin, repoKey: nil)
        let b = try await Mac("Mac mini", origin: origin, checkout: false)
        defer { a.stop(); b.stop() }
        _ = try await Self.removeOrigin(of: a)
        try await a.pair(with: b)
        try await D.waitForReports(a, b)
        try FleetSnapshotTransferTests.write("# acme-web\nedited, not committed\n", to: "README.md", in: a.folder)
        let expected = try FleetSnapshotTransferTests.tree(of: a.folder)

        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent, key: "first")
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let key = try #require(a.sent().first?.repoKey)
        #expect(CanonicalRepoKey.isLocal(key), "named by its first commit: \(key)")
        let space = try #require(Self.space(b, repoKey: key))
        #expect(space.name == a.space.name && space.id == a.space.id && Self.cloneCount(b) == 1)
        #expect(try git(["remote"], in: URL(fileURLWithPath: space.path)).isEmpty, "the bundle file it came from is not left as its origin")
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected && D.head(worktree) == D.head(a.folder))
        try await D.wait("A to follow it as running", timeout: .seconds(90)) { a.sent().first?.state == .running && a.sent().first?.clone == nil }

        // It is a copy there now: the next dispatch finds it by the same key and sends nothing of the repository.
        _ = try await Self.send(parent, key: "second")
        try await D.wait("the second thread", timeout: .seconds(60)) { b.dispatched.count == 2 }
        #expect(Self.cloneCount(b) == 1 && b.server.state.spaces.filter { $0.repoKey == key }.count == 1)
    }

    @Test func whenBothTheCloneAndTheBundleFailTheDispatchIsRefusedWithGitsOwnError() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.breakOrigin(of: a)
        // The Mac that clones has a git that can't clone at all (a broken install, say): from origin or from the bundle.
        let broken = try makeScratchDirectory("broken-git").appendingPathComponent("git")
        try "#!/bin/sh\necho 'fatal: this git can not clone' >&2\nexit 128\n".write(to: broken, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: broken.path)
        FleetRepoClone.git = broken.path
        defer { FleetRepoClone.git = "/usr/bin/git" }
        let parent = try await a.parent()
        try parent.hello()
        _ = try await parent.dispatch("Profile the orders import.", key: "both", title: "Profile the orders import", host: "Mac mini")
        try await D.wait("the dispatch to end", timeout: .seconds(60)) { a.sent().first?.state == .failed }
        let record = try #require(a.sent().first)
        #expect(record.failure == FleetDispatchCode.repoMissing)
        #expect(record.failureDetail?.contains("fatal: this git can not clone") == true, "git's own words: \(record.failureDetail ?? "")")
        #expect(Self.cloneCount(b) == 2, "origin, then the bundle")
        #expect(b.dispatched.isEmpty && Self.space(b) == nil && !Self.exists(b.developer.path))
        let repos = b.host.dir.appendingPathComponent("fleet/repos")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: repos.path)) ?? []).isEmpty, "no half checkout is left")
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

    // MARK: A thread started in New thread, and a dispatch that carries no edits

    /// A thread the person starts in New thread on `host`: the record the host keeps for it.
    static func userThread(from a: Mac, host: String = "Mac mini", start: FleetThreadStart? = nil) async throws -> FleetDispatchRecord {
        try #require(try await a.local.fleetAction(.sendThread(FleetUserThread(spaceID: a.space.id, task: "Profile the orders import.", host: host, start: start))).dispatch)
    }

    /// A commit of `file` on `branch` that no remote has, left with the checkout on the branch it was on.
    static func commit(_ file: String, _ text: String, on branch: String, in mac: Mac) throws {
        let was = try git(["branch", "--show-current"], in: mac.folder).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["checkout", "-q", "-B", branch], in: mac.folder)
        try FleetSnapshotTransferTests.write(text, to: file, in: mac.folder)
        try git(["add", file], in: mac.folder)
        try git(["commit", "-qm", "add \(file)"], in: mac.folder)
        try git(["checkout", "-q", was], in: mac.folder)
    }

    /// Edits, a new file and an ignored `.env` in the sender's checkout, and the tree they make.
    static func dirty(_ mac: Mac) throws -> FleetSnapshotTransferTests.Tree {
        try FleetSnapshotTransferTests.write("# acme-web\nedited, not committed\n", to: "README.md", in: mac.folder)
        try FleetSnapshotTransferTests.write("take notes\n", to: "NOTES.md", in: mac.folder)
        try FleetSnapshotTransferTests.write("API_KEY=made-up-value\n", to: ".env", in: mac.folder)
        return try FleetSnapshotTransferTests.tree(of: mac.folder)
    }

    @Test func aThreadStartedInTheCheckoutOnAnotherMacSeesTheCheckoutsEditsUncommittedCommitsAndIgnoredFiles() async throws {
        let (a, b, _) = try await D.pair(originExtra: [".gitignore": FleetSnapshotTransferTests.ignores])
        defer { a.stop(); b.stop() }
        // An unpushed commit, then edits, a new file and an ignored file on top of it.
        try FleetSnapshotTransferTests.write("# The guide\n", to: "docs/guide.md", in: a.folder)
        try git(["add", "docs/guide.md"], in: a.folder)
        try git(["commit", "-qm", "guide"], in: a.folder)
        let expected = try Self.dirty(a)

        let record = try await Self.userThread(from: a, start: FleetThreadStart(place: .checkout))
        let head = try D.head(a.folder)
        #expect(record.kind == .userThread && record.commitSHA == head && record.start?.place == .checkout, "pinned at this Mac's commit")
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let thread = try #require(b.dispatched.first)
        #expect(thread.dispatchedFrom?.agentID == nil, "sent by you")
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected, "the worktree is the checkout, uncommitted edit and ignored file included")
        #expect(try D.head(worktree) == D.head(a.folder))
        #expect(a.sent().first?.snapshotBytes != nil && Self.cloneCount(b) == 0)
    }

    @Test func newThreadToAMacForARepoWithNoRemoteArrivesAsABundleAtTheCommitWithoutTheEdits() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        let key = try await Self.removeOrigin(of: a)
        let committed = try FleetSnapshotTransferTests.tree(of: a.folder)
        _ = try Self.dirty(a)

        let record = try await Self.userThread(from: a)
        #expect(record.repoKey == key && record.origin == nil && record.start?.place == .newWorktree)
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let space = try #require(Self.space(b, repoKey: key))
        #expect(space.id == a.space.id && Self.cloneCount(b) == 1, "cloned once, from the bundle: there was no origin to try")
        #expect(try git(["remote"], in: URL(fileURLWithPath: space.path)).isEmpty, "the bundle file it came from is not its origin")
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == committed, "a new worktree from the base: the commit, none of the edits")
        #expect(try D.head(worktree) == D.head(a.folder))
        try await D.wait("A to follow it as running") { a.sent().first?.state == .running && a.sent().first?.clone == nil }
        #expect(a.sent().first?.failure == nil)
    }

    @Test func aThreadStartedInNewThreadWhoseOriginTheTargetCantReachFallsBackToTheBundle() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.breakOrigin(of: a)
        let expected = try FleetSnapshotTransferTests.tree(of: a.folder)
        _ = try Self.dirty(a)

        _ = try await Self.userThread(from: a)
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        #expect(Self.cloneCount(b) == 2, "origin was tried first, then the bundle")
        let space = try #require(Self.space(b))
        #expect(try git(["remote", "get-url", "origin"], in: URL(fileURLWithPath: space.path)).trimmingCharacters(in: .whitespacesAndNewlines) == "/no/such/place/acme-web.git")
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try FleetSnapshotTransferTests.tree(of: worktree) == expected)
        #expect(a.sent().first?.failure == nil)
    }

    @Test func withEditsLeftBehindAndNoRemoteTheRepositoryStillArrivesAsABundleOfItsOwn() async throws {
        let (a, b, _) = try await Self.pair(uncommittedA: .leaveBehind)
        defer { a.stop(); b.stop() }
        let key = try await Self.removeOrigin(of: a)
        // A commit no remote has, and an edit that stays home.
        try FleetSnapshotTransferTests.write("# The guide\n", to: "docs/guide.md", in: a.folder)
        try git(["add", "docs/guide.md"], in: a.folder)
        try git(["commit", "-qm", "guide"], in: a.folder)
        try FleetSnapshotTransferTests.write("# acme-web\nedited, not committed\n", to: "README.md", in: a.folder)

        let parent = try await a.parent()
        try parent.hello()
        _ = try await Self.send(parent, key: "behind")
        try await D.wait("Mac mini to run the dispatched thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let sent = try #require(a.sent().first)
        #expect(sent.repoKey == key && sent.snapshotFiles == 0 && (sent.snapshotBytes ?? 0) > 0, "no edits sent: the bundle is the whole transfer")
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try D.head(worktree) == D.head(a.folder), "the commit no remote had arrived inside the bundle")
        #expect(try String(contentsOf: worktree.appendingPathComponent("docs/guide.md"), encoding: .utf8) == "# The guide\n")
        #expect(try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8) == "# acme-web\n", "the edit stayed home")
        #expect(Self.cloneCount(b) == 1 && Self.space(b, repoKey: key)?.id == a.space.id)
        try await D.wait("A to follow it as running", timeout: .seconds(90)) { a.sent().first?.state == .running && a.sent().first?.clone == nil }
    }

    @Test func aThreadStartedInNewThreadWithEditsLeftBehindAndAnUnreachableOriginAlsoFallsBackToTheBundle() async throws {
        let (a, b, _) = try await Self.pair(uncommittedA: .leaveBehind)
        defer { a.stop(); b.stop() }
        try Self.breakOrigin(of: a)
        _ = try await Self.userThread(from: a)
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        #expect(Self.cloneCount(b) == 2 && a.sent().first?.failure == nil)
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try D.head(worktree) == D.head(a.folder))
    }

    // MARK: Where a thread started in New thread begins

    @Test func aNewWorktreeFromABaseHasTheBasesCommitAndNoneOfTheCheckoutsEditsOrUnpushedCommits() async throws {
        let (a, b, origin) = try await D.pair(originExtra: [".gitignore": FleetSnapshotTransferTests.ignores])
        defer { a.stop(); b.stop() }
        let base = try git(["rev-parse", "origin/main"], in: a.folder).trimmingCharacters(in: .whitespacesAndNewlines)
        // Origin moves on after this Mac last fetched: the other Mac fetches the base, so the thread starts at what origin has now.
        let ahead = try makeScratchDirectory("origin-ahead").appendingPathComponent("web", isDirectory: true)
        try git(["clone", "-q", origin.url.path, ahead.path], in: ahead.deletingLastPathComponent())
        try FleetSnapshotTransferTests.write("# in origin\n", to: "docs/origin.md", in: URL(fileURLWithPath: ahead.path))
        try git(["add", "docs/origin.md"], in: ahead)
        try git(["-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-qm", "origin moves"], in: ahead)
        try git(["push", "-q", "origin", "HEAD:main"], in: ahead)
        let moved = try git(["rev-parse", "HEAD"], in: ahead).trimmingCharacters(in: .whitespacesAndNewlines)
        // This Mac has an unpushed commit on main and edits in the checkout; neither is a base.
        try Self.commit("docs/local.md", "# local\n", on: "main", in: a)
        _ = try Self.dirty(a)

        let record = try await Self.userThread(from: a, start: FleetThreadStart(place: .newWorktree, base: "origin/main"))
        #expect(record.commitSHA == base && record.start?.base == "origin/main", "pinned at the base as this Mac has it")
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try D.head(worktree) == moved, "the base's commit, fetched")
        for gone in ["NOTES.md", ".env", "docs/local.md"] { #expect(!Self.exists(worktree.appendingPathComponent(gone).path), "\(gone) stays home") }
        #expect(try String(contentsOf: worktree.appendingPathComponent("README.md"), encoding: .utf8) == "# acme-web\n")
        #expect(try String(contentsOf: worktree.appendingPathComponent("docs/origin.md"), encoding: .utf8) == "# in origin\n")
        #expect(a.sent().first?.snapshotBytes == nil && Self.cloneCount(b) == 0, "nothing of this Mac's checkout was sent")
    }

    @Test func aNewWorktreeFromALocalBaseWithUnpushedCommitsGetsThemAsABundleTheTargetLacks() async throws {
        let (a, b, _) = try await D.pair(originExtra: [".gitignore": FleetSnapshotTransferTests.ignores])
        defer { a.stop(); b.stop() }
        try Self.commit("docs/guide.md", "# The guide\n", on: "develop", in: a)
        _ = try Self.dirty(a)
        let develop = try git(["rev-parse", "develop"], in: a.folder).trimmingCharacters(in: .whitespacesAndNewlines)

        _ = try await Self.userThread(from: a, start: FleetThreadStart(place: .newWorktree, base: "develop"))
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try D.head(worktree) == develop)
        #expect(try String(contentsOf: worktree.appendingPathComponent("docs/guide.md"), encoding: .utf8) == "# The guide\n")
        #expect(!Self.exists(worktree.appendingPathComponent("NOTES.md").path), "the edits stay home")
        let repo = URL(fileURLWithPath: try #require(Self.space(b)?.path))
        try await D.wait("the bundle's refs to go") { (try? git(["for-each-ref", "refs/fleet"], in: repo))?.isEmpty == true }
        #expect(Self.cloneCount(b) == 0)
    }

    @Test func anExistingBranchStartsAtTheCommitThisMacHasForItAndItsBundleCarriesWhatTheTargetLacks() async throws {
        let (a, b, _) = try await D.pair(originExtra: [".gitignore": FleetSnapshotTransferTests.ignores])
        defer { a.stop(); b.stop() }
        try Self.commit("docs/orders.md", "# Orders\n", on: "feat/orders", in: a)
        _ = try Self.dirty(a)
        let tip = try git(["rev-parse", "feat/orders"], in: a.folder).trimmingCharacters(in: .whitespacesAndNewlines)

        let record = try await Self.userThread(from: a, start: FleetThreadStart(place: .existingBranch, branch: "feat/orders"))
        #expect(record.commitSHA == tip, "pinned at the branch's own commit, not the checkout's HEAD")
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let thread = try #require(b.dispatched.first)
        let worktree = URL(fileURLWithPath: try #require(thread.worktreePath))
        #expect(try D.head(worktree) == tip)
        #expect(thread.worktreeBranch == "feat/orders", "on the branch the person chose")
        #expect(try String(contentsOf: worktree.appendingPathComponent("docs/orders.md"), encoding: .utf8) == "# Orders\n")
        #expect(!Self.exists(worktree.appendingPathComponent("NOTES.md").path) && !Self.exists(worktree.appendingPathComponent(".env").path), "no edits of the checkout")
        #expect(a.sent().first?.snapshotBytes != nil && (a.sent().first?.snapshotBytes ?? .max) < 50_000, "only the commit it lacked, not the repository")
        #expect(Self.cloneCount(b) == 0)
    }

    @Test func aBranchThisMacNeverPushedStartsOnAMacThatCantReachOriginFromTheWholeRepository() async throws {
        let (a, b, _) = try await Self.pair()
        defer { a.stop(); b.stop() }
        try Self.breakOrigin(of: a)
        try Self.commit("docs/orders.md", "# Orders\n", on: "feat/orders", in: a)
        let tip = try git(["rev-parse", "feat/orders"], in: a.folder).trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await Self.userThread(from: a, start: FleetThreadStart(place: .existingBranch, branch: "feat/orders"))
        try await D.wait("Mac mini to run the thread", timeout: .seconds(60)) { !b.dispatched.isEmpty }
        let worktree = URL(fileURLWithPath: try #require(b.dispatched.first?.worktreePath))
        #expect(try D.head(worktree) == tip && Self.cloneCount(b) == 2)
    }

    @Test func aFormNamingNoWorkplaceIsANewWorktreeFromTheProjectsBase() throws {
        let thread = FleetUserThread(spaceID: SpaceID(rawValue: "s"), task: "t")
        #expect(thread.start == nil)
        let decoded = try JSONDecoder().decode(FleetUserThread.self, from: Data(#"{"dispatchID":"00000000-0000-0000-0000-00000000000A","spaceID":"s","task":"t"}"#.utf8))
        #expect(decoded.start == nil, "an older app's request decodes")
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
