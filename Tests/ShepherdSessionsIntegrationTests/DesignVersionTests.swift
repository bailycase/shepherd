import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// A board's versions (docs/designs.md › Versions): each write keeps what it replaced, the last
/// 20 per board; a restore puts one back as a new write (so it can be undone too); and several
/// boards written at once are one change.
@Suite("Design versions", .integrationTimeLimit)
struct DesignVersionTests {
    static func board(_ text: String) -> String {
        DesignTests.board(root: #"<div style="width: 390px; height: 844px; padding: 8px">"# + text + "</div>")
    }

    private func serverWithDesign() async throws -> (h: ScratchServer, design: Design) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([Fixture.agent(in: space)], space: space))
        let design = Design(name: "Checkout funnel", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        return (h, design)
    }

    @Test func eachRewriteKeepsWhatItReplacedAndRestoringPutsItBack() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let main = try DesignPath.validate("flows/Main.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("One"))
        #expect(try await h.server.designVersions(design.id, path: main).isEmpty, "a new board keeps no version")
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Two"))
        let third = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Three"))
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Three"))

        let versions = try await h.server.designVersions(design.id, path: main)
        #expect(versions.map(\.number) == [1, 2], "a write that changes nothing keeps nothing")
        #expect(versions.map(\.sha256) == [DesignStore.sha256(Data(Self.board("One").utf8)), DesignStore.sha256(Data(Self.board("Two").utf8))])
        let snapshot = try await h.server.designSnapshot(design.id)
        #expect(snapshot.boards.keys.map(\.rawValue) == ["flows/Main.dc.html"], "versions are no boards")

        let restored = try await h.server.restoreDesignVersions(design.id, [main: 1], ifCurrent: [main: try #require(third.sha256)],
                                                                baseRevision: snapshot.revision)
        #expect(restored.result.changed && restored.result.revision == snapshot.revision + 1)
        #expect(restored.versions == [main: 3], "what the restore replaced is kept, so it can be undone")
        #expect(try await h.server.designBoard(design.id, path: main).source == Self.board("One"))
        let undone = try await h.server.restoreDesignVersions(design.id, [main: 3], ifCurrent: restored.shas)
        #expect(undone.versions == [main: 4])
        #expect(try await h.server.designBoard(design.id, path: main).source == Self.board("Three"))
    }

    /// An undo never takes back a later write: it names the hash it expects each board to have.
    @Test func aRestoreRefusesABoardThatChangedSince() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let main = try DesignPath.validate("Main.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("One"))
        let two = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Two"))
        _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Agent"))
        let before = try await h.server.designSnapshot(design.id)

        await #expect(throws: DesignStoreError.self) {
            try await h.server.restoreDesignVersions(design.id, [main: 1], ifCurrent: [main: try #require(two.sha256)])
        }
        await #expect(throws: DesignStoreError.noSuchVersion(main, 9)) {
            try await h.server.restoreDesignVersions(design.id, [main: 9])
        }
        #expect(try await h.server.designSnapshot(design.id) == before)
        #expect(try await h.server.designBoard(design.id, path: main).source == Self.board("Agent"))
    }

    @Test func aBoardKeepsItsLastTwentyVersions() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let main = try DesignPath.validate("Main.dc.html")
        for index in 0...25 { _ = try await h.server.writeDesignBoard(design.id, path: main, source: Self.board("Take \(index)")) }
        let versions = try await h.server.designVersions(design.id, path: main)
        #expect(versions.count == DesignBoardVersion.kept)
        #expect(versions.map(\.number) == Array(6...25))
        #expect(versions.last?.sha256 == DesignStore.sha256(Data(Self.board("Take 24").utf8)))
    }

    /// A tweak on every element of a name writes each board it reaches as one change: one
    /// revision, one broadcast, and a version kept per board.
    @Test func severalBoardsWriteAsOneChange() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let a = try DesignPath.validate("A.dc.html"), phone = try DesignPath.validate("A-phone.dc.html")
        _ = try await h.server.writeDesignBoards(design.id, sources: [a: Self.board("A"), phone: Self.board("Phone")])
        await drainMainQueue()
        h.broadcasts.withValue { $0.removeAll() }
        let base = try await h.server.designSnapshot(design.id).revision

        let written = try await h.server.writeDesignBoards(design.id, sources: [a: Self.board("A2"), phone: Self.board("Phone2")],
                                                           baseRevision: base)
        await drainMainQueue()

        #expect(written.result.revision == base + 1, "one revision for both")
        #expect(written.versions == [a: 1, phone: 1])
        #expect(h.broadcasts.current.count == 1, "one broadcast")
        #expect(try await h.server.designBoard(design.id, path: phone).source == Self.board("Phone2"))
        await #expect(throws: DesignStoreError.stale(base: base, current: base + 1)) {
            try await h.server.writeDesignBoards(design.id, sources: [a: Self.board("A3")], baseRevision: base)
        }
    }

    /// Every source is checked before any is written: one bad board refuses them all.
    @Test func aRefusedBoardWritesNoneOfTheOthers() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let a = try DesignPath.validate("A.dc.html"), b = try DesignPath.validate("B.dc.html")
        _ = try await h.server.writeDesignBoards(design.id, sources: [a: Self.board("A"), b: Self.board("B")])
        let before = try await h.server.designSnapshot(design.id)
        await #expect(throws: DesignStoreError.self) {
            try await h.server.writeDesignBoards(design.id, sources: [a: Self.board("A2"), b: "<p>no runtime</p>"])
        }
        #expect(try await h.server.designSnapshot(design.id) == before)
        #expect(try await h.server.designVersions(design.id, path: a).isEmpty)
    }

    /// A board the index removes loses its versions with its file.
    @Test func removingABoardForgetsItsVersions() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let a = try DesignPath.validate("A.dc.html")
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: Self.board("A"))
        _ = try await h.server.writeDesignBoard(design.id, path: a, source: Self.board("A2"))
        _ = try await h.server.updateDesignIndex(design.id, patch: .object(["boards": .object(["A.dc.html": .object(
            ["x": .number(0), "y": .number(0), "w": .number(390), "h": .number(844)])])]))
        #expect(try await h.server.designVersions(design.id, path: a).count == 1)
        _ = try await h.server.updateDesignIndex(design.id, patch: .object(["boards": .object(["A.dc.html": .null])]))
        #expect(try await h.server.designVersions(design.id, path: a).isEmpty)
    }
}
