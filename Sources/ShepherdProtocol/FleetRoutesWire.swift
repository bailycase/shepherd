import Foundation

// Links and routes (`RemoteProtocol.fleetLinkCapability`): a pair of Macs holds one authenticated connection whichever
// of them opened it, and each Mac tells the other every way it can be reached.

/// How a route to a Mac is reached, for the words on the Fleet page and for the order a Mac prefers.
public enum FleetRouteKind: String, Codable, Hashable, Sendable {
    /// An address on a network interface the Mac is on (Wi-Fi, Ethernet).
    case lan
    /// An address in Tailscale's 100.64.0.0/10 on a tunnel interface.
    case tailscale
    /// An address on any other tunnel interface.
    case vpn
    /// A name: the Mac's `.local` name or a DNS name it has.
    case hostname

    /// "LAN", "Tailscale", "VPN" and "name": what the Fleet page says after the address.
    public var label: String {
        switch self {
        case .lan: "LAN"
        case .tailscale: "Tailscale"
        case .vpn: "VPN"
        case .hostname: "name"
        }
    }
}

/// One way a Mac says it can be reached: an address or a name, and what kind of route that is. The port is the
/// listener's, which the report carries once.
public struct FleetReportedRoute: Codable, Hashable, Sendable {
    public var host: String
    public var kind: FleetRouteKind

    public init(host: String, kind: FleetRouteKind) {
        self.host = host
        self.kind = kind
    }
}

/// Every way a Mac can be reached now (`RemoteRequest.fleetRoutes`), in the order it would have them tried. A new report
/// replaces the last: a route that is no longer in it is gone.
public struct FleetRouteReport: Codable, Hashable, Sendable {
    public var port: UInt16
    public var routes: [FleetReportedRoute]

    public init(port: UInt16, routes: [FleetReportedRoute]) {
        self.port = port
        self.routes = routes
    }

    /// Routes a report may hold, and the longest host in one.
    public static let maxRoutes = 32
    public static let maxHostBytes = 253

    /// Whether the report is something a Mac could have made: a port, a bounded list, and hosts that are one word of
    /// address or name characters (never a space, a slash or a scheme).
    public var isValid: Bool {
        port > 0 && routes.count <= Self.maxRoutes && routes.allSatisfy { Self.isHost($0.host) }
    }

    public static func isHost(_ host: String) -> Bool {
        guard !host.isEmpty, host.utf8.count <= maxHostBytes else { return false }
        return host.unicodeScalars.allSatisfy { $0.isASCII && ($0.properties.isAlphabetic || ("0"..."9").contains($0) || ".-:_%".unicodeScalars.contains($0)) }
    }
}

/// How the host reaches a peer now, for the Fleet page (`FleetPeerStatus.reach`).
public struct FleetPeerReach: Codable, Hashable, Sendable {
    /// The route the host's own connection runs on; nil when it has none.
    public var host: String?
    public var kind: FleetRouteKind?
    /// Only the other Mac can dial: the host talks to it over the connection it opened.
    public var viaItsLink: Bool

    public init(host: String? = nil, kind: FleetRouteKind? = nil, viaItsLink: Bool = false) {
        self.host = host
        self.kind = kind
        self.viaItsLink = viaItsLink
    }
}
