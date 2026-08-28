import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// A live PTY-backed process. All mutable state is confined to `queue`; that
/// queue targets the in-process server's serial queue, so the server may read
/// and mutate session state directly without extra synchronization.
final class PTYSession: @unchecked Sendable {
    struct SpawnError: Error, CustomStringConvertible {
        let message: String
        var description: String { message }
    }

    let id: SessionID
    let cwd: String
    let command: [String]
    private(set) var cols: Int
    private(set) var rows: Int
    private(set) var isAlive = true
    private(set) var exitCode: Int32?
    /// Headless emulation of this session's screen; retains the final state
    /// after child exit so late attaches still get a faithful snapshot.
    let screen: SessionScreen

    /// Invoked on `queue` with each chunk read from the PTY master.
    var onOutput: ((Data) -> Void)?
    /// Invoked on `queue` after the child is reaped and buffered PTY output is
    /// drained. nil = killed by signal.
    var onExit: ((Int32?) -> Void)?

    private let queue: DispatchQueue
    private let masterFD: Int32
    private let childPID: pid_t
    private var readSource: DispatchSourceRead?
    private var readSourceSuspended = false
    private var inputWriteSource: DispatchSourceWrite?
    private var procSource: DispatchSourceProcess?
    private var reapTimer: DispatchSourceTimer?
    private var pendingInput = Data()
    private var pendingInputOffset = 0
    private var reaped = false
    private var exitDelivered = false
    private var masterClosed = false

    private enum DrainResult {
        case wouldBlock
        case limitReached
        case suspended
        case closed
    }

    /// A terminal paste can be large, but an unbounded queue would let a
    /// wedged child consume the app's memory. Rejected writes are all-or-none.
    static let inputQueueLimit = 8 * 1024 * 1024
    /// Keep one read-source event from monopolizing the server queue. The
    /// source remains armed and dispatches another event while bytes remain.
    static let maxReadBytesPerDrain = 256 * 1024

    var info: SessionInfo {
        SessionInfo(id: id, cwd: cwd, command: command, cols: cols, rows: rows, isAlive: isAlive)
    }

    /// Name of the process the terminal is currently talking to (the PTY's
    /// foreground process group leader): "zsh" at a prompt, "pi"/"htop"/…
    /// while something runs. Nil once the child is gone or on any failure —
    /// this is display candy, never load-bearing.
    var foregroundProcessName: String? {
        guard isAlive else { return nil }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0 else { return nil }
        // argv[0] first: script-based tools (pi is a node script) report
        // their interpreter ("node") through proc_name/p_comm, while argv[0]
        // carries the name the user actually ran.
        if let arg0 = Self.argv0(pid: pgid) {
            return (arg0 as NSString).lastPathComponent
        }
        var name = [CChar](repeating: 0, count: 64)
        guard proc_name(pgid, &name, UInt32(name.count)) > 0 else { return nil }
        return String(cString: name)
    }

