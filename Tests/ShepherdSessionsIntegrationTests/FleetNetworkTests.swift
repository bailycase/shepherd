import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
import ShepherdTestSupport

/// The addresses this Mac reports of itself, read from the system's own interfaces and configuration.
@Suite("Fleet network", .integrationTimeLimit)
struct FleetNetworkTests {
    @Test func thisMacReportsOnlyWaysToReachIt() {
        let routes = FleetAddresses.reportable()
        #expect(FleetRouteReport(port: 7434, routes: routes).isValid, "everything it reports is something a peer accepts")
        #expect(Set(routes.map(\.host)).count == routes.count, "each once")
        for route in routes where route.kind != .hostname {
            #expect(route.host != "127.0.0.1" && route.host != "::1" && !route.host.hasPrefix("169.254.") && !route.host.lowercased().hasPrefix("fe80"),
                    "\(route.host) can't reach this Mac")
        }
        // IPv4 comes in the order a peer tries it: LAN addresses, then names, then Tailscale, then other tunnels.
        let rank: [FleetRouteKind: Int] = [.lan: 0, .hostname: 1, .tailscale: 2, .vpn: 3]
        let ranks = routes.filter { !$0.host.contains(":") }.map { rank[$0.kind]! }
        #expect(ranks == ranks.sorted())
    }

    @Test func theSystemNetworkSaysWhenItChangesAndStopsWhenAsked() {
        let stop = FleetNetwork.system.watch { }
        stop()
        #expect(FleetNetwork.silent.routes().isEmpty)
    }
}
