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
/// descriptors from a timer source started before the host, an open() probe that records any EMFILE, its TCP listeners, the soft limit
/// it read back) to `child-report`, so this process needs no PID. The host is `SessionHost.run` as `ShepherdHost.main` calls it, with
/// two differences, both so the test touches nothing outside its scratch: Fleet does not advertise (no Bonjour, no iCloud:
/// `configureFleet(advertises: false)`), and the port Fleet asks to listen on is one the child holds bound, so the bind fails and
/// the host opens no TCP listener.
///
/// Once #879 (`fix/host-fd-exhaustion`) has merged, `main` tells `SessionHost.run` to start Fleet (`startFleet: true`): pass it in
/// `launch` too. Until then, and if it is forgotten, the test fails on "the index never reached every checkout", so a host that
/// never started Fleet cannot pass.
@Suite("Host launch on a large workspace", .serialized, .integrationTimeLimit)
struct HostLaunchTests {
    /// Spaces Fleet syncs; every fifth also has a worktree a thread works in, which Fleet indexes too.
    static let spaceCount = 150
    static let worktreeEvery = 5
    static var worktreeCount: Int { (spaceCount + worktreeEvery - 1) / worktreeEvery }

    /// launchd's soft limit for a job that sets none.
    static let launchdDescriptorLimit: rlim_t = 256
    /// `host.sock` answers a real request within this long of the host starting.
    static let socketBound: Duration = .seconds(20)
    /// Fleet's indexes have each made their first scan within this long.
    static let scanBound: Duration = .seconds(30)
    /// The host's descriptors once Fleet is running and once every index has scanned: under launchd's limit.
    static let descriptorBudget = 256
    /// What each space may add to those, beyond the ones the host started with (the sync engine watches each checkout's
    /// `.git/config`: one).
    static let descriptorsPerSpace = 2.0
    /// A peak this close to the limit is exhaustion: a peak can never pass the limit, so "under the limit" proves nothing. The
    /// reopen-before-close spike of a healthy watcher is about 190.
    static let exhaustionMargin = 32
    /// One call to the host (a request, a connect) gets this long, so a hung one cannot hold a wait that `eventually` cannot interrupt.
    static let callBound: Duration = .seconds(5)
    /// The child exits by itself this long after it starts, whatever this process is doing (the longest the observer can take is
    /// the sum of its waits, about 90 s).
    static let childDeadlineSeconds = 110
    /// How long a host gets to stop on SIGTERM before the child ends itself.
    static let stopGraceSeconds = 20

    @Test func aHostStartsAndAnswersWithManySyncedSpaces() async throws {
        let workspace = try Workspace.make(label: "current")
        defer { workspace.remove() }
        let state = ShepherdState(spaces: workspace.spaces, tabs: workspace.tabs, agents: workspace.agents)
        try JSONEncoder().encode(state).write(to: workspace.dir.appendingPathComponent("state.json"))
        try await Self.launch(workspace, expectedRoots: Self.spaceCount + Self.worktreeCount, steps: Self.currentSteps)
        // Pass, fail or timeout, the scratch folder goes: the host is gone by now, so nothing holds it.
        workspace.remove()
        #expect(!FileManager.default.fileExists(atPath: workspace.dir.path), "the scratch folder was deleted")
    }

    /// The same start, from the oldest `state.json` the state golden holds (`Tests/Fixtures/c-state.json`), grown to the same
    /// number of spaces. Its agent is saved idle so the host respawns no pi, and its own space and pane move from `/tmp/acme` to a
    /// folder in the scratch workspace (an existing `/tmp/acme` would change what the host indexes).
    @Test func aHostStartsFromAWorkspaceSavedByAnEarlierShape() async throws {
        let workspace = try Workspace.make(label: "legacy", worktrees: false)
        defer { workspace.remove() }
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
        workspace.remove()
        #expect(!FileManager.default.fileExists(atPath: workspace.dir.path), "the scratch folder was deleted")
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
        getrlimit(RLIMIT_NOFILE, &limit)
        limit.rlim_cur = min(launchdDescriptorLimit, limit.rlim_max)
        setrlimit(RLIMIT_NOFILE, &limit)
        getrlimit(RLIMIT_NOFILE, &limit)
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
                        pullRequests: host.pullRequests, banners: host.banners)
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
        /// The soft descriptor limit the child read back after setting it.
        var limit: UInt64 = 0
        /// The soft limit now: a host may raise its own.
        var limitNow: UInt64 = 0
        /// Descriptors held just before the host started.
        var baseline = 0
        var current = 0
        var peak = 0
        /// Descriptors by kind at the peak (1 vnode, 2 socket, 3 pshm, 5 pipe, 6 kqueue).
        var peakTypes: [String: Int] = [:]
        /// Times an `open()` probe on the sampler's tick failed with EMFILE or ENFILE: the host had no descriptor left.
        var exhausted = 0
        /// TCP sockets in the LISTEN state now, the most there were at once, and every local port one had.
        var listening = 0
        var mostListening = 0
        var listenPorts: [Int] = []
        /// The vnode paths held most at the first count over 1000 and each 1000 more (what a runaway watcher opens).
        var top: [String] = []
        var ticks = 0
        var hostStarted = false
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
        /// Called, once, as the child stops: the report's last write.
        var onStop: () -> Void = {}