    /// Current working directory of the shell, for keeping shell titles in
    /// sync as the user runs `cd`.
    var foregroundWorkingDirectory: String? {
        guard isAlive else { return nil }
        // The login shell owns the persisted workspace cwd. The foreground
        // job may temporarily `cd` in a subshell without changing it.
        let pid = childPID
        guard pid > 0 else { return nil }
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) {
                String(cString: $0)
            }
        }
    }

    /// Full argv of the foreground process ("pi --session-id x"), for shell
    /// restore. Nil at a bare prompt or on failure.
    var foregroundCommandLine: String? {
        guard isAlive else { return nil }
        let pgid = tcgetpgrp(masterFD)
        guard pgid > 0, let argv = Self.argv(pid: pgid), !argv.isEmpty else { return nil }
        var parts = argv
        parts[0] = (parts[0] as NSString).lastPathComponent
        return parts.joined(separator: " ")
    }

    private static func argv0(pid: pid_t) -> String? {
        argv(pid: pid)?.first
    }

    /// argv via KERN_PROCARGS2: `argc · exec_path\0 · \0… · argv[0]\0 · …`.
    private static func argv(pid: pid_t) -> [String]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
            return nil
        }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.load(as: Int32.self) })
        guard argc > 0 else { return nil }
        var index = MemoryLayout<Int32>.size
        while index < size, buffer[index] != 0 { index += 1 }   // exec_path
        while index < size, buffer[index] == 0 { index += 1 }   // padding
        var args: [String] = []
        while args.count < argc, index < size {
            let start = index
            while index < size, buffer[index] != 0 { index += 1 }
            args.append(String(decoding: buffer[start..<index], as: UTF8.self))
            index += 1
        }
        return args.isEmpty ? nil : args
    }

    init(
        id: SessionID = SessionID(),
        params: CreateSessionParams,
        queue: DispatchQueue
    ) throws {
        self.id = id
        self.queue = queue
        self.cwd = params.cwd
        self.cols = max(1, params.cols)
        self.rows = max(1, params.rows)
        self.screen = SessionScreen(cols: self.cols, rows: self.rows)

        let argv = params.command.isEmpty ? ["/bin/zsh", "-l"] : params.command
        self.command = argv

        var env = ProcessInfo.processInfo.environment
        if let extra = params.env {
            env.merge(extra) { _, new in new }
        }
        // The child is hosted by Shepherd's Ghostty surface, not by whichever
        // terminal happened to launch the app. Advertise the capabilities we
        // actually preserve across live output and screen replay: truecolor,
        // but not an inherited Kitty/iTerm/tmux image identity.
        for key in [
            "TMUX", "TMUX_PANE", "STY", "KITTY_WINDOW_ID", "GHOSTTY_RESOURCES_DIR",
            "WEZTERM_PANE", "WARP_SESSION_ID", "ITERM_SESSION_ID", "WT_SESSION",
            "TERMINAL_EMULATOR", "TERM_PROGRAM_VERSION",
        ] {
            env.removeValue(forKey: key)
        }
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Shepherd"

        guard let execPath = Self.resolveExecutable(argv[0], env: env) else {
            throw SpawnError(message: "executable not found: \(argv[0])")
        }

        // Everything the child touches is C-allocated before fork: no Swift
        // runtime or malloc calls are safe between fork and exec.
        let execPathC = strdup(execPath)
        let cwdC = strdup(params.cwd)
        let execFailMsgC = strdup("shepherd: exec failed\r\n")
        var argvC: [UnsafeMutablePointer<CChar>?] = argv.map { strdup($0) }
        argvC.append(nil)
        var envC: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") }
        envC.append(nil)
        defer {
            free(execPathC)
            free(cwdC)
            free(execFailMsgC)
            argvC.forEach { free($0) }
            envC.forEach { free($0) }
        }

        var ws = winsize(ws_row: UInt16(rows), ws_col: UInt16(cols), ws_xpixel: 0, ws_ypixel: 0)
        var master: Int32 = -1
        let pid = forkpty(&master, nil, nil, &ws)
        if pid < 0 {
            throw SpawnError(message: "forkpty failed: errno \(errno)")
        }
        if pid == 0 {
            // The app may ignore SIGTERM/SIGINT (dispatch signal sources) and
            // SIG_IGN dispositions plus blocked masks survive exec; restore
            // defaults so children are killable. Async-signal-safe calls only.
            for sig in 1..<NSIG { signal(sig, SIG_DFL) }
            var sigmask = sigset_t()
            sigemptyset(&sigmask)
            sigprocmask(SIG_SETMASK, &sigmask, nil)
            if let cwdC { _ = chdir(cwdC) }
            argvC.withUnsafeMutableBufferPointer { argvBuf in
                envC.withUnsafeMutableBufferPointer { envBuf in
                    _ = execve(execPathC, argvBuf.baseAddress, envBuf.baseAddress)
                }
            }
            if let execFailMsgC { _ = write(2, execFailMsgC, strlen(execFailMsgC)) }
            _exit(127)
        }

        self.childPID = pid
        self.masterFD = master
        let flags = fcntl(master, F_GETFL, 0)
        _ = fcntl(master, F_SETFL, flags | O_NONBLOCK)
        _ = fcntl(master, F_SETFD, FD_CLOEXEC)
    }

    /// Begin reading output and watching for child exit. Call after wiring callbacks.
    func start() {
        queue.async { self.startSources() }
    }

    /// Must run under the session's queue hierarchy. The server uses this to
    /// stop reading when the renderer's delivery queue reaches its high-water
    /// mark. Suspension is idempotent so cleanup can balance it safely.
    func suspendOutputReading() {
        guard let readSource, !readSourceSuspended, !masterClosed else { return }
        readSource.suspend()
        readSourceSuspended = true
    }

    /// Must run under the session's queue hierarchy.
    func resumeOutputReading() {
        guard let readSource, readSourceSuspended, !masterClosed else { return }
        readSource.resume()
        readSourceSuspended = false
    }

    /// Must run under the session's queue hierarchy.
    ///
    /// The PTY master is nonblocking. If the child is not reading, the
    /// remainder stays in a FIFO and a write source resumes it later. This
    /// method never waits for the child and therefore cannot stall the server
    /// queue that owns every session.
    func writeInput(_ data: Data) {
        guard isAlive, !masterClosed, !data.isEmpty else { return }

        let pendingCount = pendingInput.count - pendingInputOffset
        guard data.count <= Self.inputQueueLimit - pendingCount else {
            ShepherdLog.warning(
                "session \(id) input rejected: pending input limit is \(Self.inputQueueLimit) bytes"
            )
            return
        }

        if pendingInputOffset > 0 {
            pendingInput.removeSubrange(0..<pendingInputOffset)
            pendingInputOffset = 0
        }
        pendingInput.append(data)
        drainPendingInput()
    }

    /// Must run under the session's queue hierarchy.
    func resize(cols: Int, rows: Int) {
        let unchanged = self.cols == max(1, cols) && self.rows == max(1, rows)
        self.cols = max(1, cols)
        self.rows = max(1, rows)
        screen.resize(cols: self.cols, rows: self.rows)
        guard isAlive, !masterClosed else { return }
        var ws = winsize(
            ws_row: UInt16(self.rows), ws_col: UInt16(self.cols), ws_xpixel: 0, ws_ypixel: 0
        )
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        // A same-size ioctl emits no SIGWINCH; nudge TUIs to repaint anyway —
        // reattached surfaces need a redraw even when the grid didn't change.
        if unchanged {
            signalProcessGroup(SIGWINCH)
        }
    }

    /// Deliver a signal to the entire process group created by `forkpty`.
    /// The group id starts equal to the leader pid, and descendants inherit it
    /// unless they deliberately create another group. Must run under the
    /// session's queue hierarchy.
    func signalProcessGroup(_ sig: Int32) {
        guard childPID > 0 else { return }
        // Probe first. After the leader exits, the numeric process-group id can
        // eventually be reused. Never signal a gone group. A live child that
        // deliberately created its own group still gets the direct fallback.
        if kill(-childPID, 0) != 0 {
            guard isAlive else { return }
            if kill(childPID, sig) != 0, errno != ESRCH, errno != EPERM {
                ShepherdLog.warning("session \(id) direct signal \(sig) failed: errno \(errno)")
            }
            return
        }
        if kill(-childPID, sig) != 0, errno != ESRCH, errno != EPERM {
            ShepherdLog.warning("session \(id) group signal \(sig) failed: errno \(errno)")
        }
    }

    /// Hard shutdown for app/server stop: signal the whole group and then
    /// force it down. Must run under the session's queue hierarchy. onExit is
    /// not invoked because the app is already tearing down its callbacks.
    func shutdown() {
        guard !exitDelivered else { return }
        if !reaped {
            signalProcessGroup(SIGHUP)
            signalProcessGroup(SIGKILL)
        }
        isAlive = false
        onOutput = nil
        onExit = nil
        pendingInput.removeAll(keepingCapacity: false)
        pendingInputOffset = 0
        cancelSources()
        if !reaped {
            // Bounded reap. A SIGKILLed child reaps in milliseconds, but the
            // kill can silently fail (EPERM on a root-owned group member) or
            // the child can sit in uninterruptible sleep — and this runs on
            // the quit path with the main thread blocked behind it. Never
            // hang the app for a child the OS will reparent and reap anyway.
            let deadline = DispatchTime.now() + .seconds(2)
            var status: Int32 = 0
            while true {
                let r = waitpid(childPID, &status, WNOHANG)
                if r == childPID { break }
                if r < 0, errno != EINTR { break }  // ECHILD: nothing to reap
                if DispatchTime.now() >= deadline {
                    ShepherdLog.warning("session \(id) child \(childPID) survived shutdown; abandoning to the OS")
                    break
                }
                usleep(10_000)
            }
            reaped = true
        }
    }

    // MARK: - Internals (session queue)

    private func startSources() {
        guard !masterClosed else { return }
        let fd = masterFD
        let rs = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        rs.setEventHandler { [weak self] in self?.drainMaster() }
        rs.setCancelHandler { close(fd) }
        readSource = rs
        rs.activate()

        let ps = DispatchSource.makeProcessSource(identifier: childPID, eventMask: .exit, queue: queue)
        ps.setEventHandler { [weak self] in self?.handleChildExited() }
        ps.activate()
        procSource = ps

        // Drain once before the immediate reap check. A short-lived child can
        // already be a zombie while its final PTY bytes are still readable.
        drainMaster()
        _ = reap()

        // The process source handles exits after startup. The timer is only a
        // fallback for a leader that was already gone before registration.
        if !reaped && (kill(childPID, 0) != 0 || readSource == nil) {
            startReapTimer()
        }
    }

    private func drainMaster() {
        guard !masterClosed, !readSourceSuspended else { return }
        var buf = [UInt8](repeating: 0, count: 64 * 1024)
        var drained = 0
        while drained < Self.maxReadBytesPerDrain {
            let limit = min(buf.count, Self.maxReadBytesPerDrain - drained)
            let n = read(masterFD, &buf, limit)
            if n > 0 {
                drained += n
                let chunk = Data(bytes: buf, count: n)
                screen.feed(chunk)
                onOutput?(chunk)
                // `onOutput` can make the server suspend this source after
                // appending the chunk. Do not read past the high-water mark.
                if readSourceSuspended { return }
                continue
            }
            if n == 0 {
                handleMasterEOF()
                return
            }
            if errno == EINTR { continue }
            if errno == EAGAIN || errno == EWOULDBLOCK { return }
            // EIO: every slave side is closed.
            handleMasterEOF()
            return
        }
    }

    private func handleMasterEOF() {
        guard !masterClosed else { return }
        cancelReadSource()
        if !reap() {
            startReapTimer()
        }
    }

    private func handleChildExited() {
        // A bounded drain may need several read-source events after the
        // process has exited. `reap` leaves that source open until EOF so the
        // final bytes cannot be discarded.
        drainMaster()
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
        // A shell can exit while a background descendant remains in the PTY
        // group. Close that group before the server releases this object.
        signalProcessGroup(SIGHUP)
        signalProcessGroup(SIGKILL)
        cancelProcessSources()
        cancelInputWriteSource()
        deliverExitIfReady()
        return true
    }

    private func deliverExitIfReady() {
        guard reaped, masterClosed, !exitDelivered else { return }
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

    private func drainPendingInput() {
        guard isAlive, !masterClosed else {
            pendingInput.removeAll(keepingCapacity: false)
            pendingInputOffset = 0
            cancelInputWriteSource()
            return
        }

        while pendingInputOffset < pendingInput.count {
            let remaining = pendingInput.count - pendingInputOffset
            let result = pendingInput.withUnsafeBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return Darwin.write(
                    masterFD,
                    base.advanced(by: pendingInputOffset),
                    remaining
                )
            }
            if result > 0 {
                pendingInputOffset += result
                continue
            }
            if result == 0 {
                armInputWriteSource()
                return
            }
            if errno == EINTR { continue }
            if result < 0, errno == EAGAIN || errno == EWOULDBLOCK {
                armInputWriteSource()
                return
            }

            ShepherdLog.warning("session \(id) input write failed: errno \(errno)")
            pendingInput.removeAll(keepingCapacity: false)
            pendingInputOffset = 0
            cancelInputWriteSource()
            return
        }

        pendingInput.removeAll(keepingCapacity: true)
        pendingInputOffset = 0
        cancelInputWriteSource()
    }

    private func armInputWriteSource() {
        guard inputWriteSource == nil, !masterClosed else { return }
        let source = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: queue)
        source.setEventHandler { [weak self] in self?.drainPendingInput() }
        source.setCancelHandler {}
        inputWriteSource = source
        source.activate()
    }

    private func cancelInputWriteSource() {
        inputWriteSource?.cancel()
        inputWriteSource = nil
    }

    private func cancelProcessSources() {
        reapTimer?.cancel()
        reapTimer = nil
        procSource?.cancel()
        procSource = nil
    }

    private func cancelReadSource() {
        if let rs = readSource {
            if readSourceSuspended {
                // Dispatch sources must be resumed before cancellation. A
                // suspended source otherwise leaves its cancellation handler
                // unbalanced and can crash during teardown.
                rs.resume()
                readSourceSuspended = false
            }
            rs.cancel()  // cancel handler closes masterFD
            readSource = nil
        } else if !masterClosed {
            close(masterFD)
        }
        masterClosed = true
    }

    private func cancelSources() {
        cancelProcessSources()
        cancelInputWriteSource()
        cancelReadSource()
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
