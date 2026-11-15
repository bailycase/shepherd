import Foundation

// Fleet ▸ Update Shepherd on another Mac (`RemoteProtocol.fleetUpdateCapability`, `fleetUpdateViewCapability`). Each Mac installs only what its own
// Sparkle feed offers, signature checked, and nothing is copied between Macs. What crosses the link is the request `RemoteRequest.hostUpdate`
// that a client of a host always had (status, check, install) with two more steps (`RemoteHostUpdateRequest.installWhenIdle`, `.cancel`),
// answered with the Mac's own `HostUpdateStatus`. The host that was asked to update a Mac keeps the job (`FleetUpdateStatus`) and the
// app and the phones draw it from `FleetSnapshot.updates`.

/// When the Mac installs: once its threads have settled, or at once (its working agents are checkpointed and carry on from their
/// sessions, as on any update of the app).
public enum FleetUpdateWhen: String, Codable, Hashable, Sendable {
    case idle, now
}

/// What the app or a phone asks the host to do about updating a Mac of its fleet (`FleetAction.update`).
public enum FleetUpdateCommand: Codable, Hashable, Sendable {
    /// Update that Mac: look at what its own feed offers, then install it `when`. A Mac that is asleep starts when it wakes.
    case start(when: FleetUpdateWhen)
    /// Stop waiting for that Mac, or put away the result of a job that ended.
    case cancel
}

/// One update this host is carrying out on a Mac of its fleet (this one included), or that just ended.
public struct FleetUpdateStatus: Codable, Hashable, Identifiable, Sendable {
    public enum Stage: String, Codable, Hashable, Sendable {
        /// The Mac isn't reachable (asleep): the job starts when its link is back.
        case waitingToWake
        /// The Mac is asking its own feed what it offers.
        case checking
        case downloading
        /// The Mac holds the offer until the threads that work there are idle (`when: .idle`).
        case waitingForThreads
        case installing
        /// The Mac went away to install and hasn't come back yet.
        case relaunching
        /// The Mac came back on another build.
        case updated
        /// The Mac's feed offers nothing newer than it runs.
        case upToDate
        case failed
        /// The Mac has no Shepherd app open and its host couldn't open one: `message` says to open it.
        case needsApp

        /// Still going: Cancel is offered.
        public var isRunning: Bool {
            switch self {
            case .waitingToWake, .checking, .downloading, .waitingForThreads, .installing, .relaunching: true
            case .updated, .upToDate, .failed, .needsApp: false
            }
        }
    }

    public var hostID: UUID
    public var stage: Stage
    public var when: FleetUpdateWhen
    /// The build the Mac ran when the job began.
    public var fromBuild: String?
    /// The version its feed offered, once it said.
    public var offered: String?
    /// Threads working on the Mac: the ones `waitingForThreads` waits for.
    public var threads: Int?
    /// Why it ended, or what the Mac said, in its words.
    public var message: String?
    /// Epoch milliseconds the job began, and its stage last changed.
    public var startedAt: Double
    public var updatedAt: Double
    public var id: UUID { hostID }

    public init(hostID: UUID, stage: Stage, when: FleetUpdateWhen, fromBuild: String? = nil, offered: String? = nil, threads: Int? = nil,
                message: String? = nil, startedAt: Double, updatedAt: Double) {
        self.hostID = hostID
        self.stage = stage
        self.when = when
        self.fromBuild = fromBuild
        self.offered = offered
        self.threads = threads
        self.message = message
        self.startedAt = startedAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey { case hostID, stage, when, fromBuild, offered, threads, message, startedAt, updatedAt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        stage = try c.decode(Stage.self, forKey: .stage)
        when = try c.decodeIfPresent(FleetUpdateWhen.self, forKey: .when) ?? .idle
        fromBuild = try c.decodeIfPresent(String.self, forKey: .fromBuild)
        offered = try c.decodeIfPresent(String.self, forKey: .offered)
        threads = try c.decodeIfPresent(Int.self, forKey: .threads)
        message = try c.decodeIfPresent(String.self, forKey: .message)
        startedAt = try c.decodeIfPresent(Double.self, forKey: .startedAt) ?? 0
        updatedAt = try c.decodeIfPresent(Double.self, forKey: .updatedAt) ?? startedAt
    }
}
