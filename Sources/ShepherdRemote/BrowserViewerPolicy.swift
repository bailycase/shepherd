import Darwin
import Foundation
import ShepherdProtocol

// Where an agent on another Mac may take a viewer's web view (docs/browser.md › Remote › What a
// host's agent can make this Mac do). A host's agent drives a page that renders on the *viewer's* Mac,
// so a `browser_open` there must not become a way into the viewer's own network: an address is served
// only when it is this thread's host (`localhost`, `127.0.0.1` and `::1`, which the viewer's forwarded
// ports carry to the host) or a public one. Everything else is refused: private ranges (RFC 1918,
// link-local, CGNAT, unique-local, the reserved blocks), the viewer's own loopback under any other
// spelling, its own interface addresses, `.local` and other local-network names, single-label names,
// and a hostname that resolves to any of those. It is pure but for the injected resolver, so it is
// tested as a table, and it is shared with the iOS client.

/// What the viewer makes of an address a host's agent asked for.
public enum BrowserViewerVerdict: Equatable, Sendable {
    /// `about:blank`, `blob:` and `data:` documents, which reach nothing.
    case inert
    /// A public address: loads from the viewer as any web page does.
    case web
    /// The thread's host, by its loopback: the viewer forwards `port` to it.
    case host(port: Int)
    case refused(BrowserViewerRefusal)

    public var isAllowed: Bool {
        if case .refused = self { return false }
        return true
    }
}

public enum BrowserViewerRefusal: Equatable, Sendable {
    /// A scheme other than http, https and `about:blank` (`file:`, `javascript:`, a custom one).
    case scheme(String)
    /// Not an address: no host, or a host that does not parse.
    case invalid
    /// The viewer's own loopback under a spelling the host's forwarded ports do not carry
    /// (`127.0.0.2`, `0.0.0.0`, `[::ffff:127.0.0.1]`, `localhost.`, `foo.localhost`).
    case viewerLoopback
    /// A private, link-local, carrier-grade NAT, unique-local or reserved address, or a name that is
    /// only ever a local network's (`.local`, `printer`).
    case privateNetwork
    /// One of the viewer's own interface addresses.
    case viewerAddress
    /// A hostname that resolves to one of the above, which it names.
    case resolvesPrivately(address: String)
    /// A hostname that does not resolve.
    case unresolved

    /// The tool error the agent reads.
    public var message: String {
        switch self {
        case .scheme(let scheme):
            "\(scheme): URLs can't be opened in the browser. browser_open takes http: and https: URLs and about:blank."
        case .invalid:
            "That is not an address the browser can open. Give an http: or https: URL such as http://localhost:5173/."
        case .viewerLoopback, .privateNetwork, .viewerAddress, .resolvesPrivately:
            "That address is on the network of the Mac showing this page, not this host's, so the browser won't open it. "
                + "Use localhost for a port on this host, or a public address."
        case .unresolved:
            "That address could not be resolved. Give a public address, or localhost for a port on this host."
        }
    }
}

public final class BrowserViewerPolicy: @unchecked Sendable {
    /// The addresses a name resolves to, as numeric text, or nil when it could not be resolved.
    public typealias Resolver = @Sendable (String) async -> [String]?
    /// The viewer's own interface addresses, as 4 or 16 bytes each.
    public typealias LocalAddresses = @Sendable () -> [[UInt8]]

    private let resolve: Resolver
    private let localAddresses: LocalAddresses
    private let cacheSeconds: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var cache: [String: (verdict: BrowserViewerVerdict, expires: Date)] = [:]

    public init(resolver: @escaping Resolver = BrowserViewerPolicy.systemResolver,
                localAddresses: @escaping LocalAddresses = BrowserViewerPolicy.systemAddresses,
                cacheSeconds: TimeInterval = 30, now: @escaping @Sendable () -> Date = { Date() }) {
        resolve = resolver
        self.localAddresses = localAddresses
        self.cacheSeconds = cacheSeconds
        self.now = now
    }

    // MARK: Verdicts

