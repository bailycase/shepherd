import Foundation
import Testing
import ShepherdCore
@testable import ShepherdApp

/// The Fleet page's "Spent today" is derived once per change, and again when the day changes, with no state push in between.
@MainActor
@Suite("Spend today model")
struct SpendTodayModelTests {
    final class Clock { var now = Date(timeIntervalSince1970: 1_778_543_940) } // 2026-05-11 23:59 UTC

    @Test func theTotalFollowsTheSpendsAndResetsAtMidnightWithNothingPushed() {
        let clock = Clock()
        var spends = [AgentSpend(tokens: 5, cost: 1, day: "2026-05-11", zone: "UTC", today: [ModelSpend(model: "a/one", tokens: 5, cost: 1)])]
        let model = SpendTodayModel(now: { clock.now }, read: { spends })
        #expect(model.summary?.total == "est. $1.00 · 5 tok")
        clock.now = clock.now.addingTimeInterval(120) // past midnight; the model is told by its own timer, here called directly
        model.refresh()
        #expect(model.summary == nil)
        spends = []
        model.refresh()
        #expect(model.summary == nil)
    }
}
