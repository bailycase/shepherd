import Foundation
import ShepherdProtocol
import Testing
@testable import ShepherdRemote

private func file(_ path: String, _ status: String = "M", old: String? = nil, added: Int = 1, removed: Int = 0) -> RemoteCommitFile {
    RemoteCommitFile(path: path, oldPath: old, status: status, added: added, removed: removed, fingerprint: "fp-\(path)")
}

private func info(files: [RemoteCommitFile] = [file("App/iOS/FleetView.swift"), file("App/iOS/HostCard.swift", "A")],
                  branch: String? = "feat/rows", upstream: String? = "origin/feat/rows", pushRemote: String? = "origin",
                  defaultBranch: String? = "main", drafts: Bool = true, working: Bool = false, blocked: String? = nil) -> RemoteCommitInfo {
    let message = reviewCommitFallbackMessage(files)
    return RemoteCommitInfo(repository: "/r", branch: branch, head: "abc", upstream: upstream, pushRemote: pushRemote,
                            defaultBranch: defaultBranch, files: files, title: message.title, body: message.body,
                            draftsMessage: drafts, agentWorking: working, blocked: blocked)
}

@Suite("Commit from review: presentation")
struct ReviewCommitPresentationTests {
    @Test(arguments: [
        ([file("App/iOS/FleetView.swift")], "Update FleetView.swift", ""),
        ([file("a/New.swift", "A")], "Add New.swift", ""),
        ([file("Old.swift", "D")], "Remove Old.swift", ""),
        ([file("b/New.swift", "R", old: "a/Old.swift")], "Rename Old.swift to New.swift", ""),
        ([file("App/iOS/A.swift", "A"), file("App/iOS/Views/B.swift", "A")], "Add 2 files in App/iOS", "- App/iOS/A.swift\n- App/iOS/Views/B.swift"),
        ([file("README.md"), file("App/C.swift", "A")], "Update 2 files", "- README.md\n- App/C.swift"),
        ([], "", ""),
    ])
    func aPlainMessageIsWrittenFromTheFileList(_ files: [RemoteCommitFile], _ title: String, _ body: String) {
        let message = reviewCommitFallbackMessage(files)
        #expect(message.title == title)
        #expect(message.body == body)
    }

    @Test(arguments: [
        ("Show commands in tool rows\n\nTool rows preview the command.", "Show commands in tool rows", "Tool rows preview the command."),
        ("```\nFix the sidebar\n```", "Fix the sidebar", ""),
        ("Subject: Fix the sidebar\nBody:\nIt jumped.", "Fix the sidebar", "It jumped."),
        ("# \"Fix the sidebar\"", "Fix the sidebar", ""),
        ("\n\n  Trim me  \n\n\n", "Trim me", ""),
        ("", nil, nil),
        ("```\n```", nil, nil),
    ] as [(String, String?, String?)])
    func aModelsReplyIsReadAsAMessage(_ output: String, _ title: String?, _ body: String?) {
        let message = reviewCommitMessage(fromModel: output)
        #expect(message?.title == title)
        #expect(message?.body == body)
    }

    @Test func aLongSummaryIsCutAtAWord() {
        let long = "Make the review pane's commit sheet draft messages from the diff and push to the upstream branch"
        let short = reviewCommitShortened(long)
        #expect(short.count <= reviewCommitTitleLimit && long.hasPrefix(short) && !short.hasSuffix(" "))
        #expect(long.dropFirst(short.count).hasPrefix(" "))
    }

    @Test(arguments: [
        ("Show commands & paths in tool rows!", "shepherd/show-commands-paths-in-tool-rows"),
        ("  Fix: the 'thing'  ", "shepherd/fix-the-thing"),
        ("Überarbeitung", "shepherd/berarbeitung"),
        ("!!!", "shepherd/commit"),
        (String(repeating: "word ", count: 20), "shepherd/word-word-word-word-word-word-word-word-word"),
    ])
    func aNewBranchIsNamedAfterTheSummary(_ title: String, _ branch: String) {
        #expect(reviewCommitBranchName(title: title) == branch)
    }

    @Test func theMessageIsTheSummaryThenTheDescription() {
        #expect(reviewCommitMessageText(title: " Fix it \n", body: "") == "Fix it")
        #expect(reviewCommitMessageText(title: "Fix it", body: "\nWhy.\n") == "Fix it\n\nWhy.")
    }

