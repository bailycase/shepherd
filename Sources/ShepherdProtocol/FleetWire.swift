import CryptoKit
import Foundation
import ShepherdCore

/// Fleet: Macs that pair once with a code and then hold links between their hosts (`fleet.v1`).
/// The payloads of `RemoteRequest.fleet*` and `RemoteReply.fleet*`. Nothing here carries a usable
/// token for a third party: each side generates the token it will present, and only SHA-256
/// hashes of tokens ever cross the wire (`FleetProtocol.hash`).
public enum FleetProtocol {
    /// The Bonjour service a Mac in a fleet advertises (and the app browses to list Macs to add).
    public static let bonjourType = "_shepherd._tcp"
    /// A join code is this many digits, shown on the Mac that joins.
    public static let codeLength = 6
    /// How long a join code lives after its Join screen opens, in seconds.
    public static let codeLifetime: TimeInterval = 5 * 60
    /// Wrong codes tried before the code is dropped.
    public static let maxCodeAttempts = 5

    /// The hex SHA-256 of a presented token: what a Mac stores of the other's token.
    public static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// A fresh token (32 random bytes as hex, like the shared remote token).
    public static func makeToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        arc4random_buf(&bytes, bytes.count)
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// What Bonjour tells about a Mac before anyone pairs with it: the first bytes of a hash of
    /// its id (so this Mac can skip its own advertisement), the name it shows and its build.
    public static func advertisedIDHash(_ hostID: UUID) -> String {
        String(SHA256.hash(data: Data(hostID.uuidString.utf8)).map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// The codes a client reads off an error reply of a fleet request.
    public enum Code {
        public static let off = "fleet_off"
        public static let notJoining = "not_joining"
        public static let badCode = "bad_code"
        public static let codeExpired = "code_expired"
        public static let lockedOut = "locked_out"
        public static let wrongHost = "wrong_host"
        public static let unreachable = "unreachable"
        public static let forbidden = "forbidden"
        public static let invalid = "invalid"
        public static let busy = "busy"
        /// A device pairs with an id that was revoked: it makes a new one and pairs again.
        public static let deviceRevoked = "device_revoked"
        /// Nobody is showing that code (`FleetAction.findAndPair`): the code finds no Join record.
        public static let notFound = "not_found"
        /// iCloud can't be used to look for a Mac (`FleetAction.findAndPair`): no account, a different Apple ID, or no
        /// access from this build. Pairing goes on the other ways.
        public static let icloudUnavailable = "icloud_unavailable"
        /// A pairing link's code has stopped working (`FleetAction.pairAt`): refused without a connection.
        public static let linkExpired = "link_expired"
    }
}

/// What a Mac says about itself when it asks to be paired or established: who it is, the hash of
/// the token it will present to the other side, and where its listener is (the other side reads
/// the address off the connection and takes the port from here).
public struct FleetIntroduction: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var name: String
    public var myTokenHash: String
    public var port: UInt16

    public init(hostID: UUID, name: String, myTokenHash: String, port: UInt16) {
        self.hostID = hostID
        self.name = name
        self.myTokenHash = myTokenHash
        self.port = port
    }
}

/// A Mac one member introduces to another (`RemoteRequest.fleetIntroduce`): its id and name, and
/// where the member that introduces it reaches it.
public struct FleetMember: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var name: String
    public var host: String?
    public var port: UInt16

    public init(hostID: UUID, name: String, host: String?, port: UInt16) {
        self.hostID = hostID
        self.name = name
        self.host = host
        self.port = port
    }
}

/// One step of introducing two members through a third. `theirTokenHash` is nil on the first
/// step (the receiver makes the token it will present to `member` and answers its hash) and the
/// hash `member` will present on the others.
public struct FleetIntroduce: Codable, Hashable, Sendable {
    public var member: FleetMember
    public var theirTokenHash: String?

    public init(member: FleetMember, theirTokenHash: String?) {
        self.member = member
        self.theirTokenHash = theirTokenHash
    }
}

public enum FleetPeerKind: String, Codable, Hashable, Sendable {
    case mac
}

/// One paired Mac as Settings ▸ Fleet lists it.
public struct FleetPeerStatus: Codable, Hashable, Identifiable, Sendable {
    public enum Link: String, Codable, Hashable, Sendable {
        case connected, connecting, offline
    }

