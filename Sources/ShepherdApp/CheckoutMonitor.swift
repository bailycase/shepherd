import Foundation
import ShepherdCore

/// Reads an agent's checkout for the header's branch chip: its branch and how many files differ
/// from HEAD, in one `git status` (`--no-optional-locks`, so it never takes the index lock
/// under pi's own git calls). Blocking; call off the main thread.
enum CheckoutStatus {
    static func read(cwd: String) -> AgentCheckout? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["--no-optional-locks", "-C", (cwd as NSString).expandingTildeInPath,
                             "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"]
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        process.environment = environment
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return parse(String(decoding: output, as: UTF8.self))
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
/// runs off the main thread, at most `maxConcurrent` at once, and requests for an agent coalesce
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
    private let write: (AgentID, AgentCheckout?) async -> Void
    /// The directory each agent works in; nil once it is gone.
    var directory: (AgentID) -> String? = { _ in nil }
    private var known: Set<AgentID> = []
    private var due: [AgentID: (deadline: ContinuousClock.Instant, task: Task<Void, Never>)] = [:]
    private var waiting: [AgentID] = []
    private var reading: Set<AgentID> = []
    /// Asked again while its read ran: it reads once more when that one lands.
    private var stale: Set<AgentID> = []

    init(read: @escaping Reader, write: @escaping (AgentID, AgentCheckout?) async -> Void) {
        self.read = read
        self.write = write
    }

    /// The workspace changed: read agents it has not seen, forget the ones that left.
    func sync(agents: [AgentID]) {
        let live = Set(agents)
        guard live != known else { return }
        for gone in known.subtracting(live) {
            due.removeValue(forKey: gone)?.task.cancel()
            waiting.removeAll { $0 == gone }
            stale.remove(gone)
        }
        let added = agents.filter { !known.contains($0) }
        known = live
        for id in added { refresh(id) }
    }

    func refresh(_ id: AgentID, after delay: Duration = .zero) {
        guard known.contains(id) else { return }
        let deadline = ContinuousClock.now + delay
        if let pending = due[id], pending.deadline <= deadline { return }
        due[id]?.task.cancel()
        let task = Task { [weak self] in
            if delay > .zero {
                try? await Task.sleep(until: deadline, clock: .continuous)
                guard !Task.isCancelled else { return }
            }
            self?.becameDue(id)
        }
        due[id] = (deadline, task)
    }

    private func becameDue(_ id: AgentID) {
        due.removeValue(forKey: id)
        if reading.contains(id) { stale.insert(id); return }
        if !waiting.contains(id) { waiting.append(id) }
        startWaiting()
    }

    private func startWaiting() {
        while reading.count < Self.maxConcurrent, !waiting.isEmpty {
            let id = waiting.removeFirst()
            guard known.contains(id), let cwd = directory(id) else { continue }
            reading.insert(id)
            let read = read
            Task { [weak self] in
                let checkout = await read(cwd)
                await self?.landed(id, checkout)
            }
        }
    }

    private func landed(_ id: AgentID, _ checkout: AgentCheckout?) async {
        if known.contains(id) { await write(id, checkout) }
        reading.remove(id)
        if stale.remove(id) != nil, known.contains(id), !waiting.contains(id) { waiting.append(id) }
        startWaiting()
    }
}

extension ShepherdViewModel {
    /// The directory an agent's pi works in: its thread pane's, else its worktree's.
    func checkoutDirectory(of id: AgentID) -> String? {
        guard let agent = state.agents.first(where: { $0.id == id }) else { return nil }
        let layout = state.tabs.first { $0.id == agent.tabID }?.layout
        return layout?.leaves.first { $0.agentID == id }?.cwd ?? agent.worktreePath ?? layout?.firstLeaf.cwd
    }
}
