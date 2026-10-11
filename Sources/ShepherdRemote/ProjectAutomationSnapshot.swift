import Foundation
import ShepherdCore
import ShepherdProtocol

/// Real owner settings and run-log data. No inferred schedule or trigger semantics.
/// Nil latestRun means no run was supplied/read, not a fabricated successful run.
public struct ProjectAutomationSnapshot: Equatable, Sendable, Identifiable {
    public var id: AutomationID { automation.id }
    public var automation: Automation
    public var ownerID: UUID
    public var ownerName: String
    public var latestRun: AutomationRun?

    public init(automation: Automation, ownerID: UUID, ownerName: String, latestRun: AutomationRun?) {
        self.automation = automation
        self.ownerID = ownerID
        self.ownerName = ownerName
        self.latestRun = latestRun
    }

    public static func rows(projectID: ProjectID, host: AutomationHost,
                            runs: [AutomationID: [AutomationRun]]) -> [Self] {
        host.state.automations.filter { $0.projectID == projectID }.map {
            Self(automation: $0, ownerID: host.id, ownerName: host.name, latestRun: runs[$0.id]?.last)
        }
    }
}
