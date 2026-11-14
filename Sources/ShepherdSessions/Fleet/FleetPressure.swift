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
        var check: FleetCheckReport?
        var checkAt: Date?
    }

    /// Sampling period.
    static let defaultInterval: TimeInterval = 5
    /// A readiness report is made again after this long even if nothing it is made of changed.
    static let readinessLifetime: TimeInterval = 24 * 60 * 60
    /// While a report lists a missing tool, it is looked at again this often: installing the tool changes nothing the report is keyed by.
    static let missingRecheckInterval: TimeInterval = 60
    /// Check (`FleetCheck`) is made again after this long even if nothing it is made of changed.
    static let checkLifetime: TimeInterval = 24 * 60 * 60
    /// Check now waits this long for the Macs' answers: each does its login shell, remotes and providers at once, each bounded.
    static let checkNowTimeout: TimeInterval = 50
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
    /// Where Check reads its facts; nil is a host that makes no Check report (tests that don't look at it).
    private let checkSources: FleetCheck.Sources?

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
    /// What this Mac found when it looked at itself for Check, and when, and what it was made from (`checkKey`).
    private(set) var localCheck: (report: FleetCheckReport, at: Date)?
    private var checkKey: String?
    private var checkRunning = false
    /// Who asked for a run and is waiting for it: the ones of the run going, and the ones that asked after it began (they get the next).
    private var checkServing: [@Sendable (FleetCheckReport?) -> Void] = []
    private var checkWaiting: [@Sendable (FleetCheckReport?) -> Void] = []
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
         interval: TimeInterval = FleetPressure.defaultInterval, check: FleetCheck.Sources? = nil) {
        self.checkSources = check
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
            let sample = await sampler.sample(activeAgents: facts.activeAgents, reserved: facts.reserved)
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
        checkIfDue(facts)
        notify()
    }

    /// Makes the readiness report again when its inputs changed (pi's MCP commands, the projects), daily, and
    /// every `missingRecheckInterval` while it lists a missing tool, and pushes it to the peers when it differs.
    /// What the readiness report is made of may have changed (the repositories this Mac can bind): it is made again now, and pushed if it did.
    func factsChanged() {
        guard !stopped else { return }
        let facts = localFacts()
        remakeReadiness(facts)
        checkIfDue(facts)
    }

    private func remakeReadiness(_ facts: FleetLocalFacts) {
        guard !makingReport else { return }
        makingReport = true
        let now = clock()
        let recheck = (localReadiness?.missing.isEmpty == false) && readinessAt.map { now.timeIntervalSince($0) >= Self.missingRecheckInterval } == true
        let known = (key: readinessKey, at: readinessAt)
        Task { [weak self] in
            let made = await self?.makeReadiness(facts, known: known, now: now, force: recheck)
            self?.queue.async { self?.remade(made?.report, key: made?.key ?? "") }
        }
    }

    /// The report for `facts`: nil while the last one still stands (nothing it is made of changed, it is not a day old and `force` is off).
    private func makeReadiness(_ facts: FleetLocalFacts, known: (key: String?, at: Date?), now: Date, force: Bool) async -> (report: FleetReadinessReport?, key: String) {
        let commands = facts.mcpConfig.flatMap { try? Data(contentsOf: $0) }.map(FleetReadiness.mcpCommands(in:)) ?? []
        let repos = Set(facts.spaces.map(\.name)).sorted()
        let key = FleetReadiness.key(commands: commands, repos: repos, repoKeys: facts.repoKeys)
        guard force || key != known.key || known.at.map({ now.timeIntervalSince($0) > Self.readinessLifetime }) != false else { return (nil, key) }
        return (await FleetReadiness.report(commands: commands, needsXcode: FleetReadiness.needsXcode(spaces: facts.spaces),
                                            spaces: facts.spaces, repoKeys: facts.repoKeys, probe: probe, hardware: hardware), key)
    }

    private func remade(_ report: FleetReadinessReport?, key: String) {
        makingReport = false
        apply(report, key: key)
    }

    /// Keeps a report; the peers hear of it, and the Fleet page reads again, only when it differs from the one held.
    private func apply(_ report: FleetReadinessReport?, key: String) {
        guard !stopped, let report else { return }
        let changed = report != localReadiness
        localReadiness = report
        readinessKey = key
        readinessAt = clock()
        guard changed else { return }
        for client in pushTargets() where client.capabilities.contains(RemoteProtocol.fleetPressureCapability) {
            Task { try? await client.fleetReadiness(report) }
        }
        notify()
    }

    // MARK: Check

    /// What Check is made from, cheap to make (pi's MCP file is read, nothing else): the same key is the same report.
    static func checkKey(_ facts: FleetLocalFacts) -> String {
        let servers = facts.mcpConfig.flatMap { try? Data(contentsOf: $0) }.map(FleetReadiness.mcpServers(in:)) ?? []
        let spaces = facts.spaces.map { "\($0.name)\u{1}\($0.path)" }.sorted()
        let commands = servers.map { "\($0.command)\u{1}\($0.servers.joined(separator: ","))" }
        return (spaces + ["\u{2}"] + commands + ["\u{3}", facts.build ?? ""]).joined(separator: "\u{4}")
    }

    /// Looks at this Mac when it has never, when a space or an MCP server changed since, and every day.
    private func checkIfDue(_ facts: FleetLocalFacts) {
        guard checkSources != nil, !stopped, !checkRunning else { return }
        if let local = localCheck, Self.checkKey(facts) == checkKey, clock().timeIntervalSince(local.at) <= Self.checkLifetime { return }
        startCheck(nil)
    }

    /// Looks at this Mac again now (Check now, a fix that ended) and answers what it found; nil when this host makes no Check. A look
    /// that is under way when this is asked doesn't answer it: the answer is of a look that began after.
    func checkNow() async -> FleetCheckReport? {
        await withCheckedContinuation { continuation in
            queue.async {
                guard self.checkSources != nil, !self.stopped else { return continuation.resume(returning: nil) }
                self.startCheck { continuation.resume(returning: $0) }
            }
        }
    }

    private func startCheck(_ waiter: (@Sendable (FleetCheckReport?) -> Void)?) {
        if let waiter { checkWaiting.append(waiter) }
        guard let sources = checkSources, !checkRunning, !stopped else { return }
        checkRunning = true
        checkServing = checkWaiting
        checkWaiting = []
        let facts = localFacts()
        let key = Self.checkKey(facts)
        Task { [weak self] in
            let report = await FleetCheck.report(facts: facts, sources: sources)
            self?.queue.async { self?.checked(report, key: key) }
        }
    }

    /// Keeps a report, tells whoever asked for it, and pushes it to the peers that take it: they stamp its arrival, so every look is news.
    private func checked(_ report: FleetCheckReport, key: String) {
        checkRunning = false
        let serving = checkServing
        checkServing = []
        guard !stopped else {
            for waiter in serving + checkWaiting { waiter(nil) }
            checkWaiting = []
            return
        }
        localCheck = (report, clock())
        checkKey = key
        for waiter in serving { waiter(report) }
        for client in pushTargets() where client.capabilities.contains(RemoteProtocol.fleetCheckCapability) {
            Task { try? await client.fleetCheck(report) }
        }
        notify()
        if !checkWaiting.isEmpty { startCheck(nil) }
    }

    /// A peer's report (`fleetCheck`, or its answer to `fleetCheckNow`): kept within bounds, stamped by this Mac's clock.
    func receivedCheck(_ report: FleetCheckReport, from hostID: UUID) {
        var peer = peers[hostID] ?? Peer()
        peer.check = report.sanitized()
        peer.checkAt = clock()
        peers[hostID] = peer
        notify()
    }

    /// A sample of this Mac now, for a peer that asked (`fleetPressureNow`). A report that lists a missing tool is looked at again
    /// first: a placement is about to rely on it, and installing the tool changes nothing it is keyed by.
    func sampleNow() async -> (FleetPressureSample, FleetReadinessReport?) {
        let facts = localFacts()
        let sample = await sampler.sample(activeAgents: facts.activeAgents, reserved: facts.reserved)
        let known: (key: String?, at: Date?, lacking: Bool) = await withCheckedContinuation { continuation in
            queue.async {
                self.local = (sample, self.clock())
                continuation.resume(returning: (self.readinessKey, self.readinessAt, self.localReadiness.map { !$0.missing.isEmpty || $0.noXcode } ?? false))
            }
        }
        let fresh = known.lacking ? await makeReadiness(facts, known: (known.key, known.at), now: clock(), force: true) : nil
        return await withCheckedContinuation { continuation in
            queue.async {
                self.apply(fresh?.report, key: fresh?.key ?? "")
                continuation.resume(returning: (sample, self.localReadiness))
            }
        }
    }

    /// A link to a peer came up: it gets what this Mac has now rather than waiting for the next tick.
    func greet(_ client: RemoteHostClient) {
        guard client.capabilities.contains(RemoteProtocol.fleetPressureCapability) else { return }
        let sample = local?.sample
        let report = localReadiness
        let check = client.capabilities.contains(RemoteProtocol.fleetCheckCapability) ? localCheck?.report : nil
        Task {
            if let report { try? await client.fleetReadiness(report) }
            if let sample { try? await client.fleetPressure(sample) }
            if let check { try? await client.fleetCheck(check) }
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
            repos: report.repos.prefix(reportLimits.repos).map(line), repoKeys: report.repoKeys.prefix(reportLimits.repos).map(line),
            noXcode: report.noXcode)
    }

    // MARK: Reading

    /// This Mac and each of `peerIDs` with what is known of them, ages by this host's clock.
    func macs(thisMac: UUID, peerIDs: [UUID]) -> [FleetMacState] {
        let now = clock()
        var macs: [FleetMacState] = []
        if local != nil || localReadiness != nil || localCheck != nil {
            macs.append(FleetMacState(hostID: thisMac, sample: local?.sample, sampleAge: local.map { max(0, now.timeIntervalSince($0.at)) },
                                      readiness: localReadiness, check: localCheck?.report,
                                      checkAge: localCheck.map { max(0, now.timeIntervalSince($0.at)) }))
        }
        for id in peerIDs {
            guard let peer = peers[id], peer.sample != nil || peer.readiness != nil || peer.check != nil else { continue }
            macs.append(FleetMacState(hostID: id, sample: peer.sample, sampleAge: peer.receivedAt.map { now.timeIntervalSince($0) },
                                      readiness: peer.readiness, check: peer.check, checkAge: peer.checkAt.map { max(0, now.timeIntervalSince($0)) }))
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