    @Test(arguments: [
        (false, false, RemoteCommitPush.none, "Commit"),
        (true, false, .upstream, "Commit & push"),
        (true, true, .pullRequest, "Commit & open PR"),
        (false, true, .pullRequest, "Commit & open PR"),
    ])
    func theOptionsNameTheAction(_ push: Bool, _ pullRequest: Bool, _ destination: RemoteCommitPush, _ title: String) {
        #expect(reviewCommitPush(push: push, pullRequest: pullRequest) == destination)
        #expect(reviewCommitActionTitle(destination) == title)
    }

    @Test func theOptionsSayWhereTheCommitGoes() {
        #expect(reviewCommitPushDetail(info()) == "origin/feat/rows")
        #expect(reviewCommitPushDetail(info(upstream: nil)) == "origin/feat/rows · sets upstream")
        #expect(reviewCommitPushDetail(info(upstream: nil, pushRemote: nil)) == "no remote to push to")
        #expect(reviewCommitPushDetail(info(branch: nil, upstream: nil)) == "no branch checked out")
        #expect(reviewCommitPullRequestDetail(info(), title: "x") == "pushes feat/rows, opens a PR into main")
        #expect(reviewCommitPullRequestDetail(info(branch: "main", upstream: "origin/main"), title: "Fix it")
                    == "creates shepherd/fix-it, opens a PR into main")
        #expect(reviewCommitPullRequestDetail(info(defaultBranch: nil), title: "x") == "pushes a branch and opens the PR")
        #expect(!reviewCommitCanOpenPullRequest(info(defaultBranch: nil)) && reviewCommitCanPush(info(defaultBranch: nil)))
    }

    @Test(arguments: [
        (info(blocked: "HEAD is detached."), 2, "t", RemoteCommitPush.none, false, "HEAD is detached."),
        (info(files: []), 0, "t", .none, false, "Nothing to commit."),
        (info(), 0, "t", .none, false, "Choose at least one file."),
        (info(), 1, "  ", .none, false, "Write a commit message."),
        (info(upstream: nil, pushRemote: nil), 1, "t", .upstream, false, "This branch has nowhere to push."),
        (info(defaultBranch: nil), 1, "t", .pullRequest, false, "A pull request needs a remote and its default branch."),
        (info(working: true), 1, "t", .upstream, false, "Confirm committing while the agent works."),
    ] as [(RemoteCommitInfo, Int, String, RemoteCommitPush, Bool, String)])
    func commitWaitsForWhatItNeeds(_ info: RemoteCommitInfo, _ selected: Int, _ title: String, _ push: RemoteCommitPush,
                                   _ confirmed: Bool, _ problem: String) {
        #expect(reviewCommitProblem(info, selected: selected, title: title, push: push, confirmedWhileWorking: confirmed) == problem)
    }

    @Test func aConfirmedCommitWhileTheAgentWorksHasNoProblem() {
        #expect(reviewCommitProblem(info(working: true), selected: 1, title: "t", push: .upstream, confirmedWhileWorking: true) == nil)
    }

    @Test func theReviewsFilesBecomeCommitFilesWithTheirPaths() {
        let files = DiffFile.parse("""
        diff --git a/Old.swift b/New.swift
        similarity index 90%
        rename from Old.swift
        rename to New.swift
        diff --git a/Gone.swift b/Gone.swift
        deleted file mode 100644
        --- a/Gone.swift
        +++ /dev/null
        @@ -1 +0,0 @@
        -gone
        diff --git a/Added.swift b/Added.swift
        new file mode 100644
        --- /dev/null
        +++ b/Added.swift
        @@ -0,0 +1 @@
        +new
        """)
        let commit = reviewCommitFiles(files) { "fp:\($0.displayPath)" }
        #expect(commit.map(\.paths) == [["Old.swift", "New.swift"], ["Gone.swift"], ["Added.swift"]])
        #expect(commit.map(\.status) == ["R", "D", "A"])
        #expect(commit[2].added == 1 && commit[1].removed == 1 && commit[0].fingerprint == "fp:New.swift")
    }

    @Test func rowsFollowTheSelection() {
        let rows = reviewCommitRows([file("App/iOS/FleetView.swift"), file("README.md", "A")], selected: ["README.md"])
        #expect(rows.map(\.name) == ["FleetView.swift", "README.md"])
        #expect(rows.map(\.directory) == ["App/iOS/", ""])
        #expect(rows.map(\.selected) == [false, true])
        #expect(rows[1].status == .added)
    }

    @Test(arguments: [
        (RemoteWorktreeOperation(id: UUID()), ReviewCommitOutcome.running),
        (RemoteWorktreeOperation(id: UUID(), finished: true), .succeeded(prURL: nil)),
        (RemoteWorktreeOperation(id: UUID(), finished: true, prURL: "https://x/pull/1"), .succeeded(prURL: "https://x/pull/1")),
        (RemoteWorktreeOperation(id: UUID(), finished: true, error: "push failed"), .failed("push failed")),
    ])
    func anOperationsOutcome(_ operation: RemoteWorktreeOperation, _ outcome: ReviewCommitOutcome) {
        #expect(ReviewCommitOutcome(operation) == outcome)
    }
}

