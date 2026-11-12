import Foundation
import Testing
import ShepherdCore
@testable import ShepherdProtocol

/// Fleet's sync wire: clock, op order, version vectors, unit names and the synced host settings.
@Suite("Fleet sync wire")
struct FleetSyncWireTests {
    static let macA = UUID(uuidString: "00000000-0000-0000-0000-00000000000A")!
    static let macB = UUID(uuidString: "00000000-0000-0000-0000-00000000000B")!

    static func op(_ mac: UUID, wall: UInt64, counter: UInt32 = 0, seed: Bool = false, unit: String = "setting:host.defaultModel") -> FleetOp {
        FleetOp(mac: mac, seq: 1, hlc: FleetHLC(wallMs: wall, counter: counter), unit: unit, change: .value("\"x\""), seed: seed)
    }

    // MARK: Clock

    @Test func theClockNeverGoesBackWhateverTheWallClockDoes() {
        let first = FleetHLC(wallMs: 1_000)
        #expect(first.next(now: 2_000) == FleetHLC(wallMs: 2_000))
        #expect(first.next(now: 1_000) == FleetHLC(wallMs: 1_000, counter: 1))
        #expect(first.next(now: 500) == FleetHLC(wallMs: 1_000, counter: 1), "a wall clock set back keeps counting")
        #expect(FleetHLC(wallMs: 1_000, counter: 7) < FleetHLC(wallMs: 1_001))
        #expect(FleetHLC(wallMs: 1_000, counter: 7) > FleetHLC(wallMs: 1_000, counter: 6))
    }

    // MARK: Which op wins

    @Test func theLaterWriteWinsAndEqualReadingsFallToTheLargerMacID() {
        let early = Self.op(Self.macA, wall: 1_000), late = Self.op(Self.macB, wall: 2_000)
        #expect(late.supersedes(early) && !early.supersedes(late))
        let tieA = Self.op(Self.macA, wall: 5_000, counter: 1), tieB = Self.op(Self.macB, wall: 5_000, counter: 1)
        #expect(tieB.supersedes(tieA) && !tieA.supersedes(tieB), "a tie never depends on a clock, so both Macs pick the same one")
    }

    @Test func aPersonsWriteBeatsASeedAndTheEarlierSeedIsTheReference() {
        let edit = Self.op(Self.macA, wall: 1_000), laterSeed = Self.op(Self.macB, wall: 9_000, seed: true)
        #expect(edit.supersedes(laterSeed) && !laterSeed.supersedes(edit), "even an older write beats a later seed")
        let firstSeed = Self.op(Self.macA, wall: 1_000, seed: true), secondSeed = Self.op(Self.macB, wall: 2_000, seed: true)
        #expect(firstSeed.supersedes(secondSeed) && !secondSeed.supersedes(firstSeed), "the Mac where sync was first on is the reference")
    }

    // MARK: Version vectors

    @Test func aVectorCoversWhatItHoldsAndReadsAbsentMacsAsZero() {
        var ours = FleetVersionVector([Self.macA: 3]), theirs = FleetVersionVector([Self.macA: 2])
        #expect(ours.covers(theirs) && !theirs.covers(ours))
        #expect(ours[Self.macB] == 0)
        theirs[Self.macB] = 1
        #expect(!ours.covers(theirs))
        ours[Self.macB] = 1
        #expect(ours.covers(theirs))
        ours[Self.macB] = 0
        #expect(ours.seqs[Self.macB] == nil, "zero is absent")
    }

    @Test func aVectorIsAnObjectOfStringKeysOnTheWire() throws {
        let data = try JSONEncoder().encode(FleetVersionVector([Self.macA: 3]))
        #expect(try JSONSerialization.jsonObject(with: data) as? [String: Int] == [Self.macA.uuidString: 3])
        #expect(try JSONDecoder().decode(FleetVersionVector.self, from: data) == FleetVersionVector([Self.macA: 3]))
    }

    // MARK: Ops

