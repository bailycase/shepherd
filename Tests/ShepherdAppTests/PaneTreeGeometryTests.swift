import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

@Suite("Pane tree geometry")
struct PaneTreeGeometryTests {
    @Test func singleLeafFillsContainer() throws {
        let pane = LeafPane(cwd: "/tmp")
        let geometry = paneTreeGeometry(for: .leaf(pane), in: CGSize(width: 800, height: 600))

        #expect(geometry.leaves.count == 1)
        #expect(try #require(geometry.leaves.first).rect == CGRect(x: 0, y: 0, width: 800, height: 600))
        #expect(geometry.separators.isEmpty)
    }

    @Test func verticalSplitSubtractsOnePointSeparator() throws {
        let first = LeafPane(cwd: "/tmp/first")
        let second = LeafPane(cwd: "/tmp/second")
        let geometry = paneTreeGeometry(
            for: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(first),
                second: .leaf(second)
            ),
            in: CGSize(width: 801, height: 600)
        )

        #expect(try #require(geometry.leaves.first { $0.pane.id == first.id }).rect ==
            CGRect(x: 0, y: 0, width: 400, height: 600))
        #expect(try #require(geometry.separators.first).rect ==
            CGRect(x: 400, y: 0, width: 1, height: 600))
        #expect(try #require(geometry.leaves.first { $0.pane.id == second.id }).rect ==
            CGRect(x: 401, y: 0, width: 400, height: 600))
    }

    @Test func nestedSplitsComposeWithinParentRect() throws {
        let top = LeafPane(cwd: "/tmp/top")
        let bottom = LeafPane(cwd: "/tmp/bottom")
        let right = LeafPane(cwd: "/tmp/right")
        let left = PaneNode.split(
            axis: .horizontal,
            ratio: 0.5,
            first: .leaf(top),
            second: .leaf(bottom)
        )
        let geometry = paneTreeGeometry(
            for: .split(axis: .vertical, ratio: 0.5, first: left, second: .leaf(right)),
            in: CGSize(width: 801, height: 601)
        )

        #expect(try #require(geometry.leaves.first { $0.pane.id == top.id }).rect ==
            CGRect(x: 0, y: 0, width: 400, height: 300))
        #expect(try #require(geometry.leaves.first { $0.pane.id == bottom.id }).rect ==
            CGRect(x: 0, y: 301, width: 400, height: 300))
        #expect(try #require(geometry.leaves.first { $0.pane.id == right.id }).rect ==
            CGRect(x: 401, y: 0, width: 400, height: 601))
        #expect(geometry.separators.map(\.rect).contains(CGRect(x: 0, y: 300, width: 400, height: 1)))
    }

    @Test func horizontalSplitSubtractsOnePointSeparator() throws {
        let first = LeafPane(cwd: "/tmp/first")
        let second = LeafPane(cwd: "/tmp/second")
        let geometry = paneTreeGeometry(
            for: .split(
                axis: .horizontal,
                ratio: 0.5,
                first: .leaf(first),
                second: .leaf(second)
            ),
            in: CGSize(width: 800, height: 801)
        )

        #expect(try #require(geometry.leaves.first { $0.pane.id == first.id }).rect ==
            CGRect(x: 0, y: 0, width: 800, height: 400))
        #expect(try #require(geometry.separators.first).rect ==
            CGRect(x: 0, y: 400, width: 800, height: 1))
        #expect(try #require(geometry.leaves.first { $0.pane.id == second.id }).rect ==
            CGRect(x: 0, y: 401, width: 800, height: 400))
    }

    @Test func zeroSizeProducesOnlyZeroRects() {
        let first = LeafPane(cwd: "/tmp/first")
        let second = LeafPane(cwd: "/tmp/second")
        let geometry = paneTreeGeometry(
            for: .split(
                axis: .vertical,
                ratio: 0.5,
                first: .leaf(first),
                second: .leaf(second)
            ),
            in: .zero
        )

        #expect(geometry.leaves.allSatisfy { $0.rect == .zero })
        #expect(geometry.separators.allSatisfy { $0.rect == .zero })
    }
}
