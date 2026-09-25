import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// How the server keeps each automation's runs: a run opens when its automation gains an agent,
/// follows the agent's status, and closes when the agent goes. The unit under test is the file.
@Suite("Automation run log")
struct AutomationRunLogTests {
    static let space = Space(name: "Automations", path: "~", hidden: true)
    static let automation = Automation(id: AutomationID(rawValue: "a"), name: "watch", prompt: "watch", cwd: "/tmp")
    static let start = Date(timeIntervalSince1970: 1_000)

    static func state(agent status: AgentStatus?, id: AgentID = AgentID(rawValue: "run")) -> ShepherdState {
        guard let status else { return ShepherdState(spaces: [space], automations: [automation]) }
        let pane = LeafPane(cwd: "/tmp", agentID: id)
        let tab = Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
        var automation = automation
        automation.agentID = id
        return ShepherdState(spaces: [space], tabs: [tab],
                             agents: [Agent(id: id, name: "watch", spaceID: space.id, tabID: tab.id, paneID: pane.id, status: status)],
                             automations: [automation])
    }

    /// The same run through a sequence of states, one second apart.
    static func replay(_ states: [ShepherdState], log: AutomationRunLog) {
        for (index, pair) in zip(states, states.dropFirst()).enumerated() {
            log.record(from: pair.0, to: pair.1, now: start.addingTimeInterval(Double(index)))
        }
    }

    @Test(arguments: [
        ([nil, .idle] as [AgentStatus?], AutomationRunResult.running, false),
        ([nil, .working, .blocked], .needsYou, false),
        ([nil, .working, .done], .finished, true),
        ([nil, .working, .done, .working], .running, true),
        ([nil, .working, .done, nil], .finished, true),
        ([nil, .working, nil], .stopped, false),
        ([nil, .working, .blocked, nil], .stopped, false),
        ([nil, .idle, nil], .stopped, false),
    ])
    func aRunFollowsItsAgent(_ statuses: [AgentStatus?], result: AutomationRunResult, settled: Bool) throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))

        Self.replay(statuses.map { Self.state(agent: $0) }, log: log)

        let run = try #require(log.runs[Self.automation.id]?.last)
        #expect(log.runs[Self.automation.id]?.count == 1)
        #expect(run.result == result)
        #expect((run.settledAt != nil) == settled)
        #expect(run.startedAt == Self.start.timeIntervalSince1970)
        #expect((run.endedAt == nil) == (statuses.last! != nil))
        #expect((run.agentID != nil) == (statuses.last! != nil))
    }

    @Test func aNewAgentStartsANewRunAndTheLogKeepsTheNewest() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        var states = [Self.state(agent: nil)]
        for index in 0..<(AutomationRunLog.limit + 2) {
            states.append(Self.state(agent: .working, id: AgentID(rawValue: "run\(index)")))
        }
        Self.replay(states, log: log)

        let runs = try #require(log.runs[Self.automation.id])
        #expect(runs.count == AutomationRunLog.limit)
        #expect(runs.dropLast().allSatisfy { $0.result == .stopped && $0.agentID == nil })
        #expect(runs.last?.agentID == AgentID(rawValue: "run\(AutomationRunLog.limit + 1)"))
    }

    /// A client sees a run's agent only while it exists in the host's state.
    @Test func aClientIsOfferedOnlyAnAgentThatStillExists() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        let live = Self.state(agent: .done)
        log.record(from: Self.state(agent: nil), to: live)

        #expect(log.runs(for: Self.automation.id, in: live).map(\.agentID) == [AgentID(rawValue: "run")])
        #expect(log.runs(for: Self.automation.id, in: ShepherdState()).map(\.agentID) == [nil])
    }

    /// Written to disk and read back by the next launch, which closes what was still open.
    @Test func runsSurviveALaunchAndOpenOnesClose() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("automation-runs.json")
        let first = AutomationRunLog(url: url)
        Self.replay([Self.state(agent: nil), Self.state(agent: .working)], log: first)
        first.flush()

        let second = AutomationRunLog(url: url)
        #expect(second.runs == first.runs)
        second.closeOpenRuns(now: Self.start.addingTimeInterval(60))
        let run = try #require(second.runs[Self.automation.id]?.first)
        #expect(run.result == .interrupted && run.endedAt == Self.start.timeIntervalSince1970 + 60 && run.agentID == nil)
    }

    @Test func aRemovedAutomationTakesItsRunsAlong() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = AutomationRunLog(url: dir.appendingPathComponent("automation-runs.json"))
        Self.replay([Self.state(agent: nil), Self.state(agent: .done), ShepherdState(spaces: [Self.space])], log: log)
        #expect(log.runs.isEmpty)
    }
}
