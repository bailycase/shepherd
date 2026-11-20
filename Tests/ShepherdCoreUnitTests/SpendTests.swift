import Foundation
import Testing
import ShepherdCore

/// What a thread has spent and how a day's spend adds up across threads.
@Suite("Spend")
struct SpendTests {
    static let monday = "2026-05-11"
    static let tuesday = "2026-05-12"
    /// Noon UTC on the day, read in UTC (a spend's zone), so a day is the day wherever the test runs.
    static func noon(_ day: String) -> Date { Date(timeIntervalSince1970: day == monday ? 1_778_500_800 : 1_778_587_200) }

    @Test func theFirstReportIsABaselineNotToday() throws {
        let spend = try #require(AgentSpend.updated(nil, tokens: 3_000_000, cost: 4.2, model: "anthropic/sonnet", day: Self.monday))
        #expect(spend.tokens == 3_000_000)
        #expect(spend.cost == 4.2)
        #expect(spend.today.isEmpty)
    }

    @Test func noTokensIsNoReport() {
        let before = AgentSpend(tokens: 10, cost: 1, day: Self.monday)
        #expect(AgentSpend.updated(before, tokens: nil, cost: 5, model: nil, day: Self.monday) == before)
        #expect(AgentSpend.updated(nil, tokens: nil, cost: 5, model: nil, day: Self.monday) == nil)
    }

