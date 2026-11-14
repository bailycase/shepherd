import Foundation
import Testing
import ShepherdTestKit
import ShepherdCore
import ShepherdProtocol
@testable import ShepherdSessions

/// The sampler's math from injected counters, and readiness from fake PATH and tool facts.
@Suite("Fleet pressure and readiness")
struct FleetPressureTests {
    // MARK: Sampler

    /// A box the fake counters read, so a test moves them between the two readings.
    final class Counters: @unchecked Sendable {
        private let lock = NSLock()
        private var readings: [FleetCPUTicks]
        private(set) var cpuReads = 0
        private(set) var pauses: [Duration] = []

        init(_ readings: [FleetCPUTicks]) { self.readings = readings }

        func nextTicks() -> FleetCPUTicks? {
            lock.lock(); defer { lock.unlock() }
            cpuReads += 1
            return readings.isEmpty ? nil : readings.removeFirst()
        }

        func paused(_ duration: Duration) {
            lock.lock(); defer { lock.unlock() }
            pauses.append(duration)
        }
    }

    static func sources(_ counters: Counters, memory: FleetMemoryPages? = FleetMemoryPages(free: 1_000, inactive: 2_000, speculative: 500, pageSize: 16_384),
                        total: UInt64 = 64 << 30, cores: Int = 12, thermal: FleetThermal = .nominal,
                        power: (onBattery: Bool, percent: Int?) = (false, nil)) -> FleetPressureSources {
        FleetPressureSources(cpuTicks: { counters.nextTicks() }, memory: { memory }, totalMemoryBytes: { total }, cpuCount: { cores },
                             thermal: { thermal }, power: { power }, pause: { counters.paused($0) })
    }

    @Test func cpuUtilizationIsTheBusyShareOfTheTicksBetweenTwoReadings() async {
        // Over the window: 600 user + 200 system + 0 nice busy, 200 idle: 80% busy.
        let counters = Counters([FleetCPUTicks(user: 1_000, system: 500, idle: 8_000, nice: 0),
                                 FleetCPUTicks(user: 1_600, system: 700, idle: 8_200, nice: 0)])
        let sample = await FleetPressureSampler(sources: Self.sources(counters)).sample(activeAgents: 3)
        #expect(abs(sample.cpuUtilization - 0.8) < 1e-9)
        #expect(sample.activeAgents == 3 && sample.cpuCount == 12)
        #expect(counters.pauses == [.milliseconds(200)], "the two readings are 200 ms apart")
    }

    @Test func aSampleCarriesWhichThreadsRunCommandsAndTheKernelsMemoryPressure() async {
        var sources = Self.sources(Counters([FleetCPUTicks(user: 0, system: 0, idle: 0, nice: 0), FleetCPUTicks(user: 1, system: 0, idle: 1, nice: 0)]))
        sources.memoryPressure = { .warn }
        let sample = await FleetPressureSampler(sources: sources).sample(activeAgents: 3, commandAgents: 2)
        #expect(sample.commandAgents == 2 && sample.memoryPressure == .warn)
        // A count above the threads is cut to them; a sampler with no pressure source says normal.
        let cut = await FleetPressureSampler(sources: Self.sources(Counters([]))).sample(activeAgents: 1, commandAgents: 5)
        #expect(cut.commandAgents == 1 && cut.memoryPressure == .normal)
        #expect(await FleetPressureSampler(sources: Self.sources(Counters([]))).sample(activeAgents: 1).commandAgents == nil)
    }

    @Test func theKernelsPressureLevelReadsAsOneOfTheThreeOnThisMac() {
        // The real sysctl: whatever level this Mac is at is one of the three names, and never throws.
        #expect([FleetMemoryPressure.normal, .warn, .critical].contains(FleetPressureSampler.systemMemoryPressure()))
    }