    @Test func anOpRoundTripsAndOlderOnesWithoutSeedOrNameDecode() throws {
        let op = FleetOp(mac: Self.macA, seq: 3, hlc: FleetHLC(wallMs: 9, counter: 1), unit: "instruction:AGENTS.md",
                         change: .blob(hash: String(repeating: "ab", count: 32), size: 5), seed: true, macName: "Mac mini")
        #expect(try JSONDecoder().decode(FleetOp.self, from: JSONEncoder().encode(op)) == op)
        let bare = FleetOp(mac: Self.macA, seq: 1, hlc: FleetHLC(wallMs: 1), unit: "setting:fleet.autoDispatch", change: .deletion)
        let object = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(bare)) as? [String: Any])
        #expect(object["seed"] == nil && object["macName"] == nil, "written only when set")
        #expect(try JSONDecoder().decode(FleetOp.self, from: JSONEncoder().encode(bare)) == bare)
    }

    @Test func aPeersOpIsRefusedWhenItsShapeIsWrong() {
        let good = Self.op(Self.macA, wall: 1)
        #expect(good.isWellFormed)
        var bad = good
        bad.seq = 0
        #expect(!bad.isWellFormed, "ops are numbered from 1")
        bad = good
        bad.unit = "../etc/passwd"
        #expect(!bad.isWellFormed)
        bad.unit = "instruction:../../x"
        #expect(!bad.isWellFormed, "a name never walks out of its folder")
        bad = good
        bad.change = .value(String(repeating: "x", count: FleetSyncProtocol.maxInlineValueBytes + 1))
        #expect(!bad.isWellFormed, "a big value is a blob")
        bad.change = .blob(hash: "not-a-hash", size: 1)
        #expect(!bad.isWellFormed)
        bad.change = .blob(hash: String(repeating: "0", count: 64), size: FleetSyncProtocol.maxBlobBytes + 1)
        #expect(!bad.isWellFormed)
    }

    @Test func unitNamesSplitIntoAKindAndAName() {
        #expect(FleetUnit.instruction(.agents) == "instruction:AGENTS.md")
        #expect(FleetUnit.kind(of: "setting:pi.theme") == "setting" && FleetUnit.name(of: "setting:pi.theme") == "pi.theme")
        #expect(FleetUnit.isValid("skill:foo/SKILL.md"), "later slices' kinds travel through an older build untouched")
        #expect(FleetUnit.isValid("mcpServer:postgres") && FleetUnit.isValid("hook:" + String(repeating: "a", count: 64)) && FleetUnit.isValid("subagent:team/api-review.md"))
        #expect(!FleetUnit.isValid("mcpServer1:x") && !FleetUnit.isValid("mcp_server:x"))
        #expect(!FleetUnit.isValid("nokind") && !FleetUnit.isValid(":name") && !FleetUnit.isValid("Setting:x") && !FleetUnit.isValid("setting:"))
    }

    @Test func signInsAreUnitsOfTheirOwnKindAndAHelloWithoutFreshDecodes() throws {
        #expect(FleetUnit.credential("openai-codex") == "credential:openai-codex" && FleetUnit.isCredential("credential:openai-codex"))
        let key = "mcp__notion|https://mcp.notion.com/mcp"
        #expect(FleetUnit.mcpAuth(key) == "mcpAuth:" + key && FleetUnit.isValid(FleetUnit.mcpAuth(key)) && FleetUnit.isCredential(FleetUnit.mcpAuth(key)))
        #expect(!FleetUnit.isCredential("setting:pi.theme") && !FleetUnit.isCredential("mcpServer:notion") && !FleetUnit.isCredential("extension:credentials"))

        // `fresh` is written only when set and a hello from a build that lacks it reads as not fresh.
        let vector = FleetVersionVector([Self.macA: 2])
        let plain = try JSONSerialization.jsonObject(with: JSONEncoder().encode(FleetSyncRequest.hello(vector: vector))) as? [String: Any]
        #expect(plain?["fresh"] == nil)
        let old = Data(#"{"kind":"hello","vector":{}}"#.utf8)
        #expect(try JSONDecoder().decode(FleetSyncRequest.self, from: old) == .hello(vector: FleetVersionVector(), fresh: false))
        let asked = try JSONEncoder().encode(FleetSyncRequest.hello(vector: vector, fresh: true))
        #expect(try JSONDecoder().decode(FleetSyncRequest.self, from: asked) == .hello(vector: vector, fresh: true))
    }

    @Test func theBlobNameIsTheHashOfItsBytes() {
        // sha256("abc")
        #expect(FleetSyncProtocol.hash(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(FleetSyncProtocol.isHash(FleetSyncProtocol.hash(Data())))
        #expect(!FleetSyncProtocol.isHash("BA78") && !FleetSyncProtocol.isHash(String(repeating: "G", count: 64)))
    }

    // MARK: Host settings

    @Test func everySyncedHostSettingRoundTripsThroughItsJSON() throws {
        var settings = HostSettings()
        settings.defaultModel = "acme/model-1"
        settings.defaultThinking = .high
        settings.defaultServiceTier = .fast
        settings.textGenerationModel = nil
        settings.compactAtPercent = 80
        settings.queueDelivery = .oneAtATime
        settings.worktreeBase = .head
        settings.fetchBeforeCreating = false
        settings.generatePRDescriptions = false
        settings.closeOnMerge = true
        settings.worktreeDeleteAction = .keepWorktree
        settings.fleetThreadsCanSend = true
        settings.fleetThreadCap = 5
        settings.fleetAutoDispatch = false
        settings.fleetBatteryCountsHalf = false
        var applied = HostSettings()
        for setting in FleetHostSetting.allCases {
            let change = try #require(setting.change(fromJSON: setting.json(in: settings)), "\(setting) decodes its own JSON")
            applied.apply(change)
        }
        for setting in FleetHostSetting.allCases { #expect(setting.json(in: applied) == setting.json(in: settings), "\(setting)") }
    }

    @Test func nullIsAValueForAnOptionalSettingAndGarbageIsNot() {
        #expect(FleetHostSetting.defaultModel.change(fromJSON: "null") == .defaultModel(nil))
        #expect(FleetHostSetting.compactAtPercent.change(fromJSON: "null") == .compactAtPercent(nil))
        #expect(FleetHostSetting.defaultModel.change(fromJSON: "{") == nil)
        #expect(FleetHostSetting.defaultThinking.change(fromJSON: "\"sideways\"") == nil, "a value from a newer build is refused, not guessed")
        #expect(FleetHostSetting.fetchBeforeCreating.change(fromJSON: "\"yes\"") == nil)
    }

    @Test func aMacThatNeverChoseASettingHasItAtItsDefaultAndSeedsNothing() {
        let fresh = HostSettings()
        for setting in FleetHostSetting.allCases { #expect(setting.isDefault(in: fresh), "\(setting)") }
        var chosen = fresh
        chosen.defaultThinking = .low
        #expect(!FleetHostSetting.defaultThinking.isDefault(in: chosen) && FleetHostSetting.queueDelivery.isDefault(in: chosen))
    }

    @Test func settingsThatStayPerMacAreNeverUnits() {
        let keys = Set(FleetHostSetting.allCases.map(\.rawValue))
        for perMac in ["fleetEnabled", "listenerPort", "backgroundService", "shepherdVersion", "slashCommands", "missionsEnabled"] {
            #expect(!keys.contains(perMac), "\(perMac) is about this Mac")
        }
        #expect(FleetHostSetting.named(unit: "setting:host.defaultModel") == .defaultModel)
        #expect(FleetHostSetting.named(unit: "setting:host.fleetEnabled") == nil && FleetHostSetting.named(unit: "setting:pi.theme") == nil)
    }
}

@Suite("Fleet weight units")
struct FleetWeightUnitTests {
    @Test func aWeightIsAUnitPerMacAndOnlyAWellFormedOneIsRead() {
        let id = UUID()
        let unit = FleetWeightSetting.unit(hostID: id)
        #expect(unit == "setting:fleet.weight.\(id.uuidString)" && FleetWeightSetting.hostID(unit: unit) == id)
        #expect(FleetWeightSetting.hostID(unit: "setting:fleet.weight.nope") == nil && FleetWeightSetting.hostID(unit: "setting:host.defaultModel") == nil)
        var settings = HostSettings()
        settings.fleetWeights[FleetSendWeight.settingKey(hostID: id)] = .lessOften
        settings.fleetWeights["fleet.weight.junk"] = .prefer
        #expect(FleetWeightSetting.values(in: settings) == [unit: "\"\(FleetSendWeight.lessOften.rawValue)\""])
        #expect(FleetWeightSetting.change(hostID: id, fromJSON: "\"\(FleetSendWeight.lessOften.rawValue)\"") == .fleetWeight(hostID: id, weight: .lessOften))
        #expect(FleetWeightSetting.change(hostID: id, fromJSON: "\"sideways\"") == nil)
    }
}
