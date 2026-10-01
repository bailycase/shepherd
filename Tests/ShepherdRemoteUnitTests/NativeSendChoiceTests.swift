import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The two ways to send while pi works, and the words each goes by on every platform.
@Suite("Send choices")
struct NativeSendChoiceTests {
    /// From the gentlest to the most urgent: the Send menu lists them in this order. Steering at
    /// the next step is not among them: no surface offers it.
    @Test func theChoicesAreWaitingAndSteeringNow() {
        #expect(NativeSendChoice.allCases == [.wait, .now])
        #expect(NativeSendChoice.allCases.map(\.delivery) == [.followUp, .interrupt])
        #expect(!NativeSendChoice.allCases.map(\.delivery).contains(.steer))
        #expect(NativeSendChoice(rawValue: "nextStep") == nil)
    }

    /// `steer` stays on the wire for older clients and for Steer now against a host that can't
    /// stop pi, so the protocol still names it even though no choice sends it.
    @Test func theProtocolStillCarriesSteer() {
        #expect(NativeThreadDelivery.allCases == [.followUp, .steer, .interrupt])
        #expect(NativeThreadDelivery(rawValue: "steer") == .steer)
    }

    @Test func eachChoiceSaysWhatItDoes() {
        #expect(NativeSendChoice.allCases.map(\.title) == ["Wait for the turn to end", "Steer now"])
        #expect(NativeSendChoice.allCases.allSatisfy { !$0.detail.isEmpty })
        #expect(NativeSendChoice.now.detail.contains("Stops"), "steering now stops the agent, and says so")
        #expect(NativeSendChoice.steerNowHelp == "Stop the agent and send this now")
        #expect(NativeSendChoice.steerAllNowHelp.contains("Stop"))
    }

    /// The raw values are ids in the Send menu, so they never change.
    @Test func choiceIDsAreStable() {
        #expect(NativeSendChoice.allCases.map(\.id) == ["wait", "now"])
    }
}
