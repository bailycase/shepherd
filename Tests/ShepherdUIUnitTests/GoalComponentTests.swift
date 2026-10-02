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

    @Test(arguments: [(0.0, "0m 0s"), (9, "0m 9s"), (400, "6m 40s"), (3600, "1h 0m"), (3661, "1h 1m")])
    func localClocksKeepTheNativeGoalTimeFormat(seconds: Double, expected: String) {
        #expect(NWGoalTime.text(seconds) == expected)
    }

    @Test func limitFieldsAcceptPositiveFiniteValuesAndBlankRemovesCaps() {
        for seconds in [0.1, 128.78, 1.2345678901234567, 1800] {
            #expect(NWGoalLimits(seconds: seconds, tokens: nil).seconds == seconds, "untouched limits remain exactly unchanged")
        }
        var limits = NWGoalLimits(seconds: 1800, tokens: 200_000)
        #expect(limits.seconds == 1800 && limits.tokenLimit == 200_000 && limits.isValid)
        for invalid in ["0", "-1", "nan", "inf", "1e309", "text"] {
            limits.minutes = invalid
            #expect(!limits.isValid)
        }
        limits.minutes = "12.5"
        #expect(limits.seconds == 750 && limits.isValid)
        for invalid in ["0", "-1", "1.5", "99999999999999999999999", "nan"] {
            limits.tokens = invalid
            #expect(!limits.isValid)
        }
        limits.tokens = "100000"
        #expect(limits.tokenLimit == 100_000 && limits.isValid)
        limits.minutes = " "
        limits.tokens = ""
        #expect(limits.isValid && limits.clearsTime && limits.clearsTokens)
        #expect(limits.seconds == nil && limits.tokenLimit == nil)
    }

    @MainActor @Test func confirmationAndAttributionAreExplicitOptionalCardInputs() {
        let card = NWGoalCard(state: .needsYou, time: "6m 40s", meta: "confirm", text: "Tests pass",
                              confirmationRequired: true, checkedBy: "provider/model", confirmedByUser: false,
                              pause: {}, resume: {}, edit: {}, clear: {})
        #expect(card.confirmationRequired && card.checkedBy == "provider/model" && !card.confirmedByUser)
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
