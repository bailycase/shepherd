import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Git sharing for designs (docs/designs.md › Sharing with Git) against real git: a bare
/// repository on disk stands in for the host, and two scratch servers are the two Macs. The
/// commit identity is passed in the environment of each git run here, never set on the user.
@Suite("Design Git sharing", .integrationTimeLimit)
struct DesignGitTests {
    /// A bare, empty repository: what Share with Git asks for.
    private func emptyRemote() throws -> URL {
        let dir = try makeScratchDirectory("remote").appendingPathComponent("design.git", isDirectory: true)
        try git(["init", "-q", "--bare", "-b", "main", dir.path], in: dir.deletingLastPathComponent())
        return dir
    }

    /// A server with the checkout design drawn, and git's identity for its commits.
    private func authorWithDesign() async throws -> (h: ScratchServer, design: Design) {
        let h = try ScratchServer.fresh()
        let design = Design(name: "Checkout funnel dashboard", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: h.server, perRow: 3)
        try Self.setIdentity("Baily", in: h)
        return (h, design)
    }

    /// The identity git reads for this server's commits: the scratch global config the test
    /// isolation made, as the user's own ~/.gitconfig would be.
    static func setIdentity(_ name: String, in h: ScratchServer) throws {
        let config = ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] ?? ""
        #expect(!config.isEmpty, "the test isolation sets a scratch global config")
        // One identity for the whole test process is enough: both "Macs" commit as the tests' user.
        _ = try? git(["config", "--file", config, "user.name", name], in: h.dir)
        _ = try? git(["config", "--file", config, "user.email", "\(name.lowercased())@example.com"], in: h.dir)
    }

    /// A restart never resumes a merge: a merge copy a quit or crash left behind is removed at
    /// launch, the design and its repository are kept, and no merge is waiting.
    @Test func launchRemovesAMergeCopyLeftBehindAndResumesNoMerge() async throws {
        let (h, design) = try await authorWithDesign()
        let remote = try emptyRemote()
        _ = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add checkout funnel design")
        let folder = try #require(h.server.designs.folder(for: design.id))
        let copy = folder.appendingPathComponent(DesignGit.mergeCopyName)
        try FileManager.default.createDirectory(at: copy.appendingPathComponent("project"), withIntermediateDirectories: true)
        try Data("<x-dc></x-dc>".utf8).write(to: copy.appendingPathComponent("project/A.dc.html"))
        let before = try await h.server.designBoard(design.id, path: try DesignPath.validate("A.dc.html")).source
        h.stop(keepFiles: true)

        let again = try ScratchServer(dir: h.dir)
        defer { again.stop() }
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the leftover merge copy is gone")
        let state = try #require(try await again.server.designGitState(design.id))
        #expect(state.merge == nil, "no merge resumes")
        #expect(state.status.isClean)
        #expect(try await again.server.designBoard(design.id, path: try DesignPath.validate("A.dc.html")).source == before)
    }

    @Test func sharingCommitsTheDesignFilesAndPushesThemToAnEmptyRepository() async throws {
        let (h, design) = try await authorWithDesign()
        defer { h.stop() }
        let remote = try emptyRemote()
        let changed = Locked(0)
        h.server.onDesignGitChanged = { id in if id == design.id { changed.withValue { $0 += 1 } } }

        let shared = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add checkout funnel design")
        #expect(shared.status.branch == "main" && shared.status.ahead == 0 && shared.status.isClean)
        try await eventually("the change announced") { changed.current >= 1 }

        // The remote holds the design's files and nothing of Shepherd's own.
        let files = try git(["ls-tree", "-r", "--name-only", "main"], in: remote).split(separator: "\n").map(String.init)
        #expect(files.contains("project/canvas.json") && files.contains("project/A.dc.html"))
        #expect(!files.contains { $0.hasPrefix("versions/") || $0 == "revision" || $0.hasPrefix("pins/") || $0.hasPrefix("checkpoints/") })
        #expect(try git(["log", "-1", "--format=%s", "main"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == "Add checkout funnel design")
        // Nothing in the design's folder (its agent's working folder) leads to the repository.
        let folder = try #require(h.server.designs.folder(for: design.id))
        let inside = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        #expect(!inside.contains { $0.hasPrefix(".git") || $0.hasPrefix(".shepherd") }, "found \(inside)")
        #expect(FileManager.default.fileExists(atPath: DesignGitRunner.repository(of: folder).appendingPathComponent("HEAD").path))
        // Deleting the design takes its repository with it.
        try await h.server.designs.delete(design.id)
        #expect(!FileManager.default.fileExists(atPath: DesignGitRunner.repository(of: folder).path))

    }

    @Test func aSecondShareIsRefused() async throws {
        let (h, design) = try await authorWithDesign()
        defer { h.stop() }
        let remote = try emptyRemote()
        _ = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        await #expect(throws: DesignGitError.alreadyShared) {
            try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Again")
        }
    }

    @Test(arguments: [
        ("https://baily:ghp_secret@github.com/acme/design.git", false),
        ("http://github.com/acme/design.git", false),
        ("--upload-pack=touch /tmp/x", false),
        ("ext::sh -c touch% /tmp/x", false),
        ("https://github.com/acme/design.git", true),
        ("https://baily@github.com/acme/design.git", true),
        ("git@github.com:acme/design.git", true),
        ("ssh://git@gitlab.example.com/team/design.git", true),
    ])
    func onlySSHOrHTTPSURLsWithoutAPasswordAreAccepted(url: String, accepted: Bool) {
        #expect(DesignGit.isRemoteURL(url) == accepted)
    }

    @Test func gitsWordsNeverCarryCredentialsFromAURL() {
        #expect(DesignGit.redacted("fatal: unable to access 'https://baily:ghp_secret@github.com/acme/design.git/': 403")
                == "fatal: unable to access 'https://github.com/acme/design.git/': 403")
        #expect(DesignGit.redacted("fatal: repository 'ssh://git@host/x' not found") == "fatal: repository 'ssh://host/x' not found")
    }

    @Test func shareRefusesARepositoryWithCommitsAndLeavesTheDesignUnshared() async throws {
        let (h, design) = try await authorWithDesign()
        defer { h.stop() }
        let remote = try emptyRemote()
        let seed = try makeScratchRepo()
        try git(["push", "-q", remote.path, "HEAD:refs/heads/main"], in: seed)

        await #expect(throws: DesignGitError.remoteNotEmpty) {
            try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        }
        #expect(try await h.server.designGitState(design.id) == nil)
        await #expect(throws: DesignGitError.invalidURL) {
            try await h.server.shareDesignWithGit(design.id, url: "--upload-pack=touch /tmp/x", message: "Add")
        }
    }

    @Test func aCoworkerOpensTheSharedDesignWithItsCommentsAndNoAgent() async throws {
        let (author, design) = try await authorWithDesign()
        defer { author.stop() }
        let remote = try emptyRemote()
        let a = try DesignPath.validate("A.dc.html")
        let source = try await author.server.designBoard(design.id, path: a).source
        let template = try #require(DesignTemplate(board: source))
        let element = try #require(template.elements.first { $0.parent != nil })
        _ = try await author.server.addDesignComment(design.id, draft: DesignCommentDraft(board: a, tid: element.tid, path: element.path,
                                                                                           text: "Show the absolute counts next to the percentages."))
        _ = try await author.server.shareDesignWithGit(design.id, url: remote.path, message: "Add checkout funnel design")

        let coworker = try ScratchServer.fresh()
        defer { coworker.stop() }
        let opened = try await coworker.server.openDesignFromGit(remote.path)
        #expect(opened.name == "Checkout funnel dashboard" && opened.agentID == nil)
        #expect(coworker.server.state.designs.map(\.id) == [opened.id])
        #expect(coworker.server.state.agents.isEmpty, "opening does not start an agent")
        let snapshot = try await coworker.server.designSnapshot(opened.id)
        #expect(snapshot.index.boards.count == DesignFixtures.checkout.count)
        let pulled = try await coworker.server.designComments(opened.id).comments
        #expect(pulled.map(\.text) == ["Show the absolute counts next to the percentages."])
        // Written after the design was shared? No: before. Its author has no name (it reads "You"
        // to its author). A comment made on the shared design carries the Git name.
        #expect(pulled.first?.authorName == nil)
        let state = try #require(try await coworker.server.designGitState(opened.id))
        #expect(state.status.branch == "main" && state.status.isClean && state.status.behind == 0)

        // A URL that isn't a repository leaves nothing behind.
        await #expect(throws: DesignGitError.self) { try await coworker.server.openDesignFromGit("/nowhere/at/all.git") }
        #expect(coworker.server.state.designs.count == 1)
        let directory = coworker.server.designs.directory
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasPrefix(".") && $0 != DesignGitRunner.repositoriesName }
        #expect(leftovers.isEmpty)
        // Only the opened design's repository is kept; the failed clone made none.
        let repositories = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent(DesignGitRunner.repositoriesName).path)
        #expect(repositories == [opened.id.rawValue])
    }

    @Test func aRepositoryThatIsNotADesignIsRefused() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let remote = try emptyRemote()
        let seed = try makeScratchRepo(files: ["README.md": "# not a design\n", "project/evil": "x"])
        try git(["push", "-q", remote.path, "HEAD:refs/heads/main"], in: seed)
        await #expect(throws: DesignGitError.notADesign("there's no project/canvas.json")) {
            try await h.server.openDesignFromGit(remote.path)
        }
        // A symlink in the tree is refused before anything is checked out.
        let linked = try makeScratchRepo(files: ["project/canvas.json": #"{"title":"x","boards":{}}"#])
        try FileManager.default.createSymbolicLink(atPath: linked.appendingPathComponent("project/A.dc.html").path, withDestinationPath: "/etc/hosts")
        try git(["add", "-A"], in: linked)
        try git(["commit", "-qm", "link"], in: linked)
        let second = try emptyRemote()
        try git(["push", "-q", second.path, "HEAD:refs/heads/main"], in: linked)
        await #expect(throws: DesignGitError.notADesign("project/A.dc.html is a link or a submodule")) {
            try await h.server.openDesignFromGit(second.path)
        }
        // A filter driver's attributes, or two names one file on APFS, are refused before checkout.
        let attributes = try makeScratchRepo(files: ["project/canvas.json": #"{"title":"x","boards":{}}"#,
                                                     "project/.gitattributes": "*.json filter=evil\n"])
        let third = try emptyRemote()
        try git(["push", "-q", third.path, "HEAD:refs/heads/main"], in: attributes)
        await #expect(throws: DesignGitError.self) { try await h.server.openDesignFromGit(third.path) }
        let cased = try makeScratchRepo(files: ["project/canvas.json": #"{"title":"x","boards":{}}"#,
                                                "project/a.dc.html": "a", "project/sub/b.dc.html": "b"])
        // Git on a case-insensitive disk can't make the twin in a work tree; write it to the index.
        let twin = try makeScratchDirectory("twin").appendingPathComponent("A.dc.html")
        try Data("A".utf8).write(to: twin)
        let blob = try git(["hash-object", "-w", twin.path], in: cased).trimmingCharacters(in: .whitespacesAndNewlines)
        try git(["update-index", "--add", "--cacheinfo", "100644,\(blob),project/A.dc.html"], in: cased)
        try git(["commit", "-qm", "twin"], in: cased)
        let fourth = try emptyRemote()
        try git(["push", "-q", fourth.path, "HEAD:refs/heads/main"], in: cased)
        await #expect(throws: DesignGitError.notADesign("project/a.dc.html differs from another file only by case")) {
            try await h.server.openDesignFromGit(fourth.path)
        }
        #expect(h.server.state.designs.isEmpty)
    }

    @Test func commitAndPushThenACoworkerPullsAndTheCanvasReloads() async throws {
        let (author, design) = try await authorWithDesign()
        defer { author.stop() }
        let remote = try emptyRemote()
        _ = try await author.server.shareDesignWithGit(design.id, url: remote.path, message: "Add checkout funnel design")
        let coworker = try ScratchServer.fresh()
        defer { coworker.stop() }
        let opened = try await coworker.server.openDesignFromGit(remote.path)

        // A comment on the shared design carries its author's Git name, so the coworker sees who wrote it.
        let phoneSource = try await author.server.designBoard(design.id, path: try DesignPath.validate("A-phone.dc.html")).source
        let phoneElement = try #require(DesignTemplate(board: phoneSource)?.elements.first { $0.parent != nil })
        let named = try await author.server.addDesignComment(design.id, draft: DesignCommentDraft(
            board: try DesignPath.validate("A-phone.dc.html"), tid: phoneElement.tid, path: phoneElement.path, text: "Shorter labels here."))
        #expect(named.comment.authorName == "Baily")

        // The author changes a board: a local change, then Commit & push.
        let a = try DesignPath.validate("A.dc.html")
        let before = try await author.server.designBoard(design.id, path: a).source
        _ = try await author.server.writeDesignBoard(design.id, path: a, source: before.replacingOccurrences(of: "</x-dc>", with: "<!-- counts --></x-dc>"),
                                                     baseRevision: nil)
        let dirty = try #require(try await author.server.designGitState(design.id))
        #expect(dirty.status.files.map(\.path) == ["comments.json", "project/A.dc.html"])
        await #expect(throws: DesignGitError.nothingToCommit) {
            try await author.server.commitDesign(design.id, message: "   ", push: true)
        }
        let pushed = try await author.server.commitDesign(design.id, message: "Show absolute counts in the checkout funnel", push: true)
        #expect(pushed.status.isClean && pushed.status.ahead == 0 && pushed.status.pushFailed == nil)

        // The coworker sees one commit to pull, pulls, and the canvas is told once.
        let incoming = try #require(try await coworker.server.designGitState(opened.id, fetch: true))
        #expect(incoming.status.behind == 1 && incoming.status.incoming?.subject == "Show absolute counts in the checkout funnel")
        let pushes = Locked(0)
        coworker.server.onDesignRevision = { _ in pushes.withValue { $0 += 1 } }
        coworker.server.watchDesignRevisions(of: [opened.id])
        let revision = try await coworker.server.designSnapshot(opened.id).revision
        #expect(try await coworker.server.pullDesign(opened.id) == .updated)
        try await eventually("the pull's revision push") { pushes.current >= 1 }
        #expect(try await coworker.server.designBoard(opened.id, path: a).source.contains("<!-- counts -->"))
        #expect(try await coworker.server.designComments(opened.id).comments.contains { $0.authorName == "Baily" && $0.text == "Shorter labels here." })
        #expect(try await coworker.server.designSnapshot(opened.id).revision == revision + 1)
        #expect(try await coworker.server.designVersions(opened.id, path: a).count == 1, "the pulled-over board's old content is a version")
        #expect(try await coworker.server.pullDesign(opened.id) == .upToDate)
    }

    @Test func aPullWithLocalChangesIsRefusedAndAPushThatFailsKeepsTheCommit() async throws {
        let (h, design) = try await authorWithDesign()
        defer { h.stop() }
        let remote = try emptyRemote()
        _ = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        let a = try DesignPath.validate("A.dc.html")
        let source = try await h.server.designBoard(design.id, path: a).source
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: source.replacingOccurrences(of: "</x-dc>", with: "<!-- x --></x-dc>"),
                                                baseRevision: nil)
        await #expect(throws: DesignGitError.dirty) { try await h.server.pullDesign(design.id) }

        // The remote goes away: the commit stays local, and the status says the push failed.
        try FileManager.default.moveItem(at: remote, to: remote.deletingLastPathComponent().appendingPathComponent("gone.git"))
        let state = try await h.server.commitDesign(design.id, message: "Local only", push: true)
        #expect(state.status.ahead == 1 && state.status.isClean)
        #expect(state.status.pushFailed?.isEmpty == false)
        // Retry push after it comes back.
        try FileManager.default.moveItem(at: remote.deletingLastPathComponent().appendingPathComponent("gone.git"), to: remote)
        let retried = try await h.server.pushDesign(design.id)
        #expect(retried.status.ahead == 0 && retried.status.pushFailed == nil)
    }

    @Test func divergedHistoryNeedsAMergeAndLeavesTheDesignFilesAlone() async throws {
        let (author, design) = try await authorWithDesign()
        defer { author.stop() }
        let remote = try emptyRemote()
        _ = try await author.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        let coworker = try ScratchServer.fresh()
        defer { coworker.stop() }
        let opened = try await coworker.server.openDesignFromGit(remote.path)
        let phone = try DesignPath.validate("A-phone.dc.html")

        // Both change the phone board: the coworker pushes first.
        let theirs = try await coworker.server.designBoard(opened.id, path: phone).source
        _ = try await coworker.server.writeDesignBoard(opened.id, path: phone, source: theirs.replacingOccurrences(of: "</x-dc>", with: "<!-- Sam --></x-dc>"),
                                                       baseRevision: nil)
        _ = try await coworker.server.commitDesign(opened.id, message: "Clarify phone step labels", push: true)
        let ours = try await author.server.designBoard(design.id, path: phone).source
        let mine = ours.replacingOccurrences(of: "</x-dc>", with: "<!-- Baily --></x-dc>")
        _ = try await author.server.writeDesignBoard(design.id, path: phone, source: mine, baseRevision: nil)
        _ = try await author.server.commitDesign(design.id, message: "Show absolute counts in the checkout funnel", push: false)

        let result = try await author.server.pullDesign(design.id)
        guard case .needsMerge(let merge) = result else { Issue.record("expected a merge, got \(result)"); return }
        #expect(merge.phase == .conflict && merge.ours.subject == "Show absolute counts in the checkout funnel")
        #expect(merge.theirs.subject == "Clarify phone step labels" && merge.theirs.files == ["project/A-phone.dc.html"])
        #expect(try await author.server.designBoard(design.id, path: phone).source == mine, "Shepherd has not changed your design files")
        await #expect(throws: DesignGitError.merging) { try await author.server.commitDesign(design.id, message: "x", push: false) }

        // Keep working locally: the merge goes, the design and both commits stay.
        await author.server.keepDesignLocal(design.id)
        #expect(try await author.server.designGitState(design.id)?.merge == nil)
        #expect(try await author.server.designBoard(design.id, path: phone).source == mine)
    }

    @Test func theMergeCopyIsCheckedBeforeItCanBeCommittedAndThenCommitsWithBothParents() async throws {
        let (author, design) = try await authorWithDesign()
        defer { author.stop() }
        let remote = try emptyRemote()
        _ = try await author.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        let coworker = try ScratchServer.fresh()
        defer { coworker.stop() }
        let opened = try await coworker.server.openDesignFromGit(remote.path)
        let phone = try DesignPath.validate("A-phone.dc.html")
        let base = try await coworker.server.designBoard(opened.id, path: phone).source
        _ = try await coworker.server.writeDesignBoard(opened.id, path: phone, source: base.replacingOccurrences(of: "</x-dc>", with: "<!-- Sam --></x-dc>"),
                                                       baseRevision: nil)
        _ = try await coworker.server.commitDesign(opened.id, message: "Clarify phone step labels", push: true)
        _ = try await author.server.writeDesignBoard(design.id, path: phone, source: base.replacingOccurrences(of: "</x-dc>", with: "<!-- Baily --></x-dc>"),
                                                     baseRevision: nil)
        _ = try await author.server.commitDesign(design.id, message: "Counts", push: false)
        guard case .needsMerge(let merge) = try await author.server.pullDesign(design.id) else { Issue.record("no merge"); return }

        // The copy git prepares still has conflict markers: not ready.
        let folder = try #require(author.server.designs.folder(for: design.id))
        let (copy, conflicts) = try DesignGit.prepareMergeCopy(folder, merge: merge)
        #expect(conflicts == ["project/A-phone.dc.html"])
        #expect(DesignGit.checkMergeCopy(copy).contains { $0.contains("conflict markers") })

        // Resolved by hand (as the agent would): both kept.
        let resolved = base.replacingOccurrences(of: "</x-dc>", with: "<!-- Baily --><!-- Sam --></x-dc>")
        try Data(resolved.utf8).write(to: copy.appendingPathComponent("project/A-phone.dc.html"))
        #expect(DesignGit.checkMergeCopy(copy).isEmpty)
        await author.server.markDesignMergeReadyForTests(design.id)
        let review = try #require(try await author.server.designGitState(design.id))
        #expect(review.merge?.phase == .ready && review.mergeFiles.map(\.path) == ["project/A-phone.dc.html"])

        // A write to the design while the merge waited would be lost by taking the merge: refused.
        let a = try DesignPath.validate("A.dc.html")
        let aSource = try await author.server.designBoard(design.id, path: a).source
        _ = try await author.server.writeDesignBoard(design.id, path: a, source: aSource + "\n", baseRevision: nil)
        await #expect(throws: DesignGitError.changedDuringMerge) {
            try await author.server.commitDesignMerge(design.id, message: "Merge", push: false)
        }
        #expect(try await author.server.designBoard(design.id, path: a).source == aSource + "\n", "the write is kept")
        _ = try await author.server.writeDesignBoard(design.id, path: a, source: aSource, baseRevision: nil)
        let committed = try await author.server.commitDesignMerge(design.id, message: "Merge phone labels with absolute counts", push: true)
        #expect(committed.status.isClean && committed.status.ahead == 0 && committed.status.behind == 0)
        #expect(try await author.server.designBoard(design.id, path: phone).source == resolved)
        let parents = try git(["log", "-1", "--format=%P", "main"], in: remote).split(separator: " ")
        #expect(parents.count == 2, "the merge commit keeps both parents")
        #expect(!FileManager.default.fileExists(atPath: copy.path), "the merge copy goes")
        #expect(try await author.server.designGitState(design.id)?.merge == nil)
    }

    @Test func aDesignCannotBeCommittedWhileItsAgentWorks() async throws {
        let h = try ScratchServer.fresh()
        defer { h.stop() }
        let agent = try await PiAgent.launch(on: h)
        let design = Design(name: "Busy", agentID: agent.agent.id, createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        try await h.server.setAgentDesignForTests(agent.agent.id, design: design.id)
        try Self.setIdentity("Baily", in: h)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(1)), in: design.id, on: h.server, perRow: 1)
        let remote = try emptyRemote()
        _ = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")

        let s = try await agent.ready()
        _ = try await agent.send("hold-start tools:1", from: s)
        try await eventually("the turn to start") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == true }
        let a = try DesignPath.validate("A.dc.html")
        let source = try await h.server.designBoard(design.id, path: a).source
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: source + "\n", baseRevision: nil)
        await #expect(throws: DesignGitError.agentWorking) { try await h.server.commitDesign(design.id, message: "x", push: false) }
        await #expect(throws: DesignGitError.agentWorking) { try await h.server.pullDesign(design.id) }
        try Data().write(to: h.dir.appendingPathComponent("start"))
        try Data().write(to: h.dir.appendingPathComponent("tool-1"))
    }

    /// A shared design whose agent is the stub pi, with a pull that needs a merge on board A.
    /// The local commit's subject reaches the merge brief: "tools:1" in it makes the stub's turn
    /// hold on a tool call until `agent.finishTool(1)` (as a long merge would), and without it
    /// the turn replies at once.
    private func mergeWorkspace(oursSubject: String) async throws -> (h: ScratchServer, agent: PiAgent, design: Design, remote: URL, base: String) {
        let h = try ScratchServer.fresh()
        let agent = try await PiAgent.launch(on: h)
        let design = Design(name: "Merge", agentID: agent.agent.id, createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        try await h.server.setAgentDesignForTests(agent.agent.id, design: design.id)
        try Self.setIdentity("Baily", in: h)
        try await DesignFixtures.draw(Array(DesignFixtures.checkout.prefix(1)), in: design.id, on: h.server, perRow: 1)
        let remote = try emptyRemote()
        _ = try await h.server.shareDesignWithGit(design.id, url: remote.path, message: "Add")
        // A second clone pushes a change to the same board.
        let other = try makeScratchDirectory("other")
        try git(["clone", "-q", remote.path, other.appendingPathComponent("c").path], in: other)
        let clone = other.appendingPathComponent("c")
        let a = try DesignPath.validate("A.dc.html")
        let base = try await h.server.designBoard(design.id, path: a).source
        try Data(base.replacingOccurrences(of: "</x-dc>", with: "<!-- Sam --></x-dc>").utf8).write(to: clone.appendingPathComponent("project/A.dc.html"))
        try git(["commit", "-qam", "Theirs"], in: clone)
        try git(["push", "-q", "origin", "HEAD:main"], in: clone)
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: base.replacingOccurrences(of: "</x-dc>", with: "<!-- me --></x-dc>"),
                                                baseRevision: nil)
        _ = try await h.server.commitDesign(design.id, message: oursSubject, push: false)
        guard case .needsMerge = try await h.server.pullDesign(design.id) else { throw CommandFailure("pull", "no merge") }
        _ = try await agent.ready()
        return (h, agent, design, remote, base)
    }

    @Test func theMergeTurnIsBoundedByItsTimeLimit() async throws {
        let (h, agent, design, remote, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        await h.server.setDesignMergeTimeoutForTests(0.5)
        try await h.server.resolveDesignMergeWithAgent(design.id)
        // Startup and a Git status read can outlast this short limit; assert its stopped outcome below.
        let brief = try await agent.waitForStdin("prompt")
        let message = try #require(brief["message"] as? String)
        // pi reads Shepherd's brief in its fence, then the request; the thread shows only the request.
        let fenced = try #require(DesignGitFence.parse(message))
        #expect(fenced.text == DesignGitMergeBrief.request)
        #expect(fenced.brief.contains(DesignGit.mergeCopyName) && fenced.brief.contains("Never run git"))
        #expect(DesignViewRecord.strippingFence(from: message) == DesignGitMergeBrief.request)
        // The tool never finishes: only the limit ends the turn.
        try await eventually("the limit to stop the merge") { (try? await h.server.designGitState(design.id))?.merge?.phase == .stopped }
        #expect(try await h.server.designGitState(design.id)?.merge?.reason?.contains("limit") == true)
        try await eventually("the turn to stop") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == false }
        let a = try DesignPath.validate("A.dc.html")
        #expect(try await h.server.designBoard(design.id, path: a).source.contains("<!-- me -->"), "the design is as it was")
        #expect(try git(["log", "-1", "--format=%s", "main"], in: remote).trimmingCharacters(in: .whitespacesAndNewlines) == "Theirs",
                "nothing was pushed")
    }

    @Test func stopEndsTheMergeTurnAndTryAgainStartsOneMore() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        try await eventually("the merge turn to run") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == true }
        await h.server.stopDesignMerge(design.id)
        #expect(try await h.server.designGitState(design.id)?.merge?.phase == .stopped)
        try await eventually("the turn to stop") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == false }
        // Stopped stays stopped: the settle that follows the abort doesn't make it ready or failed.
        #expect(try await h.server.designGitState(design.id)?.merge?.phase == .stopped)
        // Try again with agent: one more attempt, only on the user's press.
        try await h.server.resolveDesignMergeWithAgent(design.id)
        #expect(try await h.server.designGitState(design.id)?.merge?.phase == .running)
        _ = try await agent.waitForStdin("prompt", count: 2)
        await h.server.stopDesignMerge(design.id)
        try await eventually("the second turn to stop") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == false }
    }

    @Test func theComposersStopDuringTheMergeTurnReadsStopped() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        try await eventually("the merge turn to run") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == true }
        // The chat's own Stop (not the merge's): the merge reads Stopped, never Failed or Ready.
        let s = try await agent.snapshot()
        _ = try await agent.request(.abort(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID()))
        try await eventually("the merge to read stopped") { (try? await h.server.designGitState(design.id))?.merge?.phase == .stopped }
    }

    @Test func piExitingMidMergeFailsTheMergeAndLeavesTheDesign() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        h.server.killSession(agent.sessionID)
        try await eventually("the merge to fail") { (try? await h.server.designGitState(design.id))?.merge?.phase == .failed }
        let a = try DesignPath.validate("A.dc.html")
        #expect(try await h.server.designBoard(design.id, path: a).source.contains("<!-- me -->"))
    }

    @Test func aSecondPressWhileTheMergeRunsIsRefusedAndLeavesTheCopy() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        let folder = try #require(h.server.designs.folder(for: design.id))
        let marker = folder.appendingPathComponent(DesignGit.mergeCopyName).appendingPathComponent("project/agent-was-here.dc.html")
        try Data("x".utf8).write(to: marker)
        await #expect(throws: DesignGitError.merging) { try await h.server.resolveDesignMergeWithAgent(design.id) }
        #expect(FileManager.default.fileExists(atPath: marker.path), "the copy the agent edits is not rebuilt")
        #expect(agent.stdin("prompt").count == 1, "one attempt per press")
        await h.server.stopDesignMerge(design.id)
    }

    @Test func aMessageQueuedDuringTheMergeRunsAfterTheLimitStopsIt() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        await h.server.setDesignMergeTimeoutForTests(1)
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        try await eventually("the merge turn to run") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == true }
        // The user queues a message while the merge runs: the limit's stop doesn't pause it.
        let s = try await agent.snapshot()
        _ = try await agent.send("after the merge", from: s)
        try await eventually("the limit to stop the merge") { (try? await h.server.designGitState(design.id))?.merge?.phase == .stopped }
        _ = try await agent.waitForStdin("prompt", count: 2)
        #expect(agent.stdin("prompt").last?["message"] as? String == "after the merge")
    }

    @Test func resolveWithAgentNeverSendsAPausedQueue() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine")
        defer { h.stop() }
        // A message waits in a paused queue (the user stopped a turn): the merge leaves it theirs.
        let s = try await agent.ready()
        _ = try await agent.send("hold-start tools:1", from: s)
        try await eventually("the turn to start") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == true }
        let busy = try await agent.snapshot()
        _ = try await agent.send("waiting for me", from: busy)
        _ = try await agent.request(.abort(expectedSessionID: busy.piSessionID, generation: busy.generation, operationID: UUID()))
        try Data().write(to: h.dir.appendingPathComponent("start"))
        try await eventually("the turn to stop") { h.server.rpcThread(forAgent: agent.agent.id)?.piBusy == false }
        await #expect(throws: DesignGitError.self) { try await h.server.resolveDesignMergeWithAgent(design.id) }
        #expect(try await h.server.designGitState(design.id)?.merge?.phase == .conflict)
        #expect(!agent.stdin("prompt").contains { ($0["message"] as? String)?.contains("waiting for me") == true })
    }

    @Test func theMergeMessageIsNotRetriedOutsideItsBoundedAttempt() async throws {
        let (h, agent, design, _, _) = try await mergeWorkspace(oursSubject: "Mine")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        try await eventually("the merge turn to end") { (try? await h.server.designGitState(design.id))?.merge?.phase == .failed }
        // The chat's Retry on the merge's message would run the brief with no limit and no check.
        let s = try await agent.snapshot("the merge message") { snapshot in
            snapshot.messages.contains { $0.role == "user" && $0.blocks.contains { $0.text == DesignGitMergeBrief.request } }
        }
        let entry = try #require(s.messages.last { $0.role == "user" }?.entryID)
        let result = try await agent.request(.retry(expectedSessionID: s.piSessionID, generation: s.generation, operationID: UUID(), entryID: entry))
        guard case .failure(let code, _) = result else { Issue.record("retry was accepted: \(result)"); return }
        #expect(code == "git_merge")
        #expect(agent.stdin("prompt").count == 1)
    }

    @Test func aMergeTurnThatLeavesConflictMarkersFails() async throws {
        // The turn replies at once and leaves the copy as git made it: conflict markers remain.
        let (h, _, design, _, _) = try await mergeWorkspace(oursSubject: "Mine")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        try await eventually("the check to fail the merge") { (try? await h.server.designGitState(design.id))?.merge?.phase == .failed }
        let failed = try #require(try await h.server.designGitState(design.id)?.merge)
        #expect(failed.reason?.contains("conflict markers") == true)
        await #expect(throws: DesignGitError.noMerge) { try await h.server.commitDesignMerge(design.id, message: "x", push: false) }
    }

    @Test func aMergeTurnThatResolvesTheCopyIsReadyToReview() async throws {
        let (h, agent, design, _, base) = try await mergeWorkspace(oursSubject: "Mine tools:1")
        defer { h.stop() }
        try await h.server.resolveDesignMergeWithAgent(design.id)
        _ = try await agent.waitForStdin("prompt")
        // The agent's edits, made while its turn runs; then the turn ends.
        let folder = try #require(h.server.designs.folder(for: design.id))
        let copy = folder.appendingPathComponent(DesignGit.mergeCopyName)
        try Data(base.replacingOccurrences(of: "</x-dc>", with: "<!-- me --><!-- Sam --></x-dc>").utf8)
            .write(to: copy.appendingPathComponent("project/A.dc.html"))
        agent.finishTool(1)
        try await eventually("the merge to be ready") { (try? await h.server.designGitState(design.id))?.merge?.phase == .ready }
        let review = try #require(try await h.server.designGitState(design.id))
        #expect(review.mergeFiles.map(\.path) == ["project/A.dc.html"])
        let committed = try await h.server.commitDesignMerge(design.id, message: "Merge phone labels with absolute counts", push: false)
        #expect(committed.status.ahead == 2 && committed.status.isClean)
    }
}
