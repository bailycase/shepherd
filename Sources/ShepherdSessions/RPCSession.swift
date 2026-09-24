import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

enum RPCError: Error, Equatable, CustomStringConvertible {
    /// No response within the request's deadline.
    case timeout
    /// The process exited (nil = killed by signal) with the request outstanding.
    case exited(code: Int32?)
    /// The request was issued after the process had already exited.
    case notAlive

    var description: String {
        switch self {
        case .timeout: return "RPC request timed out"
        case .exited(let code): return "pi exited (\(code.map(String.init) ?? "signal")) with the request outstanding"
        case .notAlive: return "pi is not running"
        }
    }
}

/// A live `pi --mode rpc` child on plain pipes: JSONL commands in on stdin,
/// JSONL responses/events out on stdout. Same ownership rules as
/// `PTYSession`: all mutable state is confined to `queue` (which targets the
/// server's serial queue) and every callback is invoked on it.
final class RPCSession: @unchecked Sendable {
    struct SpawnError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    let id: SessionID
    let cwd: String
    let command: [String]
    private(set) var isAlive = true
    private(set) var exitCode: Int32?

    /// Every stdout record that is not a `response` (unknown types included).
    var onEvent: ((RPCEvent) -> Void)?
    /// One stderr line at a time, for the log.
    var onStderr: ((String) -> Void)?
    /// Invoked after the child is reaped and stdout is drained. nil = signal.
    var onExit: ((Int32?) -> Void)?

    /// Same bound as the PTY input queue. Rejected writes are all-or-none.
    static let outputQueueLimit = PTYSession.inputQueueLimit
    /// Strict JSONL: one record per LF. Not the 1 MiB network frame cap: pi answers
    /// `get_messages` with the whole context in one record, and a long session's (big tool
    /// results) runs to many megabytes. Dropping it left the thread showing no history at all.
    /// This bound only stops a runaway child from growing the buffer without limit.
    static let maxRecordBytes = 256 * 1024 * 1024
    /// stderr is diagnostics only; a runaway line is cut here.
    static let maxStderrLineBytes = 64 * 1024
    /// `kill()` waits this long for SIGTERM before SIGKILL.
    static let killGrace: DispatchTimeInterval = .seconds(2)
    /// Records at least this long (a long history's `get_messages`) decode off the session queue,
    /// which targets the server queue: decoding one held every other session, terminal, and
    /// request behind it for hundreds of milliseconds.
    static let offQueueDecodeBytes = 256 * 1024
    /// Concurrent, so the histories of agents resuming together decode side by side.
    private static let decodeQueue = DispatchQueue(label: "shepherd.rpc.decode", qos: .utility, attributes: .concurrent)

    /// Tests only: runs on the decode queue before each off-queue decode.
    var beforeOffQueueDecode: (() -> Void)?

    private let queue: DispatchQueue
    private let childPID: pid_t
    private let stdinFD: Int32
    private let stdoutFD: Int32
    private let stderrFD: Int32
    private var stdoutSource: DispatchSourceRead?
    private var stderrSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var procSource: DispatchSourceProcess?
    private var reapTimer: DispatchSourceTimer?
    private var stdoutBuffer = Data()
    /// Set after an oversize record: skip bytes until the next LF.
    private var discardingRecord = false
    private var stderrBuffer = Data()
    private var pendingOutput = Data()
    private var pendingOutputOffset = 0
    private var pendingRequests: [String: (Result<RPCResponse, RPCError>) -> Void] = [:]
    private var nextRequestID = 0
    private var reaped = false
    private var exitDelivered = false
    private var stdoutClosed = false
    private var stderrClosed = false
    private var stdinClosed = false
    private var isShutDown = false
    /// A record is decoding off the queue: every later record waits in `deferredRecords`, in
    /// arrival order, so the session handles its records in exactly the order pi wrote them.
    private var decodingOffQueue = false
    private var deferredRecords: [Data] = []
    private var recordsInFlight: Bool { decodingOffQueue || !deferredRecords.isEmpty }
    /// Tests: records waiting behind an off-queue decode.
    var deferredRecordCount: Int { deferredRecords.count }

