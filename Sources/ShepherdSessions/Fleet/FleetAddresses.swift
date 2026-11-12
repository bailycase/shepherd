import Darwin
import Foundation

/// The addresses a Mac is reachable at: for the join panel's text, so a person can tell whether a
/// Mac that discovery can't see is unreachable or just not discovered.
enum FleetAddresses {
    /// This Mac's IPv4 addresses on interfaces that are up, Wi-Fi and Ethernet first, loopback and
    /// link-local ones left out.
    static func local() -> [String] {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return [] }
        defer { freeifaddrs(list) }
        var found: [(name: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard let sockaddr = entry.ifa_addr, sockaddr.pointee.sa_family == sa_family_t(AF_INET),
                  Int32(entry.ifa_flags) & IFF_UP != 0, Int32(entry.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            if let address = numeric(sockaddr), !address.hasPrefix("169.254.") {
                found.append((String(cString: entry.ifa_name), address))
            }
        }
        // en0, en1… before tunnels (Tailscale, VPNs), each group in interface order.
        return found.sorted { ($0.name.hasPrefix("en") ? 0 : 1, $0.name) < ($1.name.hasPrefix("en") ? 0 : 1, $1.name) }.map(\.address)
    }

    /// The numeric host of a socket address (an accepted connection's peer, an interface's).
    static func numeric(_ address: UnsafePointer<sockaddr>) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        guard getnameinfo(address, socklen_t(address.pointee.sa_len), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else { return nil }
        return String(cString: buffer)
    }

    /// The remote end of a connected socket as text, without a port.
    static func peerHost(of fd: Int32) -> String? {
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let result = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &length) }
        }
        guard result == 0 else { return nil }
        return withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { numeric($0) }
        }
    }
}
