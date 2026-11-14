import Foundation
import ShepherdCore
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
        /// False only from a Mac on a Shepherd from when Fleet was an experiment and was off.
        public var fleetEnabled: Bool
    }

    /// Pairs with the Mac at `host`:`port` using the code its Join screen shows. The connection
    /// never authenticates: it asks who answers, refuses to go on when that isn't `expecting`
    /// (when given) or runs an older Shepherd with Fleet off, and then sends the code with `introduction`. Closes when done. An address that
    /// doesn't answer within `connectTimeout` seconds is given up on.
    public static func fleetPair(host: String, port: UInt16, code: String, introduction: FleetIntroduction,
                                 expecting: UUID? = nil, connectTimeout: TimeInterval = 10) async throws -> (pairing: FleetPairing, identity: FleetPeerIdentity) {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        try await client.openUnauthenticated(host: host, port: port, timeout: connectTimeout)
        let identity = try await client.fleetIdentify()
        if let expecting, identity.hostID != expecting {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.wrongHost, message: "Another Mac answers at this address.")
        }
        guard identity.fleetEnabled else {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.off, message: "Fleet is turned off on that Mac. It runs an older Shepherd where Fleet is under Settings ▸ Experiments: turn it on there, or update it.")
        }
        let reply = try await client.request { .fleetPair(id: $0, code: code, from: introduction) }
        return (try Self.pairing(from: reply), identity)
    }

    /// Who answers, asked before any `hello`.
    public func fleetIdentify() async throws -> FleetPeerIdentity {
        try await fleetIdentify(timeout: Self.requestTimeout)
    }

    func fleetIdentify(timeout: TimeInterval) async throws -> FleetPeerIdentity {
        let reply = try await request(timeout: timeout) { .fleetIdentify(id: $0) }
        switch reply {
        case .fleetIdentity(_, let hostID, let name, let build, let enabled):
            return FleetPeerIdentity(hostID: hostID, name: name, build: build, fleetEnabled: enabled)
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    /// Asks whether Shepherd answers at `host`:`port`: one connection, one `fleetIdentify`, then it closes.
    /// Nil for anything else (nothing listens, a refusal, another service, no answer within `timeout`).
    /// Add a Mac uses it on devices that announce an Apple service type, to list the Macs Bonjour for
    /// `_shepherd._tcp` does not reach.
    public static func fleetProbe(host: String, port: UInt16, timeout: TimeInterval = 2) async -> FleetPeerIdentity? {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        do {
            try await client.openUnauthenticated(host: host, port: port, timeout: timeout)
            return try await client.fleetIdentify(timeout: timeout)
        } catch {
            return nil
        }
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
    /// (it need not have a Mac paired). The answer lists the Macs in its fleet. Closes when done.
    public static func fleetPairDevice(host: String, port: UInt16, code: String, device: FleetDeviceIntroduction,
                                       expecting: UUID? = nil) async throws -> (result: FleetDevicesResult, identity: FleetPeerIdentity) {
        let client = RemoteHostClient()
        defer { client.disconnect() }
        try await client.openUnauthenticated(host: host, port: port)
        let identity = try await client.fleetIdentify()
        // A device pairs with a Mac that serves, whether or not it has a Mac paired.
        if let expecting, identity.hostID != expecting {
            throw RemoteHostClientError.rejected(code: FleetProtocol.Code.wrongHost, message: "Another Mac answers at this address.")
        }
        let reply = try await client.request { .fleetPairDevice(id: $0, code: code, device: device) }
        return (try Self.devices(from: reply), identity)
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

    /// The fleet of the host on this Mac, as its app draws it (local socket). A phone or an iPad on a device token
    /// reads the same answer cut down to Macs, load and readiness (`fleet.view.v1`, `FleetSnapshot.clientView`).
    public func fleetRead() async throws -> FleetResult {
        try Self.fleetResult(from: try await request { .fleetRead(id: $0) })
    }

    /// Asks the host on this Mac to act on its fleet (local socket only). A client may send `.watching` to any host with `fleet.view.v1`.
    public func fleetAction(_ action: FleetAction) async throws -> FleetResult {
        // A pairing includes a connection to another Mac and the introductions to every member.
        try Self.fleetResult(from: try await request(timeout: Self.fleetActionTimeout) { .fleetAction(id: $0, action: action) })
    }

    /// Pushes this Mac's newest sample to the host this client authenticated to as a peer.
    public func fleetPressure(_ sample: FleetPressureSample) async throws {
        try expectFleetOk(try await request { .fleetPressure(id: $0, sample: sample) })
    }

    /// Pushes this Mac's readiness report to the host this client authenticated to as a peer.
    public func fleetReadiness(_ report: FleetReadinessReport) async throws {
        try expectFleetOk(try await request { .fleetReadiness(id: $0, report: report) })
    }

    /// Tells the peer every way this Mac can be reached now (`fleetLinkCapability`); the peer keeps them in place of the last report.
    public func fleetRoutes(_ report: FleetRouteReport) async throws {
        try expectFleetOk(try await request { .fleetRoutes(id: $0, report: report) })
    }

    /// Asks the peer for a sample now.
    public func fleetPressureNow() async throws -> (sample: FleetPressureSample, readiness: FleetReadinessReport?) {
        switch try await request({ .fleetPressureNow(id: $0) }) {
        case .fleetPressureSample(_, let sample, let readiness): return (sample, readiness)
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
    }

    /// Sends work to the Mac this client is linked to (`FleetDispatchCreate`). Answers with that Mac's record:
    /// `preparing` once it took the work, `waitingRoom` when it is full and kept nothing.
    public func fleetDispatchCreate(_ create: FleetDispatchCreate) async throws -> FleetDispatchRecord {
        try Self.dispatchRecord(from: try await request { .fleetDispatchCreate(id: $0, create: create) })
    }

    /// Asks the Mac a dispatch runs on about it, stops it, or messages its thread. Throws `unknown_dispatch`
    /// when that Mac holds no such dispatch.
    public func fleetDispatchControl(_ dispatchID: UUID, _ control: FleetDispatchControl) async throws -> FleetDispatchRecord {
        try Self.dispatchRecord(from: try await request { .fleetDispatchControl(id: $0, dispatchID: dispatchID, control: control) })
    }

    /// Tells the Mac that sent a dispatch how it stands.
    public func fleetDispatchChanged(_ record: FleetDispatchRecord) async throws {
        try expectFleetOk(try await request { .fleetDispatchChanged(id: $0, record: record) })
    }

    /// Hands the Mac that sent a dispatch the thread's result.
    public func fleetDispatchResult(_ dispatchID: UUID, text: String, branchFacts: FleetBranchFacts?) async throws {
        try expectFleetOk(try await request { .fleetDispatchResult(id: $0, dispatchID: dispatchID, text: text, branchFacts: branchFacts) })
    }

    private static func dispatchRecord(from reply: RemoteReply) throws -> FleetDispatchRecord {
        switch reply {
        case .fleetDispatchAccepted(_, let record), .fleetDispatchState(_, let record): return record
        case .error(_, let code, let message): throw RemoteHostClientError.rejected(code: code, message: message)
        default: throw RemoteHostClientError.rejected(code: "protocol", message: "unexpected fleet reply")
        }
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