    public var hostID: UUID
    public var name: String
    public var kind: FleetPeerKind
    /// The address the host last reached it at, and its port.
    public var host: String?
    public var port: UInt16?
    /// Epoch milliseconds.
    public var pairedAt: Double
    public var link: Link
    /// Epoch milliseconds of the link's last drop; nil while connected or never connected.
    public var lastSeen: Double?
    /// How the host reaches it now while linked (`FleetPeerReach`); nil from a host before links ran both ways, and to a client.
    public var reach: FleetPeerReach?
    public var id: UUID { hostID }

    public init(hostID: UUID, name: String, kind: FleetPeerKind = .mac, host: String? = nil, port: UInt16? = nil,
                pairedAt: Double, link: Link, lastSeen: Double? = nil, reach: FleetPeerReach? = nil) {
        self.reach = reach
        self.hostID = hostID
        self.name = name
        self.kind = kind
        self.host = host
        self.port = port
        self.pairedAt = pairedAt
        self.link = link
        self.lastSeen = lastSeen
    }
}

/// The code window of a Mac that is joining (never the code itself, which only the reply to
/// `FleetAction.startJoin` carries).
public struct FleetJoinStatus: Codable, Hashable, Sendable {
    /// Epoch milliseconds.
    public var expiresAt: Double
    public var attemptsLeft: Int

    public init(expiresAt: Double, attemptsLeft: Int) {
        self.expiresAt = expiresAt
        self.attemptsLeft = attemptsLeft
    }
}

/// What the app draws of this Mac's fleet (`RemoteRequest.fleetRead`).
public struct FleetSnapshot: Codable, Hashable, Sendable {
    /// The host's fleet answered. Always true from this build; an older host with Fleet off said false and nothing below was live.
    public var enabled: Bool
    public var hostID: UUID?
    public var name: String
    public var build: String?
    /// This Mac's addresses on the networks it is on, for the join panel's text.
    public var addresses: [String]
    /// The port the host's listener is bound to; nil while it isn't serving.
    public var port: UInt16?
    /// Every way this Mac can be reached now, most useful first (`FleetRouteReport`), with the kind of each: what a pairing link
    /// carries and Join a fleet lists. Empty from a host that doesn't say, and never sent to a client (`clientView`).
    public var routes: [FleetReportedRoute]
    /// The host advertises itself over Bonjour now.
    public var advertising: Bool
    public var peers: [FleetPeerStatus]
    public var join: FleetJoinStatus?
    /// This Mac and each peer with the last pressure sample and readiness report the host holds
    /// (`FleetPressureWire.swift`); a Mac with nothing yet is absent.
    public var macs: [FleetMacState]
    /// Where sync stands with each Mac (`FleetSyncStatus`); nil while this host doesn't sync.
    public var sync: FleetSyncStatus?
    /// Phones, iPads and Mac apps paired as clients; nil from a host without them.
    public var devices: FleetDevicesSnapshot?
    /// The dispatches this Mac sent, newest first, without their task and result text (the Fleet page's
    /// Dispatches log); empty from a host that doesn't dispatch.
    public var dispatches: [FleetDispatchRecord]
    /// Where this Mac's content index stands (`FleetSnapshotWire.swift`); nil while it isn't indexing (no Mac paired).
    public var index: FleetIndexStatus?
    /// This Mac and the Macs of its fleet with how each is reached (`RemoteProtocol.fleetFollowCapability`): what a phone or an iPad that
    /// is paired with any of them keeps its list of Macs from. Empty from a host without the capability, and while Fleet is off.
    public var members: [FleetViewMember]

    public init(enabled: Bool = false, hostID: UUID? = nil, name: String = "", build: String? = nil, addresses: [String] = [],
                port: UInt16? = nil, routes: [FleetReportedRoute] = [], advertising: Bool = false, peers: [FleetPeerStatus] = [], join: FleetJoinStatus? = nil,
                sync: FleetSyncStatus? = nil, devices: FleetDevicesSnapshot? = nil, macs: [FleetMacState] = [],
                dispatches: [FleetDispatchRecord] = [], index: FleetIndexStatus? = nil, members: [FleetViewMember] = []) {
        self.members = members
        self.routes = routes
        self.index = index
        self.devices = devices
        self.dispatches = dispatches
        self.enabled = enabled
        self.hostID = hostID
        self.name = name
        self.build = build
        self.addresses = addresses
        self.port = port
        self.advertising = advertising
        self.peers = peers
        self.join = join
        self.macs = macs
        self.sync = sync
    }

