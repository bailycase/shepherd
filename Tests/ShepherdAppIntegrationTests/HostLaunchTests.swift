import Darwin
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// `python3 scripts/validate.py --case c-launch`: a real host process starts on a large workspace and answers.
///
/// A Mac with 137 synced projects could not open Shepherd: the background host ran out of descriptors while Fleet opened its
/// content indexes, never bound `host.sock`, and the app waited forever. launchd gives a job 256 descriptors (the host's plist sets
/// no `SoftResourceLimits`), so each host here runs in its own process (an exit test) with that soft limit, started the way
/// `ShepherdHost.main` starts it: `SessionHost.run` with the host's services. `main` itself reads the user's preferences and
/// launchd, so the test builds the same `Services` on scratch settings. This process opens the host's socket with a real request
/// and counts the host's descriptors with `proc_pidinfo`.
///
/// The host is in a process of its own that guards itself before the host starts: it exits if this process dies, at a hard deadline,
/// and on a `stop` file this process writes (no signal by PID, so a recycled PID is never hit). It also reports on itself (its peak
/// sampled descriptors from a timer source started before the host, sampled open() failures, its TCP listeners, the soft limit
/// it read back) to `child-report`, so this process needs no PID. The host is `SessionHost.run` as `ShepherdHost.main` calls it, with
/// two differences, both so the test touches nothing outside its scratch: Fleet does not advertise (no Bonjour, no iCloud:
/// `configureFleet(advertises: false)`), and the port Fleet asks to listen on is one the child holds bound, so the bind fails and
/// the host opens no TCP listener.
///
/// Once #879 (`fix/host-fd-exhaustion`) has merged, `main` tells `SessionHost.run` to start Fleet (`startFleet: true`): pass it in
/// `launch` too. Until then, and if it is forgotten, the test fails on "the index never reached every checkout", so a host that
/// never started Fleet cannot pass.
@Suite("Host launch on a large workspace", .serialized, .integrationTimeLimit,
       .enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LAUNCH_SMOKE"] == "1", "run validate.py --case c-launch"))
struct HostLaunchTests {
    /// Spaces Fleet syncs; every fifth also has a worktree a thread works in, which Fleet indexes too.
    static let spaceCount = 150
    static let worktreeEvery = 5
    static var worktreeCount: Int { (spaceCount + worktreeEvery - 1) / worktreeEvery }

    /// launchd's soft limit for a job that sets none.
    static let launchdDescriptorLimit: rlim_t = 256
    /// `host.sock` answers a real request within this long of the host starting.
    static let socketBound = 20
    /// Fleet's indexes have each made their first scan within this long.
    static let scanBound = 30
    /// The host's descriptors once Fleet is running and once every index has scanned: under launchd's limit.
    static let descriptorBudget = 256
    /// What each space may add to those, beyond the ones the host started with (the sync engine watches each checkout's
    /// `.git/config`: one).
    static let descriptorsPerSpace = 2.0
    /// A peak this close to the limit is exhaustion: a peak can never pass the limit, so "under the limit" proves nothing. The
    /// reopen-before-close spike of a healthy watcher is about 190.
    static let exhaustionMargin = 32
    /// One call to the host (a request, a connect) gets this long, so a hung one cannot hold a wait that `eventually` cannot interrupt.
    static let callBound = 5
    /// Independent backstop if the observer cannot stop the child.
    static let childDeadlineSeconds = 110
    /// How long a host gets to stop on SIGTERM before the child ends itself.
    static let stopGraceSeconds = 20

    @Test func aHostStartsAndAnswersWithManySyncedSpaces() async throws {
        let workspace = try Workspace.make(label: "current")
        defer { Self.removeScratch(workspace.dir) }
        let state = ShepherdState(spaces: workspace.spaces, tabs: workspace.tabs, agents: workspace.agents)
        try JSONEncoder().encode(state).write(to: workspace.dir.appendingPathComponent("state.json"))
        try await Self.launch(workspace, expectedRoots: Self.spaceCount + Self.worktreeCount, steps: Self.currentSteps)
    }

    /// The same start, from the oldest `state.json` the state golden holds (`Tests/Fixtures/c-state.json`), grown to the same
    /// number of spaces. Its agent is saved idle so the host respawns no pi, and its own space and pane move from `/tmp/acme` to a
    /// folder in the scratch workspace (an existing `/tmp/acme` would change what the host indexes).
    @Test func aHostStartsFromAWorkspaceSavedByAnEarlierShape() async throws {
        let workspace = try Workspace.make(label: "legacy", worktrees: false)
        defer { Self.removeScratch(workspace.dir) }
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/c-state.json")
        let files = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: Any])
            .flatMap { ($0["seed"] as? [String: Any])?["files"] as? [[String: Any]] })
        var saved = try #require(files.first { $0["case"] as? String == "workspace-initial" }?["json"] as? [String: Any])
        saved["agents"] = ((saved["agents"] as? [[String: Any]]) ?? []).map { $0.merging(["status": "idle"]) { _, new in new } }
        let acme = workspace.dir.appendingPathComponent("legacy/acme", isDirectory: true)
        try FileManager.default.createDirectory(at: acme, withIntermediateDirectories: true)
        saved = try #require(Self.rebased(saved, from: "/tmp/acme", to: acme.path) as? [String: Any])
        saved["spaces"] = ((saved["spaces"] as? [[String: Any]]) ?? []) + workspace.spaces.map {
            ["hidden": false, "id": $0.id.rawValue, "name": $0.name, "path": $0.path]
        }
        try #require(Self.paths(in: saved).allSatisfy { $0.hasPrefix(workspace.dir.path + "/") }, "every path in the state is in the scratch folder")
        try JSONSerialization.data(withJSONObject: saved).write(to: workspace.dir.appendingPathComponent("state.json"))
        try await Self.launch(workspace, expectedRoots: Self.spaceCount, steps: Self.legacySteps)
    }

    enum EarlyStop: String, CaseIterable, Sendable {
        case timeout, parentDeath, deadline
    }

    @Test(arguments: EarlyStop.allCases)
    func earlyStopDeletesBothScratchPaths(_ reason: EarlyStop) async throws {
        var workspace = try makeScratchDirectory("stop")
        defer { Self.removeScratch(workspace) } // fallback after checking the child's cleanup
        let witness = try makeScratchDirectory("witness")
        defer { Self.removeScratch(witness) }
        let receipt = witness.appendingPathComponent("child-root")

        let parentWorkspace = workspace
        switch reason {
        case .timeout:
            let observer = Task {
                do {
                    try await eventually("the guardian to arm", timeout: .seconds(5)) { FileManager.default.fileExists(atPath: receipt.path) }
                    #expect(await Self.waitForHost(parentWorkspace, timeout: .milliseconds(100)) == nil)
                    Self.requestStop(parentWorkspace)
                } catch { Issue.record(error) }
            }
            await Self.guardControl(workspace: workspace.path, receipt: receipt.path, deadline: 10, status: 76)
            await observer.value
        case .deadline:
            await Self.guardControl(workspace: workspace.path, receipt: receipt.path, deadline: 2, status: 72)
        case .parentDeath:
            try await Self.runDyingParent(receipt: receipt)
        }
        let paths = try String(contentsOf: receipt, encoding: .utf8).split(separator: "\n").map(String.init)
        try #require(paths.count == 2)
        let childRoot = URL(fileURLWithPath: paths[1], isDirectory: true)
        if reason == .parentDeath {
            let ownedPrefix = TestProcess.root.path + "/shepherd-tests-"
            try #require(paths[0].hasPrefix(ownedPrefix) && paths[1].hasPrefix(ownedPrefix))
            Self.removeScratch(workspace)
            workspace = URL(fileURLWithPath: paths[0], isDirectory: true)
            // Verify before deleting the disposable parent's own isolation root, not this test's root.
            let disposedParentRoot = workspace.deletingLastPathComponent()
            defer { Self.removeScratch(disposedParentRoot) }
            try await Self.expectClean(workspace, childRoot, reason: reason, receipt: receipt)
            return
        }
        try #require(paths[0] == workspace.path)
        try await Self.expectClean(workspace, childRoot, reason: reason, receipt: receipt)
    }

    private static func expectClean(_ workspace: URL, _ childRoot: URL, reason: EarlyStop, receipt: URL) async throws {
        try await eventually("both exact scratch paths to disappear after \(reason.rawValue)", timeout: .seconds(5)) {
            Self.scratchIsGone(workspace) && Self.scratchIsGone(childRoot)
        }
        #expect(FileManager.default.fileExists(atPath: receipt.path), "the guardian must not remove unrelated scratch")
        print("launch cleanup \(reason.rawValue): absent \(workspace.path) and \(childRoot.path)")
    }

    /// Swift Testing cannot nest exit tests. Re-run just the driver in a fresh SwiftPM test runner.
    private static func runDyingParent(receipt: URL) async throws {
        let args = CommandLine.arguments
        let index = try #require(args.firstIndex(of: "--test-bundle-path"), "run this diagnostic with SwiftPM")
        try #require(index + 1 < args.count)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        let bundle = args[index + 1]
        process.arguments = ["--test-bundle-path", bundle, "--filter", "HostLaunchTests/dyingParentDriver", bundle, "--testing-library", "swift-testing"]
        var env = ProcessInfo.processInfo.environment
        env["TMPDIR"] = TestProcess.root.path
        env["SHEPHERD_LAUNCH_DEATH_RECEIPT"] = receipt.path
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer { if process.isRunning { process.terminate() } }
        try await eventually("the disposable parent to exit", timeout: .seconds(15)) { !process.isRunning }
        try #require(process.terminationReason == .exit && process.terminationStatus == 80)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["SHEPHERD_LAUNCH_DEATH_RECEIPT"] != nil))
    func dyingParentDriver() async throws {
        let receipt = try #require(ProcessInfo.processInfo.environment["SHEPHERD_LAUNCH_DEATH_RECEIPT"])
        let workspace = try makeScratchDirectory("parent-death")
        let parent = Task {
            do {
                try await eventually("the guardian to arm", timeout: .seconds(5)) { FileManager.default.fileExists(atPath: receipt) }
                // No atexit cleanup: the guardian must remove the workspace, not the parent.
                _exit(80)
            } catch { exit(81) }
        }
        await Self.guardControl(workspace: workspace.path, receipt: receipt, deadline: 10, status: 71)
        parent.cancel()
        Issue.record("the guardian exited before its parent")
    }

    private static func guardControl(workspace: String, receipt: String, deadline: Int, status: Int32) async {
        await #expect(processExitsWith: .exitCode(status)) { [workspace, receipt, deadline, parent = getpid() as Int32] in
            let directory = URL(fileURLWithPath: workspace, isDirectory: true)
            let guardian = ChildGuard(directory: directory)
            guardian.arm(parent: parent, deadline: deadline, grace: 1)
            do { try "\(workspace)\n\(TestProcess.root.path)".write(toFile: receipt, atomically: true, encoding: .utf8) }
            catch { guardian.die("cannot publish cleanup witness", 83) }
            // No host, no network, and no pid signals in the controls. Only the armed guard can end this child.
            while true { pause() }
        }
    }

    /// `value` with each string that is `old` (or starts with it and a slash) moved under `new`.
    static func rebased(_ value: Any, from old: String, to new: String) -> Any {
        switch value {
        case let text as String: return text == old || text.hasPrefix(old + "/") ? new + text.dropFirst(old.count) : text
        case let list as [Any]: return list.map { rebased($0, from: old, to: new) }
        case let object as [String: Any]: return object.mapValues { rebased($0, from: old, to: new) }
        default: return value
        }
    }

    /// Every string in `value` that is an absolute path.
    static func paths(in value: Any) -> [String] {
        switch value {
        case let text as String: return text.hasPrefix("/") ? [text] : []
        case let list as [Any]: return list.flatMap { paths(in: $0) }
        case let object as [String: Any]: return object.values.flatMap { paths(in: $0) }
        default: return []
        }
    }

    static let currentSteps = Steps(socket: "socket-answers", isolated: "host-isolated", descriptors: "descriptors", scan: "still-answering")
    static let legacySteps = Steps(socket: "legacy-state-socket-answers", isolated: "legacy-state-host-isolated",
                                   descriptors: "legacy-state-descriptors", scan: "legacy-state-still-answering")

    struct Steps {
        let socket: String, isolated: String, descriptors: String, scan: String
        var all: [String] { [socket, isolated, descriptors, scan] }
    }

    // MARK: The host (child process)

    /// Starts the host in a process of its own (an exit test), watches it from here, and stops it by writing its `stop` file. A host that
    /// never answers fails the steps and is still stopped, and the child ends itself if this process cannot stop it (see `runHost`).
    private static func launch(_ workspace: Workspace, expectedRoots: Int, steps: Steps) async throws {
        let socket = workspace.dir.appendingPathComponent("host.sock").path
        try #require(socket.utf8.count < 100, "a unix socket path is capped at 104 bytes")
        let monitor = Task { await observe(workspace, socket: socket, expectedRoots: expectedRoots, steps: steps) }
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) { [dir = workspace.dir.path as String, parent = ProcessInfo.processInfo.processIdentifier as Int32] in
            await Self.runHost(directory: dir, parent: parent)
        }
        // The child is gone. A host that died early leaves the observer waiting on nothing: stop it.
        monitor.cancel()
        let observed = await monitor.value
        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        let final = ChildReport.read(workspace.dir)
        if let final { #expect(scratchIsGone(URL(fileURLWithPath: final.isolationRoot)), "child isolation root was deleted") }
        observed.report.note("scratch folder: \(Self.size(of: workspace.dir))")
        try observed.finish(steps: steps, expectedRoots: expectedRoots, final: final, hostLog: stderr)
    }

    /// What the child process does, in order: ends if this process is not its parent; arms its guards (parent exit, hard deadline, the
    /// stop file); fixes launchd's soft limit and reads it back; opens its report; then builds what `ShepherdHost.main` builds and
    /// runs the host. Any guard that cannot be set exits at once, before a host exists, so no host can outlive a failed setup.
    private static func runHost(directory: String, parent: pid_t) async -> Never {
        let url = URL(fileURLWithPath: directory)
        let guardian = ChildGuard(directory: url)
        guardian.arm(parent: parent, deadline: childDeadlineSeconds, grace: stopGraceSeconds)

        // As launchd starts a job: a soft limit of 256 descriptors. The test process raises its own (ShepherdTestIsolation).
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { guardian.die("getrlimit before setting failed (errno \(errno))", 73) }
        limit.rlim_cur = min(launchdDescriptorLimit, limit.rlim_max)
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { guardian.die("setrlimit failed (errno \(errno))", 73) }
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { guardian.die("getrlimit readback failed (errno \(errno))", 73) }
        guard limit.rlim_cur == launchdDescriptorLimit else {
            guardian.die("the soft descriptor limit reads back \(limit.rlim_cur), not \(launchdDescriptorLimit)", 73)
        }

        let reporter = ChildReporter(directory: url, guardian: guardian)
        // A bound socket that never listens: Fleet's request for the remote listener (a Mac is paired) then fails in `bind` on this
        // port, and the host opens no TCP listener, so it cannot collide with the owner's Shepherd or answer on their network.
        let blocked = guardian.blockPort()
        reporter.start(limit: UInt64(limit.rlim_cur))

        let server = SessionServer(socketPath: url.appendingPathComponent("shepherd.sock").path, stateURL: url.appendingPathComponent("state.json"))
        // No Bonjour advertisement and no iCloud lookup (`FleetService.advertises`).
        server.configureFleet(name: "Launch gate", advertises: false)
        let host = await MainActor.run { () -> HostPieces in
            let settings = AppSettings(store: ScratchDefaults())
            settings.remoteListenerPort = Int(blocked)
            return HostPieces(ShepherdHost.Services(settings: settings,
                                                    mcpStore: MCPStore(dependencies: .app(pi: server.pi, openURL: { _ in }, copy: { _ in })),
                                                    notifications: AgentNotifications(activate: {}), keepsAgentsRunning: { nil }))
        }
        reporter.markHostStarting()
        SessionHost.run(server, respawn: host.respawn, configure: host.configure, threads: host.threads, automations: host.automations,
                        pullRequests: host.pullRequests, banners: host.banners, ready: {
            guardian.onStop.withValue { $0 = { reporter.stopHost() } }
        })
    }

    /// What `ShepherdHost.main` hands `SessionHost.run`, made on the main actor and used off it, as the exit test must.
    private struct HostPieces: @unchecked Sendable {
        let services: ShepherdHost.Services
        let respawn: @MainActor @Sendable (Agent) -> AgentSpawn
        let configure: @MainActor @Sendable (SessionServer) -> Void
        let threads: @MainActor @Sendable (SessionServer) -> ThreadHosting
        let automations: @MainActor @Sendable (SessionServer) -> AutomationHosting
        let pullRequests: @MainActor @Sendable (SessionServer) -> PullRequestLinkHosting
        let banners: @MainActor @Sendable (SessionServer) -> ThreadBanners.Sink

        @MainActor init(_ services: ShepherdHost.Services) {
            self.services = services
            respawn = { services.respawn($0) }
            configure = { services.configure($0) }
            threads = { services.threads($0) }
            automations = { services.automations($0) }
            pullRequests = { services.pullRequests($0) }
            banners = { services.banners($0) }
        }
    }

    // MARK: The child's guards and report

    /// What the child says about itself, in `child-report`: rewritten in place, at a fixed size, so a read never sees half of it.
    struct ChildReport: Codable {
        static let fileName = "child-report"
        static let size = 8192
        var pid: Int32 = 0
        var isolationRoot = ""
        /// The soft descriptor limit the child read back after setting it.
        var limit: UInt64 = 0
        /// The soft limit now: a host may raise its own.
        var limitNow: UInt64 = 0
        /// Descriptors held just before the host started.
        var baseline: Int?
        var current: Int?
        var sampledAt: UInt64?
        var samplingFailure: String?
        var peak = 0
        /// Descriptors by kind at the peak (1 vnode, 2 socket, 3 pshm, 5 pipe, 6 kqueue).
        var peakTypes: [String: Int] = [:]
        /// Times an `open()` probe on the sampler's tick failed with EMFILE or ENFILE: the host had no descriptor left.
        var exhausted = 0
        /// TCP sockets in the LISTEN state now, the most there were at once, and every local port one had.
        var listening = 0
        var mostListening = 0
        var listenPorts: [Int] = []
        /// The vnode paths held most when the count first came within the margin of the limit, and each time it doubled after that (what a
        /// runaway watcher opens).
        var top: [String] = []
        var ticks = 0
        var hostStartedAt: UInt64?
        var stopping = false

        static func read(_ directory: URL) -> ChildReport? {
            guard let data = try? Data(contentsOf: directory.appendingPathComponent(fileName)) else { return nil }
            let text = data.prefix { $0 != 0 }
            return try? JSONDecoder().decode(ChildReport.self, from: Data(String(decoding: text, as: UTF8.self).trimmingCharacters(in: .whitespaces).utf8))
        }
    }

    /// The child's guards: each runs on its own queue, apart from the host's and the main queue, which a wedged host may block.
    private final class ChildGuard: @unchecked Sendable {
        let directory: URL
        let queue = DispatchQueue(label: "launch.child.guard")
        private var sources: [any DispatchSourceProtocol] = []
        private var blocker: Int32 = -1
        private let stopping = Locked(false)
        /// Installed only once SessionHost handles SIGTERM. Before then the guard cleans up itself.
        let onStop = Locked<(@Sendable () -> Void)?>(nil)

        init(directory: URL) { self.directory = directory }

        /// The workspace belongs to this launch, not to any other test. Never remove the parent's isolation root.
        func die(_ message: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data("launch child: \(message)\n".utf8))
            for path in [directory, TestProcess.root] { try? FileManager.default.removeItem(at: path) }
            guard HostLaunchTests.scratchIsGone(directory), HostLaunchTests.scratchIsGone(TestProcess.root) else {
                FileHandle.standardError.write(Data("launch child: scratch cleanup failed\n".utf8))
                _exit(79)
            }
            _exit(code)
        }

        func arm(parent: pid_t, deadline: Int, grace: Int) {
            guard getppid() == parent else { die("its parent is not the test process (\(getppid()) is not \(parent))", 70) }
            // This process exits when the test process does, however that ends.
            let death = DispatchSource.makeProcessSource(identifier: parent, eventMask: .exit, queue: queue)
            death.setEventHandler { [self] in die("the test process exited", 71) }
            death.activate()
            // The process source misses a parent that died between the check and now.
            guard getppid() == parent, kill(parent, 0) == 0 else { die("the test process is gone", 71) }
            // Whatever the test process is doing, and whatever the host is doing, this ends.
            let hard = DispatchSource.makeTimerSource(queue: queue)
            hard.schedule(deadline: .now() + .seconds(deadline))
            hard.setEventHandler { [self] in die("hard deadline of \(deadline) s reached", 72) }
            hard.activate()
            // The test process asks for the stop by making this file; the host then stops as it does on SIGTERM.
            let stopFile = directory.appendingPathComponent("stop").path
            let fd = open(directory.path, O_EVTONLY)
            guard fd >= 0 else { die("cannot watch \(directory.lastPathComponent): \(String(cString: strerror(errno)))", 74) }
            let watch = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: queue)
            watch.setEventHandler { [self] in
                guard access(stopFile, F_OK) == 0, stopping.withValue({ let first = !$0; $0 = true; return first }) else { return }
                guard let onStop = onStop.current else { die("stopped before the host was ready", 76) }
                queue.asyncAfter(deadline: .now() + .seconds(grace)) { [self] in die("the host did not stop within \(grace) s", 75) }
                onStop()
            }
            watch.setCancelHandler { close(fd) }
            watch.activate()
            sources = [death, hard, watch]
            // A stop file made before the watch existed is not an event.
            if access(stopFile, F_OK) == 0 { die("stopped before it started", 76) }
        }

        /// Binds a TCP socket on every interface at a port the kernel picks and never listens on it: any later bind of that port fails.
        func blockPort() -> UInt16 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_addr = in_addr(s_addr: INADDR_ANY)
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let bound = withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                    bind(fd, pointer, length) == 0 && getsockname(fd, pointer, &length) == 0
                }
            }
            guard fd >= 0, bound else { die("cannot reserve a port for the remote listener: \(String(cString: strerror(errno)))", 77) }
            blocker = fd
            return UInt16(bigEndian: address.sin_port)
        }
    }

    /// Samples in the child from before host start. A spike between ticks can still be missed.
    private final class ChildReporter: @unchecked Sendable {
        private let report = Locked(ChildReport())
        private let fd: Int32
        private let guardian: ChildGuard
        private let queue = DispatchQueue(label: "launch.child.sampler")
        private var timer: DispatchSourceTimer?
        private var lastNamed = 0
        private var lastWrite = ContinuousClock.now

        /// Opens the report (and writes the pid into it) or ends the child: a host nobody can find is not started.
        init(directory: URL, guardian: ChildGuard) {
            self.guardian = guardian
            fd = open(directory.appendingPathComponent(ChildReport.fileName).path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { guardian.die("cannot open its report: \(String(cString: strerror(errno)))", 78) }
            report.withValue { $0.pid = getpid(); $0.isolationRoot = TestProcess.root.path }
            write()
        }

        func start(limit: UInt64) {
            report.withValue { $0.limit = limit }
            let timer = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(1), leeway: .microseconds(100))
            timer.setEventHandler { [self] in tick() }
            timer.activate()
            self.timer = timer
        }

        func markHostStarting() {
            queue.sync {
                guard let baseline = HostLaunchTests.fdList(of: getpid())?.count else {
                    guardian.die("cannot sample the baseline descriptor count", 78)
                }
                report.withValue { $0.baseline = baseline; $0.hostStartedAt = HostLaunchTests.now }
                write()
            }
        }

        func stopHost() {
            queue.async { [self] in
                timer?.cancel()
                report.withValue { $0.stopping = true }
                write()
                kill(getpid(), SIGTERM)
            }
        }

        private func sampleFailed(_ reason: String) {
            report.withValue { $0.samplingFailure = $0.samplingFailure ?? reason }
            write()
        }

        private func tick() {
            let sampledAt = HostLaunchTests.now
            let probe = open("/dev/null", O_RDONLY | O_CLOEXEC)
            let probeError = probe < 0 ? errno : 0
            if probe >= 0 { close(probe) }
            let exhausted = probeError == EMFILE || probeError == ENFILE
            if exhausted { report.withValue { $0.exhausted += 1 } }
            guard probeError == 0 || exhausted else { sampleFailed("open probe failed with errno \(probeError)"); return }
            guard let list = HostLaunchTests.fdList(of: getpid()) else { sampleFailed("descriptor list unavailable"); return }
            var now = rlimit()
            guard getrlimit(RLIMIT_NOFILE, &now) == 0 else { sampleFailed("sample getrlimit failed (errno \(errno))"); return }
            var ports: [Int] = []
            for entry in list where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                guard proc_pidfdinfo(getpid(), entry.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP), info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
                ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
            }
            var names: [String: Int]?
            if list.count >= Int(HostLaunchTests.launchdDescriptorLimit) - HostLaunchTests.exhaustionMargin, list.count > lastNamed * 2 {
                lastNamed = list.count
                names = [:]
                for entry in list where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var info = vnode_fdinfowithpath()
                    guard proc_pidfdinfo(getpid(), entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                    let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                    names?[path, default: 0] += 1
                }
            }
            let changed = report.withValue { report -> Bool in
                report.ticks += 1
                report.current = list.count
                report.sampledAt = sampledAt
                var changed = exhausted
                if now.rlim_cur != report.limitNow { report.limitNow = now.rlim_cur; changed = true }
                if list.count > report.peak {
                    report.peak = list.count
                    report.peakTypes = Dictionary(list.map { (String($0.proc_fdtype), 1) }, uniquingKeysWith: +)
                    changed = true
                }
                if ports.count != report.listening || ports.count > report.mostListening { changed = true }
                report.listening = ports.count
                report.mostListening = max(report.mostListening, ports.count)
                for port in ports where !report.listenPorts.contains(port) { report.listenPorts.append(port) }
                if let names { report.top = names.sorted { $0.value > $1.value }.prefix(10).map { "\($0.value) x \($0.key.suffix(110))" }; changed = true }
                return changed
            }
            // Written when it matters, and otherwise about every 100 ms.
            if changed || lastWrite.duration(to: .now) > .milliseconds(100) { write(); lastWrite = .now }
        }

        /// The whole report at one fixed size, in one write.
        private func write() {
            var snapshot = report.current
            var encoded = try? JSONEncoder().encode(snapshot)
            if (encoded?.count ?? 0) > ChildReport.size { snapshot.top = []; encoded = try? JSONEncoder().encode(snapshot) }
            guard var data = encoded, data.count <= ChildReport.size else { guardian.die("cannot encode the child report", 78) }
            data.append(Data(repeating: 0, count: ChildReport.size - data.count))
            guard data.withUnsafeBytes({ pwrite(fd, $0.baseAddress, data.count, 0) }) == data.count else {
                guardian.die("cannot write the child report (errno \(errno))", 78)
            }
        }
    }

    // MARK: The observer (this process)

    /// What `observe` learned, and the steps it settled; `finish` adds the ones that need the child's final report.
    private final class Observed: @unchecked Sendable {
        let report = Report()
        var running: Int?
        var afterStart: Int?
        var afterScan: Int?

        func finish(steps: Steps, expectedRoots: Int, final: ChildReport?, hostLog: String) throws {
            if let final {
                let growth = if let baseline = final.baseline, let afterStart, let afterScan {
                    Double(max(afterStart, afterScan) - baseline) / Double(HostLaunchTests.spaceCount)
                } else { nil as Double? }
                let types = final.peakTypes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                let measured = "sampled peak \(final.peak) of \(final.limit), \(final.baseline.map(String.init) ?? "?") before Fleet, \(afterStart.map(String.init) ?? "?") with "
                    + "\(running.map(String.init) ?? "no") indexes running, \(afterScan.map(String.init) ?? "?") after the first scan "
                    + "(\(growth.map { String(format: "%.2f", $0) } ?? "?") per space), \(final.exhausted) sampled EMFILE/ENFILE probes"
                report.note(measured)
                if final.limitNow != final.limit { report.note("the host raised its own soft limit from \(final.limit) to \(final.limitNow)") }
                report.note("peak by type: \(types) (1 vnode, 2 socket, 3 pshm, 5 pipe, 6 kqueue); sampled \(final.ticks) times")
                for line in final.top { report.note("  \(line)") }
                var problems: [String] = []
                if running != expectedRoots { problems.append("the index never reached every checkout (\(running.map(String.init) ?? "no index"))") }
                if final.baseline == nil { problems.append("missing baseline descriptor sample") }
                if !final.stopping { problems.append("missing final sampler report") }
                if let failure = final.samplingFailure { problems.append(failure) }
                if afterStart == nil { problems.append("missing fresh running descriptor sample") }
                if afterScan == nil { problems.append("missing fresh post-scan descriptor sample") }
                if final.exhausted > 0 { problems.append("the host ran out of descriptors (\(final.exhausted) sampled EMFILE/ENFILE probes)") }
                if final.peak >= Int(final.limit) - HostLaunchTests.exhaustionMargin {
                    problems.append("the sampled peak \(final.peak) is within \(HostLaunchTests.exhaustionMargin) of the limit \(final.limit)")
                }
                if [afterStart, afterScan].compactMap({ $0 }).contains(where: { $0 >= HostLaunchTests.descriptorBudget }) {
                    problems.append("descriptors once running are not under \(HostLaunchTests.descriptorBudget)")
                }
                if let growth, growth > HostLaunchTests.descriptorsPerSpace { problems.append("more than \(HostLaunchTests.descriptorsPerSpace) descriptors per space") }
                let expected = "zero sampled EMFILE/ENFILE probes, a sampled peak more than \(HostLaunchTests.exhaustionMargin) under the \(HostLaunchTests.launchdDescriptorLimit) limit, under \(HostLaunchTests.descriptorBudget) once running, "
                    + "at most \(HostLaunchTests.descriptorsPerSpace) more per space, with all \(expectedRoots) indexes running"
                if problems.isEmpty { report.pass(steps.descriptors, expected: expected, actual: measured) }
                else { report.fail(steps.descriptors, expected: expected, actual: problems.joined(separator: "; ") + ": " + measured) }

                let isolatedExpected = "the soft limit reads back \(HostLaunchTests.launchdDescriptorLimit), no TCP listener ever open in the host, none on the edition's own port, and no listener line in its log"
                var leaks: [String] = []
                if final.limit != HostLaunchTests.launchdDescriptorLimit { leaks.append("soft limit \(final.limit)") }
                if final.mostListening > 0 { leaks.append("\(final.mostListening) TCP listener(s) on port(s) \(final.listenPorts)") }
                if hostLog.contains("remote listener on port") { leaks.append("the log says the remote listener opened") }
                if leaks.isEmpty { report.pass(steps.isolated, expected: isolatedExpected, actual: "limit \(final.limit), no TCP listener in \(final.ticks) samples") }
                else { report.fail(steps.isolated, expected: isolatedExpected, actual: leaks.joined(separator: "; ")) }
            }
            try report.record(steps: steps, hostLog: hostLog)
        }
    }

    // Darwin's system-wide uptime clock, comparable across the child and the observer.
    private static var now: UInt64 { DispatchTime.now().uptimeNanoseconds }

    private static func remaining(until deadline: UInt64) -> Duration? {
        let instant = now
        return instant < deadline ? .nanoseconds(deadline - instant) : nil
    }

    /// An uncooperative call cannot keep the observer waiting. Check time on both sides of delivery
    /// so a late reply cannot win just because the timeout task was scheduled late too.
    private static func within<T: Sendable>(until deadline: UInt64, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        let deadline = min(deadline, (DispatchTime.now() + .seconds(callBound)).uptimeNanoseconds)
        let (stream, reply) = AsyncStream<T?>.makeStream()
        let call = Task {
            guard !Task.isCancelled, now < deadline else { reply.finish(); return }
            let value = await operation()
            if now < deadline { reply.yield(value) }
            reply.finish()
        }
        let timer = Task {
            if let left = remaining(until: deadline) { try? await Task.sleep(for: left) }
            reply.finish()
        }
        defer { call.cancel(); timer.cancel() }
        for await value in stream { return now < deadline ? value : nil }
        return nil
    }

    private static func poll(until deadline: UInt64, _ condition: () async -> Bool) async -> Bool {
        guard let left = remaining(until: deadline) else { return false }
        do {
            try await eventually("host readiness", timeout: left, poll: .milliseconds(50)) {
                guard now < deadline else { return false }
                let ready = await condition()
                return ready && now < deadline
            }
            return true
        } catch { return false }
    }

    private static func waitForHost(_ directory: URL, timeout: Duration) async -> ChildReport? {
        var started: ChildReport?
        try? await eventually("the host process to report", timeout: timeout) {
            started = ChildReport.read(directory)
            return started?.hostStartedAt != nil
        }
        return started
    }

    private static func requestStop(_ directory: URL) {
        let path = directory.appendingPathComponent("stop").path
        if !scratchIsGone(directory) {
            #expect(FileManager.default.createFile(atPath: path, contents: nil) || scratchIsGone(directory), "could not request child stop")
        }
    }

    private static func freshDescriptorCount(in directory: URL, after checkpoint: UInt64, until deadline: UInt64) async -> Int? {
        var count: Int?
        let ready = await poll(until: deadline) {
            guard let sample = ChildReport.read(directory) else { return false }
            if sample.samplingFailure != nil || sample.stopping { return true } // no later report can repair this
            let instant = now
            guard let sampledAt = sample.sampledAt, sampledAt >= checkpoint, sampledAt <= instant, sampledAt < deadline,
                  instant - sampledAt < 500_000_000 else { return false }
            count = sample.current
            return count != nil
        }
        return ready ? count : nil
    }

    private static func observe(_ workspace: Workspace, socket: String, expectedRoots: Int, steps: Steps) async -> Observed {
        let observed = Observed()
        let report = observed.report
        // However this ends, the child is told to stop: it ends itself if it cannot, by its own deadline.
        defer { requestStop(workspace.dir) }
        let started = await waitForHost(workspace.dir, timeout: .seconds(30))
        guard let started, let hostStart = started.hostStartedAt, let baseline = started.baseline else {
            report.fail(steps.socket, expected: "the host process starts", actual: started == nil ? "it never wrote \(ChildReport.fileName)" : "it never got as far as starting the host")
            return observed
        }
        let socketDeadline = (DispatchTime(uptimeNanoseconds: hostStart) + .seconds(socketBound)).uptimeNanoseconds
        let scanDeadline = (DispatchTime(uptimeNanoseconds: hostStart) + .seconds(scanBound)).uptimeNanoseconds
        report.note("host pid \(started.pid), \(baseline) descriptors before Fleet, soft limit \(started.limit)")

        // 1. The local socket answers a real request. One client asks for the rest: a client per poll fills the log.
        var snapshot: FleetSnapshot?
        let client = RemoteHostClient(localSocket: socket)
        defer { client.disconnect() }
        func read(until deadline: UInt64) async -> FleetSnapshot? { await within(until: deadline) { try? await client.fleetRead().snapshot } }
        var connected = false
        var answeredAt = hostStart
        let answered = await poll(until: socketDeadline) {
            if !connected {
                guard await within(until: socketDeadline, { RemoteHostClient.localSocketAnswers(socket) }) == true else { return false }
                connected = await within(until: socketDeadline) {
                    try? await client.connect(host: "", port: 0, token: "", clientName: "launch-gate", fetchesState: false)
                } != nil
            }
            guard connected, await read(until: socketDeadline) != nil else { return false }
            answeredAt = now
            return true
        }
        let expectedSocket = "host.sock answers a request within \(socketBound) s of host start"
        if answered {
            report.pass(steps.socket, expected: expectedSocket, actual: "answered after \(Duration.nanoseconds(answeredAt - hostStart))")
        } else {
            report.fail(steps.socket, expected: expectedSocket, actual: "no timely answer (soft limit \(started.limit))")
        }

        // Both index checkpoints, the second socket probe and the final request share one scan deadline.
        var runningAt = hostStart
        let running = answered ? await poll(until: scanDeadline) {
            observed.running = await read(until: scanDeadline)?.index?.repos.count
            runningAt = now
            return observed.running == expectedRoots
        } : false
        if running {
            observed.afterStart = await freshDescriptorCount(in: workspace.dir, after: runningAt, until: scanDeadline)
        } else if observed.running == expectedRoots {
            observed.running = nil // the matching reply came too late
        }

        var scannedAt = hostStart
        let scanned = running ? await poll(until: scanDeadline) {
            guard let index = await read(until: scanDeadline)?.index,
                  !index.indexing, index.repos.count == expectedRoots, index.repos.allSatisfy(\.ready),
                  await within(until: scanDeadline, { RemoteHostClient.localSocketAnswers(socket) }) == true else { return false }
            snapshot = await read(until: scanDeadline)
            scannedAt = now
            return snapshot != nil
        } : false
        let expectedScan = "the host answers after all \(expectedRoots) indexes finish their first scan, within \(scanBound) s of host start"
        if scanned {
            observed.afterScan = await freshDescriptorCount(in: workspace.dir, after: scannedAt, until: scanDeadline)
            report.pass(steps.scan, expected: expectedScan,
                        actual: "answered after \(Duration.nanoseconds(scannedAt - hostStart)), \(snapshot?.index?.repos.map(\.files).reduce(0, +) ?? 0) files indexed")
        } else {
            report.fail(steps.scan, expected: expectedScan, actual: running ? "no timely post-scan answer" : "the indexes never reached every checkout in time")
        }
        return observed
    }

    /// Bytes and files under `directory`, for the log.
    private static func size(of directory: URL) -> String {
        var bytes = 0, files = 0
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        for case let url as URL in FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) ?? NSEnumerator() {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            bytes += values?.totalFileAllocatedSize ?? 0
            files += 1
        }
        return "\(bytes / 1024) KiB in \(files) files"
    }

    /// The process's open descriptors, as `lsof` lists them.
    static func fdList(of pid: pid_t) -> [proc_fdinfo]? {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return nil }
        var list = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride + 32)
        let capacity = Int32(list.count * MemoryLayout<proc_fdinfo>.stride)
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, capacity)
        guard bytes > 0, bytes < capacity, Int(bytes).isMultiple(of: MemoryLayout<proc_fdinfo>.stride) else { return nil }
        return Array(list.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride))
    }

    private static func scratchIsGone(_ path: URL) -> Bool {
        var info = stat()
        return lstat(path.path, &info) == -1 && errno == ENOENT
    }

    private static func removeScratch(_ path: URL) {
        try? FileManager.default.removeItem(at: path)
        #expect(scratchIsGone(path), "scratch not deleted: \(path.path)")
    }

    // MARK: Evidence

    private final class Report: @unchecked Sendable {
        struct Result { let step: String, passed: Bool, expected: String, actual: String }
        private let results = Locked<[Result]>([])
        private let notes = Locked<[String]>([])

        func pass(_ step: String, expected: String, actual: String) { add(step, true, expected, actual) }
        func fail(_ step: String, expected: String, actual: String) { add(step, false, expected, actual) }
        func note(_ line: String) { notes.withValue { $0.append(line) } }
        private func add(_ step: String, _ passed: Bool, _ expected: String, _ actual: String) {
            results.withValue { $0.append(Result(step: step, passed: passed, expected: expected, actual: actual)) }
        }

        /// Writes `validate.py`'s step records and fails the test for each failed step, and for each step that never ran.
        func record(steps: Steps, hostLog: String) throws {
            let directory = ValidationEvidence.directory
            var evidence: [String] = []
            if let directory {
                let name = "launch-\(steps.socket).log"
                let body = (notes.current + ["", "host stderr (last 80 lines):"] + hostLog.split(separator: "\n").suffix(80).map(String.init)).joined(separator: "\n")
                try body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                evidence = ["mac/\(name)"]
            }
            for step in steps.all where !results.current.contains(where: { $0.step == step }) {
                fail(step, expected: "the step runs", actual: "it did not run: the host process ended or its report was not read")
            }
            let results = results.current
            for result in results {
                try ValidationEvidence.record(in: directory, step: result.step, status: result.passed ? "passed" : "failed",
                                              expected: result.expected, actual: result.actual, evidence: evidence)
                #expect(result.passed, Comment(rawValue: "\(result.step): expected \(result.expected); actual \(result.actual)"))
            }
            if results.count == steps.all.count, results.allSatisfy(\.passed) {
                let summary = "the host answered and held its descriptors with \(HostLaunchTests.spaceCount) synced spaces"
                try ValidationEvidence.record(in: directory, step: "complete", status: "passed", expected: summary, actual: summary)
            }
        }
    }

    // MARK: The workspace

    /// A scratch workspace: `spaceCount` small git checkouts, each a space, and (unless turned off) a worktree for every
    /// `worktreeEvery`th with a thread working in it. `dir` is also the host's support folder, so its paths stay short.
    struct Workspace {
        let dir: URL
        let spaces: [Space]
        let tabs: [ShepherdCore.Tab]
        let agents: [Agent]

        /// A setup that fails part way deletes what it made.
        static func make(label: String, worktrees: Bool = true) throws -> Workspace {
            let dir = try makeScratchDirectory(String(label.prefix(1)))
            do { return try build(in: dir, worktrees: worktrees) } catch {
                HostLaunchTests.removeScratch(dir)
                throw error
            }
        }

        private static func build(in dir: URL, worktrees: Bool) throws -> Workspace {
            let base = dir.appendingPathComponent("w", isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            // The support folder holds a Mac this host is paired with, which is what turns Fleet's content index on. It has no
            // token or address, so the host never dials it.
            let fleet = dir.appendingPathComponent("fleet", isDirectory: true)
            try FileManager.default.createDirectory(at: fleet, withIntermediateDirectories: true)
            let peer = ["hostID": UUID().uuidString, "name": "Mac mini", "kind": "mac", "pairedAt": 1_700_000_000_000.0] as [String: Any]
            try JSONSerialization.data(withJSONObject: ["peers": [peer]]).write(to: fleet.appendingPathComponent("peers.json"))

            let checkouts = base.appendingPathComponent("acme", isDirectory: true)
            let count = HostLaunchTests.spaceCount
            var paths = [String?](repeating: nil, count: count)
            var trees = [String?](repeating: nil, count: count)
            let results = Locked<[(Int, String, String?)]>([])
            let failure = Locked<Error?>(nil)
            DispatchQueue.concurrentPerform(iterations: count) { n in
                do {
                    let root = checkouts.appendingPathComponent("acme-web-\(n)", isDirectory: true)
                    try FileManager.default.createDirectory(at: root.appendingPathComponent("src"), withIntermediateDirectories: true)
                    for (name, text) in ["README.md": "# acme-web-\(n)\n", "package.json": "{\"name\":\"acme-web-\(n)\"}\n", "src/index.ts": "export const n = \(n)\n"] {
                        try text.write(to: root.appendingPathComponent(name), atomically: true, encoding: .utf8)
                    }
                    for args in [["init", "-q", "-b", "main"], ["add", "."],
                                 ["-c", "user.name=Acme", "-c", "user.email=dev@acme.example", "commit", "-qm", "initial"]] {
                        try git(args, in: root)
                    }
                    var tree: String?
                    if worktrees, n % HostLaunchTests.worktreeEvery == 0 {
                        let path = base.appendingPathComponent("trees/acme-web-\(n)-feature", isDirectory: true)
                        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
                        try git(["worktree", "add", "-q", "-b", "feature-\(n)", path.path], in: root)
                        tree = path.path
                    }
                    results.withValue { $0.append((n, root.path, tree)) }
                } catch {
                    failure.withValue { $0 = $0 ?? error }
                }
            }
            if let error = failure.current { throw error }
            for (n, path, tree) in results.current { (paths[n], trees[n]) = (path, tree) }

            var spaces: [Space] = [], tabs: [ShepherdCore.Tab] = [], agents: [Agent] = []
            for n in 0..<count {
                let space = Space(name: "acme-web-\(n)", path: try #require(paths[n]))
                spaces.append(space)
                guard let tree = trees[n] else { continue }
                let agentID = AgentID()
                let pane = LeafPane(cwd: tree, agentID: agentID)
                let tab = ShepherdCore.Tab(spaceID: space.id, order: 0, layout: .leaf(pane))
                tabs.append(tab)
                agents.append(Agent(id: agentID, name: "feature-\(n)", spaceID: space.id, tabID: tab.id, paneID: pane.id,
                                    worktreeBranch: "feature-\(n)", worktreePath: tree))
            }
            return Workspace(dir: dir, spaces: spaces, tabs: tabs, agents: agents)
        }

    }
}
