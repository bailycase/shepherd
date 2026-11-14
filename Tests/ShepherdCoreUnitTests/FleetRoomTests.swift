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

    // MARK: Heavy work, smoothing, memory pressure

    static func sample(agents: Int, commands: Int?, cpu: Double = 0, average: Double? = nil, pressure: FleetMemoryPressure? = nil) -> FleetPressureSample {
        var sample = Self.sample(cpu: cpu, agents: agents)
        sample.commandAgents = commands
        sample.cpuAverage = average
        sample.memoryPressure = pressure
        return sample
    }

    @Test func aThreadRunningACommandWeighsThreeAndAThreadWaitingOnTheModelOne() {
        #expect(FleetRoom.commandWeight == 3 && FleetRoom.modelWaitWeight == 1)
        // 2 running commands + 1 waiting = 2 * 3 + 1 = 7, so the score is the idle one over 1 + 7.
        let idle = FleetRoom.score(Self.sample())
        #expect(FleetRoom.load(Self.sample(agents: 3, commands: 2)) == 7)
        #expect(FleetRoom.score(Self.sample(agents: 3, commands: 2)) == idle / 8)
        #expect(FleetRoom.score(Self.sample(agents: 3, commands: 0)) == idle / 4)
    }

    @Test func aMacBusyBuildingHasLessRoomThanOneWithTheSameThreadsWaitingOnTheModel() {
        let building = FleetRoom.score(Self.sample(agents: 3, commands: 3))
        let waiting = FleetRoom.score(Self.sample(agents: 3, commands: 0))
        #expect(building < waiting && waiting == building * 10 / 4)
    }

    @Test func aMacThatDoesntSayWhichThreadsRunCommandsWeighsAllOfThemAsWaiting() {
        #expect(FleetRoom.load(Self.sample(agents: 3, commands: nil)) == 3)
        #expect(FleetRoom.score(Self.sample(agents: 3, commands: nil)) == FleetRoom.score(Self.sample(agents: 3)), "what an older build scored")
    }

    @Test func aPromisedPlaceWeighsAsAThreadWaitingOnTheModelAndCommandsNeverExceedTheThreads() {
        #expect(FleetRoom.load(Self.sample(cpu: 0, agents: 1, reserved: 2)) == 3)
        #expect(FleetRoom.load(Self.sample(agents: 2, commands: 9)) == 6, "a count that is higher than the threads is cut to them")
    }

    @Test func theScoreAndTheCeilingUseTheAverageWhenThereIsOneAndTheReadingWhenThereIsNot() {
        // A build spiked this reading to 99%, but the minute was 20%.
        let spiked = Self.sample(agents: 0, commands: nil, cpu: 0.99, average: 0.2)
        #expect(FleetRoom.skip(spiked, age: 1) == nil)
        #expect(abs(FleetRoom.score(spiked) - FleetRoom.score(Self.sample(cpu: 0.2))) < 1e-12)
        // The same reading from an older build, which sends no average, is the whole story.
        #expect(FleetRoom.skip(Self.sample(agents: 0, commands: nil, cpu: 0.99), age: 1) == .cpu)
        // A minute at the ceiling leaves the Mac out whatever the last reading was.
        #expect(FleetRoom.skip(Self.sample(agents: 0, commands: nil, cpu: 0.1, average: 0.96), age: 1) == .cpu)
    }

    @Test func theCpuAverageIsTheMeanOfTheLastMinuteOfReadings() {
        var average = FleetCPUAverage()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(average.add(0.9, at: start) == 0.9, "one reading is its own average")
        #expect(abs(average.add(0.3, at: start.addingTimeInterval(5)) - 0.6) < 1e-12)
        #expect(abs(average.add(0.0, at: start.addingTimeInterval(10)) - 0.4) < 1e-12)
        // At 65 s the first reading (65 s old) is out of the window; the second (60 s old) is too; the window is 60 s.
        let later = average.add(0.6, at: start.addingTimeInterval(65))
        #expect(abs(later - 0.3) < 1e-12 && average.count == 2, "0.0 and 0.6 remain")
        #expect(average.add(2, at: start.addingTimeInterval(70)) > 0 && FleetCPUAverage().window == FleetRoom.cpuWindow)
    }

    @Test func aReadingThatIsNotANumberCountsAsZero() {
        var average = FleetCPUAverage()
        #expect(average.add(.nan, at: Date(timeIntervalSince1970: 1)) == 0)
    }

    @Test(arguments: [(FleetMemoryPressure.normal, false), (.warn, true), (.critical, true)])
    func aMacUnderMemoryPressureIsLeftOutWhateverItsFreeMemory(pressure: FleetMemoryPressure, skipped: Bool) {
        // Plenty free by the counters: 48 of 64 GiB.
        let sample = Self.sample(agents: 0, commands: nil, pressure: pressure)
        #expect((FleetRoom.skip(sample, age: 1) == .memoryPressure) == skipped)
    }

    @Test func aMacThatSaysNothingOfMemoryPressureIsNormalAndTheKernelsLevelsMapToTheThreeNames() {
        #expect(FleetRoom.skip(Self.sample(), age: 1) == nil)
        #expect([1, 2, 4, 0, 3, 99].map(FleetMemoryPressure.init(kernelLevel:)) == [.normal, .warn, .critical, .normal, .normal, .normal])
        #expect(FleetMemoryPressure.normal < .warn && FleetMemoryPressure.warn < .critical)
    }

    @Test func freeMemoryStillLeavesAMacOutWhenPressureIsNormal() {
        #expect(FleetRoom.skip(Self.sample(free: 3, total: 64), age: 1) == .memory)
    }

    // MARK: Provider limits' words

    @Test(arguments: [
        ("429 rate_limit_error. Retry-After: 30", 30.0), ("Please retry after 45 seconds", 45), ("Rate limited, try again in 1m 40s", 100),
        ("try again in 2 minutes", 120), ("retry in 8s", 8), (#"{"retryDelay": "20s"}"#, 20), ("retry-after: 1 minute and 5 seconds", 65),
        ("try again in 1.5 seconds", 1.5), ("resets in 1h", 3600), ("retry after 500ms", 0.5),
    ])
    func anErrorsRetryTimeIsRead(text: String, seconds: Double) {
        #expect(FleetProviderLimits.retryAfter(in: text) == seconds)
    }

    @Test func anErrorThatNamesNoTimeHasNoRetryTimeAndTheHoldFallsBackToTheDefaultWithinBounds() {
        #expect(FleetProviderLimits.retryAfter(in: "529 overloaded_error: Overloaded") == nil)
        #expect(FleetProviderLimits.retryAfter(in: "retry after the weekend") == nil)
        #expect(FleetProviderLimits.hold(retryAfter: nil) == FleetProviderLimits.defaultHold)
        #expect(FleetProviderLimits.hold(retryAfter: 0) == FleetProviderLimits.minHold)
        #expect(FleetProviderLimits.hold(retryAfter: 90) == 90)
        #expect(FleetProviderLimits.hold(retryAfter: 86_400) == FleetProviderLimits.maxHold)
        #expect(FleetProviderLimits.hold(retryAfter: .infinity) == FleetProviderLimits.defaultHold)
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
