import Foundation

/// Check is non-destructive. Install authorizes download, signature verification and restart
/// together; never send it automatically or retry it after a lost connection.
public enum RemoteHostUpdateRequest: Codable, Hashable, Sendable {
    case status
    case check
    case install(offerID: UUID, authorized: Bool)
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
