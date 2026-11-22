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
    /// The host's descriptors, at their peak and once every index has scanned: under launchd's limit, so a host that is not given
    /// a higher one still starts.
    static let descriptorBudget = 256
    /// What each space may add to the host's descriptors once Fleet is running, beyond the ones the host started with (the
    /// sync engine watches each checkout's `.git/config`: one).
    static let descriptorsPerSpace = 2.0

    @Test func aHostStartsAndAnswersWithManySyncedSpaces() async throws {
        let workspace = try Workspace.make(label: "current")
        defer { workspace.remove() }
        let state = ShepherdState(spaces: workspace.spaces, tabs: workspace.tabs, agents: workspace.agents)
        try JSONEncoder().encode(state).write(to: workspace.dir.appendingPathComponent("state.json"))
        try await Self.launch(workspace, expectedRoots: Self.spaceCount + Self.worktreeCount, steps: Self.currentSteps)
    }

    /// The same start, from the oldest `state.json` the state golden holds (`Tests/Fixtures/c-state.json`), grown to the same
    /// number of spaces. Its agent is saved idle so the host respawns no pi.
    @Test func aHostStartsFromAWorkspaceSavedByAnEarlierShape() async throws {
        let workspace = try Workspace.make(label: "legacy", worktrees: false)
        defer { workspace.remove() }
        let golden = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Fixtures/c-state.json")
        let files = try #require((try JSONSerialization.jsonObject(with: Data(contentsOf: golden)) as? [String: Any])
            .flatMap { ($0["seed"] as? [String: Any])?["files"] as? [[String: Any]] })
        var saved = try #require(files.first { $0["case"] as? String == "workspace-initial" }?["json"] as? [String: Any])
        saved["agents"] = ((saved["agents"] as? [[String: Any]]) ?? []).map { $0.merging(["status": "idle"]) { _, new in new } }
        saved["spaces"] = ((saved["spaces"] as? [[String: Any]]) ?? []) + workspace.spaces.map {
            ["hidden": false, "id": $0.id.rawValue, "name": $0.name, "path": $0.path]
        }
        try JSONSerialization.data(withJSONObject: saved).write(to: workspace.dir.appendingPathComponent("state.json"))
        try await Self.launch(workspace, expectedRoots: Self.spaceCount, steps: Self.legacySteps)
    }

    static let currentSteps = Steps(socket: "socket-answers", descriptors: "descriptors", scan: "still-answering")
    static let legacySteps = Steps(socket: "legacy-state-socket-answers", descriptors: "legacy-state-descriptors", scan: "legacy-state-still-answering")

    struct Steps {
        let socket: String, descriptors: String, scan: String
    }

    // MARK: The host (child process)

    /// Starts the host in a process of its own, watches it from here, and stops it with SIGTERM. A host that never answers fails
    /// the steps and is still stopped, so the exit test ends.
    private static func launch(_ workspace: Workspace, expectedRoots: Int, steps: Steps) async throws {
        let socket = workspace.dir.appendingPathComponent("host.sock").path
        try #require(socket.utf8.count < 100, "a unix socket path is capped at 104 bytes")
        let monitor = Task { await observe(workspace, socket: socket, expectedRoots: expectedRoots, steps: steps) }
        let result = await #expect(processExitsWith: .success, observing: [\.standardErrorContent]) { [dir = workspace.dir.path as String] in
            // As launchd starts a job: a soft limit of 256 descriptors. The test process raises its own (ShepherdTestIsolation).
            var limit = rlimit()
            getrlimit(RLIMIT_NOFILE, &limit)
            limit.rlim_cur = min(Self.launchdDescriptorLimit, limit.rlim_max)
            setrlimit(RLIMIT_NOFILE, &limit)
            getrlimit(RLIMIT_NOFILE, &limit)
            let url = URL(fileURLWithPath: dir)
            let server = SessionServer(socketPath: url.appendingPathComponent("shepherd.sock").path, stateURL: url.appendingPathComponent("state.json"))
            try? "\(getpid()) \(Self.descriptors(of: getpid()) ?? -1) \(limit.rlim_cur)".write(to: url.appendingPathComponent("host.pid"), atomically: true, encoding: .utf8)
            let host = await MainActor.run {
                HostPieces(ShepherdHost.Services(settings: AppSettings(store: ScratchDefaults()),
                                                 mcpStore: MCPStore(dependencies: .app(pi: server.pi, openURL: { _ in }, copy: { _ in })),
                                                 notifications: AgentNotifications(activate: {}), keepsAgentsRunning: { nil }))
            }
            SessionHost.run(server, respawn: host.respawn, configure: host.configure, threads: host.threads, automations: host.automations,
                            pullRequests: host.pullRequests, banners: host.banners)
        }
        let report = await monitor.value
        let stderr = result.map { String(decoding: $0.standardErrorContent, as: UTF8.self) } ?? ""
        try report.record(steps: steps, hostLog: stderr)
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

    // MARK: The observer (this process)

    private static func observe(_ workspace: Workspace, socket: String, expectedRoots: Int, steps: Steps) async -> Report {
        let report = Report()
        let pidFile = workspace.dir.appendingPathComponent("host.pid")
        var host: (pid: pid_t, baseline: Int, limit: Int)?
        try? await eventually("the host process to start", timeout: .seconds(60)) {
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8) else { return false }
            let numbers = text.split(separator: " ").compactMap { Int($0) }
            guard numbers.count == 3 else { return false }
            host = (pid_t(numbers[0]), numbers[1], numbers[2])
            return true
        }
        guard let host else {
            report.fail(steps.socket, expected: "the host process starts", actual: "it never wrote \(pidFile.lastPathComponent)")
            return report
        }
        defer { stop(host.pid) }
        // The peak is what a limit meets: a count taken after the host has given descriptors back can be low.
        let peak = Locked<(count: Int, types: [UInt32: Int])>((0, [:]))
        let top = Locked<[String]>([])
        let sampler = Task.detached {
            var lastNamed = 0
            while !Task.isCancelled {
                if let list = Self.fdList(of: host.pid), list.count > peak.current.count {
                    peak.withValue { $0 = (list.count, Dictionary(list.map { ($0.proc_fdtype, 1) }, uniquingKeysWith: +)) }
                    if list.count > 1000 && list.count > lastNamed + 1000 {
                        lastNamed = list.count
                        var names: [String: Int] = [:]
                        for entry in list where entry.proc_fdtype == 1 {
                            var info = vnode_fdinfowithpath()
                            guard proc_pidfdinfo(host.pid, entry.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, Int32(MemoryLayout<vnode_fdinfowithpath>.size)) > 0 else { continue }
                            let path = withUnsafePointer(to: &info.pvip.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
                            names[path, default: 0] += 1
                        }
                        top.withValue { $0 = names.sorted { $0.value > $1.value }.prefix(12).map { "\($0.value) x \($0.key)" } }
                    }
                }
                try? await Task.sleep(for: .milliseconds(5))
            }
        }
        defer { sampler.cancel() }
        let started = ContinuousClock.now
        report.note("host pid \(host.pid), \(host.baseline) descriptors before Fleet, soft limit \(host.limit)")

        // 1. The local socket answers a real request. One client asks for the rest: a client per poll fills the log.
        var snapshot: FleetSnapshot?
        let client = RemoteHostClient(localSocket: socket)
        defer { client.disconnect() }
        func read() async -> FleetSnapshot? { try? await client.fleetRead().snapshot }
        do {
            try await eventually("host.sock to answer a request", timeout: socketBound, poll: .milliseconds(50)) {
                guard RemoteHostClient.localSocketAnswers(socket) else { return false }
                _ = try? await client.connect(host: "", port: 0, token: "", clientName: "launch-gate", fetchesState: false)
                snapshot = await read()
                return snapshot != nil
            }
            let took = started.duration(to: .now)
            report.pass(steps.socket, expected: "host.sock answers a request within \(socketBound)",
                        actual: "answered after \(took), \(descriptors(of: host.pid) ?? -1) descriptors")
        } catch {
            report.fail(steps.socket, expected: "host.sock answers a request within \(socketBound)",
                        actual: "no answer: the host holds \(descriptors(of: host.pid).map(String.init) ?? "no") descriptors (limit \(host.limit))")
        }

        // 2. Every checkout's index is running, and the descriptors it took are within budget.
        var running: Int?
        try? await eventually("Fleet's indexes to start", timeout: scanBound, poll: .milliseconds(100)) {
            snapshot = await read()
            running = snapshot?.index?.repos.count
            return running == expectedRoots
        }
        let afterStart = descriptors(of: host.pid)
        // 3. The first scan finishes, and the host still answers.
        var scanned = false
        // Indexes that never started are not waited for twice.
        if running == expectedRoots {
            try? await eventually("every index's first scan", timeout: scanBound, poll: .milliseconds(100)) {
                snapshot = await read()
                scanned = snapshot?.index.map { !$0.indexing && $0.repos.count == expectedRoots && $0.repos.allSatisfy(\.ready) } ?? false
                return scanned
            }
        }
        let afterScan = descriptors(of: host.pid)
        let growth = Double(max(afterStart ?? 0, afterScan ?? 0) - host.baseline) / Double(expectedRoots)
        let measured = "peak \(peak.current.count), \(host.baseline) before, \(afterStart.map(String.init) ?? "?") with \(running.map(String.init) ?? "no") indexes running, "
            + "\(afterScan.map(String.init) ?? "?") after the first scan (\(String(format: "%.2f", growth)) per checkout)"
        report.note(measured)
        report.note("peak \(peak.current.count) descriptors (by type: \(peak.current.types.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")); 1 vnode, 2 socket, 3 pshm, 5 pipe, 6 kqueue)")
        for line in top.current { report.note("  \(line)") }
        let within = [afterStart, afterScan, peak.current.count].allSatisfy { $0.map { $0 < descriptorBudget } ?? false } && growth <= descriptorsPerSpace
        let expectedDescriptors = "under \(descriptorBudget) descriptors at every sample and at most \(descriptorsPerSpace) more per checkout, with all \(expectedRoots) indexes running"
        if running == expectedRoots, within {
            report.pass(steps.descriptors, expected: expectedDescriptors, actual: measured)
        } else {
            report.fail(steps.descriptors, expected: expectedDescriptors,
                        actual: running == expectedRoots ? measured : "the index never reached every checkout (\(running.map(String.init) ?? "no index")): \(measured)")
        }
        let expectedScan = "the host answers after all \(expectedRoots) indexes finished their first scan"
        if scanned, RemoteHostClient.localSocketAnswers(socket), await read() != nil {
            report.pass(steps.scan, expected: expectedScan, actual: "answered, \(snapshot?.index?.repos.map(\.files).reduce(0, +) ?? 0) files indexed")
        } else {
            report.fail(steps.scan, expected: expectedScan, actual: scanned ? "the socket stopped answering" : "the first scan did not finish within \(scanBound)")
        }
        return report
    }

    /// SIGTERM, and SIGKILL if the host has not gone: a host that hung must not hold the test.
    private static func stop(_ pid: pid_t) {
        kill(pid, SIGTERM)
        Task.detached {
            do { try await eventually("the host to stop", timeout: .seconds(15)) { kill(pid, 0) != 0 } } catch { kill(pid, SIGKILL) }
        }
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

        /// Writes `validate.py`'s step records and fails the test for each failed step.
        func record(steps: Steps, hostLog: String) throws {
            let directory = ValidationEvidence.directory
            var evidence: [String] = []
            if let directory {
                let name = "launch-\(steps.socket).log"
                let body = (notes.current + ["", "host stderr (last 80 lines):"] + hostLog.split(separator: "\n").suffix(80).map(String.init)).joined(separator: "\n")
                try body.write(to: directory.appendingPathComponent(name), atomically: true, encoding: .utf8)
                evidence = ["mac/\(name)"]
            }
            let results = results.current
            for result in results {
                try ValidationEvidence.record(in: directory, step: result.step, status: result.passed ? "passed" : "failed",
                                              expected: result.expected, actual: result.actual, evidence: evidence)
                #expect(result.passed, Comment(rawValue: "\(result.step): expected \(result.expected); actual \(result.actual)"))
            }
            if results.count == 3, results.allSatisfy(\.passed) {
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

        static func make(label: String, worktrees: Bool = true) throws -> Workspace {
            let dir = try makeScratchDirectory(String(label.prefix(1)))
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
