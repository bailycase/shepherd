import Darwin
import Foundation

/// Short-lived catalog/git commands, not sessions. One deadline covers input, both output pipes
/// and exit. The leader stays unreaped until its group is killed, so its PID cannot be reused.
enum BoundedCommand {
    struct Result {
        var output: Data
        var errors: Data
        var status: Int32
    }

    enum Failure: Error, Equatable { case spawn(Int32), io(Int32), timedOut, outputTooLarge }

    static func run(_ argv: [String], directory: URL? = nil,
                    environment: [String: String] = ProcessInfo.processInfo.environment,
                    input: Data? = nil, timeout: TimeInterval, outputLimit: Int = 64 << 20) throws -> Result {
        precondition(!argv.isEmpty && timeout.isFinite && timeout > 0 && timeout <= 86_400)
        precondition(outputLimit >= 0)
        var pipes = [[Int32]](repeating: [-1, -1], count: 3)
        defer { for pair in pipes { for fd in pair where fd >= 0 { Darwin.close(fd) } } }
        for i in pipes.indices {
            guard pipe(&pipes[i]) == 0 else { throw Failure.spawn(errno) }
            for fd in pipes[i] { _ = fcntl(fd, F_SETFD, FD_CLOEXEC) }
        }
        var args = argv.map { strdup($0) } + [nil]
        var env = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { args.forEach { free($0) }; env.forEach { free($0) } }
        var actions: posix_spawn_file_actions_t?
        func checked(_ code: Int32) throws { if code != 0 { throw Failure.spawn(code) } }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawn_file_actions_adddup2(&actions, pipes[0][0], STDIN_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, pipes[1][1], STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, pipes[2][1], STDERR_FILENO))
        if let directory { try checked(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
        // Same ownership and inherited-signal rules as RPCSession.spawn.
        var attr: posix_spawnattr_t?
        try checked(posix_spawnattr_init(&attr))
        defer { posix_spawnattr_destroy(&attr) }
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigemptyset(&mask)
        try checked(posix_spawnattr_setsigdefault(&attr, &defaults))
        try checked(posix_spawnattr_setsigmask(&attr, &mask))
        try checked(posix_spawnattr_setpgroup(&attr, 0))
        try checked(posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        var pid: pid_t = 0
        let code = args.withUnsafeMutableBufferPointer { args in
            env.withUnsafeMutableBufferPointer { env in
                posix_spawn(&pid, argv[0], &actions, &attr, args.baseAddress, env.baseAddress)
            }
        }
        guard code == 0 else { throw Failure.spawn(code) }
        for (i, end) in [(0, 0), (1, 1), (2, 1)] { Darwin.close(pipes[i][end]); pipes[i][end] = -1 }
        let inputFD = pipes[0][1], outputFD = pipes[1][0], errorFD = pipes[2][0]
        var reaped = false
        defer {
            if !reaped {
                // Best effort graceful exit, then kill while the unreaped leader pins the PGID.
                kill(-pid, SIGTERM)
                let grace = DispatchTime.now().uptimeNanoseconds + 200_000_000
                while !exited(pid), DispatchTime.now().uptimeNanoseconds < grace { usleep(5_000) }
                kill(-pid, SIGKILL)
                // Usually already a zombie. Never hold the caller on an uninterruptible child.
                let reapDeadline = DispatchTime.now().uptimeNanoseconds + 1_000_000_000
                var status: Int32 = 0
                while true {
                    let waited = waitpid(pid, &status, WNOHANG)
                    if waited == pid || (waited < 0 && errno != EINTR) { break }
                    if DispatchTime.now().uptimeNanoseconds >= reapDeadline {
                        reapOnExit(pid)
                        break
                    }
                    usleep(5_000)
                }
            }
        }
        for fd in [inputFD, outputFD, errorFD] {
            guard fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK) == 0 else { throw Failure.io(errno) }
        }
        guard fcntl(inputFD, F_SETNOSIGPIPE, 1) == 0 else { throw Failure.io(errno) }
        let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
        var output = Data(), errors = Data(), buffer = [UInt8](repeating: 0, count: 64 << 10)
        let input = input ?? Data()
        var written = 0, inputOpen = true, outputOpen = true, errorsOpen = true, leaderExited = false
        while true {
            guard DispatchTime.now().uptimeNanoseconds < deadline else { throw Failure.timedOut }
            if inputOpen && written == input.count {
                Darwin.close(inputFD); pipes[0][1] = -1; inputOpen = false
            }
            if !leaderExited && exited(pid) {
                leaderExited = true
                kill(-pid, SIGKILL) // Helpers must not outlive the command, even after a clean exit.
            }
            if leaderExited && !outputOpen && !errorsOpen { break }
            var fds = [pollfd(fd: outputOpen ? outputFD : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: errorsOpen ? errorFD : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: inputOpen ? inputFD : -1, events: Int16(POLLOUT), revents: 0)]
            let ready = poll(&fds, nfds_t(fds.count), 20)
            if ready < 0 { if errno == EINTR { continue }; throw Failure.io(errno) }
            for i in 0..<2 where fds[i].revents != 0 {
                let count = Darwin.read(fds[i].fd, &buffer, buffer.count)
                if count > 0 {
                    if i == 0 {
                        guard count <= outputLimit - output.count else { throw Failure.outputTooLarge }
                        output.append(contentsOf: buffer.prefix(count))
                    } else {
                        errors.append(contentsOf: buffer.prefix(count))
                        if errors.count > 64 << 10 { errors = errors.suffix(64 << 10) }
                    }
                } else if count == 0 {
                    if i == 0 { outputOpen = false } else { errorsOpen = false }
                } else if errno != EAGAIN && errno != EINTR { throw Failure.io(errno) }
            }
            if inputOpen && fds[2].revents != 0 {
                let count = input.withUnsafeBytes { Darwin.write(inputFD, $0.baseAddress!.advanced(by: written), min(64 << 10, input.count - written)) }
                if count > 0 { written += count }
                else if count < 0 && errno != EAGAIN && errno != EINTR {
                    if errno != EPIPE { throw Failure.io(errno) }
                    Darwin.close(inputFD); pipes[0][1] = -1; inputOpen = false
                }
            }
        }
        var status: Int32 = 0
        var waited: pid_t
        repeat { waited = waitpid(pid, &status, WNOHANG) } while waited < 0 && errno == EINTR
        guard waited == pid else { throw Failure.io(errno) }
        reaped = true
        let signal = status & 0x7f
        return Result(output: output, errors: errors, status: signal == 0 ? (status >> 8) & 0xff : 128 + signal)
    }

    private static func exited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        return waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT) == 0 && info.si_pid == pid
    }

    private static func reapOnExit(_ pid: pid_t) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .global(qos: .utility))
        source.setEventHandler {
            var status: Int32 = 0
            while waitpid(pid, &status, WNOHANG) < 0 && errno == EINTR {}
            source.cancel()
            source.setEventHandler {}
        }
        source.resume()
    }
}
