import Darwin
import Foundation

/// Teardown ownership for a child we launched, including MCP servers in detached groups.
/// Capture before stopping the owner; saved start identities fence signals after reparenting.
/// Never discovers unrelated processes by name or signals Shepherd's own process group.
public final class OwnedProcessTree: @unchecked Sendable {
    private struct Identity {
        let pid: pid_t
        let group: pid_t
        let parent: pid_t
        let seconds: UInt64
        let microseconds: UInt64

        init?(_ pid: pid_t) {
            var info = proc_bsdinfo()
            guard pid > 0,
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout.size(ofValue: info))) == MemoryLayout.size(ofValue: info) else { return nil }
            self.pid = pid
            group = pid_t(info.pbi_pgid)
            parent = pid_t(info.pbi_ppid)
            seconds = info.pbi_start_tvsec
            microseconds = info.pbi_start_tvusec
        }

        var isCurrent: Bool {
            guard let now = Identity(pid) else { return false }
            return now.seconds == seconds && now.microseconds == microseconds && now.group == group
        }
    }

    private let lock = NSLock()
    private let root: Identity?
    private var descendants: [pid_t: Identity] = [:]

    public init(root: pid_t) { self.root = Identity(root) }

    /// Walk only children of identity-checked owned processes, not the system's process list.
    public func capture() {
        lock.withLock { captureLocked() }
    }

    private func captureLocked() {
        var pending = Array(descendants.values)
        if let root { pending.append(root) }
        var visited = Set<pid_t>()
        // ponytail: teardown walks at most 4096 owned processes; explicit registration if fleets exceed it.
        while visited.count < 4096, let parent = pending.popLast() {
            guard visited.insert(parent.pid).inserted, parent.isCurrent else { continue }
            let bytes = proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent.pid), nil, 0)
            guard bytes > 0 else { continue }
            var pids = [pid_t](repeating: 0, count: min(4096, Int(bytes) / MemoryLayout<pid_t>.stride + 32))
            let used = pids.withUnsafeMutableBytes {
                proc_listpids(UInt32(PROC_PPID_ONLY), UInt32(parent.pid), $0.baseAddress, Int32($0.count))
            }
            guard parent.isCurrent else { continue }
            let count = min(pids.count, max(0, Int(used)) / MemoryLayout<pid_t>.stride)
            for pid in pids.prefix(count) where pid > 0 {
                guard descendants.count < 4096, let child = Identity(pid), child.parent == parent.pid else { continue }
                descendants[pid] = child
                pending.append(child)
            }
        }
    }

    public func signalRoot(_ signal: Int32) {
        guard let root, root.isCurrent else { return }
        _ = kill(root.pid, signal)
    }

    /// Signals detached groups only while a captured member proves their identity. Original-group
    /// descendants get individual signals: a Foundation Process may share Shepherd's own group.
    public func signalDescendants(_ signal: Int32) {
        lock.withLock {
            captureLocked()
            var groups = Set<pid_t>()
            for child in descendants.values where child.isCurrent {
                if child.group > 0, descendants[child.group] != nil, child.group != root?.group, child.group != getpgrp() {
                    if groups.insert(child.group).inserted { _ = kill(-child.group, signal) }
                } else {
                    _ = kill(child.pid, signal)
                }
            }
        }
    }
}