    /// What a peer sends is kept within bounds.
    @Test func aPeersLimitsAndCommandCountAreCutToWhatIsSane() {
        var sample = FleetPressureSample(cpuUtilization: 0.5, cpuCount: 8, totalMemoryBytes: 100, availableMemoryBytes: 50, activeAgents: 2, commandAgents: 9,
                                         cpuAverage: .infinity, limits: [
            FleetProviderLimit(provider: " Anthropic ", seconds: 90_000), FleetProviderLimit(provider: "", seconds: 5),
            FleetProviderLimit(provider: "openai", seconds: -3), FleetProviderLimit(provider: "x", seconds: .nan)])
        sample = FleetPressure.sanitized(sample)
        #expect(sample.commandAgents == 2 && sample.cpuAverage == 0)
        #expect(sample.limits == [FleetProviderLimit(provider: "anthropic", seconds: FleetProviderLimits.maxHold)])
    }

    @Test func niceTimeCountsAsBusyAndAllIdleIsZero() async {
        let nice = await FleetPressureSampler(sources: Self.sources(Counters([
            FleetCPUTicks(user: 0, system: 0, idle: 0, nice: 0), FleetCPUTicks(user: 0, system: 0, idle: 50, nice: 50)]))).sample(activeAgents: 0)
        #expect(nice.cpuUtilization == 0.5)
        let idle = await FleetPressureSampler(sources: Self.sources(Counters([
            FleetCPUTicks(user: 5, system: 5, idle: 5, nice: 0), FleetCPUTicks(user: 5, system: 5, idle: 105, nice: 0)]))).sample(activeAgents: 0)
        #expect(idle.cpuUtilization == 0)
    }

    @Test func noTimePassingOrACounterGoingBackwardsReadsAsZeroNeverNonsense() {
        let a = FleetCPUTicks(user: 10, system: 10, idle: 10, nice: 0)
        #expect(FleetPressureSampler.cpuUtilization(from: a, to: a) == 0)
        #expect(FleetPressureSampler.cpuUtilization(from: a, to: FleetCPUTicks(user: 5, system: 10, idle: 90, nice: 0)) == 0)
    }

    @Test func aCounterThatCantBeReadLeavesCpuAtZero() async {
        let sample = await FleetPressureSampler(sources: Self.sources(Counters([]))).sample(activeAgents: 0)
        #expect(sample.cpuUtilization == 0)
    }

    @Test func availableMemoryIsFreePlusInactivePlusSpeculativePages() async {
        // (1000 + 2000 + 500) pages of 16 KiB.
        let sample = await FleetPressureSampler(sources: Self.sources(Counters([]))).sample(activeAgents: 0)
        #expect(sample.availableMemoryBytes == 3_500 * 16_384)
        #expect(sample.totalMemoryBytes == 64 << 30)
    }

    @Test func availableMemoryNeverExceedsTheTotalOrAppearsFromNothing() async {
        let tiny = Self.sources(Counters([]), memory: FleetMemoryPages(free: 1 << 40, inactive: 0, speculative: 0, pageSize: 16_384), total: 1 << 20)
        #expect(await FleetPressureSampler(sources: tiny).sample(activeAgents: 0).availableMemoryBytes == 1 << 20)
        let none = Self.sources(Counters([]), memory: nil)
        #expect(await FleetPressureSampler(sources: none).sample(activeAgents: 0).availableMemoryBytes == 0)
    }

    @Test func thermalPowerAndAgentCountsAreCarriedAsRead() async {
        let sources = Self.sources(Counters([]), thermal: .serious, power: (true, 41))
        let sample = await FleetPressureSampler(sources: sources).sample(activeAgents: -4, reserved: 2)
        #expect(sample.thermal == .serious && sample.onBattery && sample.batteryPercent == 41)
        #expect(sample.activeAgents == 0 && sample.reserved == 2)
    }

