import Foundation

/// How hot a Mac runs (`ProcessInfo.ThermalState`).
public enum FleetThermal: String, Codable, Hashable, Sendable, Comparable {
    case nominal, fair, serious, critical

    private var rank: Int {
        switch self {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        }
    }

    public static func < (a: FleetThermal, b: FleetThermal) -> Bool { a.rank < b.rank }
}

/// The kernel's memory pressure level (`kern.memorystatus_vm_pressure_level`: 1, 2 and 4), the same signal Activity Monitor colors green,
/// yellow and red. Free memory alone misses a Mac that is compressing and swapping with pages still "inactive".
public enum FleetMemoryPressure: String, Codable, Hashable, Sendable, Comparable {
    case normal, warn, critical

    private var rank: Int {
        switch self {
        case .normal: 0
        case .warn: 1
        case .critical: 2
        }
    }

    public static func < (a: FleetMemoryPressure, b: FleetMemoryPressure) -> Bool { a.rank < b.rank }

    /// The kernel's level; anything it doesn't name reads as normal, so a number this build doesn't know never leaves a Mac out.
    public init(kernelLevel: Int) {
        switch kernelLevel {
        case 2: self = .warn
        case 4: self = .critical
        default: self = .normal
        }
    }
}

/// A provider that answered a request with a rate limit or "overloaded" (`FleetProviderLimits`): sign-ins are shared by the fleet, so the
/// limit is the whole fleet's, and is carried to every Mac in the pressure sample of the one that saw it.
public struct FleetProviderLimit: Codable, Hashable, Sendable {
    /// pi's provider id ("anthropic").
    public var provider: String
    /// How long it lasts from the moment the sample was taken. A duration, never a time: the receiver stamps its own clock.
    public var seconds: Double

    public init(provider: String, seconds: Double) {
        self.provider = provider
        self.seconds = seconds
    }
}

/// One reading of a Mac's load (`FleetPressureSampler`). The receiver stamps when it arrived and
/// never compares the sender's clock, so a sample carries no time.
public struct FleetPressureSample: Codable, Hashable, Sendable {
    /// 0...1, the share of the CPUs busy over the sampling window.
    public var cpuUtilization: Double
    public var cpuCount: Int
    public var totalMemoryBytes: UInt64
    /// Free, inactive and speculative pages: what an app can take without the Mac swapping.
    public var availableMemoryBytes: UInt64
    public var thermal: FleetThermal
    public var onBattery: Bool
    /// 0...100 while on battery or charging; nil on a Mac without one.
    public var batteryPercent: Int?
    /// Threads working on this Mac now.
    public var activeAgents: Int
    /// Places promised to dispatches that haven't started yet (slice 4 fills it in).
    public var reserved: Int
    /// Of `activeAgents`, the threads running a tool command now (a build, a test run); the rest wait on the model. Nil from a Mac
    /// that doesn't say (an older build): all of its threads then weigh the same.
    public var commandAgents: Int?
    /// `cpuUtilization` averaged over the last `FleetRoom.cpuWindow` seconds, as the sending Mac took it. Nil from an older build.
    public var cpuAverage: Double?
    /// Nil from an older build, which reads as normal.
    public var memoryPressure: FleetMemoryPressure?
    /// The providers this Mac itself saw limit its requests and that still are (never ones it was told of: a Mac that relayed them would
    /// keep them alive for ever). Nil from an older build.
    public var limits: [FleetProviderLimit]?

    public init(cpuUtilization: Double, cpuCount: Int, totalMemoryBytes: UInt64, availableMemoryBytes: UInt64,
                thermal: FleetThermal = .nominal, onBattery: Bool = false, batteryPercent: Int? = nil,
                activeAgents: Int = 0, reserved: Int = 0, commandAgents: Int? = nil, cpuAverage: Double? = nil,
                memoryPressure: FleetMemoryPressure? = nil, limits: [FleetProviderLimit]? = nil) {
        self.commandAgents = commandAgents
        self.cpuAverage = cpuAverage
        self.memoryPressure = memoryPressure
        self.limits = limits
        self.cpuUtilization = cpuUtilization
        self.cpuCount = cpuCount
        self.totalMemoryBytes = totalMemoryBytes
        self.availableMemoryBytes = availableMemoryBytes
        self.thermal = thermal
        self.onBattery = onBattery
        self.batteryPercent = batteryPercent
        self.activeAgents = activeAgents
        self.reserved = reserved
    }

    /// Available memory as a share of the total, 0...1.
    public var availableShare: Double {
        totalMemoryBytes == 0 ? 0 : min(1, Double(availableMemoryBytes) / Double(totalMemoryBytes))
    }
}

/// How much of the fleet's auto placed work a Mac should get (Fleet page ▸ Send work here). The
/// choice is the setting `fleet.weight.<hostID>`.
public enum FleetSendWeight: String, Codable, Hashable, Sendable, CaseIterable {
    case prefer, normal, lessOften, manualOnly

    /// What the score multiplies by; nil for a Mac Auto never picks (it can still be named).
    public var multiplier: Double? {
        switch self {
        case .prefer: 1.5
        case .normal: 1.0
        case .lessOften: 0.5
        case .manualOnly: nil
        }
    }

    public var title: String {
        switch self {
        case .prefer: "Prefer"
        case .normal: "Normal"
        case .lessOften: "Less often"
        case .manualOnly: "Manual only"
        }
    }