    var info: SessionInfo {
        SessionInfo(id: id, cwd: cwd, command: command, cols: 0, rows: 0, isAlive: isAlive)
    }

    init(
        id: SessionID = SessionID(),
        params: CreateSessionParams,
        queue: DispatchQueue
    ) throws {
        self.id = id
        self.queue = queue
        self.cwd = params.cwd
        guard !params.command.isEmpty else { throw SpawnError(message: "rpc session needs a command") }
        let argv = params.command
        self.command = argv

        var env = ProcessInfo.processInfo.environment
        if let extra = params.env {
            env.merge(extra) { _, new in new }
        }
        // Same sanitising as PTYSession: the child is not hosted by whichever
        // terminal launched the app. No TERM: there is no terminal at all.
        for key in [
            "TMUX", "TMUX_PANE", "STY", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR",
            "WEZTERM_PANE", "WARP_SESSION_ID", "ITERM_SESSION_ID", "WT_SESSION",
            "TERMINAL_EMULATOR", "TERM_PROGRAM_VERSION",
        ] {
            env.removeValue(forKey: key)
        }

        guard let execPath = Self.resolveExecutable(argv[0], env: env) else {
            throw SpawnError(message: "executable not found: \(argv[0])")
        }

        var stdinPipe: [Int32] = [-1, -1]
        var stdoutPipe: [Int32] = [-1, -1]
        var stderrPipe: [Int32] = [-1, -1]
        guard pipe(&stdinPipe) == 0, pipe(&stdoutPipe) == 0, pipe(&stderrPipe) == 0 else {
            let err = errno
            for fd in stdinPipe + stdoutPipe + stderrPipe where fd >= 0 { close(fd) }
            throw SpawnError(message: "pipe failed: errno \(err)")
        }
        for fd in stdinPipe + stdoutPipe + stderrPipe {
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        }

        var argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        argvC.append(nil)
        var envC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envC.append(nil)
        defer {
            argvC.forEach { free($0) }
            envC.forEach { free($0) }
        }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_adddup2(&actions, stdinPipe[0], 0)
        posix_spawn_file_actions_adddup2(&actions, stdoutPipe[1], 1)
        posix_spawn_file_actions_adddup2(&actions, stderrPipe[1], 2)
        posix_spawn_file_actions_addchdir(&actions, params.cwd)

        // The app may ignore SIGTERM/SIGINT (dispatch signal sources); SIG_IGN
        // and blocked masks survive exec, so restore defaults or the child is
        // not killable. Own process group so descendants can be signalled
        // together, like the PTY group. CLOEXEC_DEFAULT keeps every other app
        // fd (sockets, state files) out of the child.
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        var allSignals = sigset_t()
        sigfillset(&allSignals)
        posix_spawnattr_setsigdefault(&attr, &allSignals)
        var noSignals = sigset_t()
        sigemptyset(&noSignals)
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(
            &attr,
            Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var pid: pid_t = 0
        let rc = argvC.withUnsafeMutableBufferPointer { argvBuf in
            envC.withUnsafeMutableBufferPointer { envBuf in
                posix_spawn(&pid, execPath, &actions, &attr, argvBuf.baseAddress, envBuf.baseAddress)
            }
        }
        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        close(stdinPipe[0])
        close(stdoutPipe[1])
        close(stderrPipe[1])
        guard rc == 0 else {
            close(stdinPipe[1])
            close(stdoutPipe[0])
            close(stderrPipe[0])
            throw SpawnError(message: "posix_spawn failed: errno \(rc)")
        }

        childPID = pid
        stdinFD = stdinPipe[1]
        stdoutFD = stdoutPipe[0]
        stderrFD = stderrPipe[0]
        for fd in [stdinFD, stdoutFD, stderrFD] {
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)
        }
        // A dead reader must surface as EPIPE, not kill the app.
        _ = fcntl(stdinFD, F_SETNOSIGPIPE, 1)
    }

