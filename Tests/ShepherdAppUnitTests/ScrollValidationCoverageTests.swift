#if DEBUG
import CoreGraphics
import Testing
@testable import ShepherdApp

@Test @MainActor func scrollValidationCountsAtMostOneTurnSpacingAfterARow() {
    let row = CGRect(x: 0, y: 30, width: 100, height: 20)
    #expect(MacScrollValidationTrace.readingCoverage(of: row, top: 10, bottom: 100) == [20, 40 + Double(AppLayout.turnSpacing)])
    #expect(MacScrollValidationTrace.readingCoverage(of: row, top: 10, bottom: 70) == [20, 60])
}
#endif
