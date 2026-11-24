import Testing
import ShepherdUI

/// The changes card's last row: "Show N more" pages through the files it has, ten at a time,
/// and only past them does it hand off to Review.
@Suite("Changes card more row")
struct ChangesMoreTests {
    @Test func aBigTurnPagesThroughItsListedFilesThenOpensReview() {
        #expect(SHChangesMore(shown: 3, listed: 20, total: 120) == .show(10))
        #expect(SHChangesMore(shown: 13, listed: 20, total: 120) == .show(7))
        #expect(SHChangesMore(shown: 20, listed: 20, total: 120) == .review(100))
        #expect(SHChangesMore(shown: 3, listed: 20, total: 120).text == "Show 10 more")
        #expect(SHChangesMore(shown: 20, listed: 20, total: 120).text == "100 more in Review")
    }

    @Test func aTurnWhoseFilesAreAllShownHasNoRow() {
        #expect(SHChangesMore(shown: 3, listed: 3, total: 3) == .none)
        #expect(SHChangesMore(shown: 7, listed: 7, total: 7).text == nil)
    }
}