/// A scripted host: answers each query from `answer`, recording what it was asked.
@MainActor
private final class CommitFakeHost {
    var asked: [RemoteAgentQuery] = []
    var answer: (RemoteAgentQuery) throws -> RemoteAgentResult

    init(_ answer: @escaping (RemoteAgentQuery) throws -> RemoteAgentResult) { self.answer = answer }

    func store() -> ReviewCommitStore {
        ReviewCommitStore { [self] query in
            asked.append(query)
            return try answer(query)
        }
    }
}

@Suite("Commit from review: the sheet's store")
@MainActor
struct ReviewCommitStoreTests {
    private static let id = UUID()

    private func host(info: RemoteCommitInfo = info(), draft: RemoteAgentResult? = .commitMessage(title: "Show host cards", body: "Why.", drafted: true),
                      commit: Result<RemoteWorktreeOperation, RemoteHostClientError> = .success(RemoteWorktreeOperation(id: id))) -> CommitFakeHost {
        CommitFakeHost { query in
            switch query {
            case .commitInfo: return .commitInfo(info)
            case .commitMessage:
                guard let draft else { throw RemoteHostClientError.timeout }
                return draft
            case .commit(let id, _):
                var operation = try commit.get()
                operation.id = id
                return .worktreeOperation(operation)
            case .worktreeStatus(let id):
                return .worktreeOperation(RemoteWorktreeOperation(id: id, finished: true, progress: ["check the checkout: on feat/rows",
                                                                                                    "commit 2 files: committed 1a2b3c4"]))
            default: throw RemoteHostClientError.timeout
            }
        }
    }

    @Test func openingAsksForTheInfoThenADraftAndTicksEveryFile() async {
        let fake = host()
        let store = fake.store()

        await store.begin()

        #expect(store.stage == .form)
        #expect(fake.asked == [.commitInfo, .commitMessage(paths: ["App/iOS/FleetView.swift", "App/iOS/HostCard.swift"])])
        #expect(store.title == "Show host cards" && store.body == "Why." && store.drafted)
        #expect(store.rows.allSatisfy(\.selected) && store.selectionText == "2 of 2")
        #expect(store.push && !store.pullRequest && store.actionTitle == "Commit & push" && store.canCommit)
    }

    @Test func aHostThatDraftsNothingKeepsThePlainMessage() async {
        let fake = host(info: info(drafts: false))
        let store = fake.store()

        await store.begin()

        #expect(fake.asked == [.commitInfo])
        #expect(store.title == "Update 2 files in App/iOS" && !store.drafted)
    }

    @Test func aFailedDraftKeepsThePlainMessage() async {
        let store = host(draft: nil).store()

        await store.begin()

        #expect(store.stage == .form && store.title == "Update 2 files in App/iOS" && store.error == nil)
    }

    @Test func typingWhileTheHostDraftsWinsOverTheDraft() async {
        let fake = host()
        let store = fake.store()
        fake.answer = { [weak store] query in
            if case .commitMessage = query { store?.title = "Mine" ; return .commitMessage(title: "Theirs", body: "", drafted: true) }
            return .commitInfo(info())
        }

        await store.begin()

        #expect(store.title == "Mine" && !store.drafted)
    }

    @Test func aHostThatCantSayLeavesTheSheetUnavailable() async {
        let store = CommitFakeHost { _ in throw RemoteHostClientError.rejected(code: "query_failed", message: "Not a git repository") }.store()

        await store.begin()

        #expect(store.stage == .unavailable("Not a git repository"))
    }

