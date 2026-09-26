import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// Duplicate (docs/designs.md › Writing): a board copied beside itself is one new file and one
/// new canvas entry, written as one change.
@Suite("Design duplicate", .integrationTimeLimit)
struct DesignDuplicateTests {
    private func serverWithDesign() async throws -> (h: ScratchServer, design: Design) {
        let h = try ScratchServer.fresh()
        let space = Fixture.space()
        try await h.seed(Fixture.workspace([Fixture.agent(in: space)], space: space))
        let design = Design(name: "Checkout funnel", createdAt: 1_000)
        _ = try await h.server.createDesign(design)
        try await DesignFixtures.draw(DesignFixtures.checkout, in: design.id, on: h.server, perRow: 3)
        return (h, design)
    }

    @Test func duplicatingABoardAddsOneBoardBesideIt() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let a = try DesignPath.validate("A.dc.html")
        _ = try await h.server.updateDesignIndex(design.id, patch: DesignIndex.tweakPatch(a, ["rows": .number(6)]))
        let before = try await h.server.designSnapshot(design.id)
        let pushes = Locked(0)
        h.server.onDesignRevision = { _ in pushes.withValue { $0 += 1 } }
        h.server.watchDesignRevisions(of: [design.id])

        let copy = try await h.server.duplicateDesignBoard(design.id, path: a, baseRevision: before.revision)
        #expect(copy.path.rawValue == "A-copy.dc.html")
        #expect(copy.result.revision == before.revision + 1, "one change")
        try await eventually("the duplicate's push") { pushes.current == 1 }

        let after = try await h.server.designSnapshot(design.id)
        #expect(after.index.boards.count == before.index.boards.count + 1)
        #expect(Set(after.boards.keys) == Set(before.boards.keys).union([copy.path]), "one new file")
        #expect(after.boards[copy.path] == before.boards[a], "the file byte for byte")
        #expect(try await h.server.designBoard(design.id, path: copy.path).source == DesignFixtures.source(DesignFixtures.checkout[0]))
        let entry = try #require(after.index.boards[copy.path])
        let original = try #require(before.index.boards[a])
        #expect(entry.title == "A · Funnel first copy")
        #expect(entry.w == original.w && entry.h == original.h && entry.y == original.y)
        // A, B and C sit in the first row: the copy goes after C.
        let c = try #require(before.index.boards[DesignPath.validate("C.dc.html")])
        #expect(entry.x == c.x + c.w + 80)
        #expect(after.index.order.firstIndex(of: copy.path) == after.index.order.firstIndex(of: a).map { $0 + 1 })
        #expect(after.index.tweaks(for: copy.path) == ["rows": .number(6)])
        #expect(try await h.server.designVersions(design.id, path: copy.path).isEmpty)
        #expect(h.server.state.designs.first?.lastActiveAt ?? 0 > 1_000, "a duplicate moves the design up Recents")

        let again = try await h.server.duplicateDesignBoard(design.id, path: a)
        #expect(again.path.rawValue == "A-copy-2.dc.html")
    }

    @Test func aDuplicateAtAnOldRevisionOrOfNoBoardIsRefusedAndWritesNothing() async throws {
        let (h, design) = try await serverWithDesign()
        defer { h.stop() }
        let a = try DesignPath.validate("A.dc.html")
        let before = try await h.server.designSnapshot(design.id)
        await #expect(throws: DesignStoreError.stale(base: before.revision - 1, current: before.revision)) {
            try await h.server.duplicateDesignBoard(design.id, path: a, baseRevision: before.revision - 1)
        }
        await #expect(throws: DesignStoreError.noSuchBoard(try DesignPath.validate("Z.dc.html"))) {
            try await h.server.duplicateDesignBoard(design.id, path: try DesignPath.validate("Z.dc.html"))
        }
        #expect(try await h.server.designSnapshot(design.id) == before)
    }
}
