import AppKit
import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// The app's host when the launchd service doesn't run one (T3 Code's DesktopBackendManager):
/// whoever owns `<support>/server.lock` is followed through its `host.sock`; with no owner the app
/// runs `<own executable> --host --supervised` as its child. A child that exits unexpectedly is
/// started again with backoff (`RestartPolicy`); one that finds the workspace owned exits with
/// `SessionHost.ownedExitStatus` and the supervisor follows that owner until it lets go. The
/// child's stdin is a pipe from the app, so it stops when the app does, even by a crash.
final class HostSupervisor: @unchecked Sendable {
    /// Whether this launch is the supervisor's client (`SHEPHERD_SUPERVISED_HOST=1`). Off until
    /// Designs, Automations, Projects and Missions route through the host; the flip makes it
    /// always on and deletes the in-process start.
    static func isEnabled(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["SHEPHERD_SUPERVISED_HOST"] == "1"
    }

    /// The launch's supervisor, while the flag is on; the delegate stops its child at Quit.
    nonisolated(unsafe) static var shared: HostSupervisor?
    /// The agents the app's own child runs, for the quit question (the mirrored workspace's).
    @MainActor static var agents: () -> [Agent] = { [] }

    /// When to start the child again after it exits; pure, so the schedule is unit tested.
    struct RestartPolicy: Equatable {
        static let firstDelay: Duration = .milliseconds(500)
        static let maxDelay: Duration = .seconds(10)
        /// Failed starts in a row before the failure is shown instead of retried.
        static let failuresShown = 3

        enum Decision: Equatable {
            case restart(after: Duration)
            /// Another process owns the workspace: follow it, start nothing.
            case followOwner
            case fail
        }

        private(set) var delay = firstDelay
        private(set) var failures = 0

        /// `status` is the exit status, nil for a signal or a spawn that failed; `served` says
        /// whether its socket answered during the run.
        mutating func exited(status: Int32?, served: Bool) -> Decision {
            if status == SessionHost.ownedExitStatus {
                self = RestartPolicy()
                return .followOwner
            }
            if served {
                self = RestartPolicy()
            } else {
                failures += 1
                if failures >= Self.failuresShown { return .fail }
            }
            defer { delay = min(delay * 2, Self.maxDelay) }
            return .restart(after: delay)
        }

        /// Try Again after a shown failure: three more starts, the backoff carrying on.
        mutating func retry() { failures = 0 }
    }

    /// Three starts in a row that never served.
    struct StartFailed: Error, CustomStringConvertible {
        var lastExit: String
        var description: String { "Shepherd's session host stopped before it started, three times (\(lastExit))" }
    }

    struct Configuration: Sendable {
        var executable: URL
        var arguments: [String]
        var socket: String
        var lock: String
        /// Whether launchd's host should own the workspace (the service is on): it is waited for
        /// (`ownerGrace`) before the app starts a child of its own.
        var preferOwner: @Sendable () -> Bool = { false }
        var ownerGrace: Duration = .seconds(5)
        /// How long an owner holding the lock may stay silent before the launch says it is starting.
        var silentOwner: Duration = .seconds(5)
        var probe: Duration = .milliseconds(100)
        var ownerPoll: Duration = .seconds(1)
        /// SIGTERM to SIGKILL at stop.
        var grace: Duration = .seconds(5)
        /// The clock: every wait the loop makes.
        var sleep: @Sendable (Duration) -> Void = { Thread.sleep(forTimeInterval: seconds($0)) }
        /// The child's environment, nil for the app's.
        var environment: [String: String]?

