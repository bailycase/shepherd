import Darwin
import Foundation

/// Numeric diagnostics only. Process identifiers stay local and never enter a report.
public struct SessionResourceState: Sendable {
    let piPIDs: Set<Int32>
    let terminalPIDs: Set<Int32>
    let values: [String: Double]
}

/// One bounded process census per diagnostics sample, off the server and main queues.
/// Remembers observed descendants so reparenting after an owner's exit does not hide them.
public actor SessionResourceSampler {
    static let processLimit = 8192
    static let ownershipLimit = 4096
    private var ownership = ResourceOwnership()

    public init() {}

    public func sample(_ state: SessionResourceState) -> [String: Double] {
        var pids = [pid_t](repeating: 0, count: Self.processLimit)
        let bytes = pids.withUnsafeMutableBytes { proc_listpids(UInt32(PROC_ALL_PIDS), 0, $0.baseAddress, Int32($0.count)) }
        var values = state.values
        guard bytes > 0 else {
            values["process_scan.failed"] = 1
            return values
        }
        let count = min(Int(bytes) / MemoryLayout<pid_t>.stride, pids.count)
        let rows = pids.prefix(count).compactMap { pid -> ResourceOwnership.Process? in
            guard pid > 0 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
            return .init(pid: pid, parent: Int32(info.pbi_ppid), seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec)
        }
        let groups = ownership.update(rows, roots: state.piPIDs.union(state.terminalPIDs).union([getpid()]),
                                      orphanRoots: state.piPIDs)
        values["process_scan.truncated"] = count == Self.processLimit || ownership.truncated ? 1 : 0
        values["process_scan.failed"] = 0
        values["system.memory_bytes"] = Double(ProcessInfo.processInfo.physicalMemory)
        for category in ["pi", "terminal", "descendants", "orphans"] {
            values[category + ".count"] = 0
            values[category + ".rss_bytes"] = 0
            values[category + ".cpu_seconds"] = 0
            values[category + ".max_rss_bytes"] = 0
        }
        values["process_scan.unreadable"] = 0
        let identities = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        for pid in Set(groups.keys).union([getpid()]) {
            let category: String
            if pid == getpid() { category = "app" }
            else if state.piPIDs.contains(pid) { category = "pi" }
            else if state.terminalPIDs.contains(pid) { category = "terminal" }
            else { category = groups[pid] == true ? "orphans" : "descendants" }
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout.size(ofValue: info))
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else {
                values["process_scan.unreadable", default: 0] += 1
                continue
            }
            // Fence PID reuse between the census and resource read.
            var identity = proc_bsdinfo()
            let identitySize = Int32(MemoryLayout.size(ofValue: identity))
            guard let expected = identities[pid],
                  proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &identity, identitySize) == identitySize,
                  expected.seconds == identity.pbi_start_tvsec, expected.micros == identity.pbi_start_tvusec else { continue }
            if category != "app" {
                values[category + ".count", default: 0] += 1
                values[category + ".max_rss_bytes"] = max(values[category + ".max_rss_bytes", default: 0], Double(info.pti_resident_size))
            }
            values[category + ".rss_bytes", default: 0] += Double(info.pti_resident_size)
            values[category + ".cpu_seconds", default: 0] += Double(info.pti_total_user + info.pti_total_system) / 1_000_000_000
        }
        var usage = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &usage) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        if result == 0 { values["app.footprint_bytes"] = Double(usage.ri_phys_footprint) }
        return values
    }
}

/// Pure ownership bookkeeping. A reused PID never inherits the old process's owner.
struct ResourceOwnership {
    struct Process: Equatable, Sendable {
        let pid: Int32
        let parent: Int32
        let seconds: UInt64
        let micros: UInt64
        func sameIdentity(as other: Self) -> Bool {
            pid == other.pid && seconds == other.seconds && micros == other.micros
        }
    }
    private var known: [Int32: (process: Process, owner: Process, reportsOrphans: Bool)] = [:]
    private(set) var truncated = false

    /// true means an observed process outlived its owning session, not that it is safe to kill.
    mutating func update(_ rows: [Process], roots: Set<Int32>, orphanRoots: Set<Int32>? = nil,
                         limit: Int = SessionResourceSampler.ownershipLimit) -> [Int32: Bool] {
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.pid, $0) })
        known = known.filter { pid, value in current[pid].map { $0.sameIdentity(as: value.process) } == true }
        let children = Dictionary(grouping: rows, by: \.parent)
        var pending = roots.sorted().compactMap { pid in
            current[pid].map { (process: $0, owner: $0, reportsOrphans: (orphanRoots ?? roots).contains(pid)) }
        }
        let previous = Array(known.values)
        var visited = Set<Int32>()
        var index = 0
        var addedPrevious = false
        truncated = false
        while index < pending.count || !addedPrevious {
            // Current ancestry wins. A Pi created between the server snapshot and the census
            // may have been classified as a generic app descendant in the previous sample.
            if index == pending.count {
                pending.append(contentsOf: previous)
                addedPrevious = true
            }
            guard index < pending.count else { break }
            let entry = pending[index]
            index += 1
            guard visited.insert(entry.process.pid).inserted else { continue }
            if known[entry.process.pid] == nil, known.count >= limit { truncated = true; continue }
            known[entry.process.pid] = entry
            for child in children[entry.process.pid] ?? [] where !roots.contains(child.pid) {
                pending.append((child, entry.owner, entry.reportsOrphans))
            }
        }
        return known.mapValues { entry in
            entry.reportsOrphans && (!roots.contains(entry.owner.pid)
                || current[entry.owner.pid].map { $0.sameIdentity(as: entry.owner) } != true)
        }
    }
}
