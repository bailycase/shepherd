import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Goal components")
struct GoalComponentTests {
    @Test(arguments: [
        (NWGoalState.working, true, false, true),
        (.checking, true, false, true),
        (.met, false, false, false),
        (.paused, false, true, true),
        (.needsYou, false, true, true),
    ])
    func theGoalOffersOnlyActionsThatItsStateCanTake(state: NWGoalState, pause: Bool, resume: Bool, edit: Bool) {
        #expect(state.offersPause == pause)
        #expect(state.offersResume == resume)
        #expect(state.offersEdit == edit)
    }

    @Test(arguments: [
        (NWGoalState.working, "6m 40s", "Working · 6m 40s"),
        (.checking, "6m 40s", "Checking · 6m 40s"),
        (.met, "9m 12s", "Met · 9m 12s"),
        (.paused, "6m 40s", "Paused · 6m 40s"),
        (.needsYou, "6m 40s", "Needs you"),
        (.working, "", "Working"),
    ])
    func thePillShowsElapsedTimeExceptWhenItNeedsYou(state: NWGoalState, time: String, expected: String) {
        #expect(state.pillText(time: time) == expected)
    }

    @MainActor @Test func theStatesUseTheExistingThemeRoles() {
        let nw = Color.nw
        for state in [NWGoalState.working, .checking] {
            #expect(state.color == AgentState.running.textColor)
            #expect(state.tint == AgentState.running.tint)
        }
        #expect(NWGoalState.met.color == AgentState.done.textColor)
        #expect(NWGoalState.met.tint == AgentState.done.tint)
        #expect(NWGoalState.paused.color == AgentState.idle.textColor)
        #expect(NWGoalState.paused.tint == nw.bgSelected)
        #expect(NWGoalState.needsYou.color == nw.lanternText)
        #expect(NWGoalState.needsYou.markColor == AgentState.attention.color)
        #expect(NWGoalState.needsYou.tint == nw.lanternTint)
    }

    @Test func needsYouTextMeetsContrastInBothAppearances() {
        for variant in Variant.all {
            #expect(variant.contrast(\.lanternText, on: \.lanternTint, over: \.bgRaised) >= 4.5)
        }
    }

    @Test func touchKeepsTwoLinesAndFullHitTargetsWithoutEnlargingItsChrome() {
        #expect(NWGoalSize.desktop.cardHeight == 70)
        #expect(NWGoalSize.desktop.headerHeight == 32)
        #expect(NWGoalSize.desktop.radius == 10)
        #expect(NWGoalSize.desktop.pillHeight == 20)
        #expect(NWGoalSize.desktop.textLines == 1)
        #expect(NWGoalSize.desktop.hitTarget == 24)
        #expect(NWGoalSize.touch.cardHeight == 92)
        #expect(NWGoalSize.touch.headerHeight == 40)
        #expect(NWGoalSize.touch.radius == 12)
        #expect(NWGoalSize.touch.pillHeight == 24)
        #expect(NWGoalSize.touch.textLines == 2)
        #expect(NWGoalSize.touch.actionSize == 34)
        #expect(NWGoalSize.touch.hitTarget == 44)
    }

    @MainActor @Test func aGoalDefaultsToAFramedDesktopCardAndCanJoinTheSharedDock() {
        let desktop = NWGoalCard(state: .working, time: "6m", meta: "71k tokens", text: "Tests pass",
                                 pause: {}, resume: {}, edit: {}, clear: {})
        #expect(desktop.size == .desktop)
        #expect(desktop.framed)
        let dock = NWGoalCard(state: .needsYou, time: "6m", meta: "Limit reached", text: "Tests pass",
                              size: .touch, framed: false, pause: {}, resume: {}, edit: {}, clear: {})
        #expect(dock.size == .touch)
        #expect(!dock.framed)
    }
}
