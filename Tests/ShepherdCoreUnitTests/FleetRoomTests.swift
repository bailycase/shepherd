import Foundation
import Testing
import ShepherdCore

/// The room score and the rules that leave a Mac out (Fleet ▸ Pressure, readiness, placement).
@Suite("Fleet room")
struct FleetRoomTests {
    static let gib: UInt64 = 1 << 30

    /// An idle 12 core Mac with 64 GiB, 48 of them free, plugged in.
    static func sample(cpu: Double = 0, cores: Int = 12, free: UInt64 = 48, total: UInt64 = 64, agents: Int = 0, reserved: Int = 0,
                       battery: Bool = false, thermal: FleetThermal = .nominal) -> FleetPressureSample {
        FleetPressureSample(cpuUtilization: cpu, cpuCount: cores, totalMemoryBytes: total * gib, availableMemoryBytes: free * gib,
                            thermal: thermal, onBattery: battery, batteryPercent: battery ? 41 : nil, activeAgents: agents, reserved: reserved)
    }

    // MARK: Score

    @Test func theScoreIsWeightTimesCoresTimesFreeCpuTimesFreeMemoryOverBusyness() {
        // 1.5 * 12 * (1 - 0.25) * (48 / 64) / (1 + 2 + 1) = 2.53125
        let score = FleetRoom.score(Self.sample(cpu: 0.25, agents: 2, reserved: 1), weight: .prefer)
        #expect(abs(score - 2.53125) < 1e-9)
    }

    @Test func eachWeightScalesTheScoreAndManualOnlyIsNeverPicked() {
        let sample = Self.sample()
        let normal = FleetRoom.score(sample, weight: .normal)
        #expect(FleetRoom.score(sample, weight: .prefer) == normal * 1.5)
        #expect(FleetRoom.score(sample, weight: .lessOften) == normal * 0.5)
        #expect(FleetRoom.score(sample, weight: .manualOnly) == 0)
        #expect(FleetSendWeight.manualOnly.multiplier == nil)
    }

    @Test func batteryHalvesTheScoreOnlyWhileTheFleetCountsIt() {
        let plugged = FleetRoom.score(Self.sample())
        let onBattery = Self.sample(battery: true)
        #expect(FleetRoom.score(onBattery) == plugged * 0.5)
        #expect(FleetRoom.score(onBattery, batteryCountsHalf: false) == plugged)
    }

    @Test func moreRunningThreadsAndReservationsMeanLessRoom() {
        let idle = FleetRoom.score(Self.sample())
        let busy = FleetRoom.score(Self.sample(agents: 3))
        let reserved = FleetRoom.score(Self.sample(reserved: 3))
        #expect(busy == idle / 4 && reserved == busy)
    }

    @Test func nonsenseInputNeverScoresBelowZeroOrAboveWhatIdleGets() {
        #expect(FleetRoom.score(Self.sample(cpu: 1.4)) == 0)
        #expect(FleetRoom.score(Self.sample(cpu: -3)) == FleetRoom.score(Self.sample(cpu: 0)))
        #expect(FleetRoom.score(FleetPressureSample(cpuUtilization: 0, cpuCount: 8, totalMemoryBytes: 0, availableMemoryBytes: 0)) == 0)
    }

    // MARK: Skips

    @Test func aSampleOlderThanFifteenSecondsIsStale() {
        let sample = Self.sample()
        #expect(FleetRoom.skip(sample, age: 15) == nil)
        #expect(FleetRoom.skip(sample, age: 15.001) == .stale)
        #expect(FleetRoom.skip(sample, age: 0) == nil)
    }

    @Test func aSampleStampedMoreThanFiveSecondsAheadIsRefused() {
        #expect(FleetRoom.skip(Self.sample(), age: -5) == nil)
        #expect(FleetRoom.skip(Self.sample(), age: -5.5) == .future)
    }

    @Test func aMacAtNinetyFivePercentCpuIsLeftOut() {
        #expect(FleetRoom.skip(Self.sample(cpu: 0.949), age: 1) == nil)
        #expect(FleetRoom.skip(Self.sample(cpu: 0.95), age: 1) == .cpu)
    }

    @Test func aMacWithFivePercentMemoryLeftIsLeftOut() {
        #expect(FleetRoom.skip(Self.sample(free: 4, total: 64), age: 1) == nil)   // 6.25%
        #expect(FleetRoom.skip(Self.sample(free: 3, total: 64), age: 1) == .memory) // 4.7%
        let exactlyFive = FleetPressureSample(cpuUtilization: 0, cpuCount: 8, totalMemoryBytes: 100, availableMemoryBytes: 5)
        #expect(FleetRoom.skip(exactlyFive, age: 1) == .memory)
    }

    @Test(arguments: [(FleetThermal.nominal, false), (.fair, false), (.serious, true), (.critical, true)])
    func aSeriousOrCriticalMacIsLeftOut(thermal: FleetThermal, skipped: Bool) {
        #expect((FleetRoom.skip(Self.sample(thermal: thermal), age: 1) == .thermal) == skipped)
    }

    @Test func manualOnlyIsLeftOutWhateverTheSampleSays() {
        #expect(FleetRoom.skip(Self.sample(), age: 1, weight: .manualOnly) == .manualOnly)
        #expect(FleetRoom.skip(Self.sample(), age: 1, weight: .lessOften) == nil)
    }

    // MARK: Where the next work goes

    private let here = UUID(), mini = UUID(), studio = UUID()

    @Test func theBestMacWinsWhenItClearsTheMarginOverThisOne() {
        let winner = FleetRoom.nextGoesTo([.init(id: here, score: 1), .init(id: mini, score: 1.5), .init(id: studio, score: 1.2)], local: here)
        #expect(winner == mini, "1.5 times this Mac's score is enough")
    }

    @Test func workStaysHereBelowTheMarginSoSimilarMacsDontFlap() {
        let winner = FleetRoom.nextGoesTo([.init(id: here, score: 1), .init(id: mini, score: 1.49)], local: here)
        #expect(winner == here)
    }

    @Test func theMarginDoesNotApplyWhenThisMacDoesntCount() {
        // Skipped Macs score 0, so this one is out and any other Mac, however little better, takes it.
        let winner = FleetRoom.nextGoesTo([.init(id: here, score: 0), .init(id: mini, score: 0.1)], local: here)
        #expect(winner == mini)
    }

    @Test func noMacCountingMeansNoWinner() {
        #expect(FleetRoom.nextGoesTo([.init(id: here, score: 0), .init(id: mini, score: 0)], local: here) == nil)
        #expect(FleetRoom.nextGoesTo([], local: here) == nil)
    }

    @Test func tiesKeepThisMacThenTheFirstListed() {
        #expect(FleetRoom.nextGoesTo([.init(id: mini, score: 2), .init(id: here, score: 2)], local: here) == here)
        #expect(FleetRoom.nextGoesTo([.init(id: mini, score: 2), .init(id: studio, score: 2)], local: here) == mini)
    }

    @Test func aWeightHasItsOwnSettingKey() {
        let id = UUID()
        #expect(FleetSendWeight.settingKey(hostID: id) == "fleet.weight.\(id.uuidString)")
    }
}
