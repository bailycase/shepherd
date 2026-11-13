import Darwin
import Foundation
import ShepherdProtocol

/// Where a peer Mac listens.
struct FleetAddress: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
}

/// One way to reach a peer Mac: where it listens and what kind of route that is. The host keeps the ones it was given when it paired
/// (`FleetPeerRecord.addresses`, never learned) and the ones the peer reports while they are linked (`FleetPeerRecord.learned`).
struct FleetRoute: Codable, Hashable, Sendable {
    var host: String
    var port: UInt16
    var kind: FleetRouteKind
    /// The peer reported it, so it goes when the peer stops reporting it; nobody removes it by hand.
    var learned: Bool

    var address: FleetAddress { FleetAddress(host: host, port: port) }

    /// What a route entered or observed as an address is, by its form: a name, a Tailscale address (100.64.0.0/10) or a LAN one.
    static func kind(ofAddress host: String) -> FleetRouteKind {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            let ip = UInt32(bigEndian: v4.s_addr)
            return ip & 0xffc00000 == 0x64400000 ? .tailscale : .lan
        }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1 ? .lan : .hostname
    }
}

/// One paired Mac in `peers.json`. Each side made the token it presents; this host holds that
/// token (`myToken`) and only the hash of the one the peer presents (`peerTokenHash`), so a copy
/// of this file lets nobody impersonate the peer to a third Mac.
struct FleetPeerRecord: Codable, Equatable, Identifiable, Sendable {
    var hostID: UUID
    var name: String
    var kind: FleetPeerKind
    /// Where it was reached, most recent first.
    var addresses: [FleetAddress]
    /// The token this host presents to the peer; nil on a record that is only waiting for it.
    var myToken: String?
    /// SHA-256 of the token the peer presents here; nil until the peer made it.
    var peerTokenHash: String?
    /// Epoch milliseconds.
    var pairedAt: Double
    /// Removed from the fleet. The record stays as a tombstone, tokens cleared, so every member
    /// hears of it (a Mac offline when it happened is told when its link comes up).
    var revoked: Bool
    /// Epoch milliseconds the removal was made.
    var revokedAt: Double?
    /// Members of the fleet this Mac still has to introduce to this peer, which joined through it.
    var introduce: [UUID]
    /// The routes the peer last reported (`FleetRouteReport`), in the order it gave them. Replaced by every report.
    var learned: [FleetRoute]

    var id: UUID { hostID }

    /// Every route to try, in order: the addresses this host was given, then the ones the peer reported.
    var routes: [FleetRoute] {
        addresses.map { FleetRoute(host: $0.host, port: $0.port, kind: FleetRoute.kind(ofAddress: $0.host), learned: false) }
            + learned.filter { route in !addresses.contains(route.address) }
    }

    init(hostID: UUID, name: String, kind: FleetPeerKind = .mac, addresses: [FleetAddress] = [], myToken: String? = nil,
         peerTokenHash: String? = nil, pairedAt: Double, revoked: Bool = false, revokedAt: Double? = nil, introduce: [UUID] = [],
         learned: [FleetRoute] = []) {
        self.learned = learned
        self.hostID = hostID
        self.name = name
        self.kind = kind
        self.addresses = addresses
        self.myToken = myToken
        self.peerTokenHash = peerTokenHash
        self.pairedAt = pairedAt
        self.revoked = revoked
        self.revokedAt = revokedAt
        self.introduce = introduce
    }

    private enum CodingKeys: String, CodingKey {
        case hostID, name, kind, addresses, myToken, peerTokenHash, pairedAt, revoked, revokedAt, introduce, learned
    }

