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

    @Test(arguments: [ProjectAutomationAction.create(draft: .init(name: "Watch", prompt: "Inspect", cwd: "/tmp", enabled: true)),
                      .update(draft: .init(name: "Edit", prompt: "Inspect again", cwd: "/tmp", enabled: false)),
                      .setEnabled(false), .link, .delete])
    func everyScopedActionRoundTripsWithItsFence(_ action: ProjectAutomationAction) throws {
        let project = ProjectID(), automation = AutomationID()
        let request = LogicalProjectsRequest.automation(projectID: project, expectedRevision: 7, automationID: automation, action: action)
        let wire = RemoteRequest.logicalProjects(id: 4, request: request)
        #expect(try Wire.roundTrip(wire) == wire)
        #expect(request.requiresProjectAutomations)
        #expect(request.projectID == project && request.expectedRevision == 7)
        #expect(RemoteProtocol.capabilities.contains(RemoteProtocol.logicalProjectAutomationsCapability))
        #expect(!LogicalProjectsRequest.list.requiresProjectAutomations)
    }
}