    @Test func theSystemSourcesReadThisMacWithoutAnySubprocess() async {
        let sample = await FleetPressureSampler().sample(activeAgents: 0)
        #expect(sample.cpuCount >= 1 && sample.totalMemoryBytes > 0)
        #expect(sample.availableMemoryBytes > 0 && sample.availableMemoryBytes <= sample.totalMemoryBytes)
        #expect((0...1).contains(sample.cpuUtilization))
    }

    // MARK: What a peer sends is bounded

    @Test func aPeersSampleIsClampedBeforeItIsKept() {
        let wild = FleetPressureSample(cpuUtilization: .nan, cpuCount: 0, totalMemoryBytes: 100, availableMemoryBytes: 900,
                                       batteryPercent: 400, activeAgents: -2, reserved: 10_000_000)
        let kept = FleetPressure.sanitized(wild)
        #expect(kept.cpuUtilization == 0 && kept.cpuCount == 1 && kept.availableMemoryBytes == 100)
        #expect(kept.batteryPercent == 100 && kept.activeAgents == 0 && kept.reserved == 100_000)
    }

    @Test func aPeersReportIsCutToSize() {
        let long = String(repeating: "x", count: 500)
        let report = FleetReadinessReport(model: long + "\nmore", chip: "M4", missing: Array(repeating: FleetMissingTool(kind: .binary, name: long), count: 80),
                                          repos: Array(repeating: long, count: 300))
        let kept = FleetPressure.sanitized(report)
        #expect(kept.model.count == 100 && !kept.model.contains("\n"))
        #expect(kept.missing.count == 50 && kept.missing[0].name.count == 100)
        #expect(kept.repos.count == 200)
    }

    // MARK: Readiness

    private func report(commands: [String] = [], needsXcode: Bool = false, spaces: [(name: String, path: String)] = [],
                        probe: FleetProbeResult = FleetProbeResult()) async -> FleetReadinessReport {
        await FleetReadiness.report(commands: commands, needsXcode: needsXcode, spaces: spaces,
                                    probe: { asked in
                                        // The fake PATH: only what the test marked missing is missing.
                                        FleetProbeResult(missingCommands: probe.missingCommands.intersection(asked), noGit: probe.noGit, noXcode: probe.noXcode)
                                    },
                                    hardware: { ("Mac mini", "M4 Pro") })
    }

    @Test func aMacWithNothingMissingIsReadyForEverything() async {
        let report = await report(commands: ["npx", "uvx"])
        #expect(report.missing.isEmpty)
        #expect(report.model == "Mac mini" && report.chip == "M4 Pro")
    }

    @Test func aCommandThatDoesntResolveIsReportedByName() async {
        let report = await report(commands: ["npx", "muse"], probe: FleetProbeResult(missingCommands: ["muse"]))
        #expect(report.missing == [FleetMissingTool(kind: .binary, name: "muse")])
    }

