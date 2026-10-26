import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdSessions
import ShepherdUI
@testable import ShepherdApp

/// What the Git chip and panel say for each state the boards draw (DesignGitStatus,
/// GitDesignChanges), from the engine's own state values.
@Suite("Design Git presentation")
struct DesignGitPresentationTests {
    private static let ours = DesignGitStatus.Commit(hash: "8f31c2a", subject: "Show absolute counts in the checkout funnel",
                                                    author: "Baily", files: ["project/A.dc.html", "project/canvas.json"])
    private static let theirs = DesignGitStatus.Commit(hash: "c71d9e4", subject: "Clarify phone step labels", author: "Sam",
                                                      files: ["project/A-phone.dc.html"])

    private static func status(ahead: Int = 0, behind: Int = 0, files: [DesignGitStatus.File] = [], offline: Bool = false,
                               incoming: DesignGitStatus.Commit? = nil, pushFailed: String? = nil) -> DesignGitStatus {
        DesignGitStatus(branch: "main", remoteURL: "git@github.com:acme/checkout-design.git", upstream: "origin/main",
                        ahead: ahead, behind: behind, files: files, fetchedAt: 1_000, offline: offline, incoming: incoming, pushFailed: pushFailed)
    }

    private static func merge(_ phase: DesignGitMerge.Phase) -> DesignGitMerge {
        DesignGitMerge(phase: phase, ours: ours, theirs: theirs, oursHash: "a", theirsHash: "b")
    }

    @Test(arguments: [
        (nil, "Share with Git", SHGitTone.primary),
        (DesignGitState(status: status()), "main · Up to date", .done),
        (DesignGitState(status: status(files: [.init(path: "project/A.dc.html", letter: "M"), .init(path: "project/canvas.json", letter: "M"),
                                               .init(path: "project/A-phone.dc.html", letter: "M")])), "main · 3 changes", .primary),
        (DesignGitState(status: status(files: [.init(path: "project/A.dc.html", letter: "M")])), "main · 1 change", .primary),
        (DesignGitState(status: status(behind: 1, incoming: theirs)), "main · Pull 1", .running),
        (DesignGitState(status: status(ahead: 1)), "main · Push 1", .primary),
        (DesignGitState(status: status(ahead: 1, behind: 1), merge: merge(.conflict)), "main · Pull paused", .attention),
        (DesignGitState(status: status(ahead: 1, behind: 1), merge: merge(.running)), "main · Merging", .running),
        (DesignGitState(status: status(ahead: 1, behind: 1), merge: merge(.ready)), "main · Merge ready", .attention),
        (DesignGitState(status: status(offline: true)), "main · Offline", .secondary),
    ] as [(DesignGitState?, String, SHGitTone)])
    func theChipSaysTheBranchAndItsMostUrgentState(state: DesignGitState?, label: String, tone: SHGitTone) {
        let chip = DesignGitPresentation.chip(state, drawing: false)
        #expect(chip.label == label)
        #expect(chip.tone == tone)
        #expect(chip.hint == (state == nil ? DesignGitPresentation.shareHint : DesignGitPresentation.statusHint))
    }

