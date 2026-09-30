import CryptoKit
import Darwin
import Foundation
import ShepherdTestKit

/// A server on the loopback and an ephemeral port, standing in for a host's dev server in tunnel
/// tests: a blocking thread per connection over plain POSIX sockets, so what a test sees is the
/// bytes and nothing a framework did to them. It never leaves the machine and stops with the test.
///
/// `handler` gets each accepted socket on its own thread and owns it (it must close it). The
/// HTTP and WebSocket servers below are handlers.
public final class LoopbackServer: @unchecked Sendable {
    public enum Family { case ipv4, ipv6 }

    public let port: UInt16
    private let listenFD: Int32
    private let lock = NSLock()
    private var accepted: Set<Int32> = []
    private var stopped = false
    /// Connections accepted, ever.
    public let connections = Locked<Int>(0)

    /// `address` is an IPv4 address to listen on instead of the loopback, for a test that a tunnel
    /// reaches only the loopback.
    public init(family: Family = .ipv4, address: String? = nil, port requested: UInt16 = 0, handler: @escaping @Sendable (Int32) -> Void) throws {
        let domain = family == .ipv4 ? AF_INET : AF_INET6
        let listenAddress = address
        let fd = socket(domain, SOCK_STREAM, 0)
        guard fd >= 0 else { throw LoopbackError.system("socket") }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var bound: Int32
        if family == .ipv4 {
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = requested.bigEndian
            address.sin_addr = in_addr(s_addr: UInt32(0x7f00_0001).bigEndian)
            if let listenAddress {
                guard inet_pton(AF_INET, listenAddress, &address.sin_addr) == 1 else { throw LoopbackError.system("address") }
            }
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
        } else {
            var address = sockaddr_in6()
            address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            address.sin6_family = sa_family_t(AF_INET6)
            address.sin6_port = requested.bigEndian
            address.sin6_addr = in6addr_loopback
            bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) }
            }
        }
        guard bound == 0, listen(fd, 128) == 0 else {
            close(fd)
            throw LoopbackError.system("bind/listen")
        }
        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        _ = withUnsafeMutablePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        port = withUnsafePointer(to: &storage) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt16(bigEndian: $0.pointee.sin_port) }
        }
        listenFD = fd
        Thread.detachNewThread { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { return }
                var noSigpipe: Int32 = 1
                _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSigpipe, socklen_t(MemoryLayout<Int32>.size))
                lock.lock()
                let live = !stopped
                if live { accepted.insert(client) }
                lock.unlock()
                guard live else { close(client); return }
                connections.withValue { $0 += 1 }
                Thread.detachNewThread { handler(client) }
            }
        }
    }

    /// Stops listening and shuts every connection a handler may still be blocked on.
    public func stop() {
        lock.lock()
        stopped = true
        let open = accepted
        accepted.removeAll()
        lock.unlock()
        shutdown(listenFD, SHUT_RDWR)
        close(listenFD)
        for fd in open { shutdown(fd, SHUT_RDWR) }
    }

    public enum LoopbackError: Error { case system(String) }

    // MARK: Helpers for handlers

    /// Reads exactly `count` bytes, or nil at EOF.
    public static func readExactly(_ fd: Int32, _ count: Int) -> Data? {
        var data = Data(capacity: count)
        var buffer = [UInt8](repeating: 0, count: min(max(count, 1), 64 * 1024))
        while data.count < count {
            let n = read(fd, &buffer, min(buffer.count, count - data.count))
            if n <= 0 { return nil }
            data.append(buffer, count: n)
        }
        return data
    }

    /// Writes all of `data`; false if the peer went away.
    @discardableResult
    public static func writeAll(_ fd: Int32, _ data: Data) -> Bool {
        var offset = 0
        while offset < data.count {
            let n = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, data.count - offset) }
            if n <= 0 { return false }
            offset += n
        }
        return true
    }

    /// Reads a request head (through the blank line) and whatever followed it in the same reads.
    public static func readHead(_ fd: Int32) -> (head: String, rest: Data)? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 16 * 1024)
        let terminator = Data("\r\n\r\n".utf8)
        while data.range(of: terminator) == nil {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { return nil }
            data.append(buffer, count: n)
            if data.count > 256 * 1024 { return nil }
        }
        let end = data.range(of: terminator)!.upperBound
        return (String(decoding: data[data.startIndex..<end], as: UTF8.self), Data(data[end...]))
    }
}

