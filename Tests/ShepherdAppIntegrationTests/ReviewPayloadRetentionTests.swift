import Foundation
import Observation
import SwiftUI
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The model outlives the lazy diff subtree (empty/error scopes and detached panes included).
@Suite("Review payload retention", .mainActorExclusive)
@MainActor
struct ReviewPayloadRetentionTests {
    private func file(_ name: String) -> DiffFile {
        DiffFile(oldPath: name, newPath: name, displayPath: name, isNew: false, isDeleted: false, isRenamed: false,
                 isBinary: false, hunks: [DiffHunk(header: "@@ -1,2 +1,2 @@", lines: [
                    DiffLine(kind: .context, text: "package main", oldLine: 1, newLine: 1, id: 0),
                    DiffLine(kind: .removed, text: "var value = 1", oldLine: 2, newLine: nil, id: 1),
                    DiffLine(kind: .added, text: "var value = 2", oldLine: nil, newLine: 2, id: 2),
                 ])])
    }

    private func model(_ files: [DiffFile]) -> ReviewPaneModel {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/review-retention", reference: nil, files: files)
        return ReviewPaneModel(session: session, actions: ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}))
    }

    @Test func unchangedRefreshDuringHighlightingFinishesTheRemainingFiles() async throws {
        let files = [file("first.go"), file("second.go")]
        let model = model(files)
        let version = model.session.filesVersion
        // Refresh synchronously at the first publication, before the next file starts.
        withObservationTracking {
            _ = model.highlights
        } onChange: {
            MainActor.assumeIsolated {
                model.session.adopt(files: files, truncated: [])
            }
        }
        let window = OffscreenWindow(ReviewPaneContent(model: model))
        defer { window.close() }
        try await eventuallyOnMain("unchanged refresh finishes highlighting both files") {
            files.allSatisfy { model.highlights[$0.id] != nil }
        }
        #expect(model.session.filesVersion == version + 1)
        #expect(model.session.files == files)
    }

    @Test(arguments: [false, true])
    func departedPayloadIsReleasedWithoutADiffViewAndReturningScopesRecompute(error: Bool) async throws {
        let a = file("a.go"), b = file("b.go"), shared = file("shared.go")
        let model = model([a, shared])
        await model.highlightFiles(style: .theme)
        _ = model.rows(for: a) // CachedRows itself strongly retains the highlight.
        _ = model.splitLineWidths(a, textScale: 1)
        let sharedRows = model.rows(for: shared)
        let expectedColors = try #require(model.highlights[a.id]?.lines)
        weak var departed = model.highlights[a.id]
        weak var live = model.highlights[shared.id]
        #expect(departed != nil && live != nil)

        // Metadata is deliberately not payload: it survives a scope leaving and returning.
        model.collapsed = [a.id]
        model.revealed[a.id] = IndexSet(integer: 1)
        model.currentFile = a.id
        model.session.viewed = [a.id]
        model.session.comments = [ReviewComment(fileID: a.id, lineID: 2, filePath: a.id, lineNumber: 2,
                                                marker: "+", content: "var value = 2", text: "Keep this note")]
        let scroll = model.splitScroll(for: a.id)
        scroll.resize(oldWidth: 500, newWidth: 500, viewport: 100)
        scroll.move(to: 40, old: false)

        // No view is mounted, and no new highlighting/row request drives this eviction.
        model.session.files = [b, shared]
        try await eventuallyOnMain("departed highlight and its cached rows released") { departed == nil }
        #expect(Set(model.highlights.keys) == [shared.id])
        #expect(model.highlights[shared.id] === live, "pruning does not discard unchanged live colors")
        #expect(model.rows(for: shared) == sharedRows)
        await model.highlightFiles(style: .theme)
        _ = model.rows(for: b)
        _ = model.splitLineWidths(b, textScale: 1)
        weak var second = model.highlights[b.id]

        model.session.files = [a, shared]
        await model.highlightFiles(style: .theme)
        try await eventuallyOnMain("second departed scope released") { second == nil }
        #expect(model.highlights[a.id]?.lines == expectedColors, "returning scopes recompute the same colors")
        #expect(model.rows(for: shared) == sharedRows, "live rows remain reusable across both changes")
        #expect(model.collapsed == [a.id] && model.revealed[a.id] == IndexSet(integer: 1))
        #expect(model.currentFile == a.id && model.session.viewed == [a.id])
        #expect(model.session.comments.first?.text == "Keep this note")
        #expect(model.splitScroll(for: a.id) === scroll && scroll.newOffset == 40)

        _ = model.rows(for: a)
        _ = model.splitLineWidths(a, textScale: 1)
        weak var returning = model.highlights[a.id]
        weak var remaining = model.highlights[shared.id]
        if error { model.session.loadError = "The scope could not be loaded" }
        model.session.files = []
        try await eventuallyOnMain("empty or failed scope releases every cached highlight and row") {
            returning == nil && remaining == nil && model.highlights.isEmpty
        }
        // A departing lazy section may still ask for its old file during a transition.
        _ = model.rows(for: a)
        _ = model.splitLineWidths(a, textScale: 1)
        #expect(model.highlights.isEmpty)
        #expect(model.session.comments.count == 1 && model.splitScroll(for: a.id) === scroll)
    }
}
