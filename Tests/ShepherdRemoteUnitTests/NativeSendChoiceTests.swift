import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The three ways to send while pi works, and the words each goes by on every platform.
@Suite("Send choices")
struct NativeSendChoiceTests {
    /// From the gentlest to the most urgent: the Send menu lists them in this order.
    @Test func theChoicesRunFromWaitingToSteeringNow() {
        #expect(NativeSendChoice.allCases == [.wait, .nextStep, .now])
        #expect(NativeSendChoice.allCases.map(\.delivery) == [.followUp, .steer, .interrupt])
    }

    @Test(arguments: NativeThreadDelivery.allCases)
    func everyDeliveryHasOneChoiceThatSendsIt(delivery: NativeThreadDelivery) {
        #expect(NativeSendChoice(delivery: delivery).delivery == delivery)
    }

    @Test func eachChoiceSaysWhatItDoes() {
        #expect(NativeSendChoice.allCases.map(\.title) == ["Wait for the turn to end", "Steer at the next step", "Steer now"])
        #expect(Set(NativeSendChoice.allCases.map(\.title)).count == 3)
        #expect(NativeSendChoice.allCases.allSatisfy { !$0.detail.isEmpty })
        #expect(NativeSendChoice.now.detail.contains("Stops"), "steering now stops the agent, and says so")
        #expect(NativeSendChoice.nextStep.detail.contains("before its next step"))
        #expect(NativeSendChoice.steerNowHelp.contains("Stop") && NativeSendChoice.steerAllNowHelp.contains("Stop"))
    }

    /// The raw values are ids in the Send menu, so they never change.
    @Test func choiceIDsAreStable() {
        #expect(NativeSendChoice.allCases.map(\.id) == ["wait", "nextStep", "now"])
    }
}
