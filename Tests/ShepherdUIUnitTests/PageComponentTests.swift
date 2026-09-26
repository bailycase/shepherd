import SwiftUI
import Testing
@testable import ShepherdUI

/// The destination pages' table: fixed columns keep their width and flexible ones share what is
/// left by their shares, after the gaps (the boards' `2fr 76px 76px 1.15fr`, 16pt gaps).
@Suite("Page components")
struct PageComponentTests {
    private let columns: [NWTableColumns.Column] = [.flex(2), .fixed(76), .fixed(76), .flex(1.15)]

    @Test(arguments: [(CGFloat(1000), [CGFloat(507.94), 76, 76, 292.06]), (CGFloat(400), [CGFloat(126.98), 76, 76, 73.02])] as [(CGFloat, [CGFloat])])
    func flexibleColumnsShareWhatTheFixedOnesLeave(total: CGFloat, expected: [CGFloat]) {
        let widths = NWTableColumns.widths(columns, spacing: 16, total: total)
        #expect(widths.count == 4)
        for (width, want) in zip(widths, expected) {
            #expect(abs(width - want) < 0.01, "\(widths)")
        }
    }

    @Test func tooNarrowLeavesFlexibleColumnsEmptyAndFixedOnesWhole() {
        #expect(NWTableColumns.widths(columns, spacing: 16, total: 100) == [0, 76, 76, 0])
        #expect(NWTableColumns.widths([], spacing: 16, total: 100).isEmpty)
    }
}
