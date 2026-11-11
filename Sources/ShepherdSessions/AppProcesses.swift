import Darwin
import Foundation
import ShepherdCore

// The apps Shepherd runs (Settings › Apps, the thread header's Run, New thread's quick actions,
// the agent's app tools): each a background process in its own process group, keyed by its
// space and name, owned here (the host's server) and by nothing else (no thread, no terminal, not
// the app, which drives them over `apps.v2`). Its output (stdout and stderr together) goes to a
// bounded ring of lines. Nothing here outlives the host: its stop stops every app, and nothing
// restarts on the next launch.
//
// One serial queue owns every app's state. Callers never wait on it: answers come back through
// completions, and `onChange` reports what changed (coalesced) on the queue, for the caller to
// hop where it needs.

/// Where an app is saved: for every space on this Mac, or in one space.
public enum AppScope: Hashable, Sendable {
    case mac
    case space(SpaceID)
}

/// One app, as everything that runs it names it: its scope and its name in that scope's file.
public struct AppKey: Hashable, Sendable {
    public var scope: AppScope
    public var name: String
    public init(scope: AppScope, name: String) {
        self.scope = scope
        self.name = name
    }
}

/// What a managed app is doing.
public enum AppStatus: Equatable, Sendable {
    /// Started; no output yet and less than a moment old.
    case starting
    case running
    /// It ended by itself (or after Stop): its exit code, 128 + the signal for a signal.
    case exited(Int32)
    /// It couldn't start.
    case failed(String)

    public var isLive: Bool { self == .starting || self == .running }
}

/// One app as the views and tools see it.
public struct AppProcessSnapshot: Equatable, Sendable {
    public var status: AppStatus
    /// The port it serves on: from its address, else the first one its output names.
    public var port: Int?
    public var directory: String
    public var command: String
    /// Lines written so far (it only grows): a view reads the lines again when it changes.
    public var lineCount: Int
    /// Grows with every bit of output, a line still being written included.
    public var revision: Int
    /// Stop was asked for and the process hasn't ended yet.
    public var stopping: Bool
}

public final class AppProcesses: @unchecked Sendable {
    /// The most lines an app keeps; older ones drop off the top.
    public static let maxLines = 5000
    /// The longest line kept; the rest of a longer one is cut.
    public static let maxLineLength = 4096
    /// How long Stop waits after SIGTERM before SIGKILL.
    public let grace: TimeInterval
    /// How long an app with no output reads as starting.
    public let settle: TimeInterval

    private final class Process {
        let pid: pid_t
        let directory: String
        let command: String
        var status: AppStatus = .starting
        var port: Int?
        let portFromAddress: Bool
        var lines: [String] = []
        var dropped = 0
        var partial = ""
        var stopping = false
        var revision = 0
        var exitSource: DispatchSourceProcess?
        var readSource: DispatchSourceRead?

        init(pid: pid_t, directory: String, command: String, port: Int?) {
            self.pid = pid
            self.directory = directory
            self.command = command
            self.port = port
            portFromAddress = port != nil
        }

        var snapshot: AppProcessSnapshot {
            AppProcessSnapshot(status: status, port: port, directory: directory, command: command,
                               lineCount: dropped + lines.count, revision: revision, stopping: stopping)
        }
    }

    private let queue = DispatchQueue(label: "shepherd.apps", qos: .userInitiated)
    private var processes: [AppKey: Process] = [:]
    /// Apps that failed to start, kept to say why.
    private var failures: [AppKey: AppProcessSnapshot] = [:]
    /// What runs a command: the user's login shell, its last argument the command. Previews
    /// replace it (`setLauncher`) so a render never shows this machine's tools or names.
    private var launcher: [String] = {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        // A login, interactive shell reads the person's rc files, so the PATH their terminal has
        // (nvm, asdf, Homebrew) finds their tools.
        return [shell, "-ilc"]
    }()
    private var notifyScheduled = false
    private var closed = false
    /// Every app's state, on the queue, at most ten times a second.
    public var onChange: (@Sendable ([AppKey: AppProcessSnapshot]) -> Void)?

    public func setLauncher(_ argv: [String]) { queue.async { self.launcher = argv } }

    public init(grace: TimeInterval = 3, settle: TimeInterval = 1) {
        self.grace = grace
        self.settle = settle
    }

    // MARK: Start and stop

    /// Starts `command` in `directory` through the user's login shell, unless it is already live.
    /// `address` gives its port up front.
    public func start(_ key: AppKey, command: String, directory: String, address: URL? = nil,
                      completion: (@Sendable (AppProcessSnapshot) -> Void)? = nil) {
        queue.async {
            if let live = self.processes[key], live.status.isLive { completion?(live.snapshot); return }
            let snapshot = self.spawn(key, command: command, directory: directory, port: address?.port ?? Self.defaultPort(address))
            self.scheduleNotify()
            completion?(snapshot)
        }
    }