    private enum CodingKeys: String, CodingKey { case enabled, hostID, name, build, addresses, port, routes, advertising, peers, join, macs, devices, sync, dispatches, index, members }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        hostID = try c.decodeIfPresent(UUID.self, forKey: .hostID)
        name = try c.decode(String.self, forKey: .name)
        build = try c.decodeIfPresent(String.self, forKey: .build)
        addresses = try c.decode([String].self, forKey: .addresses)
        port = try c.decodeIfPresent(UInt16.self, forKey: .port)
        // A host from before pairing links has none.
        routes = (try? c.decodeIfPresent([FleetReportedRoute].self, forKey: .routes)) ?? []
        advertising = try c.decode(Bool.self, forKey: .advertising)
        peers = try c.decode([FleetPeerStatus].self, forKey: .peers)
        join = try c.decodeIfPresent(FleetJoinStatus.self, forKey: .join)
        // A host from before pressure has none.
        macs = try c.decodeIfPresent([FleetMacState].self, forKey: .macs) ?? []
        devices = try c.decodeIfPresent(FleetDevicesSnapshot.self, forKey: .devices)
        sync = try c.decodeIfPresent(FleetSyncStatus.self, forKey: .sync)
        dispatches = (try? c.decodeIfPresent([FleetDispatchRecord].self, forKey: .dispatches)) ?? []
        index = try c.decodeIfPresent(FleetIndexStatus.self, forKey: .index)
        members = (try? c.decodeIfPresent([FleetViewMember].self, forKey: .members)) ?? []
    }
}

extension FleetSnapshot {
    /// What a client (a phone or an iPad) may read: the Macs, whether each is reachable, and their load and
    /// readiness, and the routes to each (`members`: what it needs to keep its own list of Macs). Not the addresses this Mac lists for
    /// itself, a code window, the devices, the sync state, the dispatches or the build.
    public var clientView: FleetSnapshot {
        FleetSnapshot(enabled: enabled, hostID: hostID, name: name,
                      peers: peers.map {
                          FleetPeerStatus(hostID: $0.hostID, name: $0.name, kind: $0.kind, pairedAt: $0.pairedAt, link: $0.link, lastSeen: $0.lastSeen)
                      },
                      macs: macs, members: members)
    }
}

/// What this Mac's app asks its own host to do about the fleet (`RemoteRequest.fleetAction`,
/// local socket only).
public enum FleetAction: Codable, Hashable, Sendable {
    /// Open the code window of a Mac that joins; answered with the code (`FleetResult.join`).
    case startJoin
    /// Close it (the Join screen closed).
    case stopJoin
    /// Pair with the Mac at `host`:`port` (found by Bonjour) using the code its screen shows.
    case pair(host: String, port: UInt16, code: String)
    /// Remove a Mac from the fleet, here and on every other member.
    case remove(hostID: UUID)
    /// The Fleet page is on screen (true) or isn't (false): the host samples and pushes while it
    /// is, and stops when the connection that said so closes.
    case watching(Bool)
    /// Try the link to this Mac again now, without waiting out its backoff.
    case reconnect(hostID: UUID)
    /// Fleet ▸ Check ▸ Check now (`RemoteProtocol.fleetCheckCapability`): this Mac looks at itself again, and asks each Mac of the fleet that
    /// can to do the same, read only; answered once they have answered (or after a bound). The snapshot then holds the new reports.
    case checkNow
    /// Open the code window of Add a device and answer its code (`FleetResult.deviceCode`).
    case startDeviceCode
    /// Close it (the Add a device screen closed).
    case stopDeviceCode
    /// Revoke a phone, iPad or Mac app, here and on every member (`FleetDevices`).
    case revokeDevice(UUID)
    /// This Mac's app asks for a token of its own for its direct connections to the Macs of the fleet
    /// (a device of kind `macApp`); answered with it (`FleetResult.appToken`).
    case enrollApp(name: String)
    /// Start a thread the person made in New thread on the Mac Auto (or a named one) picks
    /// (`RemoteProtocol.fleetDispatchCapability`); answered with the dispatch it made (`FleetResult.dispatch`), or with none
    /// when the work stays on this Mac and the app starts it itself.
    case sendThread(FleetUserThread)
    /// Send a dispatch that is waiting, held or not sent again: to the Mac `host` (this Mac included), or as it was asked
    /// when nil. Answered with the record (`FleetResult.dispatch`).
    case retryDispatch(id: UUID, host: UUID?)
    /// Stop a dispatch this Mac sent, and its thread on the other Mac.
    case cancelDispatch(id: UUID)
    /// Pair with the Mac showing `code` without knowing where it is: the host asks the person's own iCloud
    /// (`RemoteProtocol.fleetRendezvousCapability`) where that code was shown, then pairs over the routes it
    /// finds exactly as `pair` does. The code is still the only proof. Answered with the Mac (`FleetResult.paired`).
    case findAndPair(code: String)
    /// Pair with the Mac `hostID` over `routes` (tried in order, each on `port`) using the code its screen shows, as a pairing link or a
    /// Mac found over SSH says (`RemoteProtocol.fleetPairLinkCapability`). The Mac that answers must be `hostID`, or nothing is sent to it:
    /// the code is still the only proof. `expiresAt` (epoch milliseconds) is when the code stops working; an expired one is refused
    /// without a connection. Answered with the Mac (`FleetResult.paired`).
    case pairAt(hostID: UUID, port: UInt16, routes: [FleetReportedRoute], code: String, expiresAt: Double?)
}