    /// The setting's key for the Mac with this id.
    public static func settingKey(hostID: UUID) -> String { "fleet.weight.\(hostID.uuidString)" }
}

/// The room a Mac has for more work, from its last sample: the plan's score and the rules that
/// leave a Mac out (docs: Fleet ▸ Pressure, readiness, placement). Pure; the caller supplies the
/// age of the sample from its own clock.
public enum FleetRoom {
    /// A sample older than this counts for nothing.
    public static let staleAfter: TimeInterval = 15
    /// A sample stamped further ahead than this is wrong, whoever's clock it is.
    public static let futureTolerance: TimeInterval = 5
    /// A Mac this busy is left out.
    public static let cpuCeiling = 0.95
    /// A Mac with this little memory left, as a share of its total, is left out.
    public static let memoryFloor = 0.05
    /// Auto moves work off this Mac only to a Mac that scores at least this many times higher
    /// (a dispatch costs a fetch, a worktree and a round trip; noisy samples must not flap work
    /// between two similar Macs).
    public static let moveMargin = 1.5
    /// A Mac on battery scores this much of what it would plugged in, when the fleet counts it.
    public static let batteryFactor = 0.5
    /// What a thread running a tool command (a build, a test run, a dev server) takes of a Mac's room, in threads: it holds the CPU and
    /// the disk, where a thread waiting on the model holds almost nothing.
    public static let commandWeight = 3.0
    /// What a thread waiting on the model takes of a Mac's room, and a place promised to a dispatch that hasn't started.
    public static let modelWaitWeight = 1.0
    /// The CPU the score and the ceiling see is its average over this long, not the one reading a build or a test run can spike.
    public static let cpuWindow: TimeInterval = 60
    /// A Mac whose memory pressure is at this level or worse is left out, whatever its free memory says.
    public static let memoryPressureCutoff = FleetMemoryPressure.warn

    /// Why a Mac is left out of Auto.
    public enum Skip: String, Hashable, Sendable {
        case stale
        case future
        case cpu
        case memory
        case memoryPressure
        case thermal
        case manualOnly
    }

    /// What leaves a Mac out, or nil while it counts. `age` is how long ago the sample arrived,
    /// by the receiver's clock (negative: stamped in the future).
    public static func skip(_ sample: FleetPressureSample, age: TimeInterval, weight: FleetSendWeight = .normal) -> Skip? {
        if weight == .manualOnly { return .manualOnly }
        if age > staleAfter { return .stale }
        if age < -futureTolerance { return .future }
        if smoothedCPU(sample) >= cpuCeiling { return .cpu }
        if sample.availableShare <= memoryFloor { return .memory }
        if (sample.memoryPressure ?? .normal) >= memoryPressureCutoff { return .memoryPressure }
        if sample.thermal >= .serious { return .thermal }
        return nil
    }

    /// The CPU share the score and the ceiling use: the sender's average over `cpuWindow` when it sent one, else its single reading.
    public static func smoothedCPU(_ sample: FleetPressureSample) -> Double {
        let share = sample.cpuAverage ?? sample.cpuUtilization
        return share.isFinite ? share : 0
    }

    /// What the Mac's threads and promised places take of it, in threads: a thread running a command weighs `commandWeight`, a thread
    /// waiting on the model (or one whose Mac doesn't say) and a promised place `modelWaitWeight`.
    public static func load(_ sample: FleetPressureSample) -> Double {
        let working = max(0, sample.activeAgents)
        let commands = min(working, max(0, sample.commandAgents ?? 0))
        return Double(commands) * commandWeight + Double(working - commands) * modelWaitWeight + Double(max(0, sample.reserved)) * modelWaitWeight
    }

    /// `weight * cpuCount * (1 - cpu) * (available / total) / (1 + load)` (`smoothedCPU`, `load`),
    /// halved on battery when `batteryCountsHalf`. Zero for a Mac Auto never picks.
    public static func score(_ sample: FleetPressureSample, weight: FleetSendWeight = .normal, batteryCountsHalf: Bool = true) -> Double {
        guard let multiplier = weight.multiplier else { return 0 }
        let busy = min(1, max(0, smoothedCPU(sample)))
        var score = multiplier * Double(max(0, sample.cpuCount)) * (1 - busy) * sample.availableShare / (1 + load(sample))
        if sample.onBattery, batteryCountsHalf { score *= batteryFactor }
        return score
    }

    /// One Mac Auto could pick.
    public struct Candidate: Hashable, Sendable {
        public var id: UUID
        public var score: Double

        public init(id: UUID, score: Double) {
            self.id = id
            self.score = score
        }
    }

    /// Where work started on `local` would go now: the best counted Mac, except that it leaves
    /// `local` only for one that scores `moveMargin` times higher (the margin doesn't apply when
    /// `local` isn't counted). Nil when no Mac counts. Ties keep `local`, then the first listed.
    public static func nextGoesTo(_ candidates: [Candidate], local: UUID?) -> UUID? {
        let counted = candidates.filter { $0.score > 0 }
        guard let best = counted.reduce(nil, { (leader: Candidate?, next) in
            guard let leader else { return next }
            return next.score > leader.score || (next.score == leader.score && next.id == local) ? next : leader
        }) else { return nil }
        guard let local, let mine = counted.first(where: { $0.id == local }), best.id != local else { return best.id }
        return best.score >= mine.score * moveMargin ? best.id : local
    }
}
