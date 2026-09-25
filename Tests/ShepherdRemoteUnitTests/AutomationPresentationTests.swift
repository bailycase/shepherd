import Foundation
import Testing
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdRemote

@Suite("Automations across hosts")
struct AutomationPresentationTests {
    static let studio = UUID(uuidString: "00000000-0000-4000-8000-000000000001")!
    static let build = UUID(uuidString: "00000000-0000-4000-8000-000000000002")!
    static let hidden = Space(id: SpaceID(rawValue: "auto"), name: "Automations", path: "~", hidden: true)
    static let utc = TimeZone(identifier: "UTC")!
    static let posix = Locale(identifier: "en_US_POSIX")
    /// 2026-09-24 02:00:00 UTC.
    static let t0: Double = 1_790_215_200

    static func automation(_ id: String, enabled: Bool = true, agent: String? = nil) -> Automation {
        Automation(id: AutomationID(rawValue: id), name: id.capitalized, prompt: "Do \(id)", cwd: "/src/Shepherd", enabled: enabled,
                   agentID: agent.map { AgentID(rawValue: $0) })
    }

    static func host(_ automations: [Automation], agents: [(String, AgentStatus)] = [], id: UUID = studio, name: String = "Studio",
                     connected: Bool = true, manageable: Bool = true) -> AutomationHost {
        AutomationHost(id: id, name: name, connected: connected, manageable: manageable, state: ShepherdState(
            spaces: [hidden],
            agents: agents.map { Agent(id: AgentID(rawValue: $0.0), name: $0.0, spaceID: hidden.id, tabID: TabID(rawValue: "t-" + $0.0), status: $0.1) },
            automations: automations))
    }

    static func key(_ id: String, on host: UUID = studio) -> AutomationKey { AutomationKey(host: host, automation: AutomationID(rawValue: id)) }

    static func run(_ offset: Double, _ result: AutomationRunResult, took: Double? = nil, ended: Double? = nil, agent: String? = nil,
                    id: Int = 0) -> AutomationRun {
        AutomationRun(id: UUID(uuidString: String(format: "00000000-0000-4000-8000-%012d", id))!, startedAt: t0 + offset,
                      settledAt: took.map { t0 + offset + $0 }, endedAt: ended.map { t0 + offset + $0 }, result: result,
                      agentID: agent.map { AgentID(rawValue: $0) })
    }

    // MARK: Rows

    @Test(arguments: [
        ("working", AgentStatus.working, "Running", AutomationTone.running),
        ("starting", .idle, "Running", .running),
        ("asking", .blocked, "Asked you", .attention),
        ("finished", .done, "Finished", .done),
    ])
    func aLiveRunReadsItsAgent(_ name: String, status: AgentStatus, word: String, tone: AutomationTone) throws {
        let runs = [Self.key("a"): [Self.run(0, .running, took: status == .done ? 43 : nil, agent: "run")]]
        let model = AutomationsModel(hosts: [Self.host([Self.automation("a", agent: "run")], agents: [("run", status)])], runs: runs)
        let row = try #require(model.rows.first)
        #expect(row.status == word && row.tone == tone)
        #expect(row.run == FleetRef(host: Self.studio, agent: AgentID(rawValue: "run")))
        #expect(row.abilities.stop && !row.abilities.run && row.abilities.toggle)
        switch status {
        case .working, .idle: #expect(row.clock == .elapsed(since: Date(timeIntervalSince1970: Self.t0)))
        case .done: #expect(row.clock == .ago(Date(timeIntervalSince1970: Self.t0 + 43)))
        case .blocked: #expect(row.clock == nil)
        }
        #expect(model.live.map(\.key) == (tone == .done ? [] : [Self.key("a")]))
    }

    @Test(arguments: [
        (true, [AutomationRun]?.none, "On", AutomationTone.stopped),
        (false, nil, "Off", .off),
        (true, [], "Not run yet", .stopped),
        (false, [], "Off", .off),
        (true, [run(0, .finished, took: 43, ended: 600)], "Finished", .done),
        (true, [run(0, .interrupted, ended: 60)], "Interrupted", .failed),
        (false, [run(0, .stopped, ended: 60)], "Off · stopped", .stopped),
    ])
    func withoutARunTheLastOneSpeaks(enabled: Bool, runs: [AutomationRun]?, word: String, tone: AutomationTone) throws {
        let model = AutomationsModel(hosts: [Self.host([Self.automation("a", enabled: enabled)])], runs: runs.map { [Self.key("a"): $0] } ?? [:])
        let row = try #require(model.rows.first)
        #expect(row.status == word && row.tone == tone)
        #expect(row.run == nil && row.abilities.run && !row.abilities.stop)
        #expect(row.when == (enabled ? "When Shepherd starts" : "By hand"))
        #expect(row.place == "Shepherd")
        if let last = runs?.last {
            #expect(row.clock == .ago(Date(timeIntervalSince1970: last.endedAt!)))
        }
    }

