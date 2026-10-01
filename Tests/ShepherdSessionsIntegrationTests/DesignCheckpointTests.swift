import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Checkpoints (docs/designs.md › Checkpoints): a named state of every board and canvas.json that
/// one call puts back as one revision, after saving the design as it was so a restore can be undone.
@Suite("Design checkpoints", .integrationTimeLimit)
struct DesignCheckpointTests {
    typealias T = DesignToolsStoreTests
    let t = DesignToolsStoreTests()

    /// A, B and C drawn on the canvas, each with its own words.
    func threeBoards() async throws -> (h: ScratchServer, design: Design) {
        let (h, design) = try await t.serverWithDesign()
        try await t.draw(h, design, [T.a: T.board("<p>A one</p>"), T.b: T.board("<p>B one</p>"), T.c: T.board("<p>C one</p>")])
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        return (h, design)
    }

    func checkpoint(_ h: ScratchServer, _ design: Design, _ action: DesignCheckpointRequest.Action, _ name: String? = nil) async throws -> DesignCheckpointResult {
        try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: action, name: name))
    }

    // MARK: Saving

    @Test func aCheckpointHoldsEveryBoardAndTheCanvasAndMovesNoRevision() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        let at = try await t.revision(h, design)
        let made = try await checkpoint(h, design, .create, "  before   chip move ")
        #expect(made.checkpoint?.name == "before chip move" && made.checkpoint?.boards == 3 && made.checkpoint?.revision == at)
        #expect(made.checkpoints.map(\.name) == ["before chip move"] && made.pruned.isEmpty)
        #expect(try await t.revision(h, design) == at, "saving changes no file of the design")
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)
        // It is kept beside project/, never in it: nothing serves it and an export carries none.
        let folder = try #require(h.server.designs.folder(for: design.id))
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("checkpoints").path))
        #expect(!t.files(h, design).keys.contains { $0.hasPrefix("checkpoints") })
        let listed = try await checkpoint(h, design, .list)
        #expect(listed.checkpoints == made.checkpoints && listed.checkpoint == nil)
    }

    @Test func aNameIsValidatedAndUniqueWhateverItsCase() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        _ = try await checkpoint(h, design, .create, "Before chip move")
        for name in ["before CHIP move", "BEFORE  chip   move"] {
            do {
                _ = try await checkpoint(h, design, .create, name)
                Issue.record("\(name) was accepted twice")
            } catch let error as DesignStoreError {
                #expect(error.code == "checkpoint_exists")
            }
        }
        for name in ["", "../escape", "-rf", "a/b", "name;rm", String(repeating: "x", count: 61)] {
            do {
                _ = try await checkpoint(h, design, .create, name)
                Issue.record("\(name) was accepted")
            } catch let error as DesignStoreError {
                #expect(error.code == "invalid_checkpoint", "\(name): \(error)")
            }
        }
        do {
            _ = try await h.server.designCheckpoint(design.id, request: DesignCheckpointRequest(action: .create))
            Issue.record("a checkpoint with no name was made")
        } catch let error as DesignStoreError {
            #expect(error.code == "invalid_checkpoint")
        }
        #expect(try await checkpoint(h, design, .list).checkpoints.map(\.name) == ["Before chip move"])
        let folder = try #require(h.server.designs.folder(for: design.id)).appendingPathComponent("checkpoints")
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).count == 1, "no staging left behind, nothing outside")
    }

    // MARK: Restoring

    @Test func aRestorePutsEveryBoardAndTheCanvasBackAsOneRevision() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        let original = t.files(h, design)
        let originalIndex = try await h.server.designSnapshot(design.id).index
        _ = try await checkpoint(h, design, .create, "before chip move")

        // Everything a design does after it: a board rewritten, one deleted, one added, a frame moved, a title changed.
        _ = try await h.server.writeDesignBoard(design.id, path: T.a, source: T.board("<p>A two</p>"))
        _ = try await h.server.writeDesignBoard(design.id, path: DesignPath("D.dc.html")!, source: T.board("<p>D</p>"))
        _ = try await h.server.updateDesignIndex(design.id, patch: .object([
            "title": .string("Renamed"),
            "boards": .object(["C.dc.html": .null, "B.dc.html": .object(["x": .number(9_000)]),
                               "D.dc.html": .object(["x": .number(0), "y": .number(1_000), "w": .number(390), "h": .number(844)])]),
        ]))
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let before = try await t.revision(h, design)

        let restored = try await checkpoint(h, design, .restore, "before chip move")
        #expect(restored.restored == ["A.dc.html"] && restored.recreated == ["C.dc.html"] && restored.removed == ["D.dc.html"])
        #expect(restored.write?.changed == true && restored.write?.revision == before + 1, "one revision")
        let after = try await h.server.designSnapshot(design.id)
        #expect(after.revision == before + 1)
        #expect(after.index == originalIndex, "the canvas is as it was, boards, frames and title")
        #expect(t.files(h, design).filter { $0.key.hasSuffix(".dc.html") } == original.filter { $0.key.hasSuffix(".dc.html") })
        #expect(h.server.state.designs.first?.name == "Checkout funnel", "the design's name follows the canvas's title")
        await drainMainQueue()
        #expect(h.broadcasts.current.count == 1, "one broadcast for the whole restore")
        #expect(try await h.server.designVersions(design.id, path: T.a).count == 2, "what the restore replaced is a version, as with any write")
    }

    @Test func aRestoreSavesTheDesignFirstSoItCanBeUndone() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        _ = try await checkpoint(h, design, .create, "before chip move")
        _ = try await h.server.writeDesignBoard(design.id, path: T.a, source: T.board("<p>A two</p>"))
        _ = try await h.server.writeDesignBoard(design.id, path: DesignPath("D.dc.html")!, source: T.board("<p>D</p>"))

        let restored = try await checkpoint(h, design, .restore, "before chip move")
        #expect(restored.automatic?.name == "before restore before chip move" && restored.automatic?.boards == 4)
        #expect(Set(restored.checkpoints.map(\.name)) == ["before chip move", "before restore before chip move"])
        #expect(try await h.server.designBoard(design.id, path: T.a).source.contains("A one"))

        // Undo: restoring what it saved brings the later work back, in one revision again.
        let before = try await t.revision(h, design)
        let undone = try await checkpoint(h, design, .restore, "before restore before chip move")
        #expect(undone.write?.revision == before + 1 && undone.recreated == ["D.dc.html"] && undone.restored == ["A.dc.html"])
        #expect(try await h.server.designBoard(design.id, path: T.a).source.contains("A two"))
        #expect(try await h.server.designBoard(design.id, path: DesignPath("D.dc.html")!).source.contains(">D<"))
        #expect(undone.automatic?.name == "before restore before restore before chip move")
    }

    @Test func aRestoreWhereNothingDiffersWritesNothingAndSavesNothing() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        _ = try await checkpoint(h, design, .create, "now")
        let at = try await t.revision(h, design)
        let restored = try await checkpoint(h, design, .restore, "now")
        #expect(restored.write?.changed == false && restored.automatic == nil && restored.checkpoints.map(\.name) == ["now"])
        #expect(try await t.revision(h, design) == at)
        await drainMainQueue()
        #expect(h.broadcasts.current.isEmpty)
    }

    @Test func aRestoreNeverTouchesCommentsOrInstalledSystems() async throws {
        let (h, design) = try await serverWithComment()
        defer { h.stop() }
        let comment = try await h.server.designComments(design.id).comments[0]
        _ = try await checkpoint(h, design, .create, "before")

        try await t.installSystem(h, design)
        let installed = try await h.server.designSnapshot(design.id).index.designSystems
        #expect(installed?.map(\.namespace) == ["acme"])
        let ds = t.files(h, design).filter { $0.key.hasPrefix("ds/") }
        _ = try await h.server.writeDesignBoard(design.id, path: T.a, source: T.board(#"<div data-el="Checkout funnel"><h2>Checkout funnel</h2><h3>New</h3><p>48,210 people</p></div>"#))
        let reply = try await h.server.replyToDesignComment(design.id, commentID: comment.id, text: "Done.", author: .agent)
        #expect(reply.comment.replies.count == 1)
        let commentsBefore = try await h.server.designComments(design.id)

        _ = try await checkpoint(h, design, .restore, "before")
        let after = try await h.server.designSnapshot(design.id)
        #expect(after.index.designSystems == installed, "a system installed since the checkpoint stays installed")
        #expect(t.files(h, design).filter { $0.key.hasPrefix("ds/") } == ds && !ds.isEmpty, "its files are untouched")
        let commentsAfter = try await h.server.designComments(design.id)
        #expect(commentsAfter.comments.count == commentsBefore.comments.count)
        let kept = try #require(commentsAfter.comments.first)
        #expect(kept.id == comment.id && kept.text == comment.text && kept.replies == commentsBefore.comments[0].replies
                && kept.resolvedAt == nil, "the comment, its reply and its state are what they were")
    }

    private func serverWithComment() async throws -> (h: ScratchServer, design: Design) {
        let (h, design) = try await t.serverWithDesign()
        let root = #"<div data-el="Checkout funnel" style="width: 390px; height: 844px"><h2>Checkout funnel</h2><p>48,210 people</p></div>"#
        try await t.draw(h, design, [T.a: DesignTests.board(root: root)])
        _ = try await h.server.addDesignComment(design.id, draft: DesignCommentDraft(board: T.a, tid: 4, path: [1, 1], text: "Show the counts."))
        return (h, design)
    }

    @Test func aRestoreDoesNotHoldABoardToTheChecksAWriteWould() async throws {
        let (h, design) = try await t.serverWithDesign()
        defer { h.stop() }
        try await t.draw(h, design, [T.a: T.board("<p>A</p>")])
        // A board an import brought along that the lint would refuse (an iframe), put in place as an import does.
        let url = try #require(h.server.designs.projectFolder(for: design.id)).appendingPathComponent("B.dc.html")
        let imported = T.board("<p>B</p><iframe src=\"https://example.com\"></iframe>")
        try Data(imported.utf8).write(to: url)
        try await h.server.designs.run { h.server.designs.forget(design.id) }
        #expect(try await h.server.designSnapshot(design.id).boards.keys.contains(T.b))
        _ = try await checkpoint(h, design, .create, "as imported")

        _ = try await h.server.editDesignBoard(design.id, path: T.b, edits: [DesignBoardEdit(find: "<iframe src=\"https://example.com\"></iframe>", replace: "")])
        #expect(try await h.server.designBoard(design.id, path: T.b).source.contains("iframe") == false)
        let restored = try await checkpoint(h, design, .restore, "as imported")
        #expect(restored.restored == ["B.dc.html"], "the checkpoint's content comes back as it was kept")
        #expect(try await h.server.designBoard(design.id, path: T.b).source == imported)
    }

    @Test func anUnknownCheckpointIsRefusedAndTouchesNothing() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        let project = t.files(h, design), at = try await t.revision(h, design)
        do {
            _ = try await checkpoint(h, design, .restore, "never saved")
            Issue.record("restored a checkpoint that does not exist")
        } catch let error as DesignStoreError {
            #expect(error.code == "no_such_checkpoint" && error.description.contains("checkpoint_list"))
        }
        #expect(t.files(h, design) == project)
        #expect(try await t.revision(h, design) == at)
        #expect(try await checkpoint(h, design, .list).checkpoints.isEmpty, "a failed restore saved nothing")
    }

    // MARK: Bounds

    @Test func aDesignKeepsAFewCheckpointsAndDropsTheOldestWithANote() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        h.server.designs.checkpointCaps.count = 3
        var pruned: [String] = []
        for n in 1...5 {
            let made = try await checkpoint(h, design, .create, "save \(n)")
            pruned += made.pruned
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(pruned == ["save 1", "save 2"])
        #expect(try await checkpoint(h, design, .list).checkpoints.map(\.name) == ["save 3", "save 4", "save 5"], "oldest first")
    }

    @Test func theByteCapRefusesAHugeCheckpointAndDropsOldOnesToFitANewOne() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        let size = try await checkpoint(h, design, .create, "first").checkpoint?.bytes ?? 0
        #expect(size > 0)
        h.server.designs.checkpointCaps.bytes = size * 2 - 1
        let second = try await checkpoint(h, design, .create, "second")
        #expect(second.pruned == ["first"] && second.checkpoints.map(\.name) == ["second"], "two would not fit")
        h.server.designs.checkpointCaps.bytes = size - 1
        do {
            _ = try await checkpoint(h, design, .create, "third")
            Issue.record("a checkpoint over the cap was kept")
        } catch let error as DesignStoreError {
            #expect(error.code == "checkpoint_too_large" && error.description.contains("MB"))
        }
        #expect(try await checkpoint(h, design, .list).checkpoints.map(\.name) == ["second"], "a refused one drops nothing")
    }

    @Test func theSaveARestoreMakesNeverDropsTheCheckpointBeingRestored() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        _ = try await checkpoint(h, design, .create, "oldest")
        try await Task.sleep(for: .milliseconds(5))
        _ = try await checkpoint(h, design, .create, "newer")
        _ = try await h.server.writeDesignBoard(design.id, path: T.a, source: T.board("<p>A two</p>"))
        h.server.designs.checkpointCaps.count = 2
        let restored = try await checkpoint(h, design, .restore, "oldest")
        #expect(restored.pruned == ["newer"], "the one being restored is protected, so another makes room")
        #expect(Set(restored.checkpoints.map(\.name)) == ["oldest", "before restore oldest"])
        #expect(try await h.server.designBoard(design.id, path: T.a).source.contains("A one"))
    }

    @Test func aDuplicateOfTheDesignStartsWithNoCheckpoints() async throws {
        let (h, design) = try await threeBoards()
        defer { h.stop() }
        _ = try await checkpoint(h, design, .create, "before chip move")
        let copy = try await h.server.duplicateDesign(design.id)
        #expect(try await h.server.designCheckpoint(copy.id, request: DesignCheckpointRequest(action: .list)).checkpoints.isEmpty,
                "checkpoints stay with the original, as versions and comments do")
        #expect(try await checkpoint(h, design, .list).checkpoints.count == 1)
    }
}
