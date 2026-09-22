import Darwin
import Foundation
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdSessions

struct TestSocketError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<R>(_ body: (inout Value) -> R) -> R {
        lock.lock()
        defer { lock.unlock() }
        return body(&value)
    }

    var current: Value { withValue { $0 } }
}

@discardableResult
func waitUntil(
    timeout: Duration = .seconds(30),
    interval: Duration = .milliseconds(50),
    _ condition: @Sendable () -> Bool
) async throws -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: interval)
    }
    return condition()
}

/// A short-pathed scratch directory (sun_path caps UDS paths at 104 bytes).
func makeScratchDirectory() throws -> URL {
    var base = FileManager.default.temporaryDirectory
    if base.path.utf8.count > 70 {
        base = URL(fileURLWithPath: "/tmp")
    }
    let dir = base.appendingPathComponent("shepherd-\(UInt32.random(in: 0..<1_000_000))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// Raw POSIX-socket NDJSON client for the status-extension socket, mirroring
/// what `Extensions/shepherd-status.ts` does: connect, write fire-and-forget
/// setAgentStatus lines, never read.
final class ExtensionClient {
    private let fd: Int32
    private var closed = false

    init(path: String, receiveBufferSize: Int32? = nil) throws {
        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw TestSocketError(message: "socket failed: errno \(errno)") }
        var addr = try SessionServer.socketAddress(for: path)
        let r = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard r == 0 else {
            let err = errno
            close(fd)
            throw TestSocketError(message: "connect failed: errno \(err)")
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        if var receiveBufferSize {
            _ = setsockopt(fd, SOL_SOCKET, SO_RCVBUF, &receiveBufferSize, socklen_t(MemoryLayout<Int32>.size))
        }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }

    deinit { closeConnection() }

    func closeConnection() {
        if !closed {
            closed = true
            close(fd)
        }
    }

    func send(_ message: ExtensionMessage) throws {
        try sendRaw(NDJSON.encode(message))
    }

    func sendRaw(_ data: Data, timeout: Duration = .seconds(10)) throws {
        let deadline = ContinuousClock.now + timeout
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < data.count {
                guard ContinuousClock.now < deadline else {
                    throw TestSocketError(message: "timed out writing to socket")
                }
                let n = write(fd, base + offset, data.count - offset)
                if n > 0 {
                    offset += n
                    continue
                }
                if errno == EINTR || errno == EAGAIN || errno == EWOULDBLOCK {
                    usleep(2000)
                    continue
                }
                throw TestSocketError(message: "write failed: errno \(errno)")
            }
        }
    }

    private var readBuffer = Data()

    func waitForDisconnect(timeout: Duration = .seconds(10)) throws -> Bool {
        let deadline = ContinuousClock.now + timeout
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while ContinuousClock.now < deadline {
            let n = read(fd, &buf, buf.count)
            if n == 0 { return true }
            if n > 0 {
                readBuffer.append(contentsOf: buf[0..<n])
                continue
            }
            if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(5000)
                continue
            }
            throw TestSocketError(message: "read failed: errno \(errno)")
        }
        return false
    }

    /// Read the next NDJSON `ExtensionReply` line (pane request/reply traffic,
    /// mirroring `Extensions/shepherd-panes.ts`).
    func readReply(timeout: Duration = .seconds(10)) throws -> ExtensionReply {
        let deadline = ContinuousClock.now + timeout
        var buf = [UInt8](repeating: 0, count: 32 * 1024)
        while ContinuousClock.now < deadline {
            if let nl = readBuffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = readBuffer[readBuffer.startIndex..<nl]
                readBuffer.removeSubrange(readBuffer.startIndex...nl)
                return try NDJSON.decode(ExtensionReply.self, from: Data(line))
            }
            let n = read(fd, &buf, buf.count)
            if n > 0 {
                readBuffer.append(contentsOf: buf[0..<n])
            } else if n == 0 {
                throw TestSocketError(message: "socket closed while awaiting reply")
            } else if errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR {
                usleep(5000)
            } else {
                throw TestSocketError(message: "read failed: errno \(errno)")
            }
        }
        throw TestSocketError(message: "timed out awaiting reply")
    }
}
