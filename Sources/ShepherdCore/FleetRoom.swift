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

    public init(cpuUtilization: Double, cpuCount: Int, totalMemoryBytes: UInt64, availableMemoryBytes: UInt64,
                thermal: FleetThermal = .nominal, onBattery: Bool = false, batteryPercent: Int? = nil,
                activeAgents: Int = 0, reserved: Int = 0) {
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

    /// Why a Mac is left out of Auto.
    public enum Skip: String, Hashable, Sendable {
        case stale
        case future
        case cpu
        case memory
        case thermal
        case manualOnly
    }

    /// What leaves a Mac out, or nil while it counts. `age` is how long ago the sample arrived,
    /// by the receiver's clock (negative: stamped in the future).
    public static func skip(_ sample: FleetPressureSample, age: TimeInterval, weight: FleetSendWeight = .normal) -> Skip? {
        if weight == .manualOnly { return .manualOnly }
        if age > staleAfter { return .stale }
        if age < -futureTolerance { return .future }
        if sample.cpuUtilization >= cpuCeiling { return .cpu }
        if sample.availableShare <= memoryFloor { return .memory }
        if sample.thermal >= .serious { return .thermal }
        return nil
    }

    /// `weight * cpuCount * (1 - cpu) * (available / total) / (1 + activeAgents + reserved)`,
    /// halved on battery when `batteryCountsHalf`. Zero for a Mac Auto never picks.
    public static func score(_ sample: FleetPressureSample, weight: FleetSendWeight = .normal, batteryCountsHalf: Bool = true) -> Double {
        guard let multiplier = weight.multiplier else { return 0 }
        let busy = min(1, max(0, sample.cpuUtilization))
        var score = multiplier * Double(max(0, sample.cpuCount)) * (1 - busy) * sample.availableShare
            / Double(1 + max(0, sample.activeAgents) + max(0, sample.reserved))
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
