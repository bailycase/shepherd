import AppKit
import ShepherdCore
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Terminal split accessibility", .mainActorExclusive)
@MainActor
struct TerminalSplitAccessibilityTests {
    @Test(arguments: [SplitAxis.vertical, .horizontal])
    func theAdjustableSplitUsesTheSameCommitAndBoundsAsDragging(axis: SplitAxis) {
        var ratio = 0.5
        func control() -> PaneSeparatorView {
            PaneSeparatorView(axis: axis,
                              rect: CGRect(x: axis == .vertical ? 799 * ratio : 0,
                                           y: axis == .horizontal ? 799 * ratio : 0,
                                           width: axis == .vertical ? 1 : 800,
                                           height: axis == .horizontal ? 1 : 800),
                              containerRect: CGRect(x: 0, y: 0, width: 800, height: 800),
                              color: .gray, coordinateSpace: "split", liveRatio: .constant(nil),
                              onCommit: { ratio = $0 })
        }
        // Invoke the same action wired to SwiftUI's accessibilityAdjustableAction. The
        // offscreen host exposes no SwiftUI AX children without an external AX client.
        control().adjust(.increment)
        #expect(abs(ratio - 0.55) < 0.001)
        control().adjust(.decrement)
        #expect(abs(ratio - 0.5) < 0.001)
        for _ in 0..<30 { control().adjust(.increment) }
        // The 799 usable points must leave 160 points for the smaller pane.
        #expect(abs(ratio - 0.799749687) < 0.000001)
        control().adjust(.increment)
        #expect(abs(ratio - 0.799749687) < 0.000001)
        for _ in 0..<30 { control().adjust(.decrement) }
        #expect(abs(ratio - 0.200250313) < 0.000001)
        control().adjust(.decrement)
        #expect(abs(ratio - 0.200250313) < 0.000001)
    }
}