/// The answer to `fleetRead` and `fleetAction`: the snapshot after it, plus what the action made.
public struct FleetResult: Codable, Hashable, Sendable {
    public struct Join: Codable, Hashable, Sendable {
        public var code: String
        /// Epoch milliseconds.
        public var expiresAt: Double

        public init(code: String, expiresAt: Double) {
            self.code = code
            self.expiresAt = expiresAt
        }
    }

    public var snapshot: FleetSnapshot
    public var join: Join?
    public var paired: FleetPeerStatus?
    /// The code of Add a device, answering `FleetAction.startDeviceCode`.
    public var deviceCode: Join?
    /// The token this Mac's app was given, answering `FleetAction.enrollApp`. Over the local socket only.
    public var appToken: String?
    /// The dispatch `FleetAction.sendThread`, `retryDispatch` or `cancelDispatch` made or changed, with its task and result
    /// text left out like the log's (`FleetDispatchRecord.summary`).
    public var dispatch: FleetDispatchRecord?

    public init(snapshot: FleetSnapshot, join: Join? = nil, paired: FleetPeerStatus? = nil,
                deviceCode: Join? = nil, appToken: String? = nil, dispatch: FleetDispatchRecord? = nil) {
        self.dispatch = dispatch
        self.deviceCode = deviceCode
        self.appToken = appToken
        self.snapshot = snapshot
        self.join = join
        self.paired = paired
    }
}

// MARK: - Devices (slice 5)

/// What a phone, an iPad or a Mac's app is to a fleet: a client. It has a token of its own that
/// every Mac in the fleet accepts, and no part of the fleet's store: sync and credential units
/// never reach it (`FleetAccess`).
public enum FleetDeviceKind: String, Codable, Hashable, Sendable {
    case macApp, iphone, ipad
}

/// What a device says about itself when it pairs or is offered its own token: the id it picked,
/// what to call it, and the hash of the token it will present (it makes the token, like a Mac does).
public struct FleetDeviceIntroduction: Codable, Hashable, Sendable {
    public var deviceID: UUID
    public var name: String
    public var kind: FleetDeviceKind
    public var tokenHash: String

    public init(deviceID: UUID, name: String, kind: FleetDeviceKind, tokenHash: String) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.tokenHash = tokenHash
    }
}

/// One device as the Macs of a fleet tell each other (`RemoteRequest.fleetSyncDevices`): a revoked
/// one stays as a tombstone with no token hash, so a Mac that was offline still hears of it.
public struct FleetDeviceEntry: Codable, Hashable, Sendable {
    public var deviceID: UUID
    public var name: String
    public var kind: FleetDeviceKind
    /// SHA-256 of its token; nil once revoked.
    public var tokenHash: String?
    /// Epoch milliseconds.
    public var pairedAt: Double
    /// Epoch milliseconds the device was revoked; nil while it isn't.
    public var revokedAt: Double?

