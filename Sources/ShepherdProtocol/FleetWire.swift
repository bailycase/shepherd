import CryptoKit
import Foundation

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
    public var id: UUID { hostID }

    public init(hostID: UUID, name: String, kind: FleetPeerKind = .mac, host: String? = nil, port: UInt16? = nil,
                pairedAt: Double, link: Link, lastSeen: Double? = nil) {
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
    /// Settings ▸ Experiments ▸ Fleet is on for this host. Off: nothing below is live.
    public var enabled: Bool
    public var hostID: UUID?
    public var name: String
    public var build: String?
    /// This Mac's addresses on the networks it is on, for the join panel's text.
    public var addresses: [String]
    /// The port the host's listener is bound to; nil while it isn't serving.
    public var port: UInt16?
    /// The host advertises itself over Bonjour now.
    public var advertising: Bool
    public var peers: [FleetPeerStatus]
    public var join: FleetJoinStatus?

    public init(enabled: Bool = false, hostID: UUID? = nil, name: String = "", build: String? = nil, addresses: [String] = [],
                port: UInt16? = nil, advertising: Bool = false, peers: [FleetPeerStatus] = [], join: FleetJoinStatus? = nil) {
        self.enabled = enabled
        self.hostID = hostID
        self.name = name
        self.build = build
        self.addresses = addresses
        self.port = port
        self.advertising = advertising
        self.peers = peers
        self.join = join
    }
}

/// A host this Mac's app already knew by address and the shared token (`RemoteHostStore`),
/// handed to its host to become a fleet peer without pairing again.
public struct FleetLegacyHost: Codable, Hashable, Sendable {
    /// The app's own id for the configuration.
    public var id: UUID
    public var name: String
    public var host: String
    public var port: UInt16
    public var token: String

    public init(id: UUID, name: String, host: String, port: UInt16, token: String) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.token = token
    }
}

/// What became of one legacy host the app handed over.
public struct FleetAdoption: Codable, Hashable, Sendable {
    public enum Outcome: Codable, Hashable, Sendable {
        /// Now a fleet peer: the Mac's id and name.
        case established(hostID: UUID, name: String)
        /// A Mac that doesn't speak fleet (or has it off): left exactly as it was.
        case notFleet
        /// Couldn't be reached: left as it was and tried again later.
        case unreachable
        /// Refused with this code.
        case refused(code: String)
    }

    public var id: UUID
    public var outcome: Outcome

    public init(id: UUID, outcome: Outcome) {
        self.id = id
        self.outcome = outcome
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
    /// Make these known hosts fleet peers where they can be (`FleetAdoption`).
    case adopt([FleetLegacyHost])
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
    public var adopted: [FleetAdoption]?

    public init(snapshot: FleetSnapshot, join: Join? = nil, paired: FleetPeerStatus? = nil, adopted: [FleetAdoption]? = nil) {
        self.snapshot = snapshot
        self.join = join
        self.paired = paired
        self.adopted = adopted
    }
}