    @Test func untickingEveryFileOrClearingTheSummaryDisablesCommit() async {
        let store = host().store()
        await store.begin()

        store.selectAll(false)
        #expect(store.problem == "Choose at least one file." && !store.canCommit)
        store.toggle("App/iOS/HostCard.swift")
        #expect(store.canCommit && store.selectedFiles.map(\.path) == ["App/iOS/HostCard.swift"])
        store.title = " "
        #expect(store.problem == "Write a commit message.")
    }

    @Test func aPullRequestFromTheDefaultBranchNamesItsNewBranch() async {
        let store = host(info: info(branch: "main", upstream: "origin/main")).store()
        await store.begin()
        #expect(store.newBranch == nil)

        store.pullRequest = true

        #expect(store.newBranch == "shepherd/show-host-cards" && store.destination == .pullRequest)
    }

    @Test func committingSendsTheTickedFilesWithTheirFingerprintsThenPolls() async {
        let fake = host(info: info(working: true))
        let store = fake.store()
        await store.begin()
        store.toggle("App/iOS/FleetView.swift")
        #expect(!store.canCommit)
        store.confirmedWhileWorking = true

        await store.commit()

        guard case .commit(let id, let options)? = fake.asked.last else { Issue.record("expected a commit"); return }
        #expect(options.files == [file("App/iOS/HostCard.swift", "A")] && options.head == "abc" && options.push == .upstream)
        #expect(options.title == "Show host cards" && options.confirmedWhileWorking)
        #expect(store.stage == .operation && store.operationID == id && store.outcome == .running)

        #expect(await store.pollOnce())
        #expect(store.outcome == .succeeded(prURL: nil))
        #expect(store.steps.map(\.state) == [.done("on feat/rows"), .done("committed 1a2b3c4")])
    }

    @Test func aRefusedCommitBringsTheFormBackWithWhy() async {
        let store = host(commit: .failure(.rejected(code: "query_failed", message: "README.md changed since the sheet opened."))).store()
        await store.begin()

        await store.commit()

        #expect(store.stage == .form && store.operationID == nil && store.error == "README.md changed since the sheet opened.")
    }

    @Test func aRefusalBecauseTheAgentStartedWorkingOffersTheConfirmation() async {
        let fake = host(commit: .failure(.rejected(code: "query_failed", message: "busy is working. Confirm to commit anyway.")))
        let store = fake.store()
        await store.begin()
        fake.answer = { query in
            switch query {
            case .commitInfo: return .commitInfo(info(working: true))
            default: throw RemoteHostClientError.rejected(code: "query_failed", message: "busy is working. Confirm to commit anyway.")
            }
        }

        await store.commit()

        #expect(store.stage == .form && store.info?.agentWorking == true && store.info?.head == "abc")
        #expect(store.problem == "Confirm committing while the agent works." && !store.canCommit)
        store.confirmedWhileWorking = true
        #expect(store.canCommit && store.title == "Show host cards", "the typed form stays")
    }

    @Test func closingAfterAnUnknownOutcomeStartsOverWhileARunningCommitKeepsItsProgress() async {
        let store = host(commit: .failure(.timeout)).store()
        await store.begin()
        await store.commit()

        #expect(store.closed())
        #expect(store.operationID == nil && store.stage == .loading)

        store.adopt(RemoteWorktreeOperation(id: UUID(), progress: ["check the checkout: working…"]))
        #expect(!store.closed() && store.operationID != nil, "a running commit keeps its progress")
    }

    @Test func anUnknownOutcomeKeepsPollingRatherThanCommittingAgain() async {
        let store = host(commit: .failure(.timeout)).store()
        await store.begin()

        await store.commit()

        #expect(store.stage == .operation && store.operationID != nil)
        #expect(store.error?.hasPrefix("Outcome not yet known") == true)
        #expect(!store.canCommit)
    }

    @Test func reopeningAfterAFinishedCommitStartsOver() async {
        let fake = host()
        let store = fake.store()
        await store.begin()
        await store.commit()
        await store.pollOnce()

        await store.begin()

        #expect(store.stage == .form && store.operation == nil && fake.asked.filter { $0 == .commitInfo }.count == 2)
    }
}
