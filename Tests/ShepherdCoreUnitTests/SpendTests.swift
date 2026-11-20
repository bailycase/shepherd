import Foundation
import Testing
import ShepherdCore

/// What a thread has spent and how a day's spend adds up across threads.
@Suite("Spend")
struct SpendTests {
    static let monday = "2026-05-11"
    static let tuesday = "2026-05-12"

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

    @Test func aFreshSessionCountsWhole() throws {
        var spend = try #require(AgentSpend.updated(nil, tokens: 9_000, cost: 3, model: "a/one", day: Self.monday))
        spend = try #require(AgentSpend.updated(spend, tokens: 400, cost: 0.1, model: "a/one", day: Self.monday))
        #expect(spend.today == [ModelSpend(model: "a/one", tokens: 400, cost: 0.1)])
    }

    @Test func aDayAddsUpAcrossThreadsAndModelsCostliestFirst() {
        let one = AgentSpend(tokens: 5_000, cost: 2, day: Self.monday, today: [
            ModelSpend(model: "a/cheap", tokens: 1_000, cost: 0.1), ModelSpend(model: "b/dear", tokens: 500, cost: 1.5),
        ])
        let two = AgentSpend(tokens: 9_000, cost: 1, day: Self.monday, today: [
            ModelSpend(model: "a/cheap", tokens: 2_000, cost: 0.2),
        ])
        let rollup = SpendRollup.today([one, two], day: Self.monday)
        #expect(rollup.tokens == 3_500)
        #expect(abs((rollup.cost ?? 0) - 1.8) < 1e-9)
        #expect(rollup.models.map(\.model) == ["b/dear", "a/cheap"])
        #expect(rollup.models.map(\.tokens) == [500, 3_000])
    }

    @Test func aThreadWithNoCostAddsTokensAndTheTotalCostIsTheKnownOnes() {
        let priced = AgentSpend(tokens: 1, cost: 1, day: Self.monday, today: [ModelSpend(model: "a/one", tokens: 100, cost: 0.4)])
        let free = AgentSpend(tokens: 1, cost: nil, day: Self.monday, today: [ModelSpend(model: "sub/plan", tokens: 900, cost: nil)])
        let rollup = SpendRollup.today([priced, free], day: Self.monday)
        #expect(rollup.tokens == 1_000)
        #expect(rollup.cost == 0.4)
        #expect(rollup.models.map(\.model) == ["a/one", "sub/plan"])
        #expect(SpendRollup.today([free], day: Self.monday).cost == nil)
    }

    @Test func aThreadFromAnotherDayAddsNothing() {
        let old = AgentSpend(tokens: 1, cost: 1, day: Self.monday, today: [ModelSpend(model: "a/one", tokens: 100, cost: 0.4)])
        let rollup = SpendRollup.today([old], day: Self.tuesday)
        #expect(rollup == .empty)
        #expect(rollup.isEmpty)
        #expect(SpendFormat.line(rollup) == nil)
    }

    @Test func theDayKeyIsTheLocalCalendarDay() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let lateEvening = Date(timeIntervalSince1970: 1_778_565_000) // 2026-05-12 05:30 UTC, still the 11th in Los Angeles
        #expect(SpendDay.key(lateEvening, calendar: calendar) == "2026-05-11")
        calendar.timeZone = TimeZone(identifier: "UTC")!
        #expect(SpendDay.key(lateEvening, calendar: calendar) == "2026-05-12")
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
        let broken = try JSONDecoder().decode(Agent.self, from: Self.agentJSON(extra: #","spend":{"tokens":"many"}"#))
        #expect(broken.spend == nil)
    }
}
