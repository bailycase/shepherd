import Foundation
import Testing
@testable import ShepherdProtocol

@Suite("Changes wire")
struct ChangesTests {
    static let turnID = UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!

    @Test(arguments: [
        (ChangesScope.lastTurn, "Last turn"),
        (.turn(id: turnID), "Last turn"),
        (.uncommitted, "Uncommitted"),
        (.unstaged, "Unstaged"),
        (.staged, "Staged"),
        (.commits(first: "a1c9f2e0", last: "a1c9f2e0"), "Commit · a1c9f2e"),
        (.commits(first: "5d11a07aa", last: "a1c9f2e00"), "Commits · 5d11a07–a1c9f2e"),
        (.branch(base: nil), "Branch · vs main"),
        (.branch(base: "origin/release/2.4"), "Branch · vs main"),
        (.pullRequest, "Pull request · vs main"),
    ])
    func scopeTitlesFollowTheBoards(scope: ChangesScope, title: String) {
        let comparison = ChangesComparison(head: "agent/refund-events", base: "origin/main", baseName: "main", mergeBase: "3f2a91c")
        #expect(changesTitle(scope: scope, comparison: comparison) == title)
    }

    @Test func aScopeWithoutItsComparisonIsJustItsLabel() {
        #expect(changesTitle(scope: .branch(base: nil), comparison: nil) == "Branch")
        #expect(ChangesScope.Kind.allCases.map(\.label) == ["Last turn", "Uncommitted", "Unstaged", "Staged", "Commits", "Branch", "Pull request"])
    }

    @Test(arguments: [
        (ChangesRevision(old: "4b825dc642cb6eb9a060e54bf8d69288fbee4904", new: "a1c9f2e"), true),
        (ChangesRevision(old: "HEAD", new: "a1c9f2e"), false),
        (ChangesRevision(old: "--output=/tmp/x", new: "a1c9f2e"), false),
        (ChangesRevision(old: "abc", new: "a1c9f2e"), false),
        (ChangesRevision(old: "A1C9F2E", new: "a1c9f2e"), false),
    ])
    func onlyObjectIDsAreRevisions(revision: ChangesRevision, wellFormed: Bool) {
        #expect(revision.isWellFormed == wellFormed)
    }

    @Test func optionsMissingFromOlderClientsAreOff() throws {
        #expect(try JSONDecoder().decode(ChangesOptions.self, from: Data("{}".utf8)) == ChangesOptions())
        #expect(try JSONDecoder().decode(ChangesOptions.self, from: Data(#"{"fullFiles":true}"#.utf8)) == ChangesOptions(fullFiles: true))
    }

    @Test(arguments: [
        (ChangesTurn.State.ready, 5, "Edited 5 files"),
        (.ready, 1, "Edited 1 file"),
        (.undone, 5, "Undid the agent’s edits to 5 files"),
    ])
    func aTurnsTitleSaysWhatItDid(state: ChangesTurn.State, files: Int, title: String) {
        #expect(ChangesTurn(startedAt: 0, state: state, fileCount: files).title == title)
    }

    @Test func aListSumsItsFiles() {
        let list = ChangesList(scope: .uncommitted, revision: .init(old: "aaaa", new: "bbbb"), comparison: .init(head: "Working tree", base: "HEAD"),
                               files: [ChangesFile(path: "a", status: .modified, added: 3, removed: 1),
                                       ChangesFile(path: "b", status: .added, added: 4, removed: 0)])
        #expect(list.added == 7 && list.removed == 1)
        #expect(list.title == "Uncommitted")
    }

    @Test func pullRequestLabelsSayDraft() {
        let pull = ChangesPullRequest(number: 31, title: "Refunds", isDraft: true, state: "OPEN", base: "main", head: "agent/refund-events", url: "u")
        #expect(pull.label == "#31 draft")
    }
}
