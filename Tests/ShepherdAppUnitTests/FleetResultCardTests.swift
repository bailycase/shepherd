import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import Testing
@testable import ShepherdApp

struct FleetResultCardTests {
    @Test(arguments: [1, 2]) func aLegacyResultNeverAttachesToAnotherCardOnItsBranch(count: Int) throws {
        let parent = AgentID(), host = UUID()
        let branch = "fleet/payment-test"
        let records = (0..<count).map { index in
            FleetDispatchRecord(parentAgentID: parent, parentHostID: host, parentHostName: "Studio Mac",
                                targetHostName: "Build Mac", state: .done, title: "Different dispatch \(index)",
                                task: "Check the build", repoKey: "github.com/acme/web", branch: branch, createdAt: Double(index))
        }
        let context = FleetCardContext(snapshot: FleetSnapshot(enabled: true, hostID: host, name: "Studio Mac"), cap: 3)
        let surface = FleetThreadSurface(cards: FleetDispatchPresentation.cards(records, in: context), parent: parent)
        let text = "[from: Payment test on Build Mac, an agent, not the user.] Result from Payment test on Build Mac:\nPassed\n\nBranch \(branch): branch work unavailable."
        let result = try #require(FleetResultMessage.parse(text))
        #expect(result.branch == branch)
        #expect(surface.cards.count == count)
        #expect(surface.card(for: result) == nil)
    }
}
