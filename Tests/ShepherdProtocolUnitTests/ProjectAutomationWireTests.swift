import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol

@Suite("Project automation compatibility")
struct ProjectAutomationWireTests {
    @Test func anOldAutomationDecodesUnscopedAndNewAssociationRoundTrips() throws {
        let automation = Automation(name: "Watch", prompt: "Inspect", cwd: "/tmp")
        let encoded = try JSONEncoder().encode(automation)
        #expect(String(decoding: encoded, as: UTF8.self).contains("projectID") == false)
        #expect(try JSONDecoder().decode(Automation.self, from: encoded).projectID == nil)
        var scoped = automation
        scoped.projectID = ProjectID()
        #expect(try JSONDecoder().decode(Automation.self, from: JSONEncoder().encode(scoped)) == scoped)
    }

    private static let actions: [ProjectAutomationAction] = [
        .create(draft: .init(name: "Watch", prompt: "Inspect", cwd: "/tmp", enabled: true)),
        .update(draft: .init(name: "Edit", prompt: "Inspect again", cwd: "/tmp", enabled: false)),
        .setEnabled(false), .link, .delete,
    ]
    static let wireRequests = actions.map {
        RemoteRequest.logicalProjects(id: 4, request: .automation(projectID: LogicalProjectsSamples.id,
            expectedRevision: 7, automationID: AutomationID(rawValue: "00000000-0000-4000-8000-000000000007"), action: $0))
    }

    @Test(arguments: wireRequests)
    func everyScopedActionRoundTripsWithItsFence(_ wire: RemoteRequest) throws {
        #expect(try Wire.roundTrip(wire) == wire)
        guard case .logicalProjects(_, let request) = wire else {
            Issue.record("Expected a logicalProjects request")
            return
        }
        #expect(request.requiresProjectAutomations)
        #expect(request.projectID == LogicalProjectsSamples.id && request.expectedRevision == 7)
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.logicalProjectAutomationsCapability))
        #expect(!LogicalProjectsRequest.list.requiresProjectAutomations)
    }
}
