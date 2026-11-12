import Foundation
import ShepherdProtocol

/// Fleet requests (`RemoteProtocol.fleetCapability`, `FleetWire.swift`). The host owns a client of
/// each peer Mac; the app owns one of its own host over `host.sock`.
extension RemoteHostClient {
    /// What a host answered to `fleetPair` or an introduction: who it is and the hash of the token
    /// it will present to the Mac that asked.
    public struct FleetPairing: Equatable, Sendable {
        public var hostID: UUID
        public var name: String
        public var myTokenHash: String
    }

    /// A Mac that identified itself without a token.
    public struct FleetPeerIdentity: Equatable, Sendable {
        public var hostID: UUID
        public var name: String
        public var build: String?
        public var fleetEnabled: Bool
    }

    /// Pairs with the Mac at `host`:`port` using the code its Join screen shows. The connection
    /// never authenticates: it asks who answers, refuses to go on when that isn't `expecting`
    /// (when given) or has Fleet off, and then sends the code with `introduction`. Closes when done.
    public static func fleetPair(host: String, port: UInt16, code: String, introduction: FleetIntroduction,
                                 expecting: UUID? = nil) async throws -> (pairing: FleetPairing, identity: FleetPeerIdentity) {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        try await client.openUnauthenticated(host: host, port: port)
        let identity = try await client.fleetIdentify()
        if let expecting, identity.hostID != expecting {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.wrongHost, message: "Another Mac answers at this address.")
        }
        guard identity.fleetEnabled else {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.off, message: "Fleet is off on that Mac.")
        }
        let reply = try await client.request { .fleetPair(id: $0, code: code, from: introduction) }
        return (try Self.pairing(from: reply), identity)
    }

    /// Who answers, asked before any `hello`.
    public func fleetIdentify() async throws -> FleetPeerIdentity {
        let reply = try await request { .fleetIdentify(id: $0) }
        switch reply {
        case .fleetIdentity(_, let hostID, let name, let build, let enabled):
            return FleetPeerIdentity(hostID: hostID, name: name, build: build, fleetEnabled: enabled)
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    /// Becomes a peer of the host this client authenticated to with the shared token.
    public func fleetEstablish(from introduction: FleetIntroduction) async throws -> FleetPairing {
        try Self.pairing(from: try await request { .fleetEstablish(id: $0, from: introduction) })
    }

    /// One step of introducing `introduction.member` to this host. Nil: the host already knows it.
    public func fleetIntroduce(_ introduction: FleetIntroduce) async throws -> FleetPairing? {
        let reply = try await request { .fleetIntroduce(id: $0, introduction: introduction) }
        if case .ok = reply { return nil }
        return try Self.pairing(from: reply)
    }

    /// Tells the host `hostID` left the fleet at `at` (epoch milliseconds).
    public func fleetRevoke(hostID: UUID, at: Double) async throws {
        try expectFleetOk(try await request { .fleetRevoke(id: $0, hostID: hostID, at: at) })
    }

    /// Pairs this device with the Mac at `host`:`port` using the code its Add a device screen shows. Like
    /// `fleetPair`, it asks who answers first and goes on only when that is `expecting` (when given) and
    /// (Fleet is not required). The answer lists the Macs in its fleet, none with Fleet off. Closes when done.
    public static func fleetPairDevice(host: String, port: UInt16, code: String, device: FleetDeviceIntroduction,
                                       expecting: UUID? = nil) async throws -> (result: FleetDevicesResult, identity: FleetPeerIdentity) {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        try await client.openUnauthenticated(host: host, port: port)
        let identity = try await client.fleetIdentify()
        // Fleet need not be on: a device pairs with a Mac that serves, whether or not it is in a fleet.
        if let expecting, identity.hostID != expecting {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.wrongHost, message: "Another Mac answers at this address.")
        }
        let reply = try await client.request { .fleetPairDevice(id: $0, code: code, device: device) }
        return (try Self.devices(from: reply), identity)
    }

    /// A client on the shared token asks for a token of its own (the host keeps only its hash).
    public func fleetEnrollDevice(_ device: FleetDeviceIntroduction) async throws -> FleetDevicesResult {
        try Self.devices(from: try await request { .fleetEnrollDevice(id: $0, device: device) })
    }

    /// Sends the devices this Mac holds to a member and reads back the ones it holds.
    public func fleetSyncDevices(_ devices: [FleetDeviceEntry]) async throws -> FleetDevicesResult {
        try Self.devices(from: try await request { .fleetSyncDevices(id: $0, devices: devices) })
    }

    private static func devices(from reply: RemoteReply) throws -> FleetDevicesResult {
        switch reply {
        case .fleetDevices(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    /// The fleet of the host on this Mac, as its app draws it (local socket only).
    public func fleetRead() async throws -> FleetResult {
        try Self.fleetResult(from: try await request { .fleetRead(id: $0) })
    }

    /// Asks the host on this Mac to act on its fleet (local socket only).
    public func fleetAction(_ action: FleetAction) async throws -> FleetResult {
        // A pairing includes a connection to another Mac and the introductions to every member.
        try Self.fleetResult(from: try await request(timeout: Self.fleetActionTimeout) { .fleetAction(id: $0, action: action) })
    }

    /// An action that reaches other Macs takes longer than a read.
    static let fleetActionTimeout: TimeInterval = 60

    private static func pairing(from reply: RemoteReply) throws -> FleetPairing {
        switch reply {
        case .fleetPaired(_, let hostID, let name, let hash): return FleetPairing(hostID: hostID, name: name, myTokenHash: hash)
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    private static func fleetResult(from reply: RemoteReply) throws -> FleetResult {
        switch reply {
        case .fleetResult(_, let result): return result
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    private func expectFleetOk(_ reply: RemoteReply) throws {
        switch reply {
        case .ok: return
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }
}