    @Test func growthIsAddedToTheModelTheThreadRan() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 0.5, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 1_600, cost: 0.8, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 2_000, cost: 1.0, model: "b/two", day: Self.monday))
        #expect(spend.tokens == 2_000)
        #expect(spend.today.map(\.model) == ["a/one", "b/two"])
        #expect(spend.today.map(\.tokens) == [600, 400])
        #expect(abs((spend.today[0].cost ?? 0) - 0.3) < 1e-9)
        #expect(abs((spend.today[1].cost ?? 0) - 0.2) < 1e-9)
    }

    @Test func aProviderWithNoCostAddsTokensAlone() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 100, cost: nil, model: "sub/plan", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 900, cost: nil, model: "sub/plan", day: Self.monday))
        #expect(spend.cost == nil)
        #expect(spend.today == [ModelSpend(model: "sub/plan", tokens: 800, cost: nil)])
    }

    @Test func aNewDayStartsTheEntriesOver() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 0, cost: 0, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 500, cost: 1, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 700, cost: 1.5, model: "a/one", day: Self.tuesday))
        #expect(spend.day == Self.tuesday)
        #expect(spend.today == [ModelSpend(model: "a/one", tokens: 200, cost: 0.5)])
    }

    @Test func aTotalThatDropsWithinTheSessionAddsNothing() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 1_400, cost: 1.4, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 800, cost: 0.8, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.today == [ModelSpend(model: "a/one", tokens: 400, cost: spend.today[0].cost)], "the drop is not a new session's 800")
        #expect(spend.tokens == 800)
    }

    @Test func theSameReportAgainAddsNothingAndARetryBilledAgainCountsOnce() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        for _ in 0..<3 { spend = try #require(AgentSpend.updated(spend, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1")) }
        #expect(spend.today.isEmpty, "a replayed report is nothing new")
        // A failed reply (200 tokens) leaves the session total; the retry is billed again and grows it back.
        spend = try #require(AgentSpend.updated(spend, tokens: 800, cost: 0.8, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.today.map(\.tokens) == [200])
    }

    @Test func compactionThatLowersTheTokensButNotTheCostAddsNoCost() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 9_000, cost: 3, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 2_000, cost: 3, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.today.isEmpty)
        spend = try #require(AgentSpend.updated(spend, tokens: 2_500, cost: 3.2, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.today.map(\.tokens) == [500])
        #expect(abs((spend.today[0].cost ?? 0) - 0.2) < 1e-9)
    }

    @Test func aCostThatGoesMissingKeepsTheLastKnownSoTheNextOneAddsTheDifference() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 100, cost: 4, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 200, cost: nil, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.cost == 4)
        spend = try #require(AgentSpend.updated(spend, tokens: 300, cost: 5, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(spend.today.map(\.tokens) == [200])
        #expect(spend.today.first?.cost == 1, "$4 → nil → $5 grew by $1, not $5")
    }

    @Test func aDifferentSessionCountsWholeButAnUnnamedOneIsTheSame() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 9_000, cost: 3, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.updated(spend, tokens: 400, cost: 0.1, model: "a/one", day: Self.monday, sessionID: "s2"))
        #expect(spend.sessionID == "s2")
        #expect(spend.today == [ModelSpend(model: "a/one", tokens: 400, cost: 0.1)])
        spend = try #require(AgentSpend.updated(spend, tokens: 450, cost: 0.1, model: "a/one", day: Self.monday))
        #expect(spend.today.map(\.tokens) == [450], "no session id: the same session")
        // A spend saved before sessions were named adopts the first id it hears without counting the session again.
        var old = try #require(AgentSpend.updated(nil, tokens: 5_000, cost: 1, model: "a/one", day: Self.monday))
        old = try #require(AgentSpend.updated(old, tokens: 5_100, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        #expect(old.today.map(\.tokens) == [100])
    }

    // MARK: Subagents

    private static func run(_ id: String, tokens: Int?, cost: Double?, finished: Bool = false, model: String? = "b/helper") -> ChildUsage {
        ChildUsage(id: id, model: model, tokens: tokens, cost: cost, finished: finished)
    }

    @Test func aSubagentsUsageIsAddedOnceByWhatItGrewBy() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r1", tokens: 300, cost: 0.3)], day: Self.monday))
        // Published again and again with the same totals: nothing more.
        for _ in 0..<3 { spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r1", tokens: 300, cost: 0.3)], day: Self.monday)) }
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r1", tokens: 500, cost: 0.5), Self.run("r2", tokens: 50, cost: nil)], day: Self.monday))
        #expect(spend.today.map(\.model) == ["b/helper"])
        #expect(spend.today.first?.tokens == 550)
        #expect(abs((spend.today.first?.cost ?? 0) - 0.5) < 1e-9)
        #expect(spend.totalTokens == 1_550, "the thread's own total and its subagents'")
        #expect(abs((spend.totalCost ?? 0) - 1.5) < 1e-9)
        #expect(spend.tokens == 1_000, "pi's own session total stays what pi said")
    }

    @Test func aFinishedRunSeenFirstIsHistoryAndNothingIsCountedBeforeTheThreadsBaseline() throws {
        #expect(AgentSpend.addingChildren(nil, [Self.run("r1", tokens: 300, cost: 0.3)], day: Self.monday) == nil)
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("old", tokens: 9_000, cost: 5, finished: true)], day: Self.monday))
        #expect(spend.today.isEmpty)
        #expect(spend.totalTokens == 10_000)
        // The run that published before and finishes with more is counted by its growth.
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r2", tokens: 100, cost: nil)], day: Self.monday))
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r2", tokens: 160, cost: nil, finished: true)], day: Self.monday))
        #expect(spend.today.map(\.tokens) == [160])
    }

    @Test func aNewSessionForgetsTheOldSessionsSubagents() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 1_000, cost: 1, model: "a/one", day: Self.monday, sessionID: "s1"))
        spend = try #require(AgentSpend.addingChildren(spend, [Self.run("r1", tokens: 300, cost: 0.3)], day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 10, cost: 0.01, model: "a/one", day: Self.monday, sessionID: "s2"))
        #expect(spend.children.isEmpty)
        #expect(spend.totalTokens == 10)
    }

    @Test func aDayAddsUpAcrossThreadsAndModelsCostliestFirst() {
        let one = AgentSpend(tokens: 5_000, cost: 2, day: Self.monday, zone: "UTC", today: [
            ModelSpend(model: "a/cheap", tokens: 1_000, cost: 0.1), ModelSpend(model: "b/dear", tokens: 500, cost: 1.5),
        ])
        let two = AgentSpend(tokens: 9_000, cost: 1, day: Self.monday, zone: "UTC", today: [
            ModelSpend(model: "a/cheap", tokens: 2_000, cost: 0.2),
        ])
        let rollup = SpendRollup.today([one, two], now: Self.noon(Self.monday))
        #expect(rollup.tokens == 3_500)
        #expect(abs((rollup.cost ?? 0) - 1.8) < 1e-9)
        #expect(rollup.models.map(\.model) == ["b/dear", "a/cheap"])
        #expect(rollup.models.map(\.tokens) == [500, 3_000])
    }

    @Test func aThreadWithNoCostAddsTokensAndTheTotalCostIsTheKnownOnes() {
        let priced = AgentSpend(tokens: 1, cost: 1, day: Self.monday, zone: "UTC", today: [ModelSpend(model: "a/one", tokens: 100, cost: 0.4)])
        let free = AgentSpend(tokens: 1, cost: nil, day: Self.monday, zone: "UTC", today: [ModelSpend(model: "sub/plan", tokens: 900, cost: nil)])
        let rollup = SpendRollup.today([priced, free], now: Self.noon(Self.monday))
        #expect(rollup.tokens == 1_000)
        #expect(rollup.cost == 0.4)
        #expect(rollup.models.map(\.model) == ["a/one", "sub/plan"])
        #expect(SpendRollup.today([free], now: Self.noon(Self.monday)).cost == nil)
    }

    @Test func aThreadFromAnotherDayAddsNothing() {
        let old = AgentSpend(tokens: 1, cost: 1, day: Self.monday, zone: "UTC", today: [ModelSpend(model: "a/one", tokens: 100, cost: 0.4)])
        let rollup = SpendRollup.today([old], now: Self.noon(Self.tuesday))
        #expect(rollup == .empty)
        #expect(rollup.isEmpty)
        #expect(SpendFormat.line(rollup) == nil)
    }

    @Test func theDayKeyIsTheCalendarDayInItsZone() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lateEvening = Date(timeIntervalSince1970: 1_778_565_000) // 2026-05-12 05:30 UTC, still the 11th in Los Angeles
        #expect(SpendDay.key(lateEvening, calendar: calendar) == "2026-05-11")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(SpendDay.key(lateEvening, calendar: calendar) == "2026-05-12")
    }

    @Test func todayIsTheHostsDayForEveryViewer() throws {
        // A host in Los Angeles stamped its report at 21:30 on the 11th (04:30 UTC on the 12th).
        let reported = Date(timeIntervalSince1970: 1_778_560_200)
        let day = SpendDay.key(reported, zone: "America/Los_Angeles")
        #expect(day == "2026-05-11")
        let spend = AgentSpend(tokens: 5, cost: nil, day: day, zone: "America/Los_Angeles", today: [ModelSpend(model: "a/one", tokens: 5, cost: nil)])
        // A viewer in UTC (already the 12th) and one in Tokyo still see it as today until the host's midnight.
        let before = Date(timeIntervalSince1970: 1_778_564_000)
        #expect(SpendRollup.today([spend], now: before).tokens == 5)
        let after = try #require(SpendDay.nextChange(of: [spend], after: before)).addingTimeInterval(1)
        #expect(SpendRollup.today([spend], now: after) == .empty)
        // The change is the host's midnight, 07:00 UTC on the 12th.
        #expect(after.timeIntervalSince1970 == 1_778_569_201)
    }

    @Test func aDayRollsOverAtMidnightWithoutAnythingPushed() throws {
        let spend = AgentSpend(tokens: 5, cost: 1, day: Self.monday, zone: "UTC", today: [ModelSpend(model: "a/one", tokens: 5, cost: 1)])
        let evening = Date(timeIntervalSince1970: 1_778_543_940) // 2026-05-11 23:59 UTC
        #expect(SpendSummary([spend], now: evening)?.total == "est. $1.00 · 5 tok")
        let midnight = try #require(SpendDay.nextChange(of: [spend], after: evening))
        #expect(midnight == Date(timeIntervalSince1970: 1_778_544_000))
        #expect(SpendSummary([spend], now: midnight) == nil, "the day's total is gone at midnight")
        #expect(SpendDay.nextChange(of: [], after: evening) == nil)
    }

    @Test func aSummaryIsFormattedOnceWithItsRows() throws {
        let spend = AgentSpend(tokens: 1, cost: nil, day: Self.monday, zone: "UTC", today: [
            ModelSpend(model: "anthropic/opus", tokens: 640_000, cost: 8.9), ModelSpend(model: nil, tokens: 12_400, cost: nil)])
        let summary = try #require(SpendSummary([spend], now: Self.noon(Self.monday)))
        #expect(summary.total == "est. $8.90 · 652.4k tok")
        #expect(summary.rows.map(\.name) == ["opus", "Unknown model"])
        #expect(summary.rows.map(\.value) == ["est. $8.90 · 640k tok", "12.4k tok"])
    }

    @Test(arguments: [
        (950, "950"), (1_000, "1k"), (12_400, "12.4k"), (999_949, "999.9k"), (999_950, "1M"), (3_100_000, "3.1M"), (2_000_000_000, "2B"),
    ] as [(Int, String)])
    func tokensAreCompact(count: Int, text: String) {
        #expect(SpendFormat.tokens(count) == text)
    }

    @Test func aLineSaysEstAndDropsWhatIsUnknown() {
        #expect(SpendFormat.line(tokens: 3_100_000, cost: 4.2) == "est. $4.20 · 3.1M tok")
        #expect(SpendFormat.line(tokens: 3_100_000, cost: nil) == "3.1M tok")
        #expect(SpendFormat.line(tokens: 3_100_000, cost: 0) == "3.1M tok")
        #expect(SpendFormat.line(tokens: 0, cost: 0.3) == "est. $0.30")
        #expect(SpendFormat.line(tokens: 0, cost: 0.001) == "est. <$0.01")
        #expect(SpendFormat.line(tokens: 0, cost: nil) == nil)
        #expect(SpendFormat.line(nil as AgentSpend?) == nil)
        #expect(SpendFormat.brief(AgentSpend(tokens: 3_100_000, cost: 4.2, day: Self.monday)) == "est. $4.20")
        #expect(SpendFormat.brief(AgentSpend(tokens: 12_400, cost: nil, day: Self.monday)) == "12.4k tok")
        #expect(SpendFormat.brief(nil) == nil)
        #expect(SpendFormat.modelName("anthropic/claude-sonnet-4") == "claude-sonnet-4")
        #expect(SpendFormat.modelName(nil) == "Unknown model")
    }

    // MARK: Persistence

    private static func agentJSON(extra: String = "") -> Data {
        Data("""
        {"id":"a1","name":"Fix login","spaceID":"s1","tabID":"t1","status":"idle"\(extra)}
        """.utf8)
    }

    @Test func anOlderAgentWithoutSpendDecodesWithNone() throws {
        let agent = try JSONDecoder().decode(Agent.self, from: Self.agentJSON())
        #expect(agent.spend == nil)
        let reencoded = try JSONEncoder().encode(agent)
        #expect(try JSONSerialization.jsonObject(with: reencoded) is [String: Any])
        #expect(!String(decoding: reencoded, as: UTF8.self).contains("\"spend\""))
    }

    @Test func spendRoundTripsAndAnUnreadableOneIsNone() throws {
        var agent = try JSONDecoder().decode(Agent.self, from: Self.agentJSON())
        agent.spend = AgentSpend(tokens: 10, cost: nil, day: Self.monday, today: [ModelSpend(model: "a/one", tokens: 4, cost: nil)])
        let back = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent))
        #expect(back.spend == agent.spend)
        agent.spend?.sessionID = "s1"
        agent.spend?.zone = "UTC"
        agent.spend?.children = ["r1#1": ChildSpend(tokens: 3, cost: 0.2)]
        #expect(try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(agent)).spend == agent.spend)
        let broken = try JSONDecoder().decode(Agent.self, from: Self.agentJSON(extra: #","spend":{"tokens":"many"}"#))
        #expect(broken.spend == nil)
    }
}
