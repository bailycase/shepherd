import Testing
import Foundation
import ShepherdProtocol
import ShepherdRemote

@Suite("Goal alert predicate")
struct GoalAlertPolicyTests {
    @Test func availabilityDependsOnlyOnBundleAndAuthorization() {
        let available: (String?, Bool) -> Bool = GoalAlertPolicy.isAvailable
        #expect(available("com.bailycase.shepherd.ios", true))
        #expect(!available("com.bailycase.shepherd.ios", false))
        #expect(!available("com.shepherd.ios-fixture", true))
        #expect(!available(nil, true))
    }

    private func goal(id: String = "goal-1", state: NativeGoalState) -> NativeGoal {
        NativeGoal(id: id, text: "Tidy the shed", state: state)
    }

    @Test func metTransitionPosts() {
        #expect(GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .met),
                                           previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func needsYouTransitionPosts() {
        #expect(GoalAlertPolicy.shouldPost(old: goal(state: .checking), new: goal(state: .needsYou),
                                           previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func firstSnapshotIsABaselineNotAnAlert() {
        #expect(!GoalAlertPolicy.shouldPost(old: nil, new: goal(state: .met),
                                            previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func reconnectDoesNotReplayAnOldAlert() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .met),
                                            previouslyLive: false, live: true, pushEnabled: false))
    }

    @Test func sameStateRevisionIsNotAnAlert() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .working),
                                            previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func nonTerminalTransitionsStayQuiet() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .checking),
                                            previouslyLive: true, live: true, pushEnabled: false))
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .checking), new: goal(state: .working),
                                            previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func differentGoalIsNotATransition() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(id: "goal-1", state: .working),
                                            new: goal(id: "goal-2", state: .met),
                                            previouslyLive: true, live: true, pushEnabled: false))
    }

    @Test func pushEnabledSuppressesTheLocalPost() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .met),
                                            previouslyLive: true, live: true, pushEnabled: true))
    }

    @Test func disconnectedThreadStaysQuiet() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: goal(state: .met),
                                            previouslyLive: true, live: false, pushEnabled: false))
    }

    @Test func noGoalStaysQuiet() {
        #expect(!GoalAlertPolicy.shouldPost(old: goal(state: .working), new: nil,
                                            previouslyLive: true, live: true, pushEnabled: false))
    }
}
