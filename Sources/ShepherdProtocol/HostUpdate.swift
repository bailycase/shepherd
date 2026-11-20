import Foundation

/// Check is non-destructive. Install authorizes download, signature verification and restart
/// together; never send it automatically or retry it after a lost connection.
public enum RemoteHostUpdateRequest: Codable, Hashable, Sendable {
    case status
    case check
    /// Install now: the host checkpoints its working agents and restarts, and they carry on from their sessions.
    case install(offerID: UUID, authorized: Bool)
    /// Install once no thread on the host is working (`RemoteProtocol.fleetUpdateCapability`). The host answers it for the updater: with
    /// nothing working it is `install`; otherwise the updater is asked to hold the offer (and answers `waitingForIdle`), the host counts
    /// `busyThreads`, and sends `install` itself once they have settled. `install` (now) and `cancel` end the wait.
    case installWhenIdle(offerID: UUID, authorized: Bool)
    /// Let go of an offer held for idle threads or a download that hasn't reached the installer (`RemoteProtocol.fleetUpdateCapability`).
    /// Nothing that has reached the installer can be taken back.
    case cancel
}

extension RemoteHostUpdateRequest {
    /// How long the host that serves a request waits for its updater, which may have to open the app first, before it answers that it didn't.
    public static let hostReplyDeadline: TimeInterval = 10
    /// How long the asker waits: longer than the host does, so the host's own answer comes first. A request on a link to another Mac that
    /// times out takes the whole link down with it.
    public static let askerTimeout: TimeInterval = hostReplyDeadline + 5
}

/// What this Mac's app, whose Sparkle installs an update, asks its background host, which owns
/// the agents an update restarts (`RemoteRequest.hostUpdateGate`, local clients only). Each is
/// answered `ok` (yes, or no reason for `blockReason`) or an error whose message is the reason.
public enum HostUpdateGateStep: String, Codable, Hashable, Sendable {
    /// Hold the host for an install: checkpoint its agents and refuse new work.
    case reserve
    /// Let the hold go (the install ended or failed).
    case release
    /// Whether the update may restart now (its agents checkpointed, none busy).
    case canRestart
    /// Why an update can't be installed now, if anything.
    case blockReason
    /// Whether the app may quit for the restart now.
    case canTerminate
}

public struct HostUpdateStatus: Codable, Hashable, Sendable {
    public enum Phase: String, Codable, Sendable {
        case unsupported, idle, checking, available, upToDate, downloading, installing, failed
    }
    public var version: String
    public var build: String
    public var channel: String
    public var phase: Phase
    public var offerID: UUID?
    public var offeredVersion: String?
    public var error: String?
    public var canInstall: Bool
    /// Threads working on the host now, which the host counts for every answer (`fleet.update.v1`); nil from an older host.
    public var busyThreads: Int?
    /// An install was asked for once the threads are idle and is waiting for them (`RemoteHostUpdateRequest.installWhenIdle`). The
    /// phase stays `available`, so an older client reads an offer it can't install yet.
    public var waitingForIdle: Bool
    /// The host sent the updater an install (asked for now, or held for idle threads) and the updater took it: an app that quits now is installing,
    /// not closed by its person. Reset by the next request that isn't a status, and lost when the host restarts.
    public var installHandedOff: Bool

    public init(version: String, build: String, channel: String, phase: Phase,
                offerID: UUID? = nil, offeredVersion: String? = nil, error: String? = nil, canInstall: Bool = false,
                busyThreads: Int? = nil, waitingForIdle: Bool = false, installHandedOff: Bool = false) {
        self.version = version; self.build = build; self.channel = channel; self.phase = phase
        self.offerID = offerID; self.offeredVersion = offeredVersion; self.error = error; self.canInstall = canInstall
        self.busyThreads = busyThreads; self.waitingForIdle = waitingForIdle; self.installHandedOff = installHandedOff
    }

    private enum CodingKeys: String, CodingKey {
        case version, build, channel, phase, offerID, offeredVersion, error, canInstall, busyThreads, waitingForIdle, installHandedOff
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(String.self, forKey: .version)
        build = try c.decode(String.self, forKey: .build)
        channel = try c.decode(String.self, forKey: .channel)
        phase = try c.decode(Phase.self, forKey: .phase)
        offerID = try c.decodeIfPresent(UUID.self, forKey: .offerID)
        offeredVersion = try c.decodeIfPresent(String.self, forKey: .offeredVersion)
        error = try c.decodeIfPresent(String.self, forKey: .error)
        canInstall = try c.decode(Bool.self, forKey: .canInstall)
        busyThreads = try c.decodeIfPresent(Int.self, forKey: .busyThreads)
        waitingForIdle = try c.decodeIfPresent(Bool.self, forKey: .waitingForIdle) ?? false
        installHandedOff = try c.decodeIfPresent(Bool.self, forKey: .installHandedOff) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(build, forKey: .build)
        try c.encode(channel, forKey: .channel)
        try c.encode(phase, forKey: .phase)
        try c.encodeIfPresent(offerID, forKey: .offerID)
        try c.encodeIfPresent(offeredVersion, forKey: .offeredVersion)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(canInstall, forKey: .canInstall)
        try c.encodeIfPresent(busyThreads, forKey: .busyThreads)
        if waitingForIdle { try c.encode(true, forKey: .waitingForIdle) }
        if installHandedOff { try c.encode(true, forKey: .installHandedOff) }
    }
}