// MARK: A dev server

/// What a dev server answers, for tunnel tests. One request per connection unless the connection
/// upgrades to a WebSocket, which echoes every message.
///
///     GET  /hello        "hello from the host"
///     GET  /bytes?n=N    N bytes, byte i being i % 251
///     POST /sum          the body's length and SHA-256, however large the body
///     GET  /cookie       the request's Cookie header, and sets `sid=<value of ?set=>`
///     GET  /page         a page that loads /asset.js, which sets the title
///     GET  /asset.js     a script
///     GET  /ws           upgrades to a WebSocket that echoes text and binary frames
public final class DevServerFixture: @unchecked Sendable {
    public let server: LoopbackServer
    public var port: UInt16 { server.port }
    /// Request lines seen, in order.
    public let requests = Locked<[String]>([])

    /// `port` binds a port chosen beforehand (a dev server that comes up later); 0 takes a free one.
    public init(family: LoopbackServer.Family = .ipv4, port: UInt16 = 0) throws {
        let requests = requests
        server = try LoopbackServer(family: family, port: port) { fd in
            defer { close(fd) }
            guard let (head, rest) = LoopbackServer.readHead(fd) else { return }
            let lines = head.components(separatedBy: "\r\n")
            let requestLine = lines[0]
            requests.withValue { $0.append(requestLine) }
            let parts = requestLine.split(separator: " ")
            guard parts.count >= 2 else { return }
            let method = String(parts[0])
            let target = String(parts[1])
            var headers: [String: String] = [:]
            for line in lines.dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            }
            let path = String(target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)[0])
            let query = target.contains("?") ? String(target.split(separator: "?", maxSplits: 1)[1]) : ""

            func respond(_ status: String = "200 OK", type: String = "text/plain", headers extra: [String] = [], body: Data) {
                var out = "HTTP/1.1 \(status)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\n"
                for header in extra { out += header + "\r\n" }
                out += "\r\n"
                LoopbackServer.writeAll(fd, Data(out.utf8) + body)
            }

            switch (method, path) {
            case ("GET", "/hello"):
                respond(body: Data("hello from the host".utf8))
            case ("GET", "/bytes"):
                let n = Int(query.replacingOccurrences(of: "n=", with: "")) ?? 0
                respond(type: "application/octet-stream", body: Data((0..<n).map { UInt8($0 % 251) }))
            case ("POST", "/sum"):
                let length = Int(headers["content-length"] ?? "0") ?? 0
                var body = rest
                if body.count < length, let more = LoopbackServer.readExactly(fd, length - body.count) { body.append(more) }
                let digest = SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined()
                respond(type: "application/json", body: Data(#"{"bytes":\#(body.count),"sha256":"\#(digest)"}"#.utf8))
            case ("GET", "/cookie"):
                var extra: [String] = []
                if let value = query.split(separator: "=").last, query.hasPrefix("set=") { extra.append("Set-Cookie: sid=\(value); Path=/") }
                respond(headers: extra, body: Data((headers["cookie"] ?? "none").utf8))
            case ("GET", "/page"):
                let html = "<html><head><title>page</title></head><body><script src=\"/asset.js\"></script></body></html>"
                respond(type: "text/html", body: Data(html.utf8))
            case ("GET", "/asset.js"):
                respond(type: "application/javascript", body: Data("document.title = 'asset loaded';".utf8))
            case ("GET", "/ws") where headers["upgrade"]?.lowercased() == "websocket":
                guard let key = headers["sec-websocket-key"] else { return }
                let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
                LoopbackServer.writeAll(fd, Data("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n".utf8))
                Self.echoWebSocket(fd, leftover: rest)
            default:
                respond("404 Not Found", body: Data("not found".utf8))
            }
        }
    }

    public func stop() { server.stop() }

