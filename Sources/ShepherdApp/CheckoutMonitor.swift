import Foundation
import ShepherdCore
import ShepherdSessions

/// Reads an agent's checkout for the header's branch chip: its branch and how many files differ
/// from HEAD, in one `git status` (`--no-optional-locks`, so it never takes the index lock
/// under pi's own git calls). Blocking; call off the main thread.
enum CheckoutStatus {
    static func read(cwd: String, executable: String = "/usr/bin/git", timeout: TimeInterval = 10) -> AgentCheckout? {
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        guard let result = try? BoundedCommand.run(
            [executable, "--no-optional-locks", "-C", (cwd as NSString).expandingTildeInPath,
             "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"],
            environment: environment, timeout: timeout, outputLimit: 8 << 20
        ), result.status == 0 else { return nil }
        return parse(String(decoding: result.output, as: UTF8.self))
    }

    /// `git status --porcelain=v2 --branch -z`: the branch from its headers (a detached HEAD
    /// reads as its short commit), and one file per changed, unmerged or untracked entry. A
    /// rename's second field is its old path, not another file.
    static func parse(_ output: String) -> AgentCheckout? {
        var head: String?
        var oid: String?
        var files = 0
        var fields = output.split(separator: "\0", omittingEmptySubsequences: true).makeIterator()
        while let field = fields.next() {
            if field.hasPrefix("# branch.head ") {
                head = String(field.dropFirst("# branch.head ".count))
            } else if field.hasPrefix("# branch.oid ") {
                oid = String(field.dropFirst("# branch.oid ".count))
            } else if field.hasPrefix("1 ") || field.hasPrefix("u ") || field.hasPrefix("? ") {
                files += 1
            } else if field.hasPrefix("2 ") {
                files += 1
                _ = fields.next()
            }
        }
        guard let head else { return nil }
        if head == "(detached)" {
            guard let oid, oid != "(initial)" else { return nil }
            return AgentCheckout(branch: String(oid.prefix(7)), changedFiles: files)
        }
        return AgentCheckout(branch: head, changedFiles: files)
    }
}

/// Keeps every local agent's `Agent.checkout` current without a git call per frame: each read
/// runs off the main thread, at most `maxConcurrent` at once, and requests for a checkout coalesce
/// into one read `delay` later (a read already due is never pushed back, so a burst of edits
/// reads at most once a second). The view model asks after the events that change a checkout:
/// an agent appearing, a finished tool call that may write files, a status change (a turn
/// starting or ending), the agent being selected, the app coming to the front, and commits and
/// reverts from the review.
@MainActor
final class CheckoutMonitor {
    typealias Reader = @Sendable (String) async -> AgentCheckout?

    static let maxConcurrent = 4
    /// Tools that only read: their calls never change what the chip counts.
    nonisolated static let readOnlyTools: Set<String> = ["read", "grep", "find", "ls"]

    nonisolated static func touchesFiles(tool: String) -> Bool { !readOnlyTools.contains(tool) }

    /// `CheckoutStatus.read` on a detached task.
    nonisolated static let git: Reader = { cwd in await Task.detached { CheckoutStatus.read(cwd: cwd) }.value }

    private let read: Reader
    private let write: ([AgentID], String, AgentCheckout?) async -> Void
    /// The directory each agent works in; nil once it is gone.
    var directory: (AgentID) -> String? = { _ in nil }
    private var known: [AgentID: String] = [:]
    private var due: [String: (deadline: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
    private var waiting: [String] = []
    private var reading: Set<String> = []
    private var delivering: Set<String> = []
    /// Asked again while its read ran: it reads once more when that one lands.
    private var stale: Set<String> = []
    private var prioritized: Set<String> = []

    private func checkout(_ id: AgentID) -> String? {
        directory(id).map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized.path }
    }

    init(read: @escaping Reader, write: @escaping ([AgentID], String, AgentCheckout?) async -> Void) {
        self.read = read
        self.write = write
    }

    /// The workspace changed: read agents it has not seen, forget the ones that left.
    func sync(agents: [AgentID]) {
        let next = Dictionary(agents.compactMap { id in checkout(id).map { (id, $0) } }, uniquingKeysWith: { first, _ in first })
        sync(directories: next, order: agents)
    }

    func sync(directories: [AgentID: String], order: [AgentID]? = nil) {
        let next = directories.mapValues { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath).standardized.path }
        guard next != known else { return }
        let added = (order ?? Array(next.keys)).filter { next[$0] != nil && next[$0] != known[$0] }
        known = next
        let live = Set(next.values)
        for gone in Set(due.keys).subtracting(live) { due.removeValue(forKey: gone)?.task.cancel() }
        waiting.removeAll { !live.contains($0) }
        stale.formIntersection(live)
        prioritized.formIntersection(live)
        // An agent joining a checkout already being read shares its result, not another process.
        for id in added {
            if let cwd = next[id], !reading.contains(cwd) || delivering.contains(cwd) { refresh(id) }
        }
    }

    func refresh(_ id: AgentID, after delay: Duration = .zero, priority: Bool = false) {
        guard let cwd = known[id] else { return }
        if priority { prioritized.insert(cwd) }
        let deadline = ContinuousClock.now + delay
        if let pending = due[cwd], pending.deadline <= deadline { return }
        due[cwd]?.task.cancel()
        let task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(until: deadline, clock: .continuous)
            }
            guard !Task.isCancelled else { return }
            self?.becameDue(cwd)
        }
        due[cwd] = (deadline, task)
    }

    private func becameDue(_ cwd: String) {
        due.removeValue(forKey: cwd)
        if reading.contains(cwd) { stale.insert(cwd); return }
        if prioritized.contains(cwd) {
            waiting.removeAll { $0 == cwd }
            waiting.insert(cwd, at: 0)
        } else if !waiting.contains(cwd) { waiting.append(cwd) }
        startWaiting()
    }

    private func startWaiting() {
        while reading.count < Self.maxConcurrent, !waiting.isEmpty {
            let cwd = waiting.removeFirst()
            prioritized.remove(cwd)
            guard known.values.contains(cwd) else { continue }
            reading.insert(cwd)
            let read = read
            Task { [weak self] in
                let checkout = await read(cwd)
                await self?.landed(cwd, checkout)
            }
        }
    }

    private func landed(_ cwd: String, _ value: AgentCheckout?) async {
        delivering.insert(cwd)
        let members = known.keys.filter { known[$0] == cwd }
        // The server rechecks every member in the same queue turn as the single publication.
        if !members.isEmpty { await write(members, cwd, value) }
        delivering.remove(cwd)
        reading.remove(cwd)
        if stale.remove(cwd) != nil, known.values.contains(cwd), !waiting.contains(cwd) {
            if prioritized.contains(cwd) { waiting.insert(cwd, at: 0) } else { waiting.append(cwd) }
        }
        startWaiting()
    }
}

extension ShepherdViewModel {
    /// The directory an agent's pi works in: its thread pane's, else its worktree's.
    func checkoutDirectory(of id: AgentID) -> String? {
        // A thread of This Mac's background host checks out on this machine too.
        let state = state.agents.contains(where: { $0.id == id }) ? state : thisMacAgent(id)?.connection.state ?? state
        guard let agent = state.agents.first(where: { $0.id == id }) else { return nil }
        let layout = state.tabs.first { $0.id == agent.tabID }?.layout
        return layout?.leaves.first { $0.agentID == id }?.cwd ?? agent.worktreePath ?? layout?.firstLeaf.cwd
    }
}