    /// Every field but the id decodes with a default, so older files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(FleetPeerKind.self, forKey: .kind)) ?? nil ?? .mac
        addresses = try c.decodeIfPresent([FleetAddress].self, forKey: .addresses) ?? []
        myToken = try c.decodeIfPresent(String.self, forKey: .myToken)
        peerTokenHash = try c.decodeIfPresent(String.self, forKey: .peerTokenHash)
        pairedAt = try c.decodeIfPresent(Double.self, forKey: .pairedAt) ?? 0
        revoked = try c.decodeIfPresent(Bool.self, forKey: .revoked) ?? false
        revokedAt = try c.decodeIfPresent(Double.self, forKey: .revokedAt)
        introduce = try c.decodeIfPresent([UUID].self, forKey: .introduce) ?? []
        learned = (try? c.decodeIfPresent([FleetRoute].self, forKey: .learned)) ?? []
    }

    /// A peer this host holds a link to: not removed, and it has a token to present.
    var isLinkable: Bool { !revoked && myToken != nil && !addresses.isEmpty }

    /// Takes in what the peer reports: the routes it gave replace the ones it gave before, except where they are an address this host
    /// was given. False when nothing changed.
    @discardableResult
    mutating func learn(_ report: FleetRouteReport) -> Bool {
        var next: [FleetRoute] = []
        for reported in report.routes.prefix(FleetRouteReport.maxRoutes) {
            let route = FleetRoute(host: reported.host, port: report.port, kind: reported.kind, learned: true)
            if !addresses.contains(route.address), !next.contains(where: { $0.address == route.address }) { next.append(route) }
        }
        guard next != learned else { return false }
        learned = next
        return true
    }

    /// Puts `address` first, keeping the others.
    mutating func reached(at address: FleetAddress) {
        addresses.removeAll { $0 == address }
        addresses.insert(address, at: 0)
    }
}

/// `<support>/fleet/peers.json`: the Macs this host is paired with, and the tombstones of those
/// removed. Plain values; `FleetService` owns the one copy on the server queue.
struct FleetPeers: Codable, Equatable, Sendable {
    var peers: [FleetPeerRecord] = []

    static let fileName = "peers.json"

    static func load(from directory: URL) throws -> FleetPeers {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return FleetPeers() }
        return try JSONDecoder().decode(FleetPeers.self, from: data)
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FleetFiles.write(try encoder.encode(self), to: directory.appendingPathComponent(Self.fileName))
    }

    func record(_ hostID: UUID) -> FleetPeerRecord? { peers.first { $0.hostID == hostID } }

    /// The Macs in the fleet now: not removed.
    var members: [FleetPeerRecord] { peers.filter { !$0.revoked } }

    var tombstones: [FleetPeerRecord] { peers.filter(\.revoked) }

    mutating func upsert(_ record: FleetPeerRecord) {
        if let index = peers.firstIndex(where: { $0.hostID == record.hostID }) {
            peers[index] = record
        } else {
            peers.append(record)
        }
    }

    /// The Mac whose token this is, or nil. Every record is compared, so how long it takes does
    /// not say which one matched (`RemoteToken.matches`).
    func authenticate(token: String) -> UUID? {
        let presented = FleetProtocol.hash(token)
        var match: UUID?
        for record in peers where !record.revoked {
            guard let expected = record.peerTokenHash else { continue }
            if RemoteToken.matches(presented, expected: expected) { match = record.hostID }
        }
        return match
    }

    /// Removes `hostID` as of `at` (epoch milliseconds): its tokens are cleared and the record
    /// stays as a tombstone. False when nothing changed: it was already removed, or it joined
    /// again after `at`, which makes the news stale.
    @discardableResult
    mutating func revoke(_ hostID: UUID, at: Double) -> Bool {
        if var record = record(hostID) {
            guard !record.revoked, record.pairedAt <= at else { return false }
            record.revoked = true
            record.revokedAt = at
            record.myToken = nil
            record.peerTokenHash = nil
            record.introduce = []
            record.learned = []
            upsert(record)
        } else {
            upsert(FleetPeerRecord(hostID: hostID, name: "", pairedAt: 0, revoked: true, revokedAt: at))
        }
        return true
    }
}