    /// Echoes each message of a WebSocket (text stays text, binary stays binary) until it closes.
    private static func echoWebSocket(_ fd: Int32, leftover: Data) {
        var pending = leftover
        func fill(_ count: Int) -> Data? {
            while pending.count < count {
                var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { return nil }
                pending.append(buffer, count: n)
            }
            let out = Data(pending.prefix(count))
            pending.removeFirst(count)
            return out
        }
        while let head = fill(2) {
            let opcode = head[0] & 0x0F
            let masked = head[1] & 0x80 != 0
            var length = Int(head[1] & 0x7F)
            if length == 126 {
                guard let extended = fill(2) else { return }
                length = Int(extended[0]) << 8 | Int(extended[1])
            } else if length == 127 {
                guard let extended = fill(8) else { return }
                length = extended.reduce(0) { $0 << 8 | Int($1) }
            }
            let mask = masked ? fill(4) : Data(count: 4)
            guard let mask, var payload = fill(length) else { return }
            if masked { for i in 0..<payload.count { payload[i] ^= mask[i % 4] } }
            if opcode == 0x8 {
                LoopbackServer.writeAll(fd, Data([0x88, 0x00]))
                return
            }
            var frame = Data([0x80 | opcode])
            if payload.count < 126 {
                frame.append(UInt8(payload.count))
            } else if payload.count < 65536 {
                frame.append(126)
                frame.append(UInt8(payload.count >> 8))
                frame.append(UInt8(payload.count & 0xFF))
            } else {
                frame.append(127)
                for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
            }
            LoopbackServer.writeAll(fd, frame + payload)
        }
    }
}

// MARK: Raw servers

extension LoopbackServer {
    /// Echoes every byte it is sent.
    public static func echo(family: Family = .ipv4) throws -> LoopbackServer {
        try LoopbackServer(family: family) { fd in
            defer { close(fd) }
            var buffer = [UInt8](repeating: 0, count: 64 * 1024)
            while true {
                let n = read(fd, &buffer, buffer.count)
                if n <= 0 { return }
                if !writeAll(fd, Data(buffer[0..<n])) { return }
            }
        }
    }

    /// Writes as fast as the connection takes bytes (byte i being i % 251) until it closes, and
    /// counts what it wrote: how far a slow reader lets a sender run ahead.
    public static func firehose(written: Locked<Int>) throws -> LoopbackServer {
        try LoopbackServer { fd in
            defer { close(fd) }
            let block = Data((0..<(64 * 1024)).map { UInt8($0 % 251) })
            while writeAll(fd, block) { written.withValue { $0 += block.count } }
        }
    }

    /// Takes a connection and never reads it. Holds it open until the peer or the server closes
    /// it, and counts the connections it holds open now in `open`.
    public static func deaf(open: Locked<Int> = Locked(0), address: String? = nil) throws -> LoopbackServer {
        try LoopbackServer(address: address) { fd in
            open.withValue { $0 += 1 }
            defer { open.withValue { $0 -= 1 }; close(fd) }
            var byte: UInt8 = 0
            // Block until the peer or the server closes the socket, reading nothing that arrived.
            var pfd = pollfd(fd: fd, events: Int16(POLLHUP), revents: 0)
            while poll(&pfd, 1, 100) >= 0 {
                if pfd.revents & Int16(POLLHUP) != 0 { break }
                if recv(fd, &byte, 1, MSG_PEEK | MSG_DONTWAIT) == 0 { break }
            }
        }
    }

    /// An IPv4 address of this machine that is not the loopback, if it has one up.
    public static func nonLoopbackIPv4() -> String? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let first = list else { return nil }
        defer { freeifaddrs(list) }
        var next: UnsafeMutablePointer<ifaddrs>? = first
        while let entry = next {
            defer { next = entry.pointee.ifa_next }
            let flags = Int32(entry.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0, let address = entry.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            let ip = address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var copy = ip
            guard inet_ntop(AF_INET, &copy, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else { continue }
            let text = String(cString: buffer)
            if !text.hasPrefix("169.254.") { return text }
        }
        return nil
    }
}