    /// Begin reading stdout/stderr and watching for exit. Call after wiring callbacks.
    func start() {
        queue.async { self.startSources() }
    }

    /// Fire-and-forget: write one command record. Must run under the
    /// session's queue hierarchy.
    func send(_ command: RPCCommand, id: String? = nil) {
        guard isAlive, !stdinClosed else { return }
        let line: Data
        do {
            line = try NDJSON.encode(RPCCommandFrame(id: id, command: command))
        } catch {
            ShepherdLog.warning("rpc session \(self.id) failed to encode \(command.type): \(error)")
            return
        }
        let pendingCount = pendingOutput.count - pendingOutputOffset
        guard line.count <= Self.outputQueueLimit - pendingCount else {
            ShepherdLog.warning("rpc session \(self.id) command dropped: pending output limit is \(Self.outputQueueLimit) bytes")
            return
        }
        if pendingOutputOffset > 0 {
            pendingOutput.removeSubrange(0..<pendingOutputOffset)
            pendingOutputOffset = 0
        }
        pendingOutput.append(line)
        drainPendingOutput()
    }

    /// Send a command with a fresh id and resolve on the matching response.
    /// Must run under the session's queue hierarchy; `completion` runs there too.
    func request(
        _ command: RPCCommand,
        timeout: TimeInterval = 10,
        completion: @escaping (Result<RPCResponse, RPCError>) -> Void
    ) {
        guard isAlive, !stdinClosed else {
            completion(.failure(.notAlive))
            return
        }
        nextRequestID += 1
        let requestID = "\(id.rawValue)-\(nextRequestID)"
        pendingRequests[requestID] = completion
        send(command, id: requestID)
        queue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self, let pending = self.pendingRequests.removeValue(forKey: requestID) else { return }
            ShepherdLog.warning("rpc session \(self.id) \(command.type) timed out after \(timeout)s")
            pending(.failure(.timeout))
        }
    }

    /// Graceful stop: SIGTERM the process group, SIGKILL after `killGrace`.
    /// Must run under the session's queue hierarchy. onExit still fires.
    func kill() {
        guard isAlive, !reaped else { return }
        signalProcessGroup(SIGTERM)
        queue.asyncAfter(deadline: .now() + Self.killGrace) { [weak self] in
            guard let self, !self.reaped else { return }
            ShepherdLog.warning("rpc session \(self.id) ignored SIGTERM; sending SIGKILL")
            self.signalProcessGroup(SIGKILL)
        }
    }

    /// Hard shutdown for server stop, mirroring `PTYSession.shutdown()`:
    /// signal the group, force it down, fail outstanding requests, release
    /// the pipes. onExit is not invoked. Must run under the queue hierarchy.
    func shutdown() {
        guard !exitDelivered else { return }
        if !reaped {
            signalProcessGroup(SIGHUP)
            signalProcessGroup(SIGKILL)
        }
        isAlive = false
        exitDelivered = true
        isShutDown = true
        deferredRecords.removeAll()
        onEvent = nil
        onStderr = nil
        onExit = nil
        let outstanding = pendingRequests
        pendingRequests.removeAll()
        for (_, completion) in outstanding { completion(.failure(.notAlive)) }
        closeStdin()
        stdoutClosed = true
        stdoutSource?.cancel()
        stdoutSource = nil
        stderrClosed = true
        stderrSource?.cancel()
        stderrSource = nil
        cancelProcessSources()
        if !reaped {
            // Bounded reap, same reasoning as PTYSession: never hang the quit path.
            let deadline = DispatchTime.now() + .seconds(2)
            var status: Int32 = 0
            while true {
                let r = waitpid(childPID, &status, WNOHANG)
                if r == childPID { break }
                if r < 0, errno != EINTR { break }
                if DispatchTime.now() >= deadline {
                    ShepherdLog.warning("rpc session \(id) child \(childPID) survived shutdown; abandoning to the OS")
                    break
                }
                usleep(10_000)
            }
            reaped = true
        }
    }

    /// Deliver a signal to the child's process group (it leads its own, via
    /// POSIX_SPAWN_SETPGROUP). Must run under the session's queue hierarchy.
    func signalProcessGroup(_ sig: Int32) {
        guard childPID > 0 else { return }
        if Darwin.kill(-childPID, 0) != 0 {
            guard isAlive else { return }
            if Darwin.kill(childPID, sig) != 0, errno != ESRCH, errno != EPERM {
                ShepherdLog.warning("rpc session \(id) direct signal \(sig) failed: errno \(errno)")
            }
            return
        }
        if Darwin.kill(-childPID, sig) != 0, errno != ESRCH, errno != EPERM {
            ShepherdLog.warning("rpc session \(id) group signal \(sig) failed: errno \(errno)")
        }
    }

    // MARK: - Internals (session queue)

    private func startSources() {
        guard !stdoutClosed else { return }
        let outFD = stdoutFD
        let out = DispatchSource.makeReadSource(fileDescriptor: outFD, queue: queue)
        out.setEventHandler { [weak self] in self?.drainStdout() }
        out.setCancelHandler { close(outFD) }
        stdoutSource = out
        out.activate()

        let errFD = stderrFD
        let err = DispatchSource.makeReadSource(fileDescriptor: errFD, queue: queue)
        err.setEventHandler { [weak self] in self?.drainStderr() }
        err.setCancelHandler { close(errFD) }
        stderrSource = err
        err.activate()

        let ps = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in self?.handleChildExited() }
        ps.activate()
        procSource = ps

        drainStdout()
        drainStderr()
        _ = reap()
        // The process source covers exits after registration; the timer is a
        // fallback for a child already gone before it.
        if !reaped && Darwin.kill(childPID, 0) != 0 {
            startReapTimer()
        }
    }

    private func drainStdout() {
        guard !stdoutClosed else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let n = read(stdoutFD, &buf, buf.count)
            if n > 0 {
                feedStdout(Data(bytes: buf, count: n))
                continue
            }
            if n == 0 {
                handleStdoutEOF()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            handleStdoutEOF()
            return
        }
    }

    /// Strict JSONL: split on LF only, strip one trailing CR. Records over
    /// `maxRecordBytes` and malformed JSON are logged and dropped; the reader
    /// never stops.
    private func feedStdout(_ chunk: Data) {
        // Only the new bytes can hold the next LF: rescanning a multi-megabyte partial record
        // on every chunk made large replies quadratic.
        let searchFrom = stdoutBuffer.count
        stdoutBuffer.append(chunk)
        var from = stdoutBuffer.startIndex + searchFrom
        while let lf = stdoutBuffer[from...].firstIndex(of: 0x0A) {
            var line = stdoutBuffer[stdoutBuffer.startIndex..<lf]
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...lf)
            from = stdoutBuffer.startIndex
            if discardingRecord {
                discardingRecord = false
                continue
            }
            if line.last == 0x0D { line = line.dropLast() }
            if line.count > Self.maxRecordBytes {
                ShepherdLog.warning("rpc session \(id) dropped a \(line.count)-byte record (limit \(Self.maxRecordBytes))")
                continue
            }
            if line.isEmpty { continue }
            receiveRecord(Data(line))
        }
        if stdoutBuffer.count > Self.maxRecordBytes {
            ShepherdLog.warning("rpc session \(id) dropping an unterminated record over \(Self.maxRecordBytes) bytes")
            stdoutBuffer.removeAll(keepingCapacity: false)
            discardingRecord = true
        }
    }

    private func receiveRecord(_ line: Data) {
        if decodingOffQueue {
            deferredRecords.append(line)
        } else if line.count >= Self.offQueueDecodeBytes {
            decodeOffQueue(line)
        } else {
            handleRecord(line)
        }
    }

    private func decodeOffQueue(_ line: Data) {
        decodingOffQueue = true
        let hook = beforeOffQueueDecode
        Self.decodeQueue.async { [weak self] in
            hook?()
            let decoded = Result { try NDJSON.decode(RPCIncoming.self, from: line) }
            guard let self else { return }
            self.queue.async { self.finishOffQueueDecode(decoded) }
        }
    }

    /// Back on the session queue: handle the record, then the ones that arrived behind it, until
    /// they run out or another long one goes off the queue.
    private func finishOffQueueDecode(_ decoded: Result<RPCIncoming, Error>) {
        decodingOffQueue = false
        guard !isShutDown else { return }
        switch decoded {
        case .success(let incoming): dispatch(incoming)
        case .failure(let error): ShepherdLog.warning("rpc session \(id) dropped a malformed record: \(error)")
        }
        var waiting = deferredRecords[...]
        deferredRecords.removeAll()
        while let line = waiting.popFirst() {
            receiveRecord(line)
            if decodingOffQueue {
                deferredRecords = Array(waiting)
                return
            }
        }
        failRequestsAfterExit()
        deliverExitIfReady()
    }

    private func handleRecord(_ line: Data) {
        let incoming: RPCIncoming
        do {
            incoming = try NDJSON.decode(RPCIncoming.self, from: line)
        } catch {
            ShepherdLog.warning("rpc session \(id) dropped a malformed record: \(error)")
            return
        }
        dispatch(incoming)
    }

    private func dispatch(_ incoming: RPCIncoming) {
        switch incoming {
        case .event(let event):
            if case .unknown(let type) = event {
                ShepherdLog.info("rpc session \(id) unknown event type \(type)")
            }
            onEvent?(event)
        case .response(let response):
            if let rid = response.id, let pending = pendingRequests.removeValue(forKey: rid) {
                pending(.success(response))
            } else if response.id != nil || !response.success {
                // A late reply after timeout, or an id-less failure such as
                // pi's `parse` error for a command we sent fire-and-forget.
                ShepherdLog.warning(
                    "rpc session \(id) unmatched response \(response.command) id=\(response.id ?? "-") success=\(response.success) error=\(response.error ?? "-")"
                )
            }
        }
    }

    private func drainStderr() {
        guard !stderrClosed else { return }
        var buf = [UInt8](repeating: 0, count: 16 * 1024)
        while true {
            let n = read(stderrFD, &buf, buf.count)
            if n > 0 {
                stderrBuffer.append(buf, count: n)
                while let lf = stderrBuffer.firstIndex(of: 0x0A) {
                    let line = stderrBuffer[stderrBuffer.startIndex..<lf]
                    stderrBuffer.removeSubrange(stderrBuffer.startIndex...lf)
                    emitStderr(line)
                }
                if stderrBuffer.count > Self.maxStderrLineBytes {
                    emitStderr(stderrBuffer.prefix(Self.maxStderrLineBytes))
                    stderrBuffer.removeAll(keepingCapacity: false)
                }
                continue
            }
            if n == 0 { break }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            break
        }
        if !stderrBuffer.isEmpty {
            emitStderr(stderrBuffer)
            stderrBuffer.removeAll(keepingCapacity: false)
        }
        stderrClosed = true
        stderrSource?.cancel()
        stderrSource = nil
    }

    private func emitStderr(_ bytes: Data) {
        guard !bytes.isEmpty else { return }
        onStderr?(String(decoding: bytes, as: UTF8.self))
    }

    private func handleStdoutEOF() {
        guard !stdoutClosed else { return }
        stdoutClosed = true
        stdoutSource?.cancel()  // cancel handler closes the fd
        stdoutSource = nil
        if !reap() {
            startReapTimer()
        }
    }

    private func handleChildExited() {
        drainStdout()
        drainStderr()
        _ = reap()
    }

    @discardableResult
    private func reap() -> Bool {
        if reaped {
            deliverExitIfReady()
            return true
        }
        var status: Int32 = 0
        guard waitpid(childPID, &status, WNOHANG) == childPID else { return false }
        reaped = true
        isAlive = false
        // WIFEXITED/WEXITSTATUS are macros Swift does not import.
        let code: Int32? = (status & 0x7f) == 0 ? (status >> 8) & 0xff : nil
        exitCode = code
        // Descendants still holding our pipes would delay EOF forever.
        signalProcessGroup(SIGHUP)
        signalProcessGroup(SIGKILL)
        cancelProcessSources()
        closeStdin()
        failRequestsAfterExit()
        deliverExitIfReady()
        return true
    }

    /// Requests pi never answered fail once it is gone, but only after every record it wrote
    /// has been handled: an answer may still be decoding.
    private func failRequestsAfterExit() {
        guard reaped, !recordsInFlight else { return }
        let outstanding = pendingRequests
        pendingRequests.removeAll()
        for (_, completion) in outstanding {
            completion(.failure(.exited(code: exitCode)))
        }
    }

    private func deliverExitIfReady() {
        guard reaped, stdoutClosed, !exitDelivered, !recordsInFlight else { return }
        exitDelivered = true
        onExit?(exitCode)
    }

    private func startReapTimer() {
        guard reapTimer == nil, !reaped else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        t.setEventHandler { [weak self] in
            guard let self else { return }
            if self.reap() {
                self.reapTimer?.cancel()
                self.reapTimer = nil
            }
        }
        t.activate()
        reapTimer = t
    }

    private func drainPendingOutput() {
        guard isAlive, !stdinClosed else {
            pendingOutput.removeAll(keepingCapacity: false)
            pendingOutputOffset = 0
            cancelWriteSource()
            return
        }
        while pendingOutputOffset < pendingOutput.count {
            let remaining = pendingOutput.count - pendingOutputOffset
            let result = pendingOutput.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(stdinFD, base.advanced(by: pendingOutputOffset), remaining)
            }
            if result > 0 {
                pendingOutputOffset += result
                continue
            }
            if result < 0, errno == EINTR { continue }
            if result == 0 || errno == EAGAIN || errno == EWOULDBLOCK {
                armWriteSource()
                return
            }
            ShepherdLog.warning("rpc session \(id) stdin write failed: errno \(errno)")
            closeStdin()
            return
        }
        pendingOutput.removeAll(keepingCapacity: true)
        pendingOutputOffset = 0
        cancelWriteSource()
    }

    private func armWriteSource() {
        guard writeSource == nil, !stdinClosed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: stdinFD, queue: queue)
        source.setEventHandler { [weak self] in self?.drainPendingOutput() }
        source.setCancelHandler {}
        writeSource = source
        source.activate()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func closeStdin() {
        guard !stdinClosed else { return }
        stdinClosed = true
        cancelWriteSource()
        pendingOutput.removeAll(keepingCapacity: false)
        pendingOutputOffset = 0
        close(stdinFD)
    }

    private func cancelProcessSources() {
        reapTimer?.cancel()
        reapTimer = nil
        procSource?.cancel()
        procSource = nil
    }

    private static func resolveExecutable(_ name: String, env: [String: String]) -> String? {
        if name.contains("/") {
            return access(name, X_OK) == 0 ? name : nil
        }
        let path = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        for dir in path.split(separator: ":") {
            let candidate = "\(dir)/\(name)"
            if access(candidate, X_OK) == 0 { return candidate }
        }
        return nil
    }
}
