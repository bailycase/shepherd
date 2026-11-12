import Foundation
import ShepherdProtocol

/// One client device in `devices.json`: a phone, an iPad or a Mac's app. The device made its token;
/// this host keeps only the hash, so a copy of the file lets nobody connect as it.
struct FleetDeviceRecord: Codable, Equatable, Identifiable, Sendable {
    var deviceID: UUID
    var name: String
    var kind: FleetDeviceKind
    /// SHA-256 of its token; nil once revoked.
    var tokenHash: String?
    /// Epoch milliseconds.
    var pairedAt: Double
    /// Epoch milliseconds the device was revoked. The record stays as a tombstone so every Mac hears of it.
    var revokedAt: Double?
    /// Epoch milliseconds this Mac last had a connection of it.
    var lastSeen: Double?

    var id: UUID { deviceID }
    var isRevoked: Bool { revokedAt != nil }

    init(deviceID: UUID, name: String, kind: FleetDeviceKind, tokenHash: String?, pairedAt: Double, revokedAt: Double? = nil, lastSeen: Double? = nil) {
        self.deviceID = deviceID
        self.name = name
        self.kind = kind
        self.tokenHash = tokenHash
        self.pairedAt = pairedAt
        self.revokedAt = revokedAt
        self.lastSeen = lastSeen
    }

    private enum CodingKeys: String, CodingKey { case deviceID, name, kind, tokenHash, pairedAt, revokedAt, lastSeen }

    /// Every field but the id decodes with a default, so older files keep loading.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        deviceID = try c.decode(UUID.self, forKey: .deviceID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = (try? c.decodeIfPresent(FleetDeviceKind.self, forKey: .kind)) ?? nil ?? .iphone
        tokenHash = try c.decodeIfPresent(String.self, forKey: .tokenHash)
        pairedAt = try c.decodeIfPresent(Double.self, forKey: .pairedAt) ?? 0
        revokedAt = try c.decodeIfPresent(Double.self, forKey: .revokedAt)
        lastSeen = try c.decodeIfPresent(Double.self, forKey: .lastSeen)
    }

    var entry: FleetDeviceEntry {
        FleetDeviceEntry(deviceID: deviceID, name: name, kind: kind, tokenHash: tokenHash, pairedAt: pairedAt, revokedAt: revokedAt)
    }
}

/// A client seen on the shared token that hasn't been given a token of its own.
struct FleetLegacySighting: Codable, Equatable, Identifiable, Sendable {
    /// Name and address together: an old client says only its name ("Shepherd iOS" for every
    /// phone), so where it connected from tells two of them apart.
    var id: String
    var name: String
    /// Epoch milliseconds.
    var lastSeen: Double

    var client: FleetLegacyClient { FleetLegacyClient(id: id, name: name, lastSeen: lastSeen) }
}

/// `<support>/fleet/devices.json`: the client devices of the fleet (the same list on every Mac, kept
/// equal by `merge`), the clients still on the shared token, and whether the shared token is
/// retired. Plain values; `FleetService` owns the one copy on the server queue.
struct FleetDevices: Codable, Equatable, Sendable {
    var devices: [FleetDeviceRecord] = []
    var legacy: [FleetLegacySighting] = []
    var sharedTokenRetired = false

    static let fileName = "devices.json"
    /// A sighting older than this stops holding the shared token back: the client is gone.
    static let sightingLifetime: TimeInterval = 30 * 24 * 3600

    init() {}

