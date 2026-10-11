import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

@Suite("Project automation snapshots")
struct ProjectAutomationSnapshotTests {
    @Test func rowsKeepRealOwnerPromptAndLatestRunWithoutInventingASchedule() throws {
        let project = ProjectID(), owner = UUID()
        let scoped = Automation(name: "Inspect checks", prompt: "Inspect the supplied checks", cwd: "/tmp", projectID: project)
        let ordinary = Automation(name: "Other", prompt: "Other", cwd: "/tmp")
        let run = AutomationRun(startedAt: 42, endedAt: 45, result: .interrupted)
        let host = AutomationHost(id: owner, name: "Actual Mac", connected: true, manageable: true,
                                  state: ShepherdState(automations: [ordinary, scoped]))
        let rows = ProjectAutomationSnapshot.rows(projectID: project, host: host, runs: [scoped.id: [run]])
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.automation == scoped)
        #expect(row.ownerID == owner && row.ownerName == "Actual Mac")
        #expect(row.latestRun == run)
        #expect(ProjectAutomationSnapshot.rows(projectID: project, host: host, runs: [:]).first?.latestRun == nil)
        let presentation = AutomationsModel(hosts: [host], runs: [:])
        let shared = try #require(presentation.rows.first { $0.key.automation == scoped.id })
        #expect(shared.when == "By explicit Project action")
        #expect(!shared.abilities.run && !shared.abilities.toggle && !shared.abilities.edit)
    }
}
