import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The side pane's Changes tab (GXSidePane) draws the files and one diff: no toolbar, no compare row. What they held lives in the
/// pane's ⋯ menu, which acts on the same model (the pane itself is drawn in `GXBoardPreviewTests.sidePane`).
@Suite("Compact review pane", .mainActorExclusive)
@MainActor
struct ReviewCompactPaneTests {
    private func file(_ name: String) -> DiffFile {
        DiffFile(oldPath: name, newPath: name, displayPath: name, isNew: false, isDeleted: false, isRenamed: false, isBinary: false,
                 hunks: [DiffHunk(header: "@@ -1,2 +1,2 @@", lines: [
                    DiffLine(kind: .removed, text: "old \(name)", oldLine: 1, newLine: nil, id: 0),
                    DiffLine(kind: .added, text: "new \(name)", oldLine: nil, newLine: 1, id: 1),
                 ])])
    }

    @Test func aRowShowsItsFileAndKeepsAViewedMark() {
        let model = ListFixtures.reviewModel([file("a.swift"), file("b.swift")])
        model.session.viewed = ["b.swift"]
        model.show("b.swift")
        #expect(model.currentFile == "b.swift", "the row's file is the one on show")
        #expect(model.session.viewed == ["b.swift"], "showing a viewed file does not un-view it")
        model.toggleViewed("b.swift")
        #expect(model.session.viewed.isEmpty, "the ⋯ menu's Viewed mark toggles it")
    }

    @Test func commitIsOfferedOnlyWithChangesToCommit() {
        let model = ListFixtures.reviewModel([file("a.swift")])
        #expect(model.canCommit, "a working-tree review with files")
        let empty = ListFixtures.reviewModel([])
        #expect(!empty.canCommit, "nothing to commit")
    }
}