    private enum CodingKeys: String, CodingKey { case devices, legacy, sharedTokenRetired }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        devices = try c.decodeIfPresent([FleetDeviceRecord].self, forKey: .devices) ?? []
        legacy = try c.decodeIfPresent([FleetLegacySighting].self, forKey: .legacy) ?? []
        sharedTokenRetired = try c.decodeIfPresent(Bool.self, forKey: .sharedTokenRetired) ?? false
    }

    static func load(from directory: URL) throws -> FleetDevices {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return FleetDevices() }
        return try JSONDecoder().decode(FleetDevices.self, from: data)
    }

    func save(to directory: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try FleetFiles.write(try encoder.encode(self), to: directory.appendingPathComponent(Self.fileName))
    }

    func record(_ deviceID: UUID) -> FleetDeviceRecord? { devices.first { $0.deviceID == deviceID } }

    /// The devices that can connect now: not revoked.
    var active: [FleetDeviceRecord] { devices.filter { !$0.isRevoked } }

    var entries: [FleetDeviceEntry] { devices.map(\.entry) }

    /// The device whose token this is, or nil. Every record is compared, so how long it takes does
    /// not say which one matched (`RemoteToken.matches`).
    func authenticate(token: String) -> UUID? {
        let presented = FleetProtocol.hash(token)
        var match: UUID?
        for record in devices where !record.isRevoked {
            guard let expected = record.tokenHash else { continue }
            if RemoteToken.matches(presented, expected: expected) { match = record.deviceID }
        }
        return match
    }

    /// Adds a device that paired here. False when its id is already taken (a device made a new
    /// identity, so one that exists was revoked or is another device).
    @discardableResult
    mutating func add(_ device: FleetDeviceRecord) -> Bool {
        guard record(device.deviceID) == nil else { return false }
        devices.append(device)
        return true
    }

    /// Revokes `deviceID` as of `at` (epoch milliseconds): its token hash is dropped and the record
    /// stays as a tombstone. False when nothing changed: unknown, or revoked already.
    @discardableResult
    mutating func revoke(_ deviceID: UUID, at: Double) -> Bool {
        guard let index = devices.firstIndex(where: { $0.deviceID == deviceID }), !devices[index].isRevoked else { return false }
        devices[index].revokedAt = at
        devices[index].tokenHash = nil
        return true
    }

    /// Takes in the devices another Mac holds: ones this Mac doesn't know are added and a revocation
    /// is final, so the lists converge whichever way they are exchanged. Returns the devices that were
    /// revoked by this (their connections end) and whether anything changed.
    mutating func merge(_ entries: [FleetDeviceEntry]) -> (changed: Bool, revoked: [UUID]) {
        var changed = false
        var revoked: [UUID] = []
        for entry in entries {
            guard let index = devices.firstIndex(where: { $0.deviceID == entry.deviceID }) else {
                devices.append(FleetDeviceRecord(deviceID: entry.deviceID, name: entry.name, kind: entry.kind,
                                                 tokenHash: entry.revokedAt == nil ? entry.tokenHash : nil,
                                                 pairedAt: entry.pairedAt, revokedAt: entry.revokedAt))
                changed = true
                continue
            }
            if devices[index].isRevoked { continue }
            if let at = entry.revokedAt {
                devices[index].revokedAt = at
                devices[index].tokenHash = nil
                revoked.append(entry.deviceID)
                changed = true
            }
        }
        return (changed, revoked)
    }

    // MARK: The shared token

    /// A client connected with the shared token and may still need a token of its own.
    mutating func sighted(name: String, host: String?, now: Double) {
        let key = Self.key(name: name, host: host)
        if let index = legacy.firstIndex(where: { $0.id == key }) {
            legacy[index].lastSeen = now
        } else {
            legacy.append(FleetLegacySighting(id: key, name: name, lastSeen: now))
        }
    }

    /// The client at `key` has a token of its own now.
    @discardableResult
    mutating func switched(name: String, host: String?) -> Bool {
        let key = Self.key(name: name, host: host)
        let before = legacy.count
        legacy.removeAll { $0.id == key }
        return legacy.count != before
    }

    @discardableResult
    mutating func forget(legacy key: String) -> Bool {
        let before = legacy.count
        legacy.removeAll { $0.id == key }
        return legacy.count != before
    }

    /// Clients seen on the shared token within `sightingLifetime` that haven't switched.
    func waiting(now: Double) -> [FleetLegacySighting] {
        legacy.filter { now - $0.lastSeen < Self.sightingLifetime * 1000 }.sorted { ($0.name, $0.id) < ($1.name, $1.id) }
    }

    static func key(name: String, host: String?) -> String { "\(name)@\(host ?? "")" }
}