    @Test func thePanelListsLocalChangesWithTheirBoardsAndBothCommitButtons() {
        let board = DesignIndex.Board(x: 0, y: 0, w: 390, h: 844, title: "Funnel first")
        let state = DesignGitState(status: Self.status(files: [.init(path: "project/A.dc.html", letter: "M"), .init(path: "project/canvas.json", letter: "M")]))
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: "project/A.dc.html", preview: nil,
                                                      boards: [try! DesignPath.validate("A.dc.html"): board], lastChecked: nil))
        #expect(panel.branch == "main" && panel.repository == "acme/checkout-design")
        #expect(panel.sync == "Remote is up to date" && panel.syncTone == .done && !panel.canPull)
        #expect(panel.pullHint == "Commit local changes before pulling", "Pull says why it can't go")
        let changes = try! #require(panel.changes)
        #expect(changes.title == "Local changes" && changes.note == "Saved on this Mac. Not shared yet.")
        #expect(changes.files.map(\.id) == ["A.dc.html", "canvas.json"])
        #expect(changes.files.map(\.label) == ["Funnel first", "Board placement"])
        #expect(changes.selected == "A.dc.html")
        #expect(changes.localTitle == "Commit locally" && changes.pushTitle == "Commit & push" && changes.canCommit && changes.canPush)
        #expect(panel.notice == nil && panel.incoming == nil && panel.pushTitle == nil)
    }

    @Test func theCommitButtonsWaitForAMessageAndAFailureShowsInTheNotice() {
        let state = DesignGitState(status: Self.status(files: [.init(path: "project/A.dc.html", letter: "M")]))
        let empty = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:],
                                                      lastChecked: nil, failure: nil, hasMessage: false))
        #expect(empty.changes?.canCommit == false && empty.changes?.canPush == false)
        let failed = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:],
                                                       lastChecked: nil, failure: "Commit local changes before pulling.", hasMessage: true))
        #expect(failed.notice == .init(title: "Git couldn't finish", text: "Commit local changes before pulling.", tone: .attention))
    }

    @Test(arguments: [("A · Funnel first", "Funnel first"), ("A · phone", "Phone"), ("Checkout", "Checkout"), ("", nil)] as [(String, String?)])
    func aFileIsNamedByItsBoardsTitleWithoutItsLetter(title: String, name: String?) {
        #expect(DesignGitPresentation.boardName(title) == name)
    }

    @Test func whileTheAgentDrawsCommitAndPullWait() {
        let state = DesignGitState(status: Self.status(files: [.init(path: "project/A.dc.html", letter: "M")]))
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: true, working: false, selected: nil, preview: nil, boards: [:], lastChecked: nil))
        #expect(panel.notice?.title == "Design agent is drawing")
        #expect(panel.changes?.canCommit == false && panel.changes?.canPush == false)
        #expect(panel.pullHint == "Wait for the design agent to finish this turn")
    }

    @Test func anIncomingCommitOffersPullAndNamesItsAuthor() {
        let state = DesignGitState(status: Self.status(behind: 1, incoming: Self.theirs))
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:], lastChecked: nil))
        #expect(panel.sync == "1 commit to pull · no local changes" && panel.syncTone == .running)
        #expect(panel.canPull && panel.pullHint == "Pull the new commit and reload the design")
        #expect(panel.incoming == SHGitPanelState.Incoming(subject: "Clarify phone step labels", author: "Sam", hash: "c71d9e4",
                                                           files: ["A-phone.dc.html"]))
        #expect(panel.changes == nil)
    }

    @Test func aFailedPushKeepsTheCommitAndOffersRetry() {
        let state = DesignGitState(status: Self.status(ahead: 1, pushFailed: "Could not resolve host"))
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:], lastChecked: nil))
        #expect(panel.sync == "1 local commit · push failed" && panel.syncTone == .attention)
        #expect(panel.notice?.title == "Your commit is safe on this Mac")
        #expect(panel.pushTitle == "Retry push")
    }

    @Test func offlineSaysWhenTheRemoteWasLastReachedAndHoldsPush() {
        let state = DesignGitState(status: Self.status(files: [.init(path: "project/A.dc.html", letter: "M")], offline: true))
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:],
                                                      lastChecked: 1_791_900_000_000))
        #expect(panel.sync.hasPrefix("Offline · last checked "))
        #expect(panel.notice?.title == "You can keep working offline")
        #expect(panel.changes?.canCommit == true && panel.changes?.canPush == false)
    }

    @Test func aReadyMergeIsReviewedFileByFileWithTheMergeButtons() {
        let state = DesignGitState(status: Self.status(ahead: 1, behind: 1), merge: Self.merge(.ready),
                                   mergeFiles: [.init(path: "project/A-phone.dc.html", letter: "M")])
        let panel = DesignGitPresentation.panel(.init(state: state, drawing: false, working: false, selected: nil, preview: nil, boards: [:], lastChecked: nil))
        #expect(panel.sync == "Merge prepared · not committed" && panel.syncTone == .attention)
        #expect(panel.notice?.title == "Agent resolved the merge" && panel.notice?.tone == .done)
        #expect(panel.changes?.title == "Review merge")
        #expect(panel.changes?.localTitle == "Commit merge locally" && panel.changes?.pushTitle == "Commit merge & push")
        #expect(panel.changes?.files.map(\.id) == ["A-phone.dc.html"])
    }

    @Test(arguments: [
        ("git@github.com:acme/checkout-design.git", "acme/checkout-design"),
        ("https://github.com/acme/checkout-design.git", "acme/checkout-design"),
        ("ssh://git@gitlab.example.com/team/design", "team/design"),
    ])
    func theRepositoryIsShownByOwnerAndName(url: String, shown: String) {
        #expect(DesignGitPresentation.repository(url) == shown)
    }

    @Test func thePreviewShowsTheTextThatChangedWithoutItsMarkup() {
        // One line holding several labels: only the one that changed shows.
        let before = "<x-dc><style>p{}</style><div><p>Step 1</p><p>90%</p></div><div><p>Checkout started</p></div></x-dc>"
        let after = "<x-dc><style>p{}</style><div><p>Step 1</p><p>90%</p></div><div><p>Checkout started · 12,904</p></div></x-dc>"
        let (a, b) = DesignGitPresentation.firstDifference(before, after)
        #expect(a == "Checkout started" && b == "Checkout started · 12,904")
        // A change to markup alone (a comment, a style) says so.
        let (c, d) = DesignGitPresentation.firstDifference(before, before.replacingOccurrences(of: "</x-dc>", with: "<!-- x --></x-dc>"))
        #expect(c == "Markup only" && d == "Markup only")
    }

    @Test func theMergeDialogCallsTheLocalCommitYoursAndListsBoardsFirst() {
        let local = DesignGitPresentation.commit(Self.ours, local: true)
        #expect(local.author == "You")
        #expect(local.files == ["A.dc.html", "canvas.json"])
        #expect(DesignGitPresentation.commit(Self.theirs).author == "Sam")
    }

    @Test(arguments: [
        (DesignGitMerge.Phase.conflict, nil),
        (.running, SHGitMergePhase.running),
        (.ready, .ready),
        (.stopped, .stopped(nil)),
    ] as [(DesignGitMerge.Phase, SHGitMergePhase?)])
    func theChatShowsTheMergeOnlyOnceItIsTheAgents(phase: DesignGitMerge.Phase, card: SHGitMergePhase?) {
        #expect(DesignGitPresentation.mergePhase(Self.merge(phase)) == card)
    }
}
