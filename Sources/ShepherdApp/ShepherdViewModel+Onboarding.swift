import Foundation
import ShepherdCore

extension ShepherdViewModel {
    /// Setup starts on the first launch of a support folder with no space in it. Someone who already has spaces (an update) is never shown it.
    func beginOnboardingIfNeeded() async {
        guard runsOnboarding, !onboarding.finishedBefore else { return }
        for _ in 0..<200 where !didAdopt { try? await Task.sleep(for: .milliseconds(50)) }
        // The copy of their pi is over once the hold lifts or its sheet has something to show.
        for _ in 0..<600 where holdsForWelcome && yourPi.importSheet == nil { try? await Task.sleep(for: .milliseconds(50)) }
        guard !state.spaces.contains(where: { !$0.hidden }) else { onboarding.finish(); return }
        onboarding.hasPi = yourPi.importSheet != nil
        await onboarding.scan()
        onboarding.begin()
    }
}