    public init(deviceID: UUID, name: String, kind: FleetDeviceKind, tokenHash: String?, pairedAt: Double, revokedAt: Double? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
    }
}

/// The answer to `fleetPairDevice` and `fleetSyncDevices`: who answers, the
/// Macs it is in a fleet with (a device reaches each of them with the token it just made), and
/// the devices it holds (the answer to a sync).
public struct FleetDevicesResult: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var name: String
    public var members: [FleetMember]
    public var devices: [FleetDeviceEntry]

    public init(hostID: UUID, name: String, members: [FleetMember] = [], devices: [FleetDeviceEntry] = []) {
        self.hostID = hostID
        self.name = name
        self.members = members
        self.devices = devices
    }
}

/// One device as Settings ▸ Fleet lists it.
public struct FleetDeviceStatus: Codable, Hashable, Identifiable, Sendable {
    public var deviceID: UUID
    public var name: String
    public var kind: FleetDeviceKind
    /// Epoch milliseconds.
    public var pairedAt: Double
    /// A connection of this device is open on this Mac now.
    public var connected: Bool
    /// Epoch milliseconds this Mac last had a connection of it; nil if never.
    public var lastSeen: Double?
    public var id: UUID { deviceID }

    public init(deviceID: UUID, name: String, kind: FleetDeviceKind, pairedAt: Double, connected: Bool, lastSeen: Double? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.pairedAt = pairedAt
        self.connected = connected
        self.lastSeen = lastSeen
    }
}

/// The part of `FleetSnapshot` about client devices.
public struct FleetDevicesSnapshot: Codable, Hashable, Sendable {
    public var devices: [FleetDeviceStatus]
    /// The window of Add a device, while it is open.
    public var code: FleetJoinStatus?

    public init(devices: [FleetDeviceStatus] = [], code: FleetJoinStatus? = nil) {
        self.devices = devices
        self.code = code
    }
}

/// What a connection may do in a fleet, by how it authenticated. Slices that sync or move
/// credentials check it: only a member (a Mac holding a peer's token) and this Mac's own app
/// take part in the fleet's store; a device is a client and never reaches it.
public enum FleetAccess: Sendable, Hashable {
    /// This Mac's own app on `host.sock`.
    case local
    /// A Mac in the fleet, with the token it made for this one.
    case member
    /// A phone, iPad or Mac app with a token of its own.
    case device
    /// Not yet authenticated: it may only identify the Mac and pair with a code.
    case unauthenticated

    /// Sync, credential and dispatch units, and the requests that pair or remove Macs.
    public var takesPartInFleet: Bool { self == .local || self == .member }

    /// May read the fleet's Macs, load and readiness (`FleetSnapshot.clientView`) and ask for it to be
    /// sampled while it looks. A device does; nothing else of the fleet.
    public var mayViewFleet: Bool { self == .device }

    /// Whether `capability` is offered to a connection with this access. A device is offered no
    /// fleet capability.
    public func isOffered(_ capability: String) -> Bool {
        self != .device || !RemoteProtocol.fleetMemberCapabilities.contains(capability)
    }
}

extension FleetProtocol {
    /// What the QR code of Add a device holds: the same code, and which Mac shows it, so a phone
    /// that finds several Macs asks the right one (a wrong try spends one of the five).
    public static let pairLinkScheme = "shepherd-pair"

    public static func pairLink(code: String, advertisedID: String) -> String {
        var parts = URLComponents()
        parts.scheme = pairLinkScheme
        parts.host = "device"
        parts.queryItems = [URLQueryItem(name: "code", value: code), URLQueryItem(name: "mac", value: advertisedID)]
        return parts.string ?? ""
    }

    /// The code and Mac a scanned QR names; nil for anything else.
    public static func parsePairLink(_ text: String) -> (code: String, advertisedID: String)? {
        guard let parts = URLComponents(string: text), parts.scheme == pairLinkScheme, parts.host == "device",
              let code = parts.queryItems?.first(where: { $0.name == "code" })?.value,
              let mac = parts.queryItems?.first(where: { $0.name == "mac" })?.value,
              code.count == codeLength, code.allSatisfy(\.isNumber), !mac.isEmpty else { return nil }
        return (code, mac)
    }

    /// Devices one Mac holds, so a stolen code can't fill the list.
    public static let maxDevices = 64
}
