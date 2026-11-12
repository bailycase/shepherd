import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The pressure and readiness half of a fleet (`fleet.pressure.v1`): this Mac's samples, the last
/// sample and readiness report each paired Mac pushed, and the timer that takes them.
///
/// Samples are taken every `interval` only while somebody wants them: a link to a peer is up (the
/// peer will be sent them) or a viewing client (the Fleet page) said it is watching. An idle
/// host never samples. A received sample is stamped with the arrival time on this Mac's clock;
/// the sender's clock never matters.
///
/// Every property belongs to the server queue, like the rest of the fleet.
final class FleetPressure: @unchecked Sendable {
    struct Peer {
        var sample: FleetPressureSample?
        var receivedAt: Date?
        var readiness: FleetReadinessReport?
    }

    /// Sampling period.
    static let defaultInterval: TimeInterval = 5
    /// A readiness report is made again after this long even if nothing it is made of changed.
    static let readinessLifetime: TimeInterval = 24 * 60 * 60
    /// A burst of changes reaches the app as one.
    static let notifyDelay: TimeInterval = 0.3
    /// What a peer's report is cut to.
    static let reportLimits = (repos: 200, missing: 50, text: 100)

    private let queue: DispatchQueue
    private let clock: @Sendable () -> Date
    private let sampler: FleetPressureSampler
    private let localFacts: @Sendable () -> FleetLocalFacts
    private let probe: FleetReadiness.Probe
    private let hardware: FleetReadiness.Hardware
    private let interval: TimeInterval

    /// A link to a peer is connected.
    var linkConnected: () -> Bool = { false }
    /// The links to push to: each peer's client, connected.
    var pushTargets: () -> [RemoteHostClient] = { [] }
    /// The Fleet page should read again (coalesced; only while a client watches).
    var onChange: (() -> Void)?

    private(set) var local: (sample: FleetPressureSample, at: Date)?
    private(set) var localReadiness: FleetReadinessReport?
    private var readinessKey: String?
    private var readinessAt: Date?
    private var peers: [UUID: Peer] = [:]
    private var watchers: Set<Int32> = []
    private var timer: DispatchSourceTimer?
    private var taking = false
    private var makingReport = false
    private var notifying = false
    private var stopped = false

    init(queue: DispatchQueue, clock: @escaping @Sendable () -> Date, sampler: FleetPressureSampler = FleetPressureSampler(),
         localFacts: @escaping @Sendable () -> FleetLocalFacts = { FleetLocalFacts() },
         probe: @escaping FleetReadiness.Probe = FleetReadiness.systemProbe,
         hardware: @escaping FleetReadiness.Hardware = FleetReadiness.systemHardware,
         interval: TimeInterval = FleetPressure.defaultInterval) {
        self.queue = queue
        self.clock = clock
        self.sampler = sampler
        self.localFacts = localFacts
        self.probe = probe
        self.hardware = hardware
        self.interval = interval
    }

    // MARK: Subscribers

    /// Sampling runs: a link is up or a client watches.
    var isSampling: Bool { timer != nil }

    var isWatched: Bool { !watchers.isEmpty }

    /// `connection` is watching the Fleet page (or stopped).
    func watch(_ on: Bool, connection: Int32) {
        if on { watchers.insert(connection) } else { watchers.remove(connection) }
        refresh()
    }

    func connectionClosed(_ connection: Int32) {
        if watchers.remove(connection) != nil { refresh() }
    }

