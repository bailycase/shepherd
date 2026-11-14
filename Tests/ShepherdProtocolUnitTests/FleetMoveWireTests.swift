import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Fleet move wire")
struct FleetMoveWireTests {
    @Test func aMoveRequestRoundTripsAndDefaultsToNow() throws {
        let request = FleetMoveRequest(agentID: AgentID(rawValue: "agent-1"), host: "Mac mini", when: .whenDone)
        #expect(try JSONDecoder().decode(FleetMoveRequest.self, from: JSONEncoder().encode(request)) == request)
        let bare = #"{"moveID":"\#(UUID().uuidString)","agentID":"agent-1","host":"Mac mini","when":"from the future"}"#
        #expect(try JSONDecoder().decode(FleetMoveRequest.self, from: Data(bare.utf8)).when == .now)
    }

    @Test func aHandoffRoundTripsAndAnOldOneDecodesWithDefaults() throws {
        let handoff = FleetMoveHandoff(agentID: AgentID(rawValue: "agent-1"), sessionID: "session-1", name: "Speed up checkout CI", nameIsFinal: true,
                                       model: "acme/model", pushMuted: true, branch: "perf/checkout-ci", worktreeBase: "main", movedAt: 1_760_000_000_000,
                                       messages: 412, uncommittedFiles: 3, unpushedCommits: 1)
        #expect(try JSONDecoder().decode(FleetMoveHandoff.self, from: JSONEncoder().encode(handoff)) == handoff)
        let minimal = try JSONDecoder().decode(FleetMoveHandoff.self, from: Data(#"{"agentID":"agent-1"}"#.utf8))
        #expect(minimal.sessionID == "agent-1" && !minimal.pushMuted && minimal.uncommittedFiles == 0 && minimal.isValid)
        #expect(!FleetMoveHandoff(agentID: AgentID(rawValue: "a"), sessionID: "../escape", name: "", nameIsFinal: false, movedAt: 0).isValid)
    }

    @Test func aTombstoneDecodesWithoutItsOptionalFields() throws {
        let moved = try JSONDecoder().decode(MovedTo.self, from: JSONEncoder().encode(
            MovedTo(hostID: UUID(), hostName: "Mac mini", at: 1_760_000_000_000, moveID: UUID())))
        #expect(moved.hostName == "Mac mini")
    }

    @Test func aPeerStatusSaysWhetherItTakesThreadsAndAnOldOneDoesNotSay() throws {
        let peer = FleetPeerStatus(hostID: UUID(), name: "Mac mini", pairedAt: 1, link: .connected, takesThreads: false)
        #expect(try JSONDecoder().decode(FleetPeerStatus.self, from: JSONEncoder().encode(peer)).takesThreads == false)
        let old = #"{"hostID":"\#(UUID().uuidString)","name":"Mac mini","kind":"mac","pairedAt":1,"link":"offline"}"#
        #expect(try JSONDecoder().decode(FleetPeerStatus.self, from: Data(old.utf8)).takesThreads == nil)
    }

    @Test func theMoveCapabilityIsAMemberOneAndTheViewOneIsOfferedToADevice() {
        #expect(RemoteProtocol.fleetMemberCapabilities.contains(RemoteProtocol.fleetMoveCapability))
        #expect(FleetAccess.device.isOffered(RemoteProtocol.fleetMoveViewCapability))
        #expect(!FleetAccess.device.isOffered(RemoteProtocol.fleetMoveCapability))
    }
}
