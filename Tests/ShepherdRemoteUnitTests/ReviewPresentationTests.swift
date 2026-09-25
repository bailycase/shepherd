import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

/// A remote review's rows and requests: the file list, totals, side-by-side rows, loading the
/// host's diff, and sending the review as the agent's turn.
@Suite("Review presentation")
struct ReviewPresentationTests {
    static let files = DiffFile.parse("""
    diff --git a/App/iOS/FleetView.swift b/App/iOS/FleetView.swift
    --- a/App/iOS/FleetView.swift
    +++ b/App/iOS/FleetView.swift
    @@ -1,4 +1,4 @@
     a
    -b
    -c
    +B
     d
    diff --git a/README.md b/README.md
    new file mode 100644
    --- /dev/null
    +++ b/README.md
    @@ -0,0 +1 @@
    +hello
    diff --git a/old.txt b/old.txt
    deleted file mode 100644
    --- a/old.txt
    +++ /dev/null
    @@ -1 +0,0 @@
    -bye
    """)

    @Test func eachFileIsARowWithItsNameDirectoryStatusStatAndComments() {
        let comment = ReviewComment(fileID: "App/iOS/FleetView.swift", lineID: 1, filePath: "App/iOS/FleetView.swift", lineNumber: 2, text: "x")
        let (rows, totals) = reviewSummaries(files: Self.files, comments: [comment], viewed: ["README.md", "gone.swift"])
        #expect(rows.map(\.name) == ["FleetView.swift", "README.md", "old.txt"])
        #expect(rows.map(\.directory) == ["App/iOS/", "", ""])
        #expect(rows.map(\.status) == [.modified, .added, .deleted])
        #expect(rows.map(\.comments) == [1, 0, 0])
        #expect(rows.map(\.viewed) == [false, true, false])
        #expect(rows[0].added == 1 && rows[0].removed == 2 && rows[0].hunks == 1)
        #expect(totals == ReviewTotals(files: 3, added: 2, removed: 3, viewed: 1), "a viewed mark on a file no longer in the diff doesn't count")
        #expect(totals.viewedText == "1 of 3 viewed")
        #expect(totals.filesText == "3 files")
    }

    @Test(arguments: [(3, 1, 1.0 / 3.0), (0, 0, 0.0), (1, 1, 1.0)])
    func progressIsTheViewedShare(files: Int, viewed: Int, progress: Double) {
        #expect(ReviewTotals(files: files, added: 0, removed: 0, viewed: viewed).progress == progress)
    }

    @Test(arguments: [(false, nil, "working tree vs HEAD"), (true, nil, "the pull request"),
                      (true, "origin/main...HEAD", "origin/main...HEAD"), (false, "", "working tree vs HEAD")] as [(Bool, String?, String)])
    func theScopeNamesWhatTheDiffCompares(pullRequest: Bool, reference: String?, text: String) {
        #expect(reviewScopeText(pullRequest: pullRequest, reference: reference) == text)
    }

    @Test func requestChangesNeedsALineOrOverallComment() {
        let comment = ReviewComment(fileID: "a", lineID: 0, filePath: "a", lineNumber: 1, text: "x")
        #expect(!reviewHasNotes(comments: [], summary: " \n"))
        #expect(reviewHasNotes(comments: [], summary: "ship it"))
        #expect(reviewHasNotes(comments: [comment], summary: ""))
    }

    // MARK: Side by side

    private func describe(_ rows: [ReviewSplitRow]) -> [String] {
        rows.map { row in
            switch row.kind {
            case .hunk: return "@@"
            case .pair(let old, let new): return "\(old?.text ?? "_")|\(new?.text ?? "_")"
            case .collapsed(_, let count, _, _, let side): return "fold \(count) \(side)"
            }
        }
    }

    @Test func aRemovalSitsBesideTheAdditionThatReplacedIt() {
        #expect(describe(reviewSplitRows(Self.files[0], expandedRuns: nil)) == ["@@", "a|a", "b|B", "c|_", "d|d"])
        #expect(describe(reviewSplitRows(Self.files[1], expandedRuns: nil)) == ["@@", "_|hello"])
        #expect(describe(reviewSplitRows(Self.files[2], expandedRuns: nil)) == ["@@", "bye|_"])
    }

    @Test func aFoldKeepsItsOwnRowOnItsSide() throws {
        let removed = (1...15).map { "-r\($0)" }.joined(separator: "\n")
        let added = (1...3).map { "+a\($0)" }.joined(separator: "\n")
        let file = try #require(DiffFile.parse("--- a/f.swift\n+++ b/f.swift\n@@ -1,15 +1,3 @@\n\(removed)\n\(added)\n").first)
        let rows = describe(reviewSplitRows(file, expandedRuns: []))
        // Five removals head the run and one tails it, beside the three additions in order.
        #expect(rows == ["@@", "r1|a1", "r2|a2", "r3|a3", "r4|_", "r5|_", "fold 9 old", "r15|_"])
        let key = try #require(reviewRows(file, expandedRuns: []).compactMap { row -> String? in
            if case .collapsed(let key, _, _, _) = row.kind { key } else { nil }
        }.first)
        #expect(reviewSplitRows(file, expandedRuns: [key]).count == 1 + 15)
    }

    @Test func rowIDsAreUniqueWithinAFile() {
        for file in Self.files {
            let ids = reviewSplitRows(file, expandedRuns: nil).map(\.id)
            #expect(Set(ids).count == ids.count)
        }
    }

    // MARK: Requests

    @Test func aReviewReplyDecodesToFilesAndReference() throws {
        let reply = RemoteAgentResult.review(files: try JSONEncoder().encode(Self.files), reference: "origin/main...HEAD")
        let (files, reference) = try remoteReviewFiles(reply)
        #expect(files == Self.files)
        #expect(reference == "origin/main...HEAD")
        #expect(throws: RemoteReviewError.unexpectedReply) { try remoteReviewFiles(.ok) }
    }

    @Test func sendingTheReviewFollowsUpOnTheLiveSession() async throws {
        var sent: [NativeThreadRequest] = []
        let operation = UUID(uuidString: "00000000-0000-0000-0000-0000000000AB")!
        try await remoteReviewSend("Commit these changes.", operationID: operation) { request in
            sent.append(request)
            if case .snapshot = request { return .snapshot(value: Self.snapshot(session: "s1")) }
            return .accepted(operationID: operation)
        }
        #expect(sent == [
            .snapshot(),
            .send(expectedSessionID: "s1", generation: "g1", operationID: operation, text: "Commit these changes.", delivery: .followUp),
        ])
    }

    @Test func sendingWaitsForAStartedAgentAndReportsARefusal() async throws {
        await #expect(throws: RemoteReviewError.notReady) {
            try await remoteReviewSend("x") { _ in .snapshot(value: Self.snapshot(session: "")) }
        }
        await #expect(throws: RemoteReviewError.rejected("busy")) {
            try await remoteReviewSend("x") { request in
                if case .snapshot = request { return .snapshot(value: Self.snapshot(session: "s1")) }
                return .failure(code: "busy", message: "busy")
            }
        }
    }

    static func snapshot(session: String) -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: session, generation: "g1", revision: 1, running: false, model: nil, thinking: nil,
                             supportedActions: ["send"], dialogsSupported: true, dialogs: [], messages: [], provisional: [],
                             clipped: false)
    }
}
