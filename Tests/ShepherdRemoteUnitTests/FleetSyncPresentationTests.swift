import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Settings ▸ Fleet's sync line, in the words FleetSettings draws.
@Suite("Fleet sync presentation")
struct FleetSyncPresentationTests {
    static func peer(_ name: String, _ state: FleetSyncStatus.Peer.State) -> FleetSyncStatus.Peer {
        FleetSyncStatus.Peer(hostID: UUID(), name: name, state: state)
    }

    @Test func nothingIsSaidWithNoMacPaired() {
        #expect(FleetSyncPresentation.line(FleetSyncStatus()) == nil)
        #expect(FleetSyncPresentation.line(FleetSyncStatus(notice: "left over")) == nil)
    }

    /// FleetSettings: "In sync on This Mac and Mac mini · Mac Studio is asleep and catches up when it wakes".
    @Test func theBoardsLineNamesWhoIsInSyncAndWhoIsAsleep() {
        let line = FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .inSync), Self.peer("Mac Studio", .offline)]))
        #expect(line == FleetSyncLine(tone: .inSync, lead: "In sync on This Mac and Mac mini",
                                      tail: "Mac Studio is asleep and catches up when it wakes"))
    }

    @Test func everyoneLinkedAndHoldingTheSameIsOneShortSentence() {
        #expect(FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .inSync)]))
                == FleetSyncLine(tone: .inSync, lead: "In sync on This Mac and Mac mini"))
        #expect(FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .inSync), Self.peer("Mac Studio", .inSync)]))?.lead
                == "In sync on This Mac, Mac mini and Mac Studio")
    }

    @Test func aMacStillTakingChangesIsCatchingUpAndTheRestAreStillNamed() {
        let line = FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .inSync), Self.peer("Mac Studio", .catchingUp)]))
        #expect(line == FleetSyncLine(tone: .catchingUp, lead: "Catching up with Mac Studio", tail: "In sync on This Mac and Mac mini"))
    }

    @Test func withEveryMacAwayThereIsNothingToBeInSyncWith() {
        let line = FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .offline), Self.peer("Mac Studio", .offline)]))
        #expect(line == FleetSyncLine(tone: .alone, lead: nil, tail: "Mac mini and Mac Studio are asleep and catch up when they wake"))
    }

    @Test func theNoticeRidesOnItsOwnLine() {
        let notice = "Replaced AGENTS.md with Mac mini's. The old copy is in its history."
        #expect(FleetSyncPresentation.line(FleetSyncStatus(peers: [Self.peer("Mac mini", .inSync)], notice: notice))?.notice == notice)
    }
}