    /// SIGTERM to the app's process group, then SIGKILL to it after `grace`.
    public func stop(_ key: AppKey, completion: (@Sendable () -> Void)? = nil) {
        queue.async {
            defer { completion?() }
            guard let process = self.processes[key], process.status.isLive, !process.stopping else { return }
            process.stopping = true
            kill(-process.pid, SIGTERM)
            self.scheduleNotify()
            self.queue.asyncAfter(deadline: .now() + self.grace) { [weak process] in
                // The leader is unreaped until its exit is handled, so its group id is still ours.
                guard let process, process.status.isLive else { return }
                kill(-process.pid, SIGKILL)
            }
        }
    }

    /// Quitting: every app's group gets SIGTERM, then SIGKILL after a short grace, and no app
    /// starts again in this process. Blocks the caller (the app's termination) until done.
    public func stopAll(grace: TimeInterval = 1) {
        let pids: [pid_t] = queue.sync {
            closed = true
            return processes.values.filter(\.status.isLive).map(\.pid)
        }
        for pid in pids { kill(-pid, SIGTERM) }
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, pids.contains(where: { Self.alive($0) }) { usleep(20_000) }
        for pid in pids { kill(-pid, SIGKILL) }
    }

    /// Forgets an app that has ended (Settings' removed app, a dismissed exit).
    public func forget(_ key: AppKey) {
        queue.async {
            if self.processes[key]?.status.isLive == true { return }
            self.processes[key] = nil
            self.failures[key] = nil
            self.scheduleNotify()
        }
    }

    // MARK: Reading

    public func snapshots(_ completion: @escaping @Sendable ([AppKey: AppProcessSnapshot]) -> Void) {
        queue.async { completion(self.all) }
    }

    public func snapshots() async -> [AppKey: AppProcessSnapshot] {
        await withCheckedContinuation { continuation in snapshots { continuation.resume(returning: $0) } }
    }

    /// The last `tail` lines of the app's output, the line still being written last.
    public func lines(_ key: AppKey, tail: Int, completion: @escaping @Sendable ([String]) -> Void) {
        queue.async {
            guard let process = self.processes[key] else { return completion([]) }
            var lines = process.lines
            if !process.partial.isEmpty { lines.append(process.partial) }
            completion(Array(lines.suffix(max(0, tail))))
        }
    }

    public func lines(_ key: AppKey, tail: Int) async -> [String] {
        await withCheckedContinuation { continuation in lines(key, tail: tail) { continuation.resume(returning: $0) } }
    }

    private var all: [AppKey: AppProcessSnapshot] {
        failures.merging(processes.mapValues(\.snapshot)) { _, live in live }
    }

    // MARK: Process

