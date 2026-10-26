import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Goal components")
struct GoalComponentTests {
    @Test(arguments: [
        (SHGoalState.working, true, false, true),
        (.checking, true, false, true),
        (.met, false, false, false),
        (.paused, false, true, true),
        (.needsYou, false, true, true),
    ])
    func theGoalOffersOnlyActionsThatItsStateCanTake(state: SHGoalState, pause: Bool, resume: Bool, edit: Bool) {
        #expect(state.offersPause == pause)
        #expect(state.offersResume == resume)
        #expect(state.offersEdit == edit)
    }

    @Test(arguments: [
        (SHGoalState.working, "6m 40s", "Working · 6m 40s"),
        (.checking, "6m 40s", "Checking · 6m 40s"),
        (.met, "9m 12s", "Met · 9m 12s"),
        (.paused, "6m 40s", "Paused · 6m 40s"),
        (.needsYou, "6m 40s", "Needs you"),
        (.working, "", "Working"),
    ])
    func thePillShowsElapsedTimeExceptWhenItNeedsYou(state: SHGoalState, time: String, expected: String) {
        #expect(state.pillText(time: time) == expected)
    }

    @MainActor @Test func theStatesUseTheExistingThemeRoles() {
        let sh = Color.sh
        for state in [SHGoalState.working, .checking] {
            #expect(state.color == AgentState.running.textColor)
            #expect(state.tint == AgentState.running.tint)
        }
        #expect(SHGoalState.met.color == AgentState.done.textColor)
        #expect(SHGoalState.met.tint == AgentState.done.tint)
        #expect(SHGoalState.paused.color == AgentState.idle.textColor)
        #expect(SHGoalState.paused.tint == sh.bgSelected)
        #expect(SHGoalState.needsYou.color == sh.lanternText)
        #expect(SHGoalState.needsYou.markColor == AgentState.attention.color)
        #expect(SHGoalState.needsYou.tint == sh.lanternTint)
    }

    @Test func needsYouTextMeetsContrastInBothAppearances() {
        for variant in Variant.all {
            #expect(variant.contrast(\.lanternText, on: \.lanternTint, over: \.bgRaised) >= 4.5)
        }
    }

    @Test func touchKeepsTwoLinesAndFullHitTargetsWithoutEnlargingItsChrome() {
        #expect(SHGoalSize.desktop.cardHeight == 70)
        #expect(SHGoalSize.desktop.headerHeight == 32)
        #expect(SHGoalSize.desktop.radius == 10)
        #expect(SHGoalSize.desktop.pillHeight == 20)
        #expect(SHGoalSize.desktop.textLines == 1)
        #expect(SHGoalSize.desktop.hitTarget == 24)
        #expect(SHGoalSize.touch.cardHeight == 92)
        #expect(SHGoalSize.touch.headerHeight == 40)
        #expect(SHGoalSize.touch.radius == 12)
        #expect(SHGoalSize.touch.pillHeight == 24)
        #expect(SHGoalSize.touch.textLines == 2)
        #expect(SHGoalSize.touch.actionSize == 34)
        #expect(SHGoalSize.touch.hitTarget == 44)
    }

    @Test(arguments: [(0.0, "0m 0s"), (9, "0m 9s"), (400, "6m 40s"), (3600, "1h 0m"), (3661, "1h 1m")])
    func localClocksKeepTheNativeGoalTimeFormat(seconds: Double, expected: String) {
        #expect(SHGoalTime.text(seconds) == expected)
    }

    @MainActor @Test func confirmationAndAttributionAreExplicitOptionalCardInputs() {
        let card = SHGoalCard(state: .needsYou, time: "6m 40s", meta: "confirm", text: "Tests pass",
                              confirmationRequired: true, checkedBy: "provider/model", confirmedByUser: false,
                              pause: {}, resume: {}, edit: {}, clear: {})
        #expect(card.confirmationRequired && card.checkedBy == "provider/model" && !card.confirmedByUser)
    }

    @MainActor @Test func aGoalDefaultsToAFramedDesktopCardAndCanJoinTheSharedDock() {
        let desktop = SHGoalCard(state: .working, time: "6m", meta: "71k tokens", text: "Tests pass",
                                 pause: {}, resume: {}, edit: {}, clear: {})
        #expect(desktop.size == .desktop)
        #expect(desktop.framed)
        let dock = SHGoalCard(state: .needsYou, time: "6m", meta: "waiting for your input", text: "Tests pass",
                              size: .touch, framed: false, pause: {}, resume: {}, edit: {}, clear: {})
        #expect(dock.size == .touch)
        #expect(!dock.framed)
    }
}
