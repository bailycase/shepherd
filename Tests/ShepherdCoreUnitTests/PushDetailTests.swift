import Foundation
import Testing
@testable import ShepherdCore

@Suite("Push detail")
struct PushDetailTests {
    @Test func optionsAreButtonsOnlyWhenEveryOneFitsWholeAndRedactionDropsChangedOnes() {
        #expect(PushDetail.question(options: ["Use checkout_id", "Use order_id"])?.options == ["Use checkout_id", "Use order_id"])
        #expect(PushDetail.question(options: []) == nil)
        #expect(PushDetail.question(options: ["a", "b", "c", "d", "e"]) == nil)
        #expect(PushDetail.question(options: ["ok", String(repeating: "x", count: 41)]) == nil)
        let redacted = PushDetail(options: ["secret"]).mapText { $0 == "secret" ? "[redacted]" : $0 }
        #expect(redacted.options == nil, "a changed option would answer something else")
        let kept = PushDetail(options: ["Use checkout_id"]).mapText { $0 }
        #expect(kept.options == ["Use checkout_id"])
    }
}