        /// The app's own executable as the host, on the app's support directory.
        static func app(preferOwner: @escaping @Sendable () -> Bool) -> Configuration {
            let support = ShepherdPaths.supportDirectory()
            return Configuration(executable: Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]),
                                 arguments: [ShepherdHost.argument, ShepherdHost.supervisedArgument],
                                 socket: support.appendingPathComponent("host.sock").path,
                                 lock: support.appendingPathComponent("server.lock").path,
                                 preferOwner: preferOwner)
        }
    }

    private let configuration: Configuration
    /// After launch, a shown failure: Try Again calls `retry`. Set and read on main.
    var onFailure: (@MainActor (StartFailed) -> Void)?

    private let lock = NSLock()
    private var stopping = false
    private var child: Process?
    private var childExited: DispatchGroup?
    private var childServed = false
    private var launchResult: Result<Void, Error>?
    private let launched = DispatchSemaphore(value: 0)
    private let retried = DispatchSemaphore(value: 0)

    init(_ configuration: Configuration) {
        self.configuration = configuration
    }

    /// Starts supervising and blocks until a host answers (off main, in the launch's start).
    /// Throws `StartFailed` after three failed starts, or `HostStarting` for an owner that never
    /// answers.
    func start() throws {
        let thread = Thread { [self] in supervise() }
        thread.name = "HostSupervisor"
        thread.start()
        launched.wait()
        try lock.withLock { launchResult! }.get()
    }

    /// Whether the app's own child runs the agents now: Quit stops them.
    var ownsAgents: Bool { lock.withLock { child?.isRunning == true && childServed } }

    /// After a shown failure: three more starts.
    func retry() { retried.signal() }

    /// Stops supervising and the child: SIGTERM, `grace` for the host to stop every pi, then SIGKILL.
    func stop() {
        let (child, exited) = lock.withLock { () -> (Process?, DispatchGroup?) in
            stopping = true
            return (self.child, childExited)
        }
        retried.signal()
        guard let child, let exited, child.isRunning else { return }
        kill(child.processIdentifier, SIGTERM)
        if exited.wait(timeout: .now() + seconds(configuration.grace)) == .timedOut {
            ShepherdLog.connection("host \(child.processIdentifier) still running after SIGTERM; killing it")
            kill(child.processIdentifier, SIGKILL)
            _ = exited.wait(timeout: .now() + 1)
        }
    }

    /// Closes the app's end of the child's stdin, as a crash of the app would (tests).
    func closeChildStdin() {
        let pipe = lock.withLock { child?.standardInput as? Pipe }
        try? pipe?.fileHandleForWriting.close()
    }

    /// The child's pid while one runs (tests).
    var childPID: pid_t? { lock.withLock { child?.isRunning == true ? child?.processIdentifier : nil } }

    private var isStopping: Bool { lock.withLock { stopping } }

    private func supervise() {
        var policy = RestartPolicy()
        var waitForOwner = configuration.preferOwner()
        while !isStopping {
            if waitForOwner || ownerHoldsLock() {
                // An owner that left while the service is on is launchd's, restarting: wait for it again.
                let sawOwner = follow(grace: waitForOwner ? configuration.ownerGrace : .zero)
                waitForOwner = sawOwner && configuration.preferOwner()
                continue
            }
            let (status, served) = runChild()
            if isStopping { return }
            switch policy.exited(status: status.code, served: served) {
            case .followOwner:
                ShepherdLog.connection("host child found the workspace owned; following its owner")
                configuration.sleep(configuration.probe)
            case .restart(let delay):
                ShepherdLog.connection("host child exited (\(status.text)); starting it again in \(delay)")
                configuration.sleep(delay)
            case .fail:
                let failure = StartFailed(lastExit: status.text)
                ShepherdLog.connection("\(failure)")
                if !launch(.failure(failure)) {
                    DispatchQueue.main.async { [self] in onFailure?(failure) }
                }
                retried.wait()
                policy.retry()
            }
        }
    }

    /// Spawns the child and waits for it to exit: its exit and whether its socket answered.
    private func runChild() -> (status: (code: Int32?, text: String), served: Bool) {
        let process = Process()
        process.executableURL = configuration.executable
        process.arguments = configuration.arguments
        if let environment = configuration.environment { process.environment = environment }
        let input = Pipe()
        // Only the child may hold the read end; nothing else the app spawns inherits the write end.
        _ = fcntl(input.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        process.standardInput = input
        let exited = DispatchGroup()
        exited.enter()
        process.terminationHandler = { _ in exited.leave() }
        do {
            try lock.withLock {
                guard !stopping else { throw CancellationError() }
                try process.run()
                child = process
                childExited = exited
                childServed = false
            }
        } catch {
            if !(error is CancellationError) { ShepherdLog.connection("host child didn't start: \(error)") }
            return ((nil, "\(error)"), false)
        }
        ShepherdLog.connection("host child started (pid \(process.processIdentifier))")
        var served = false
        while exited.wait(timeout: .now()) == .timedOut {
            if RemoteHostClient.localSocketAnswers(configuration.socket) {
                served = true
                lock.withLock { childServed = true }
                _ = launch(.success(()))
                break
            }
            configuration.sleep(configuration.probe)
        }
        exited.wait()
        try? input.fileHandleForWriting.close()
        lock.withLock { child = nil; childExited = nil }
        let status = process.terminationReason == .exit
            ? (Optional(process.terminationStatus), "status \(process.terminationStatus)")
            : (nil, "signal \(process.terminationStatus)")
        return (status, served)
    }

    /// Follows the process holding the workspace: connected once its socket answers, until it lets
    /// go of the lock. `grace` waits for an owner that hasn't taken the lock yet (launchd's).
    /// Whether an owner answered.
    private func follow(grace: Duration) -> Bool {
        var elapsed = Duration.zero
        var answered = false
        while !isStopping {
            let held = ownerHoldsLock()
            if !held, answered || elapsed >= grace { return answered }
            if !answered, RemoteHostClient.localSocketAnswers(configuration.socket) {
                answered = true
                ShepherdLog.connection("following the host that owns the workspace")
                _ = launch(.success(()))
            }
            if !answered, held, elapsed >= configuration.silentOwner { _ = launch(.failure(BackgroundHostClient.HostStarting())) }
            let wait = answered ? configuration.ownerPoll : configuration.probe
            configuration.sleep(wait)
            elapsed += wait
        }
        return answered
    }

    /// Whether another process holds the workspace lock. ponytail: asks by taking it for an
    /// instant, so a host starting in that instant exits owned (launchd's tries again, ours
    /// follows); a lock-holder query would need the owner to publish its pid.
    private func ownerHoldsLock() -> Bool {
        let fd = open(configuration.lock, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { return true }
        flock(fd, LOCK_UN)
        return false
    }

    /// Resolves the launch once; false when it already was (later results go to `onFailure`).
    private func launch(_ result: Result<Void, Error>) -> Bool {
        let first = lock.withLock { () -> Bool in
            guard launchResult == nil else { return false }
            launchResult = result
            return true
        }
        if first { launched.signal() }
        return first
    }
}

private func seconds(_ duration: Duration) -> Double {
    Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
}

extension HostSupervisor.StartFailed {
    /// The shown failure: Quit, or (after launch) Try Again. True for Try Again.
    @MainActor static func show(_ failure: Self, canRetry: Bool) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = "Shepherd couldn't start its agents"
        alert.informativeText = "\(failure.description)."
        if canRetry { alert.addButton(withTitle: "Try Again") }
        alert.addButton(withTitle: "Quit")
        NSApp.activate()
        return canRetry && alert.runModal() == .alertFirstButtonReturn
    }
}