    /// What a page's address is to the viewer: the agent's `browser_open`, and a main-frame
    /// navigation (a redirect included) while the agent drives the page.
    public func verdict(for url: URL) async -> BrowserViewerVerdict {
        await verdict(for: url, subframe: false)
    }

    /// The same for an iframe's navigation: a document with no address of its own (`about:srcdoc`,
    /// `blob:`, `data:`) reaches nothing, so it is let through.
    public func subframeVerdict(for url: URL) async -> BrowserViewerVerdict {
        await verdict(for: url, subframe: true)
    }

    /// What the page open now is, for whether the agent may read or act on it: no page, and a
    /// `blob:` page (by the address it was made for), included.
    public func pageVerdict(for url: URL?) async -> BrowserViewerVerdict {
        guard let url else { return .inert }
        if url.scheme?.lowercased() == "blob" {
            guard let inner = URL(string: String(url.absoluteString.dropFirst("blob:".count))) else { return .refused(.invalid) }
            return await verdict(for: inner, subframe: false)
        }
        return await verdict(for: url, subframe: false)
    }

    private func verdict(for url: URL, subframe: Bool) async -> BrowserViewerVerdict {
        guard let scheme = url.scheme?.lowercased() else { return .refused(.invalid) }
        switch scheme {
        case "about":
            if url.absoluteString.lowercased() == "about:blank" || subframe { return .inert }
            return .refused(.scheme(scheme))
        case "blob", "data":
            return subframe ? .inert : .refused(.scheme(scheme))
        case "http", "https":
            break
        default:
            return .refused(.scheme(scheme))
        }
        guard let host = url.host, !host.isEmpty else { return .refused(.invalid) }
        switch Self.parse(host: host) {
        case nil:
            return .refused(.invalid)
        case .ipv4(let bytes)?:
            return literal(Self.classify(ipv4: bytes), bytes: bytes, url: url)
        case .ipv6(let bytes)?:
            return literal(Self.classify(ipv6: bytes), bytes: bytes, url: url)
        case .name(let name)?:
            return await named(name, url: url)
        }
    }

    /// An address the URL spells out.
    private func literal(_ kind: AddressClass, bytes: [UInt8], url: URL) -> BrowserViewerVerdict {
        switch kind {
        case .loopback:
            // The host's loopback is carried by the forwarded port, and only as the spellings the
            // forwarder knows; 127.0.0.2 and the rest are this Mac's own.
            guard let port = BrowserTunnelTarget.port(of: url) else { return .refused(.viewerLoopback) }
            return .host(port: port)
        case .viewerLoopback: return .refused(.viewerLoopback)
        case .nonPublic: return .refused(.privateNetwork)
        case .global:
            return localAddresses().contains(bytes) ? .refused(.viewerAddress) : .web
        }
    }

    private func named(_ name: String, url: URL) async -> BrowserViewerVerdict {
        if name == "localhost" {
            guard let port = BrowserTunnelTarget.port(of: url) else { return .refused(.viewerLoopback) }
            return .host(port: port)
        }
        if let refusal = Self.refusal(forName: name) { return .refused(refusal) }
        if let cached = cached(name) { return cached }
        let verdict = await resolved(name)
        store(verdict, for: name)
        return verdict
    }

    /// A name that is only ever this Mac's, or a local network's, whatever it resolves to.
    static func refusal(forName name: String) -> BrowserViewerRefusal? {
        let bare = name.hasSuffix(".") ? String(name.dropLast()) : name
        if bare == "localhost" || bare.hasSuffix(".localhost") { return .viewerLoopback }
        if !bare.contains(".") { return .privateNetwork }
        for suffix in ["local", "localdomain", "internal", "lan", "home", "home.arpa", "intranet", "corp", "private"]
        where bare == suffix || bare.hasSuffix("." + suffix) {
            return .privateNetwork
        }
        return nil
    }