    private func spawn(_ key: AppKey, command: String, directory: String, port: Int?) -> AppProcessSnapshot {
        guard !closed else { return fail(key, "Shepherd is quitting.", command: command, directory: directory) }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory, isDirectory: &isDirectory), isDirectory.boolValue else {
            return fail(key, "Its folder \(directory) doesn’t exist.", command: command, directory: directory)
        }
        var fds: [Int32] = [-1, -1]
        guard pipe(&fds) == 0 else { return fail(key, "Couldn’t make a pipe (\(errno)).", command: command, directory: directory) }
        for fd in fds { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        let argv = launcher + [command]
        // Never the agent's socket, identity or secrets.
        var environment = PiHome.withoutAgentOnly(ProcessInfo.processInfo.environment)
        environment["TERM"] = "dumb"
        var args = argv.map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&actions, fds[1], STDERR_FILENO)
        posix_spawn_file_actions_addchdir(&actions, directory)
        // Its own process group, default signal dispositions and an empty mask (as BoundedCommand).
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setsigmask(&attr, &mask)
        posix_spawnattr_setpgroup(&attr, 0)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT))
        var pid: pid_t = 0
        let code = args.withUnsafeMutableBufferPointer { args in
            env.withUnsafeMutableBufferPointer { env in posix_spawn(&pid, argv[0], &actions, &attr, args.baseAddress, env.baseAddress) }
        }
        Darwin.close(fds[1])
        guard code == 0 else {
            Darwin.close(fds[0])
            return fail(key, "Couldn’t start \(argv[0]) (\(String(cString: strerror(code)))).", command: command, directory: directory)
        }
        failures[key] = nil
        let process = Process(pid: pid, directory: directory, command: command, port: port)
        processes[key] = process

        let reader = fds[0]
        _ = fcntl(reader, F_SETFL, fcntl(reader, F_GETFL, 0) | O_NONBLOCK)
        let read = DispatchSource.makeReadSource(fileDescriptor: reader, queue: queue)
        read.setEventHandler { [weak self, weak process, weak read] in
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            let count = Darwin.read(reader, &buffer, buffer.count)
            if count > 0, let self, let process {
                self.ingest(String(decoding: buffer.prefix(count), as: UTF8.self), into: process)
            } else if count == 0 || (count < 0 && errno != EAGAIN && errno != EINTR) {
                read?.cancel()
            }
        }
        read.setCancelHandler { Darwin.close(reader) }
        process.readSource = read
        read.resume()

        let exit = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: queue)
        exit.setEventHandler { [weak self, weak process] in
            guard let self, let process else { return }
            self.exited(process)
        }
        process.exitSource = exit
        exit.resume()
        // A process that died before the source was armed never fires it.
        if Self.exitedUnreaped(pid) { exited(process) }

        queue.asyncAfter(deadline: .now() + settle) { [weak self, weak process] in
            guard let process, process.status == .starting else { return }
            process.status = .running
            self?.scheduleNotify()
        }
        return process.snapshot
    }

    private func fail(_ key: AppKey, _ message: String, command: String, directory: String) -> AppProcessSnapshot {
        let snapshot = AppProcessSnapshot(status: .failed(message), port: nil, directory: directory, command: command, lineCount: 0, revision: 0, stopping: false)
        processes[key] = nil
        failures[key] = snapshot
        return snapshot
    }

    private func exited(_ process: Process) {
        guard process.status.isLive else { return }
        // Helpers the command left behind must not outlive it (BoundedCommand does the same),
        // and the unreaped leader still pins the group id while they are killed.
        kill(-process.pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(process.pid, &status, 0) < 0 && errno == EINTR {}
        let signal = status & 0x7f
        process.status = .exited(signal == 0 ? (status >> 8) & 0xff : 128 + signal)
        process.stopping = false
        process.exitSource?.cancel()
        process.exitSource = nil
        // Drain what is still in the pipe, then let it go.
        if let read = process.readSource {
            let fd = Int32(read.handle)
            var buffer = [UInt8](repeating: 0, count: 64 << 10)
            while true {
                let count = Darwin.read(fd, &buffer, buffer.count)
                guard count > 0 else { break }
                ingest(String(decoding: buffer.prefix(count), as: UTF8.self), into: process)
            }
        }
        process.readSource?.cancel()
        process.readSource = nil
        if !process.partial.isEmpty { append(process.partial, to: process); process.partial = "" }
        scheduleNotify()
    }

    // MARK: Output

    private func ingest(_ text: String, into process: Process) {
        let clean = Self.stripANSI(text)
        var pending = process.partial + clean
        process.partial = ""
        while let newline = pending.firstIndex(of: "\n") {
            append(String(pending[..<newline]), to: process)
            pending = String(pending[pending.index(after: newline)...])
        }
        // A progress line redraws itself with \r: keep what it says now.
        process.partial = String(Self.lastSegment(pending).prefix(Self.maxLineLength))
        process.revision += 1
        if process.status == .starting { process.status = .running }
        scheduleNotify()
    }

    private func append(_ raw: String, to process: Process) {
        let line = String(Self.lastSegment(raw).prefix(Self.maxLineLength))
        process.lines.append(line)
        if process.lines.count > Self.maxLines {
            let extra = process.lines.count - Self.maxLines
            process.lines.removeFirst(extra)
            process.dropped += extra
        }
        if process.port == nil, let port = Self.port(in: line) { process.port = port }
    }

    private func scheduleNotify() {
        guard !notifyScheduled else { return }
        notifyScheduled = true
        queue.asyncAfter(deadline: .now() + 0.1) {
            self.notifyScheduled = false
            self.onChange?(self.all)
        }
    }

    // MARK: Pure helpers

    /// CSI and OSC escapes out; what a terminal would show is left.
    public static func stripANSI(_ text: String) -> String {
        guard text.contains("\u{1B}") else { return text }
        return text.replacingOccurrences(of: "\u{1B}(\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])",
                                         with: "", options: .regularExpression)
    }

    private static func lastSegment(_ line: String) -> Substring {
        let trimmed = line.hasSuffix("\r") ? line.dropLast() : Substring(line)
        return trimmed.split(separator: "\r", omittingEmptySubsequences: false).last ?? trimmed
    }

    /// The port a dev server's line names: `localhost:3000`, `127.0.0.1:5173`, `0.0.0.0:8080`,
    /// `[::1]:4000`, or "port 3000".
    public static func port(in line: String) -> Int? {
        let patterns = ["(?:localhost|127\\.0\\.0\\.1|0\\.0\\.0\\.0|\\[::1?\\]):(\\d{2,5})", "(?i)\\bport\\s+(\\d{2,5})\\b"]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
                  let range = Range(match.range(at: 1), in: line), let port = Int(line[range]), (1...65535).contains(port) else { continue }
            return port
        }
        return nil
    }

    private static func defaultPort(_ url: URL?) -> Int? {
        guard let url, url.host != nil else { return nil }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    private static func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 && !exitedUnreaped(pid) }

    private static func exitedUnreaped(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }
}
