import Darwin
import Dispatch
import Foundation

/// Owns only establishment. DNS, pending sockets and the waiter share one deadline and can be
/// cancelled before a descriptor is handed to the client's established-stream transport.
final class RemoteSocketOpen: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shepherd.remote.open")
    private var continuation: CheckedContinuation<Int32, Error>?
    private var finished = false
    private var sockets: [Int32: DispatchSourceWrite] = [:]
    private var addresses: Set<Data> = []
    private var timer: DispatchSourceTimer?
    private var port: UInt16 = 0
    private var lastError: Error = RemoteHostClientError.timeout

    func open(host: String, port: UInt16, timeout: TimeInterval = 10,
              override: (@Sendable (String, UInt16) throws -> Int32)? = nil) async throws -> Int32 {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !self.finished else { continuation.resume(throwing: CancellationError()); return }
                self.continuation = continuation
                self.port = port
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                timer.schedule(deadline: .now() + timeout)
                timer.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.finish(.failure(self.lastError))
                }
                self.timer = timer
                timer.activate()
                if let override {
                    // The legacy test seam may block; its waiter never does, and a late fd
                    // belongs here until it can be handed off (or closed after cancellation).
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = Result { try override(host, port) }
                        self.queue.async { self.finish(result) }
                    }
                } else {
                    self.resolve(host)
                }
            }
        }
    }

    func cancel() {
        queue.async { self.finish(.failure(CancellationError())) }
    }

    private func resolve(_ host: String) {
        let port = port
        // Use the system host lookup, including hosts-file and private DNS names. It can
        // block, so the connection's deadline and cancellation stay on our own queue.
        DispatchQueue.global(qos: .userInitiated).async {
            var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                                 ai_protocol: IPPROTO_TCP, ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil)
            var result: UnsafeMutablePointer<addrinfo>?
            let error = getaddrinfo(host, String(port), &hints, &result)
            var resolved: [Data] = []
            if let result {
                defer { freeaddrinfo(result) }
                var next: UnsafeMutablePointer<addrinfo>? = result
                while let value = next {
                    if let address = value.pointee.ai_addr {
                        resolved.append(Data(bytes: address, count: Int(value.pointee.ai_addrlen)))
                    }
                    next = value.pointee.ai_next
                }
            }
            let addresses = resolved
            self.queue.async {
                guard !self.finished else { return }
                guard error == 0, !addresses.isEmpty else {
                    self.finish(.failure(RemoteHostClientError.resolveFailed(host: host)))
                    return
                }
                for address in addresses where !self.finished {
                    address.withUnsafeBytes { self.connect($0.bindMemory(to: sockaddr.self).baseAddress!) }
                }
                if !self.finished, self.sockets.isEmpty { self.finish(.failure(self.lastError)) }
            }
        }
    }

    private func connect(_ address: UnsafePointer<sockaddr>) {
        let length = Int(address.pointee.sa_len)
        guard length > 0 else { return }
        var bytes = Data(bytes: address, count: length)
        let fresh = addresses.insert(bytes).inserted
        guard fresh else { return }
        let family = Int32(address.pointee.sa_family)
        guard family == AF_INET || family == AF_INET6 else { return }
        let fd = socket(family, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { lastError = RemoteHostClientError.system(call: "socket", errno: errno); return }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            let error = errno
            close(fd)
            lastError = RemoteHostClientError.system(call: "fcntl", errno: error)
            return
        }
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
        let status = bytes.withUnsafeMutableBytes { raw -> Int32 in
            if family == AF_INET { raw.bindMemory(to: sockaddr_in.self).baseAddress!.pointee.sin_port = port.bigEndian }
            else { raw.bindMemory(to: sockaddr_in6.self).baseAddress!.pointee.sin6_port = port.bigEndian }
            return Darwin.connect(fd, raw.bindMemory(to: sockaddr.self).baseAddress!, socklen_t(length))
        }
        if status == 0 { finish(.success(fd)); return }
        guard errno == EINPROGRESS else {
            lastError = RemoteHostClientError.system(call: "connect", errno: errno)
            close(fd)
            return
        }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setCancelHandler { close(fd) }
        source.setEventHandler { [weak self] in
            guard let self, !self.finished else { return }
            var error: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            if getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) != 0 { error = errno }
            if error == 0 {
                // The source owns the original until its cancel handler runs. Transfer a dup
                // rather than racing close/reuse of a descriptor still watched by dispatch.
                let connected = fcntl(fd, F_DUPFD_CLOEXEC, 0)
                if connected >= 0 { self.finish(.success(connected)); return }
                error = errno
            }
            self.lastError = RemoteHostClientError.system(call: "connect", errno: error)
            self.sockets.removeValue(forKey: fd)?.cancel()
            if self.sockets.isEmpty { self.finish(.failure(self.lastError)) }
        }
        sockets[fd] = source
        source.activate()
    }

    private func finish(_ result: Result<Int32, Error>) {
        guard !finished else {
            if case .success(let fd) = result { close(fd) }
            return
        }
        finished = true
        timer?.cancel()
        timer = nil
        for source in sockets.values { source.cancel() }
        sockets = [:]
        let continuation = continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}
