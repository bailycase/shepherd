import Foundation
import ShepherdCore

// Pressure and readiness (`RemoteProtocol.fleetPressureCapability`): what each Mac says of its
// load and of what it can run, pushed to the Macs it is paired with, and what this Mac's app draws
// of all of them (`FleetSnapshot.macs`).

/// A tool or program a Mac lacks. Facts only: Fleet never offers to install one.
public struct FleetMissingTool: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// A program an MCP server runs that isn't on the login shell's PATH (`name` is the command).
        case binary
        case git
        case xcode
    }

    public var kind: Kind
    /// The command's name for `binary`; empty otherwise.
    public var name: String

    public init(kind: Kind, name: String = "") {
        self.kind = kind
        self.name = name
    }
}

/// What a Mac is and what it can do: the facts sync can't carry (a missing program, a missing
/// tool) and the hardware. Never "needs sign-in": credentials sync.
public struct FleetReadinessReport: Codable, Hashable, Sendable {
    /// "MacBook Pro", or "Mac" when the model identifier doesn't say.
    public var model: String
    /// "M4 Pro".
    public var chip: String
    public var missing: [FleetMissingTool]
    /// The projects this Mac has a folder for, by name, sorted.
    public var repos: [String]
    /// The repositories those projects are, by canonical key (`CanonicalRepoKey`), sorted: what a dispatch
    /// is matched against. Empty from an older Mac, which no dispatch is placed on.
    public var repoKeys: [String]
    /// Xcode isn't installed, whether or not a project here needs it (`missing` names it only when one does): a dispatch of a
    /// repository with an Xcode project is refused there. False from an older Mac, which `missing` speaks for.
    public var noXcode: Bool

    public init(model: String = "Mac", chip: String = "", missing: [FleetMissingTool] = [], repos: [String] = [], repoKeys: [String] = [],
                noXcode: Bool = false) {
        self.model = model
        self.chip = chip
        self.missing = missing
        self.repos = repos
        self.repoKeys = repoKeys
        self.noXcode = noXcode
    }

    private enum CodingKeys: String, CodingKey { case model, chip, missing, repos, repoKeys, noXcode }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? "Mac"
        chip = try c.decodeIfPresent(String.self, forKey: .chip) ?? ""
        missing = try c.decodeIfPresent([FleetMissingTool].self, forKey: .missing) ?? []
        repos = try c.decodeIfPresent([String].self, forKey: .repos) ?? []
        repoKeys = try c.decodeIfPresent([String].self, forKey: .repoKeys) ?? []
        noXcode = try c.decodeIfPresent(Bool.self, forKey: .noXcode) ?? false
    }

    /// What this Mac lacks, as placement weighs it: git and Xcode decide where work goes for the dispatches that need them, and an
    /// MCP server's command never does.
    public var lacks: [FleetPlacement.Lack] {
        var lacks = missing.map { tool -> FleetPlacement.Lack in
            switch tool.kind {
            case .binary: .mcpCommand(tool.name)
            case .git: .git
            case .xcode: .xcode
            }
        }
        if noXcode, !lacks.contains(.xcode) { lacks.append(.xcode) }
        return lacks
    }
}

/// One Mac of the fleet as its host knows it now: this Mac or a peer, with the last sample and
/// readiness report it has (a peer that never sent one has none).
public struct FleetMacState: Codable, Hashable, Identifiable, Sendable {
    public var hostID: UUID
    public var sample: FleetPressureSample?
    /// Seconds between the sample's arrival and the snapshot, by this host's clock; nil without a
    /// sample. This Mac's own sample is 0.
    public var sampleAge: Double?
    public var readiness: FleetReadinessReport?
    /// What the Mac found when it looked at itself (`FleetCheckWire.swift`); nil from a Mac that doesn't (an older build) or hasn't yet.
    public var check: FleetCheckReport?
    /// Seconds since this host last had `check` (this Mac's own is when it made it), by this host's clock; nil without a report.
    public var checkAge: Double?
    public var id: UUID { hostID }

    public init(hostID: UUID, sample: FleetPressureSample? = nil, sampleAge: Double? = nil, readiness: FleetReadinessReport? = nil,
                check: FleetCheckReport? = nil, checkAge: Double? = nil) {
        self.hostID = hostID
        self.sample = sample
        self.sampleAge = sampleAge
        self.readiness = readiness
        self.check = check
        self.checkAge = checkAge
    }

    private enum CodingKeys: String, CodingKey { case hostID, sample, sampleAge, readiness, check, checkAge }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        sample = try c.decodeIfPresent(FleetPressureSample.self, forKey: .sample)
        sampleAge = try c.decodeIfPresent(Double.self, forKey: .sampleAge)
        readiness = try c.decodeIfPresent(FleetReadinessReport.self, forKey: .readiness)
        check = (try? c.decodeIfPresent(FleetCheckReport.self, forKey: .check)) ?? nil
        checkAge = try c.decodeIfPresent(Double.self, forKey: .checkAge)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(hostID, forKey: .hostID)
        try c.encodeIfPresent(sample, forKey: .sample)
        try c.encodeIfPresent(sampleAge, forKey: .sampleAge)
        try c.encodeIfPresent(readiness, forKey: .readiness)
        try c.encodeIfPresent(check, forKey: .check)
        try c.encodeIfPresent(checkAge, forKey: .checkAge)
    }
}
