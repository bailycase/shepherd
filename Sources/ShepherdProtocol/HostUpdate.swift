import Foundation

/// Check is non-destructive. Install authorizes download, signature verification and restart
/// together; never send it automatically or retry it after a lost connection.
public enum RemoteHostUpdateRequest: Codable, Hashable, Sendable {
    case status
    case check
    case install(offerID: UUID, authorized: Bool)
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

    public init(version: String, build: String, channel: String, phase: Phase,
                offerID: UUID? = nil, offeredVersion: String? = nil, error: String? = nil, canInstall: Bool = false) {
        self.version = version; self.build = build; self.channel = channel; self.phase = phase
        self.offerID = offerID; self.offeredVersion = offeredVersion; self.error = error; self.canInstall = canInstall
    }
}
