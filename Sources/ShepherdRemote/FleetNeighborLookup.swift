import Darwin
import Foundation
import dnssd

/// Finds the addresses of devices that announce one of Apple's own Bonjour types, without
/// connecting to any of them: browse the type, resolve each service to its host name, and ask for
/// that name's IPv4 addresses. It is `DNSServiceBrowse`, `DNSServiceResolve` and
/// `DNSServiceGetAddrInfo` only: nothing is sent to the device. `FleetBrowser` uses it for the
/// networks that pass `_ssh._tcp` and the like but not `_shepherd._tcp`.
final class FleetNeighborLookup: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shepherd.fleet.lookup")
    private let found: @Sendable (String) -> Void
    // Everything below belongs to `queue`.
    private var browses: [DNSServiceRef] = []
    private var resolves: [String: DNSServiceRef] = [:]
    private var lookups: [String: DNSServiceRef] = [:]
    private var stopped = false

    /// `found` hears each IPv4 address on a private queue, and may hear one again.
    init(found: @escaping @Sendable (String) -> Void) {
        self.found = found
    }

    deinit { stop() }

    func start(types: [String]) {
        queue.sync {
            guard !stopped else { return }
            for type in types {
                var ref: DNSServiceRef?
                let status = DNSServiceBrowse(&ref, 0, 0, type, nil, Self.browseReply, Unmanaged.passUnretained(self).toOpaque())
                guard status == kDNSServiceErr_NoError, let ref else { continue }
                DNSServiceSetDispatchQueue(ref, queue)
                browses.append(ref)
            }
        }
    }

    func stop() {
        queue.sync {
            stopped = true
            for ref in browses + Array(resolves.values) + Array(lookups.values) { DNSServiceRefDeallocate(ref) }
            browses = []
            resolves = [:]
            lookups = [:]
        }
    }

    // MARK: Callbacks (all on `queue`)

    private static let browseReply: DNSServiceBrowseReply = { _, flags, interface, error, name, type, domain, context in
        guard error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0,
              let context, let name, let type, let domain else { return }
        Unmanaged<FleetNeighborLookup>.fromOpaque(context).takeUnretainedValue()
            .resolve(name: String(cString: name), type: String(cString: type), domain: String(cString: domain), interface: interface)
    }

    private static let resolveReply: DNSServiceResolveReply = { _, _, interface, error, _, host, _, _, _, context in
        guard error == kDNSServiceErr_NoError, let context, let host else { return }
        Unmanaged<FleetNeighborLookup>.fromOpaque(context).takeUnretainedValue().resolved(host: String(cString: host), interface: interface)
    }

    private static let addressReply: DNSServiceGetAddrInfoReply = { _, flags, _, error, _, address, _, context in
        guard error == kDNSServiceErr_NoError, flags & kDNSServiceFlagsAdd != 0, let context, let address,
              address.pointee.sa_family == sa_family_t(AF_INET) else { return }
        let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var raw = ip
        guard inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil else { return }
        Unmanaged<FleetNeighborLookup>.fromOpaque(context).takeUnretainedValue().found(String(cString: buffer))
    }

    private func resolve(name: String, type: String, domain: String, interface: UInt32) {
        let key = "\(name)|\(type)|\(domain)|\(interface)"
        guard !stopped, resolves[key] == nil else { return }
        var ref: DNSServiceRef?
        let status = DNSServiceResolve(&ref, 0, interface, name, type, domain, Self.resolveReply, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        resolves[key] = ref
    }

    private func resolved(host: String, interface: UInt32) {
        let key = "\(host)|\(interface)"
        guard !stopped, lookups[key] == nil else { return }
        var ref: DNSServiceRef?
        let status = DNSServiceGetAddrInfo(&ref, 0, interface, DNSServiceProtocol(kDNSServiceProtocol_IPv4), host,
                                           Self.addressReply, Unmanaged.passUnretained(self).toOpaque())
        guard status == kDNSServiceErr_NoError, let ref else { return }
        DNSServiceSetDispatchQueue(ref, queue)
        lookups[key] = ref
    }
}