    /// The links changed: start or stop the timer to match who wants samples.
    func refresh() {
        let wanted = !stopped && (!watchers.isEmpty || linkConnected())
        if wanted, timer == nil {
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: interval, leeway: .milliseconds(100))
            timer.setEventHandler { [weak self] in self?.tick() }
            self.timer = timer
            timer.resume()
        } else if !wanted, let running = timer {
            running.cancel()
            timer = nil
        }
    }

    /// Fleet was switched off: no Mac is sampled for, and the Fleet page isn't shown.
    func reset() {
        watchers = []
        peers = [:]
        refresh()
    }

    func stop() {
        stopped = true
        watchers = []
        timer?.cancel()
        timer = nil
    }

    // MARK: Taking samples

    /// Takes a sample, keeps it and pushes it to the peers; then, if what the readiness report is
    /// made of changed, makes a report apart from it (the login shell can take a while, and the
    /// samples must not wait for it). A tick that finds the last one still running does nothing.
    func tick() {
        guard !stopped, !taking else { return }
        taking = true
        let facts = localFacts()
        Task { [weak self, sampler] in
            let sample = await sampler.sample(activeAgents: facts.activeAgents)
            self?.queue.async { self?.took(sample, facts: facts) }
        }
    }

    private func took(_ sample: FleetPressureSample, facts: FleetLocalFacts) {
        taking = false
        guard !stopped else { return }
        local = (sample, clock())
        for client in pushTargets() where client.capabilities.contains(RemoteProtocol.fleetPressureCapability) {
            Task { try? await client.fleetPressure(sample) }
        }
        remakeReadiness(facts)
        notify()
    }

    /// Makes the readiness report again when its inputs changed (pi's MCP commands, the projects)
    /// and daily, and pushes it to the peers.
    private func remakeReadiness(_ facts: FleetLocalFacts) {
        guard !makingReport else { return }
        makingReport = true
        let known = (key: readinessKey, at: readinessAt)
        let now = clock()
        Task { [weak self, probe, hardware] in
            let commands = facts.mcpConfig.flatMap { try? Data(contentsOf: $0) }.map(FleetReadiness.mcpCommands(in:)) ?? []
            let repos = Set(facts.spaces.map(\.name)).sorted()
            let key = FleetReadiness.key(commands: commands, repos: repos)
            var report: FleetReadinessReport?
            if key != known.key || known.at.map({ now.timeIntervalSince($0) > Self.readinessLifetime }) != false {
                report = await FleetReadiness.report(commands: commands, needsXcode: FleetReadiness.needsXcode(spaces: facts.spaces),
                                                     spaces: facts.spaces, probe: probe, hardware: hardware)
            }
            self?.queue.async { self?.remade(report, key: key) }
        }
    }

    private func remade(_ report: FleetReadinessReport?, key: String) {
        makingReport = false
        guard !stopped, let report else { return }
        localReadiness = report
        readinessKey = key
        readinessAt = clock()
        for client in pushTargets() where client.capabilities.contains(RemoteProtocol.fleetPressureCapability) {
            Task { try? await client.fleetReadiness(report) }
        }
        notify()
    }

    /// A sample of this Mac now, for a peer that asked (`fleetPressureNow`).
    func sampleNow() async -> (FleetPressureSample, FleetReadinessReport?) {
        let facts = localFacts()
        let sample = await sampler.sample(activeAgents: facts.activeAgents)
        return await withCheckedContinuation { continuation in
            queue.async {
                self.local = (sample, self.clock())
                continuation.resume(returning: (sample, self.localReadiness))
            }
        }
    }

    /// A link to a peer came up: it gets what this Mac has now rather than waiting for the next tick.
    func greet(_ client: RemoteHostClient) {
        guard client.capabilities.contains(RemoteProtocol.fleetPressureCapability) else { return }
        let sample = local?.sample
        let report = localReadiness
        Task {
            if let report { try? await client.fleetReadiness(report) }
            if let sample { try? await client.fleetPressure(sample) }
        }
    }

    // MARK: Receiving

    func received(_ sample: FleetPressureSample, from hostID: UUID) {
        var peer = peers[hostID] ?? Peer()
        peer.sample = Self.sanitized(sample)
        peer.receivedAt = clock()
        peers[hostID] = peer
        notify()
    }

    func received(_ report: FleetReadinessReport, from hostID: UUID) {
        var peer = peers[hostID] ?? Peer()
        peer.readiness = Self.sanitized(report)
        peers[hostID] = peer
        notify()
    }

    /// A Mac was removed from the fleet.
    func forget(_ hostID: UUID) { peers[hostID] = nil }

    /// What a peer sends is kept within bounds: its own numbers, never trusted to be sane.
    static func sanitized(_ sample: FleetPressureSample) -> FleetPressureSample {
        var sample = sample
        sample.cpuUtilization = sample.cpuUtilization.isFinite ? min(1, max(0, sample.cpuUtilization)) : 0
        sample.cpuCount = min(1024, max(1, sample.cpuCount))
        sample.availableMemoryBytes = min(sample.availableMemoryBytes, sample.totalMemoryBytes)
        sample.batteryPercent = sample.batteryPercent.map { min(100, max(0, $0)) }
        sample.activeAgents = min(100_000, max(0, sample.activeAgents))
        sample.reserved = min(100_000, max(0, sample.reserved))
        return sample
    }

    static func sanitized(_ report: FleetReadinessReport) -> FleetReadinessReport {
        func line(_ text: String) -> String { String(text.filter { !$0.isNewline }.prefix(reportLimits.text)) }
        return FleetReadinessReport(
            model: line(report.model), chip: line(report.chip),
            missing: report.missing.prefix(reportLimits.missing).map { FleetMissingTool(kind: $0.kind, name: line($0.name)) },
            repos: report.repos.prefix(reportLimits.repos).map(line))
    }

    // MARK: Reading

    /// This Mac and each of `peerIDs` with what is known of them, ages by this host's clock.
    func macs(thisMac: UUID, peerIDs: [UUID]) -> [FleetMacState] {
        let now = clock()
        var macs: [FleetMacState] = []
        if local != nil || localReadiness != nil {
            macs.append(FleetMacState(hostID: thisMac, sample: local?.sample, sampleAge: local.map { max(0, now.timeIntervalSince($0.at)) },
                                      readiness: localReadiness))
        }
        for id in peerIDs {
            guard let peer = peers[id], peer.sample != nil || peer.readiness != nil else { continue }
            macs.append(FleetMacState(hostID: id, sample: peer.sample, sampleAge: peer.receivedAt.map { now.timeIntervalSince($0) },
                                      readiness: peer.readiness))
        }
        return macs
    }

    // MARK: Telling the app

    /// The app reads again shortly, once for a burst; nothing while no client watches.
    private func notify() {
        guard !watchers.isEmpty, !notifying else { return }
        notifying = true
        queue.asyncAfter(deadline: .now() + Self.notifyDelay) { [weak self] in
            guard let self else { return }
            self.notifying = false
            if !self.watchers.isEmpty { self.onChange?() }
        }
    }
}
