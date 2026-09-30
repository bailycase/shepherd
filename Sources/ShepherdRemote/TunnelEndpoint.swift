import Darwin
import Dispatch
import Foundation
import ShepherdProtocol

/// One end of a Browser tunnel (docs/browser.md › Remote): a nonblocking stream socket, and the
/// flow control of both directions of the tunnel that runs to it. The host has one for the
/// loopback connection to a dev server; a viewer has one for each connection its web view makes
/// to a forwarded port. It knows nothing of frames: its owner sends what it reads
/// (`onData`, `onFinish`) and feeds it what the other end sent (`receive`, `receiveFinish`).
///
/// Everything runs on the owner's serial queue, which the owner passes in; the sources it makes
/// run there too. The rules it keeps:
///
/// - **Reading is paced by credit.** It reads the socket only while the other end has given it
///   credit (`BrowserTunnelCredit`) and its owner's gate is open (the connection to the other end
///   is not backed up). With either closed the read source is suspended, so a slow reader on the
///   other end holds this socket's sender instead of piling bytes up here.
/// - **Writing is paced by the socket.** What the other end sends waits, at most a window's worth
///   (the other end has no more credit than that), until the socket takes it, and credit goes back
///   (`onCredit`) only for bytes the socket took.
/// - **Halves close apart.** EOF from the socket is `onFinish`; the other end's finish shuts the
///   socket's write side once what is queued has gone out. Both done is `onDone`.
public final class TunnelEndpoint {
    public var onData: ((Data) -> Void)?
    /// The socket has no more bytes for the tunnel (EOF).
    public var onFinish: (() -> Void)?
    /// Credit to give the other end: it took this many bytes of what it sent.
    public var onCredit: ((Int) -> Void)?
    /// Both halves are finished and everything is written: the tunnel is over.
    public var onDone: (() -> Void)?
    /// The socket broke, or the other end broke the protocol (`BrowserTunnelCode`).
    public var onFailure: ((String) -> Void)?
    /// False while the connection the bytes travel over is backed up: the endpoint reads nothing.
    /// Call `gateChanged` when it may have changed.
    public var gate: () -> Bool = { true }

    /// When a byte last went either way.
    public private(set) var lastActivity = DispatchTime.now()
    /// Bytes waiting to be written to the socket.
    public private(set) var pendingBytes = 0
    /// The socket has sent everything it will (EOF): nothing more will be read from it.
    public var isReadFinished: Bool { readEOF }

    private let queue: DispatchQueue
    private var fd: Int32
    private var readSource: DispatchSourceRead?
    private var readSuspended = false
    private var writeSource: DispatchSourceWrite?
    private var credit = BrowserTunnelCredit()
    private var receipt = BrowserTunnelReceipt()
    private var pending: [Data] = []
    private var pendingOffset = 0
    private var readEOF = false
    private var peerFinished = false
    private var shutdownWrite = false
    private var closed = false
    private var doneReported = false

    /// Takes ownership of `fd` (a connected stream socket): it is made nonblocking and closed by
    /// `close`.
    public init(fd: Int32, queue: DispatchQueue) {
        self.fd = fd
        self.queue = queue
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var one: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
    }

    deinit {
        // A dropped endpoint must not leak its descriptor; `close` is the normal way.
        if !closed { teardown() }
    }

    /// Starts reading. Call once, after the callbacks are set.
    public func start() {
        guard readSource == nil, !closed else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        let descriptor = fd
        source.setEventHandler { [weak self] in self?.readable() }
        // The read source owns the descriptor's close: it is the only source that lives as long
        // as the endpoint does.
        source.setCancelHandler { Darwin.close(descriptor) }
        readSource = source
        source.activate()
        updateReading()
    }

    // MARK: Toward the other end

    /// The other end took `bytes` of what this end sent: more may be read.
    public func grant(_ bytes: Int) {
        guard !closed else { return }
        credit.grant(bytes)
        updateReading()
    }

    /// The gate (or the socket's readiness to be read) may have changed.
    public func gateChanged() {
        updateReading()
    }

    // MARK: From the other end