    private func resolved(_ name: String) async -> BrowserViewerVerdict {
        guard let found = await resolve(name), !found.isEmpty else { return .refused(.unresolved) }
        let own = localAddresses()
        for text in found {
            guard let parsed = Self.parse(host: text) else { return .refused(.resolvesPrivately(address: text)) }
            switch parsed {
            case .ipv4(let bytes):
                if Self.classify(ipv4: bytes) != .global || own.contains(bytes) { return .refused(.resolvesPrivately(address: text)) }
            case .ipv6(let bytes):
                if Self.classify(ipv6: bytes) != .global || own.contains(bytes) { return .refused(.resolvesPrivately(address: text)) }
            case .name:
                return .refused(.resolvesPrivately(address: text))
            }
        }
        return .web
    }

    private func cached(_ name: String) -> BrowserViewerVerdict? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = cache[name], entry.expires > now() else { return nil }
        return entry.verdict
    }

    private func store(_ verdict: BrowserViewerVerdict, for name: String) {
        lock.lock()
        defer { lock.unlock() }
        if cache.count >= 128 { cache.removeAll() }
        cache[name] = (verdict, now().addingTimeInterval(cacheSeconds))
    }

    // MARK: Addresses

    /// What an address is, for whether a page may load from it.
    enum AddressClass: Equatable {
        /// `127.0.0.1` and `::1`: the thread's host, through the forwarded port.
        case loopback
        /// The rest of this Mac's own loopback, and the unspecified address.
        case viewerLoopback
        /// Private, link-local, shared, documentation, multicast and every other block that is not
        /// the public internet.
        case nonPublic
        /// A public address.
        case global
    }

    enum ParsedHost: Equatable {
        case ipv4([UInt8])
        case ipv6([UInt8])
        case name(String)
    }

    static func classify(ipv4 b: [UInt8]) -> AddressClass {
        guard b.count == 4 else { return .nonPublic }
        switch (b[0], b[1], b[2]) {
        case (127, 0, 0) where b[3] == 1: return .loopback
        case (127, _, _), (0, _, _): return .viewerLoopback
        case (10, _, _): return .nonPublic
        case (172, 16...31, _): return .nonPublic
        case (192, 168, _): return .nonPublic
        case (169, 254, _): return .nonPublic
        case (100, 64...127, _): return .nonPublic
        case (192, 0, 0), (192, 0, 2), (198, 51, 100), (203, 0, 113), (192, 88, 99): return .nonPublic
        case (198, 18...19, _): return .nonPublic
        case (224...255, _, _): return .nonPublic
        default: return .global
        }
    }

    static func classify(ipv6 b: [UInt8]) -> AddressClass {
        guard b.count == 16 else { return .nonPublic }
        if b.dropLast().allSatisfy({ $0 == 0 }) {
            // ::1 is the loopback; :: is the unspecified address, which connects to it.
            return b[15] == 1 ? .loopback : b[15] == 0 ? .viewerLoopback : .nonPublic
        }
        // An IPv4 address carried in an IPv6 one is classified as the IPv4 address it is, and a
        // mapped loopback is never the host's.
        if b[0..<10].allSatisfy({ $0 == 0 }), b[10] == 0xff, b[11] == 0xff {
            let v4 = classify(ipv4: Array(b[12..<16]))
            return v4 == .loopback ? .viewerLoopback : v4
        }
        if b[0..<12] == [0x00, 0x64, 0xff, 0x9b, 0, 0, 0, 0, 0, 0, 0, 0] {
            let v4 = classify(ipv4: Array(b[12..<16]))
            return v4 == .global ? .global : .nonPublic
        }
        if b[0] == 0x20, b[1] == 0x02 {
            let v4 = classify(ipv4: Array(b[2..<6]))
            return v4 == .global ? .global : .nonPublic
        }
        // Only global unicast (2000::/3) is public, less the documentation block (2001:db8::/32) and
        // Teredo (2001::/32).
        guard b[0] & 0xe0 == 0x20 else { return .nonPublic }
        if b[0] == 0x20, b[1] == 0x01, (b[2] == 0x0d && b[3] == 0xb8) || (b[2] == 0 && b[3] == 0) { return .nonPublic }
        return .global
    }

    /// A URL's host as WebKit reads it: an IPv6 literal, an IPv4 address in any of the forms a URL
    /// takes (`0x7f.1`, `2130706433`, `0177.0.0.1`), or a name. Nil for what is none of those.
    static func parse(host raw: String) -> ParsedHost? {
        var host = raw.lowercased()
        if host.hasPrefix("["), host.hasSuffix("]") { host = String(host.dropFirst().dropLast()) }
        if let zone = host.firstIndex(of: "%") { host = String(host[..<zone]) }
        guard !host.isEmpty else { return nil }
        if host.contains(":") {
            var address = in6_addr()
            guard inet_pton(AF_INET6, host, &address) == 1 else { return nil }
            return .ipv6(withUnsafeBytes(of: &address) { Array($0) })
        }
        var parts = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if parts.count > 1, parts.last == "" { parts.removeLast() }
        guard let last = parts.last, !last.isEmpty else { return nil }
        // A host whose last label is a number is an IPv4 address or nothing.
        guard endsInANumber(last) else { return .name(host) }
        guard parts.count <= 4 else { return nil }
        var numbers: [UInt64] = []
        for part in parts {
            guard let value = number(part) else { return nil }
            numbers.append(value)
        }
        let rest = numbers.dropLast()
        guard rest.allSatisfy({ $0 <= 255 }), let tail = numbers.last else { return nil }
        let room = UInt64(1) << (8 * UInt64(5 - numbers.count))
        guard tail < room else { return nil }
        var value = tail
        for (index, octet) in rest.enumerated() { value += octet << (8 * UInt64(3 - index)) }
        return .ipv4([UInt8(value >> 24 & 0xff), UInt8(value >> 16 & 0xff), UInt8(value >> 8 & 0xff), UInt8(value & 0xff)])
    }

    private static func endsInANumber(_ label: String) -> Bool {
        if label.allSatisfy(\.isASCII) && label.allSatisfy(\.isNumber) { return true }
        guard label.hasPrefix("0x") else { return false }
        return label.dropFirst(2).allSatisfy(\.isHexDigit)
    }

    private static func number(_ part: String) -> UInt64? {
        guard !part.isEmpty, part.allSatisfy(\.isASCII) else { return nil }
        if part.hasPrefix("0x") {
            let digits = part.dropFirst(2)
            return digits.isEmpty ? 0 : UInt64(digits, radix: 16)
        }
        if part.count > 1, part.hasPrefix("0") { return UInt64(part.dropFirst(), radix: 8) }
        return UInt64(part, radix: 10)
    }

    // MARK: The system

    /// Resolves `name` with the system's resolver (what WebKit's own lookup asks), off the caller's
    /// thread and for at most five seconds. Nil when it fails or takes longer.
    public static let systemResolver: Resolver = { name in
        await withTaskGroup(of: [String]?.self) { group in
            group.addTask {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: BrowserViewerPolicy.lookup(name)) }
                }
            }
            group.addTask {
                try? await Task.sleep(for: .seconds(5))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func lookup(_ name: String) -> [String]? {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var found: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(name, nil, &hints, &found) == 0, let head = found else { return nil }
        defer { freeaddrinfo(head) }
        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let entry = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(entry.pointee.ai_addr, entry.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                addresses.append(String(cString: buffer))
            }
            cursor = entry.pointee.ai_next
        }
        return addresses
    }

    /// Every address this Mac's interfaces hold.
    public static let systemAddresses: LocalAddresses = {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let head = list else { return [] }
        defer { freeifaddrs(head) }
        var addresses: [[UInt8]] = []
        var cursor: UnsafeMutablePointer<ifaddrs>? = head
        while let entry = cursor {
            if let sockaddr = entry.pointee.ifa_addr {
                switch Int32(sockaddr.pointee.sa_family) {
                case AF_INET:
                    sockaddr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin_addr
                        addresses.append(withUnsafeBytes(of: &address) { Array($0) })
                    }
                case AF_INET6:
                    sockaddr.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) { pointer in
                        var address = pointer.pointee.sin6_addr
                        addresses.append(withUnsafeBytes(of: &address) { Array($0) })
                    }
                default:
                    break
                }
            }
            cursor = entry.pointee.ifa_next
        }
        return addresses
    }
}
