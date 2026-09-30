import Foundation
import Testing
import ShepherdCore

/// The Speed control's model: which models offer a service tier (the table shared with
/// `Extensions/shepherd-service-tier.ts`) and the tier an agent keeps.
@Suite("Service tiers")
struct ServiceTierTests {
    struct Row: Decodable, Sendable, CustomTestStringConvertible {
        var provider: String
        var api: String?
        var id: String
        var ownedBy: String?
        var tiers: [ServiceTier]
        var fast: String?
        var why: String?

        var model: ServiceTierModel { ServiceTierModel(provider: provider, id: id, api: api, ownedBy: ownedBy) }
        var testDescription: String { "\(provider) \(api ?? "-") \(id) owner \(ownedBy ?? "-")" }
    }

    /// `Tests/Extensions/service-tier-support.json` is shared with the extension's node test.
    static let rows: [Row] = {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Extensions/service-tier-support.json")
        struct File: Decodable { var rows: [Row] }
        return (try? JSONDecoder().decode(File.self, from: Data(contentsOf: url)).rows) ?? []
    }()

    @Test func theSharedTableIsLoaded() {
        #expect(Self.rows.count >= 40)
        #expect(Self.rows.contains { !$0.tiers.isEmpty } && Self.rows.contains { $0.tiers.isEmpty })
    }

    @Test(arguments: rows)
    func aModelOffersTheTiersTheSharedTableSays(row: Row) {
        #expect(ServiceTierSupport.tiers(for: row.model) == row.tiers)
        #expect(ServiceTierSupport.wireValue(.fast, for: row.model) == row.fast)
        #expect(ServiceTierSupport.wireValue(.standard, for: row.model) == nil, "Standard sends nothing")
    }

    @Test func aModelThatOffersTiersOffersStandardFirst() {
        for row in Self.rows where !row.tiers.isEmpty {
            #expect(row.tiers.first == .standard)
        }
    }

    @Test func everyRuleNamesItsProviderAndApisOnce() {
        let providers = ServiceTierSupport.rules.map(\.provider)
        #expect(Set(providers).count == providers.count)
        for rule in ServiceTierSupport.rules {
            #expect(!rule.apis.isEmpty)
            #expect(rule.wire[.standard] == nil, "Standard is the absence of a value")
            #expect(rule.wire[.fast] == "priority")
        }
    }

    @Test func titlesAndSummariesAreWrittenForEveryTier() {
        for tier in ServiceTier.allCases {
            #expect(!tier.title.isEmpty && !tier.summary.isEmpty)
        }
        #expect(ServiceTier.fast.summary == "Faster responses, billed at a higher rate")
    }

    // MARK: On the agent

    @Test func aStateFileFromBeforeServiceTiersDecodesAsStandard() throws {
        let old = #"{"id":"a1","name":"worker","spaceID":"s1","tabID":"t1","status":"idle"}"#
        #expect(try Fixture.decode(Agent.self, old).serviceTier == .standard)
    }

    @Test func aFastAgentKeepsItsTierThroughAnEncodeAndDecode() throws {
        var agent = Fixture.state().agents[0]
        agent.serviceTier = .fast
        #expect(try Fixture.roundTrip(agent).serviceTier == .fast)
        #expect(try Fixture.encodeObject(agent)["serviceTier"] as? String == "fast")
    }

    @Test func aStandardAgentWritesNoKey() throws {
        #expect(try Fixture.encodeObject(Fixture.state().agents[0])["serviceTier"] == nil)
    }

    @Test func aTierFromANewerBuildReadsAsStandard() throws {
        let newer = #"{"id":"a1","name":"worker","spaceID":"s1","tabID":"t1","status":"idle","serviceTier":"ultrafast"}"#
        #expect(try Fixture.decode(Agent.self, newer).serviceTier == .standard)
    }

    @Test func aWorkspaceWithAFastAgentSurvivesValidationAndARoundTrip() throws {
        var state = Fixture.state()
        state.agents[0].serviceTier = .fast
        try state.validate()
        #expect(try Fixture.roundTrip(state).agents[0].serviceTier == .fast)
    }
}
