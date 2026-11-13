import Darwin
import Foundation
import ShepherdProtocol
import SystemConfiguration

/// What this Mac knows of its own network, for the routes it reports to the Macs it is linked to (`FleetRouteReport`): every way it
/// can be reached now, and when that changes. Tests replace it with a Mac whose addresses they set.
struct FleetNetwork: Sendable {
    /// Every address and name this Mac can be reached at, in the order it would have them tried.
    var routes: @Sendable () -> [FleetReportedRoute]
    /// Calls `onChange` (from any thread) when an interface comes or goes or its address changes. Returns what stops it.
    var watch: @Sendable (_ onChange: @escaping @Sendable () -> Void) -> @Sendable () -> Void

    /// The system's: the interfaces' addresses, this Mac's names, and the system configuration's notice of a change in either.
    static let system = FleetNetwork(routes: { FleetAddresses.reportable() }, watch: { onChange in
        let watcher = InterfaceWatcher(onChange)
        return { watcher.stop() }
    })

    /// A Mac that reports nothing and never changes.
    static let silent = FleetNetwork(routes: { [] }, watch: { _ in {} })
}

/// The system configuration's notice that an interface's address changed (Wi-Fi to Ethernet, a VPN or Tailscale coming up, a new lease).
private final class InterfaceWatcher: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shepherd.fleet.network")
    private let onChange: @Sendable () -> Void
    private var store: SCDynamicStore?

    init(_ onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        guard let store = SCDynamicStoreCreate(nil, "Shepherd Fleet" as CFString, { _, _, info in
            guard let info else { return }
            Unmanaged<InterfaceWatcher>.fromOpaque(info).takeUnretainedValue().onChange()
        }, &context) else { return }
        let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6"] as CFArray
        let patterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6", "State:/Network/Interface/.*/Link"] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, keys, patterns), SCDynamicStoreSetDispatchQueue(store, queue) else { return }
        self.store = store
    }

    func stop() {
        guard let store else { return }
        SCDynamicStoreSetDispatchQueue(store, nil)
        self.store = nil
    }

    deinit { stop() }
}

extension FleetAddresses {
    /// Every way this Mac can be reached: its LAN IPv4 addresses, its `.local` and DNS names, its Tailscale address, its other tunnel
    /// addresses and its global IPv6 ones, each once. Loopback, link-local and the interfaces that only reach this Mac's own
    /// guests or neighbours (AirDrop, bridges) are left out.
    static func reportable() -> [FleetReportedRoute] {
        var lan: [String] = [], tailscale: [String] = [], vpn: [String] = [], v6: [String] = []
        var list: UnsafeMutablePointer<ifaddrs>?
        if getifaddrs(&list) == 0, let first = list {
            for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
                let entry = pointer.pointee
                guard let sockaddr = entry.ifa_addr, Int32(entry.ifa_flags) & IFF_UP != 0, Int32(entry.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
                let interface = String(cString: entry.ifa_name)
                guard !isNoise(interface), let address = numeric(sockaddr) else { continue }
                let tunnel = isTunnel(interface)
                switch Int32(sockaddr.pointee.sa_family) {
                case AF_INET where !address.hasPrefix("169.254."):
                    switch (tunnel, FleetRoute.kind(ofAddress: address)) {
                    case (true, .tailscale): tailscale.append(address)
                    case (true, _): vpn.append(address)
                    default: lan.append(address)
                    }
                case AF_INET6 where !isLinkLocal(sockaddr):
                    if !tunnel { v6.append(address) } else { vpn.append(address) }
                default: break
                }
            }
            freeifaddrs(list)
        }
        func unique(_ list: [String]) -> [String] { var seen = Set<String>(); return list.filter { seen.insert($0).inserted } }
        // Interface order is the system's: Wi-Fi and Ethernet (en0, en1…) first.
        let routes = unique(lan).map { FleetReportedRoute(host: $0, kind: .lan) }
            + names().map { FleetReportedRoute(host: $0, kind: .hostname) }
            + unique(tailscale).map { FleetReportedRoute(host: $0, kind: .tailscale) }
            + unique(vpn).map { FleetReportedRoute(host: $0, kind: .vpn) }
            + unique(v6).map { FleetReportedRoute(host: $0, kind: .lan) }
        return Array(routes.filter { FleetRouteReport.isHost($0.host) }.prefix(FleetRouteReport.maxRoutes))
    }

    /// This Mac's `.local` name and the DNS name its host name carries, if it has one. Read from the system's configuration and the host
    /// name, never resolved, so it doesn't wait on a network.
    static func names() -> [String] {
        var found: [String] = []
        if let local = SCDynamicStoreCopyLocalHostName(nil) as String?, !local.isEmpty { found.append(local.lowercased() + ".local") }
        var buffer = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        if gethostname(&buffer, buffer.count - 1) == 0 {
            let name = String(cString: buffer).lowercased()
            if name.contains("."), !found.contains(name) { found.append(name) }
        }
        return found
    }

    /// Interfaces whose addresses nobody else can reach this Mac at: AirDrop and other peer-to-peer links, bridges to this Mac's
    /// guests (virtual machines, Internet Sharing), packet tap and tunnel stubs.
    private static func isNoise(_ interface: String) -> Bool {
        ["awdl", "llw", "anpi", "ap", "bridge", "gif", "stf", "XHC", "vmenet", "vnic"].contains { interface.hasPrefix($0) }
    }

    private static func isTunnel(_ interface: String) -> Bool {
        ["utun", "ipsec", "ppp", "tun", "tap"].contains { interface.hasPrefix($0) }
    }

    private static func isLinkLocal(_ address: UnsafePointer<sockaddr>) -> Bool {
        address.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            var bytes = $0.pointee.sin6_addr
            return withUnsafeBytes(of: &bytes) { $0[0] == 0xfe && $0[1] & 0xc0 == 0x80 }
        }
    }
}