        init(directory: URL) { self.directory = directory }

        /// Ends the child at once, saying why on stderr (which the test reads), and removes this process's own scratch root.
        func die(_ message: String, _ code: Int32) -> Never {
            FileHandle.standardError.write(Data("launch child: \(message)\n".utf8))
            try? FileManager.default.removeItem(at: TestProcess.root)
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
                onStop()
                kill(getpid(), SIGTERM)
                queue.asyncAfter(deadline: .now() + .seconds(grace)) { [self] in die("the host did not stop within \(grace) s", 75) }
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

    /// Samples this process's descriptors from a timer source from before the host starts, so a spike between two polls from outside
    /// cannot be missed, and writes the result where the test process reads it.
    private final class ChildReporter: @unchecked Sendable {
        private let report = Locked(ChildReport())
        private let fd: Int32
        private let queue = DispatchQueue(label: "launch.child.sampler")
        private var timer: DispatchSourceTimer?
        private var lastNamed = 0
        private var lastWrite = ContinuousClock.now

        /// Opens the report (and writes the pid into it) or ends the child: a host nobody can find is not started.
        init(directory: URL, guardian: ChildGuard) {
            fd = open(directory.appendingPathComponent(ChildReport.fileName).path, O_WRONLY | O_CREAT | O_CLOEXEC, 0o600)
            guard fd >= 0 else { guardian.die("cannot open its report: \(String(cString: strerror(errno)))", 78) }
            report.withValue { $0.pid = getpid() }
            guard write() else { guardian.die("cannot write its report: \(String(cString: strerror(errno)))", 78) }
            guardian.onStop = { [self] in
                report.withValue { $0.stopping = true }
                _ = write()
            }
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
            let held = HostLaunchTests.descriptors(of: getpid()) ?? -1
            report.withValue { $0.baseline = held; $0.hostStarted = true }
            _ = write()
        }

        private func tick() {
            guard let list = HostLaunchTests.fdList(of: getpid()) else { return }
            // The probe: a descriptor the host could not get is a descriptor this cannot get either.
            let probe = open("/dev/null", O_RDONLY | O_CLOEXEC)
            let exhausted = probe < 0 && (errno == EMFILE || errno == ENFILE)
            if probe >= 0 { close(probe) }
            var ports: [Int] = []
            for entry in list where entry.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
                var info = socket_fdinfo()
                guard proc_pidfdinfo(getpid(), entry.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size)) > 0,
                      info.psi.soi_kind == Int32(SOCKINFO_TCP), info.psi.soi_proto.pri_tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
                ports.append(Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: info.psi.soi_proto.pri_tcp.tcpsi_ini.insi_lport))))
            }
            var names: [String: Int]?
            if list.count > 1000, list.count > lastNamed + 1000 {
                lastNamed = list.count
                names = [:]
                for entry in list where entry.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                    var info = vnode_fdinfowithpath()
                    guard proc_pidfdinfo(getpid(), entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                    let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                    names?[path, default: 0] += 1
                }
            }
            var now = rlimit()
            getrlimit(RLIMIT_NOFILE, &now)
            let changed = report.withValue { report -> Bool in
                report.ticks += 1
                report.current = list.count
                var changed = false
                if now.rlim_cur != report.limitNow { report.limitNow = now.rlim_cur; changed = true }
                if list.count > report.peak {
                    report.peak = list.count
                    report.peakTypes = Dictionary(list.map { (String($0.proc_fdtype), 1) }, uniquingKeysWith: +)
                    changed = true
                }
                if exhausted { report.exhausted += 1; changed = true }
                if ports.count != report.listening || ports.count > report.mostListening { changed = true }
                report.listening = ports.count
                report.mostListening = max(report.mostListening, ports.count)
                for port in ports where !report.listenPorts.contains(port) { report.listenPorts.append(port) }
                if let names { report.top = names.sorted { $0.value > $1.value }.prefix(10).map { "\($0.value) x \($0.key.suffix(110))" }; changed = true }
                return changed
            }
            // Written when it matters, and otherwise about every 100 ms.
            if changed || lastWrite.duration(to: .now) > .milliseconds(100) { _ = write(); lastWrite = .now }
        }

        /// The whole report at one fixed size, in one write.
        @discardableResult
        private func write() -> Bool {
            var snapshot = report.current
            var data = (try? JSONEncoder().encode(snapshot)) ?? Data()
            if data.count > ChildReport.size { snapshot.top = []; data = (try? JSONEncoder().encode(snapshot)) ?? Data() }
            guard data.count <= ChildReport.size else { return false }
            data.append(Data(repeating: 0, count: ChildReport.size - data.count))
            return data.withUnsafeBytes { pwrite(fd, $0.baseAddress, data.count, 0) } == data.count
        }
    }

    // MARK: The observer (this process)

    /// What `observe` learned, and the steps it settled; `finish` adds the ones that need the child's final report.
    private final class Observed: @unchecked Sendable {
        let report = Report()
        var running: Int?
        var afterStart: Int?
        var afterScan: Int?
        var reported: ChildReport?

        func finish(steps: Steps, expectedRoots: Int, final: ChildReport?, hostLog: String) throws {
            if let final {
                let growth = Double(max(afterStart ?? 0, afterScan ?? 0) - final.baseline) / Double(expectedRoots)
                let types = final.peakTypes.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                let measured = "peak \(final.peak) of \(final.limit), \(final.baseline) before Fleet, \(afterStart.map(String.init) ?? "?") with "
                    + "\(running.map(String.init) ?? "no") indexes running, \(afterScan.map(String.init) ?? "?") after the first scan "
                    + "(\(String(format: "%.2f", growth)) per checkout), \(final.exhausted) failed opens"
                report.note(measured)
                if final.limitNow != final.limit { report.note("the host raised its own soft limit from \(final.limit) to \(final.limitNow)") }
                report.note("peak by type: \(types) (1 vnode, 2 socket, 3 pshm, 5 pipe, 6 kqueue); sampled \(final.ticks) times")
                for line in final.top { report.note("  \(line)") }
                var problems: [String] = []
                if running != expectedRoots { problems.append("the index never reached every checkout (\(running.map(String.init) ?? "no index"))") }
                if final.exhausted > 0 { problems.append("the host ran out of descriptors (\(final.exhausted) failed opens)") }
                if final.peak >= Int(final.limit) - HostLaunchTests.exhaustionMargin {
                    problems.append("the peak \(final.peak) is within \(HostLaunchTests.exhaustionMargin) of the limit \(final.limit)")
                }
                if ![afterStart, afterScan].allSatisfy({ $0.map { $0 < HostLaunchTests.descriptorBudget } ?? false }) {
                    problems.append("descriptors once running are not under \(HostLaunchTests.descriptorBudget)")
                }
                if growth > HostLaunchTests.descriptorsPerSpace { problems.append("more than \(HostLaunchTests.descriptorsPerSpace) descriptors per checkout") }
                let expected = "no failed open, a peak at least \(HostLaunchTests.exhaustionMargin) under the \(HostLaunchTests.launchdDescriptorLimit) limit, under \(HostLaunchTests.descriptorBudget) once running, "
                    + "at most \(HostLaunchTests.descriptorsPerSpace) more per checkout, with all \(expectedRoots) indexes running"
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

    /// `operation`'s answer, or nil if it has not come within `limit`. `eventually` cannot interrupt a predicate, so each call a
    /// predicate makes gets its own deadline; a call that never answers is left behind (its client is disconnected at the end).
    private static func within<T: Sendable>(_ limit: Duration, _ operation: @escaping @Sendable () async -> T?) async -> T? {
        await withCheckedContinuation { continuation in
            let answered = Locked(false)
            let finish: @Sendable (T?) -> Void = { value in
                if answered.withValue({ let first = !$0; $0 = true; return first }) { continuation.resume(returning: value) }
            }
            let clock = Task { try? await Task.sleep(for: limit); finish(nil) }
            Task { finish(await operation()); clock.cancel() }
        }
    }

    private static func observe(_ workspace: Workspace, socket: String, expectedRoots: Int, steps: Steps) async -> Observed {
        let observed = Observed()
        let report = observed.report
        // However this ends, the child is told to stop: it ends itself if it cannot, by its own deadline.
        defer { FileManager.default.createFile(atPath: workspace.dir.appendingPathComponent("stop").path, contents: nil) }
        var started: ChildReport?
        try? await eventually("the host process to report", timeout: .seconds(30)) {
            started = ChildReport.read(workspace.dir)
            return started?.hostStarted == true
        }
        guard let started else {
            report.fail(steps.socket, expected: "the host process starts", actual: "it never wrote \(ChildReport.fileName)")
            return observed
        }
        let started0 = ContinuousClock.now
        report.note("host pid \(started.pid), \(started.baseline) descriptors before Fleet, soft limit \(started.limit)")
        func held() -> Int? { ChildReport.read(workspace.dir)?.current }

        // 1. The local socket answers a real request. One client asks for the rest: a client per poll fills the log.
        var snapshot: FleetSnapshot?
        let client = RemoteHostClient(localSocket: socket)
        defer { client.disconnect() }
        func read() async -> FleetSnapshot? { await within(callBound) { try? await client.fleetRead().snapshot } }
        do {
            try await eventually("host.sock to answer a request", timeout: socketBound, poll: .milliseconds(50)) {
                guard await within(callBound, { RemoteHostClient.localSocketAnswers(socket) }) == true else { return false }
                _ = await within(callBound) { (try? await client.connect(host: "", port: 0, token: "", clientName: "launch-gate", fetchesState: false)) != nil }
                snapshot = await read()
                return snapshot != nil
            }
            report.pass(steps.socket, expected: "host.sock answers a request within \(socketBound)",
                        actual: "answered after \(started0.duration(to: .now)), \(held().map(String.init) ?? "?") descriptors")
        } catch {
            report.fail(steps.socket, expected: "host.sock answers a request within \(socketBound)",
                        actual: "no answer: the host holds \(held().map(String.init) ?? "no") descriptors (limit \(started.limit))")
        }

        // 2. Every checkout's index is running.
        try? await eventually("Fleet's indexes to start", timeout: scanBound, poll: .milliseconds(100)) {
            snapshot = await read()
            observed.running = snapshot?.index?.repos.count
            return observed.running == expectedRoots
        }
        observed.afterStart = held()
        // 3. The first scan finishes, and the host still answers.
        var scanned = false
        // Indexes that never started are not waited for twice.
        if observed.running == expectedRoots {
            try? await eventually("every index's first scan", timeout: scanBound, poll: .milliseconds(100)) {
                snapshot = await read()
                scanned = snapshot?.index.map { !$0.indexing && $0.repos.count == expectedRoots && $0.repos.allSatisfy(\.ready) } ?? false
                return scanned
            }
        }
        observed.afterScan = held()
        let expectedScan = "the host answers after all \(expectedRoots) indexes finished their first scan"
        let answers = scanned ? await within(callBound, { RemoteHostClient.localSocketAnswers(socket) }) == true : false
        if scanned, answers, await read() != nil {
            report.pass(steps.scan, expected: expectedScan, actual: "answered, \(snapshot?.index?.repos.map(\.files).reduce(0, +) ?? 0) files indexed")
        } else {
            report.fail(steps.scan, expected: expectedScan, actual: scanned ? "the socket stopped answering"
                        : observed.running == expectedRoots ? "the first scan did not finish within \(scanBound)" : "the indexes never started, so there was no scan to wait for")
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
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &list, Int32(list.count * MemoryLayout<proc_fdinfo>.stride))
        return bytes > 0 ? Array(list.prefix(Int(bytes) / MemoryLayout<proc_fdinfo>.stride)) : nil
    }

    static func descriptors(of pid: pid_t) -> Int? { fdList(of: pid)?.count }

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
                try? FileManager.default.removeItem(at: dir)
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

        /// Only the folder this workspace made.
        func remove() { try? FileManager.default.removeItem(at: dir) }
    }
}