    @Test func anOfflineHostsAutomationsAreReadOnly() throws {
        let model = AutomationsModel(hosts: [Self.host([Self.automation("a", agent: "run")], agents: [("run", .working)], connected: false)],
                                     runs: [:])
        let row = try #require(model.rows.first)
        #expect(row.status == "Host offline" && row.offline && row.clock == nil)
        #expect(row.abilities == AutomationAbilities(toggle: false, run: false, stop: false, edit: false, readOnlyReason: "Host offline"))
        #expect(model.live.isEmpty)
    }

    /// A host from before automations over the remote protocol shows them, and says why nothing
    /// can be changed from here.
    @Test func anOlderHostsAutomationsAreReadOnly() throws {
        let row = try #require(AutomationsModel(hosts: [Self.host([Self.automation("a")], manageable: false)], runs: [:]).rows.first)
        #expect(!row.abilities.toggle && !row.abilities.run && !row.abilities.stop && !row.abilities.edit)
        #expect(row.abilities.readOnlyReason == "Update Shepherd on Studio to manage its automations from here.")
    }

    @Test func rowsCarryTheirHostOnlyWhenThereIsMoreThanOne() {
        let one = AutomationsModel(hosts: [Self.host([Self.automation("a")])], runs: [:])
        let two = AutomationsModel(hosts: [Self.host([Self.automation("a")]),
                                           Self.host([Self.automation("b")], id: Self.build, name: "build-01")], runs: [:])
        #expect(one.rows.map(\.hostTag) == [nil])
        #expect(two.rows.map(\.hostTag) == ["Studio", "build-01"])
        #expect(two.rows.map(\.key) == [Self.key("a"), Self.key("b", on: Self.build)])
    }

    // MARK: Detail

    @Test func theDetailListsRunsNewestFirstAndChartsTheLatest() throws {
        var runs: [AutomationRun] = []
        for day in 0..<16 {
            let result: AutomationRunResult = day == 10 ? .stopped : day == 12 ? .needsYou : .finished
            runs.append(Self.run(Double(day - 15) * 86_400, result, took: result == .finished ? Double(30 + day) : nil,
                                 ended: result == .stopped ? 20 : nil, agent: day == 15 ? "run" : nil, id: day))
        }
        let model = AutomationsModel(hosts: [Self.host([Self.automation("a")])], runs: [Self.key("a"): runs])
        let detail = try #require(model.detail(Self.key("a"), runs: runs, now: Date(timeIntervalSince1970: Self.t0 + 3600),
                                               timeZone: Self.utc, locale: Self.posix))

        #expect(detail.runsKnown)
        #expect(detail.runs.count == 16)
        #expect(detail.runs.first?.started == "Sep 24 02:00")
        #expect(detail.runs.first?.agent == FleetRef(host: Self.studio, agent: AgentID(rawValue: "run")))
        #expect(detail.runs.dropFirst().allSatisfy { $0.agent == nil })
        #expect(detail.lastRun?.started == "Today 02:00")
        #expect(detail.lastRun?.duration == "45s")
        #expect(detail.bars.count == AutomationDetail.chartLimit)
        #expect(detail.bars.map(\.id) == runs.suffix(14).map(\.id))
        #expect(detail.bars.last?.height == 1)
        #expect(detail.bars.first { $0.tone == .attention }?.height == AutomationsModel.minimumBar, "a run with no end yet is a stub")
        #expect(detail.chartSummary == "stopped: 1 · asked: 1")
        #expect(detail.chartStart == "Sep 11 02:00" && detail.chartEnd == "Sep 24 02:00", "the charted fourteen, not every run")
        #expect(detail.bars.last?.label.hasSuffix("finished, 45s") == true)
    }

    @Test func aDetailWhoseRunsAreNotReadYetSaysSo() throws {
        let model = AutomationsModel(hosts: [Self.host([Self.automation("a")])], runs: [:])
        let detail = try #require(model.detail(Self.key("a"), runs: nil))
        #expect(!detail.runsKnown && detail.runs.isEmpty && detail.bars.isEmpty && detail.lastRun == nil && detail.chartSummary == nil)
        #expect(detail.chartStart == nil && detail.chartEnd == nil)
        #expect(model.detail(Self.key("gone"), runs: nil) == nil)
    }

    @Test(arguments: [
        (0.2, "0s"), (43, "43s"), (59.6, "1m"), (240, "4m"), (3600, "1h"), (3900, "1h 5m"),
    ])
    func durationsReadShort(_ seconds: Double, _ text: String) {
        #expect(AutomationsModel.duration(seconds) == text)
    }

    @Test(arguments: [
        (0.0, "Today 02:00"), (-86_400, "Yesterday 02:00"),
    ])
    func theLastRunSaysTodayOrYesterday(_ offset: Double, _ text: String) {
        let date = Date(timeIntervalSince1970: Self.t0 + offset)
        #expect(AutomationsModel.dayTime(date, now: Date(timeIntervalSince1970: Self.t0 + 3600), timeZone: Self.utc, locale: Self.posix) == text)
    }
}
