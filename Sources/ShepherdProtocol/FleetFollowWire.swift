import Foundation

// A phone or an iPad that is paired with any Mac of a fleet keeps up with the fleet's Macs (`RemoteProtocol.fleetFollowCapability`).

/// One Mac of a fleet as a client is told of it (`FleetSnapshot.members`): who it is and every way the Mac that answers knows to reach
/// it, most useful first, all on its listener's `port`. The client matches by `hostID`, never by an address.
public struct FleetViewMember: Codable, Hashable, Sendable {
    public var hostID: UUID
    public var name: String
    public var port: UInt16
    public var routes: [FleetReportedRoute]

    public init(hostID: UUID, name: String, port: UInt16, routes: [FleetReportedRoute] = []) {
        self.hostID = hostID
        self.name = name
        self.port = port
        self.routes = routes
    }

    private enum CodingKeys: String, CodingKey { case hostID, name, port, routes }

    /// Routes decode with a default, so a Mac that names none is still listed.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hostID = try c.decode(UUID.self, forKey: .hostID)
        name = try c.decode(String.self, forKey: .name)
        port = try c.decode(UInt16.self, forKey: .port)
        routes = (try? c.decodeIfPresent([FleetReportedRoute].self, forKey: .routes)) ?? []
    }

    /// Macs a view lists, and a client reads at most this many.
    public static let maxMembers = 64

    /// A member a client may act on: a real port, a bounded list, and hosts that are one word of address or name characters.
    public var isValid: Bool {
        port > 0 && routes.count <= FleetRouteReport.maxRoutes && routes.allSatisfy { FleetRouteReport.isHost($0.host) }
    }
}