    /// Bytes the other end sent for the socket. A sender with no credit for them broke the
    /// protocol: `onFailure`.
    public func receive(_ bytes: Data) {
        guard !closed else { return }
        guard bytes.count <= BrowserTunnelLimits.chunkBytes, receipt.received(bytes.count) else {
            fail(BrowserTunnelCode.violation)
            return
        }
        guard !bytes.isEmpty else { return }
        lastActivity = .now()
        pending.append(bytes)
        pendingBytes += bytes.count
        drain()
    }

    /// The other end has no more bytes: the socket's write side shuts once what is queued is out.
    public func receiveFinish() {
        guard !closed, !peerFinished else { return }
        peerFinished = true
        drain()
    }

    /// Closes the socket now, dropping what is queued. Idempotent.
    public func close() {
        guard !closed else { return }
        closed = true
        teardown()
    }

    /// Closes the socket so its peer sees a reset rather than a clean end: a page whose tunnel
    /// broke fails to load instead of showing half a response.
    public func abort() {
        guard !closed else { return }
        var linger = linger(l_onoff: 1, l_linger: 0)
        _ = setsockopt(fd, SOL_SOCKET, SO_LINGER, &linger, socklen_t(MemoryLayout<linger>.size))
        close()
    }

    // MARK: Reading

    private func readable() {
        guard !closed, !readEOF else { return }
        // A few chunks a turn, so a busy tunnel doesn't hold the queue against the others.
        var budget = 8
        while budget > 0, !closed, !readEOF, credit.available > 0, gate() {
            budget -= 1
            let want = min(BrowserTunnelLimits.chunkBytes, credit.available)
            var data = Data(count: want)
            let n = data.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, want) }
            if n > 0 {
                data.removeSubrange(n..<data.count)
                _ = credit.take(n)
                lastActivity = .now()
                onData?(data)
                continue
            }
            if n == 0 {
                readEOF = true
                onFinish?()
                reportDoneIfFinished()
                break
            }
            if errno == EINTR { budget += 1; continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { break }
            fail(BrowserTunnelCode.reset)
            return
        }
        updateReading()
    }

    /// Suspends the read source while there is nothing to read for (no credit, a backed-up
    /// connection, EOF) and resumes it when there is.
    private func updateReading() {
        guard let source = readSource, !closed else { return }
        let want = !readEOF && credit.available > 0 && gate()
        if want, readSuspended {
            readSuspended = false
            source.resume()
        } else if !want, !readSuspended {
            readSuspended = true
            source.suspend()
        }
    }

    // MARK: Writing

    private func drain() {
        guard !closed else { return }
        while let chunk = pending.first {
            let offset = pendingOffset
            let n = chunk.withUnsafeBytes { raw -> Int in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), chunk.count - offset)
            }
            if n > 0 {
                lastActivity = .now()
                pendingOffset += n
                pendingBytes -= n
                if pendingOffset == chunk.count {
                    pending.removeFirst()
                    pendingOffset = 0
                }
                if let back = receipt.taken(n) { onCredit?(back) }
                continue
            }
            if n < 0, errno == EINTR { continue }
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armWriter()
                return
            }
            fail(BrowserTunnelCode.reset)
            return
        }
        writeSource?.cancel()
        writeSource = nil
        if peerFinished, !shutdownWrite {
            shutdownWrite = true
            _ = Darwin.shutdown(fd, SHUT_WR)
        }
        reportDoneIfFinished()
    }

    private func armWriter() {
        guard writeSource == nil, !closed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.drain() }
        source.setCancelHandler {}
        writeSource = source
        source.activate()
    }

    // MARK: Ending

    private func reportDoneIfFinished() {
        guard !doneReported, readEOF, peerFinished, shutdownWrite, pending.isEmpty else { return }
        doneReported = true
        onDone?()
    }

    private func fail(_ code: String) {
        guard !closed else { return }
        close()
        onFailure?(code)
    }

    private func teardown() {
        writeSource?.cancel()
        writeSource = nil
        if let source = readSource {
            readSource = nil
            // A suspended source never runs its cancel handler, which closes the descriptor.
            if readSuspended { source.resume() }
            readSuspended = false
            source.cancel()
        } else {
            Darwin.close(fd)
        }
        pending.removeAll()
        pendingBytes = 0
    }
}