    @Test func aCommandGivenAsAPathIsCheckedOnDiskNotAskedOfTheShell() async throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let there = dir.appendingPathComponent("tool")
        try Data("#!/bin/sh\n".utf8).write(to: there)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: there.path)
        let asked = Locked<[String]>([])
        let report = await FleetReadiness.report(commands: [there.path, dir.appendingPathComponent("gone").path], needsXcode: false, spaces: [],
                                                 probe: { commands in asked.withValue { $0 = commands }; return FleetProbeResult() },
                                                 hardware: { ("Mac", "") })
        #expect(report.missing == [FleetMissingTool(kind: .binary, name: "gone")])
        #expect(asked.current.isEmpty)
    }

    @Test func aNameWithShellSyntaxIsNeverHandedToTheShell() async {
        let asked = Locked<[String]>([])
        _ = await FleetReadiness.report(commands: ["ok-tool", "a; rm -rf ~", "$(whoami)", "a b"], needsXcode: false, spaces: [],
                                        probe: { commands in asked.withValue { $0 = commands }; return FleetProbeResult() }, hardware: { ("Mac", "") })
        #expect(asked.current == ["ok-tool"])
    }

    @Test func gitIsReportedMissingAndXcodeOnlyWhereAProjectNeedsIt() async {
        let without = await report(needsXcode: false, probe: FleetProbeResult(noGit: true, noXcode: true))
        #expect(without.missing == [FleetMissingTool(kind: .git)], "a Mac with no Xcode isn't told so unless a project needs it")
        #expect(without.noXcode, "but it says so as a fact, for a dispatch of a repository that does")
        let with = await report(needsXcode: true, probe: FleetProbeResult(noGit: false, noXcode: true))
        #expect(with.missing == [FleetMissingTool(kind: .xcode)] && with.noXcode)
        #expect(await !report(needsXcode: true, probe: FleetProbeResult()).noXcode)
    }

    @Test func theProjectsAreListedOnceEachSorted() async {
        let report = await report(spaces: [("payments-api", "/a"), ("acme-web", "/b"), ("payments-api", "/c"), ("", "/d")])
        #expect(report.repos == ["acme-web", "payments-api"])
    }

    @Test func mcpCommandsAreTheLocalServersCommandsOnceEachSorted() {
        let json = """
        {"mcpServers": {
          "a": {"command": "npx", "args": ["-y", "pkg"]},
          "b": {"command": "muse"},
          "c": {"command": "npx"},
          "remote": {"url": "https://example.com/mcp"},
          "off": {"command": "never", "shepherd": {"enabled": false}},
          "on": {"command": "uvx", "shepherd": {"enabled": true}}
        }}
        """
        #expect(FleetReadiness.mcpCommands(in: Data(json.utf8)) == ["muse", "npx", "uvx"])
        #expect(FleetReadiness.mcpCommands(in: Data("not json".utf8)) == [])
        #expect(FleetReadiness.mcpCommands(in: Data("{}".utf8)) == [])
    }

    @Test func aProjectWithAnXcodeProjectAtItsTopNeedsXcode() throws {
        let dir = try makeTempDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let app = dir.appendingPathComponent("acme-ios")
        try FileManager.default.createDirectory(at: app.appendingPathComponent("Acme.xcodeproj"), withIntermediateDirectories: true)
        let web = dir.appendingPathComponent("acme-web")
        try FileManager.default.createDirectory(at: web, withIntermediateDirectories: true)
        #expect(FleetReadiness.needsXcode(spaces: [("acme-ios", app.path)]))
        #expect(!FleetReadiness.needsXcode(spaces: [("acme-web", web.path), ("gone", dir.appendingPathComponent("gone").path)]))
    }

    @Test func theModelComesFromTheIdentifierWhenItNamesOneAndTheChipDropsApple() {
        #expect(FleetReadiness.modelName(identifier: "MacBookPro18,3") == "MacBook Pro")
        #expect(FleetReadiness.modelName(identifier: "Macmini9,1") == "Mac mini")
        #expect(FleetReadiness.modelName(identifier: "Mac16,5") == "Mac")
        #expect(FleetReadiness.chipName(brand: "Apple M4 Max") == "M4 Max")
        #expect(FleetReadiness.chipName(brand: "Intel(R) Core(TM) i9") == "Intel(R) Core(TM) i9")
    }

    @Test func aRecheckHappensOnlyWhenWhatTheReportIsMadeOfChanges() {
        let base = FleetReadiness.key(commands: ["npx"], repos: ["acme-web"])
        #expect(base == FleetReadiness.key(commands: ["npx"], repos: ["acme-web"]))
        #expect(base != FleetReadiness.key(commands: ["npx", "muse"], repos: ["acme-web"]))
        #expect(base != FleetReadiness.key(commands: ["npx"], repos: []))
        #expect(FleetReadiness.key(commands: ["a"], repos: []) != FleetReadiness.key(commands: [], repos: ["a"]), "a command is not a project")
    }
}
