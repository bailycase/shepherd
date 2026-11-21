import Darwin
import Foundation

/// An exec environment marker survives reparenting and changes of group/session. Cwd,
/// names and argv are never evidence of ownership. Keep the marker out of logs and receipts.
struct ThreadProcessSweep: Sendable {
    static let threadKey = "SHEPHERD_OWNED_THREAD"
    static let bashKey = "SHEPHERD_OWNED_BASH"

    let markers: Set<String>
    var bashScopes: Set<UUID>? = nil
    var tracked: Set<OwnedProcessTree.Birth> = []

    struct Report: Sendable {
        var found = 0
        var exited = 0
        var forced = 0
        var unconfirmed = 0
        var trackedMatches = 0
        var enumerated = true
        var incompleteInspection = false

        var complete: Bool { enumerated && unconfirmed == 0 }
        var summary: String {
            var text = "Marked process sweep: \(found) escapees found; \(exited) escapees confirmed exited after signaling; SIGKILL sent to \(forced) escapees after SIGTERM; \(trackedMatches) already tracked; \(unconfirmed) marked processes not confirmed stopped."
            if !enumerated { text += " Could not enumerate all process IDs." }
            if incompleteInspection { text += " Some processes could not be inspected for ownership markers." }
            return text
        }
    }

    static func token(_ pid: pid_t) -> audit_token_t? {
        var port: mach_port_name_t = 0
        guard task_name_for_pid(mach_task_self_, pid, &port) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, port) }
        var token = audit_token_t()
        let words = MemoryLayout<audit_token_t>.size / MemoryLayout<integer_t>.size
        var count = mach_msg_type_number_t(words)
        let status = withUnsafeMutablePointer(to: &token) {
            $0.withMemoryRebound(to: integer_t.self, capacity: words) {
                task_info(port, task_flavor_t(TASK_AUDIT_TOKEN), $0, &count)
            }
        }
        guard status == KERN_SUCCESS, count == words, token.val.5 == UInt32(pid) else { return nil }
        return token
    }

    // Darwin checks the token's PID version in the kernel, unlike kill(pid, sig).
    private static func signal(_ sig: Int32, to identity: audit_token_t) -> Int32 {
        var token = identity
        return proc_signal_with_audittoken(&token, sig)
    }

    private static func info(_ pid: pid_t) -> proc_bsdinfo? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info
    }

    private static func live(_ identity: audit_token_t) -> Bool {
        let pid = pid_t(identity.val.5)
        // A zombie is already dead, even if its parent has not reaped it.
        if info(pid)?.pbi_status == UInt32(SZOMB) { return false }
        if let now = token(pid) { return now.val.7 == identity.val.7 }
        return kill(pid, 0) == 0 || errno != ESRCH
    }

    private func matchingProcesses(incomplete: inout Bool, trackedMatches: inout Set<UInt64>) -> [audit_token_t]? {
        let flavor = UInt32(PROC_UID_ONLY)
        let uid = geteuid()
        var capacity = Int(proc_listpids(flavor, uid, nil, 0)) / MemoryLayout<pid_t>.stride + 32
        var pids: [pid_t]
        var used: Int
        repeat {
            pids = [pid_t](repeating: 0, count: capacity)
            used = pids.withUnsafeMutableBytes { Int(proc_listpids(flavor, uid, $0.baseAddress, Int32($0.count))) }
            guard used > 0 else { return nil }
            capacity *= 2
        } while used >= pids.count * MemoryLayout<pid_t>.stride

        var argMax: Int32 = 0
        var length = MemoryLayout<Int32>.size
        var mib: [Int32] = [CTL_KERN, KERN_ARGMAX]
        guard sysctl(&mib, 2, &argMax, &length, nil, 0) == 0, argMax > MemoryLayout<Int32>.size else { return nil }
        var buffer = [UInt8](repeating: 0, count: Int(argMax))
        let threadEntries = markers.map { Array("\(Self.threadKey)=\($0)".utf8) }
        let bashEntries = bashScopes.map { Set($0.map { Array("\(Self.bashKey)=\($0.uuidString.lowercased())".utf8) }) }
        return pids.prefix(used / MemoryLayout<pid_t>.stride).compactMap { pid in
            guard pid > 1, pid != getpid() else { return nil }
            guard let info = Self.info(pid) else { incomplete = true; return nil }
            guard info.pbi_status != UInt32(SZOMB) else { return nil }
            guard let identity = Self.token(pid) else { incomplete = true; return nil }
            var mib = [CTL_KERN, KERN_PROCARGS2, pid]
            var size = buffer.count
            guard buffer.withUnsafeMutableBytes({ sysctl(&mib, 3, $0.baseAddress, &size, nil, 0) }) == 0,
                  let matches = Self.matches(buffer, size: size, threadEntries: threadEntries, bashEntries: bashEntries) else {
                incomplete = true
                return nil
            }
            guard matches else { return nil }
            guard Self.token(pid)?.val.7 == identity.val.7 else { incomplete = true; return nil }
            if tracked.contains(OwnedProcessTree.Birth(info)) { trackedMatches.insert(Self.identityKey(identity)) }
            return identity
        }
    }

    private static func matches(_ args: [UInt8], size: Int, threadEntries: [[UInt8]], bashEntries: Set<[UInt8]>?) -> Bool? {
        // KERN_PROCARGS2: native argc, executable path, NUL padding, argc argv strings, envp.
        let head = MemoryLayout<Int32>.size
        guard size > head, size <= args.count else { return nil }
        let argc = args.withUnsafeBytes { Int($0.loadUnaligned(as: Int32.self)) }
        guard argc > 0, argc < size - head else { return nil }
        let bytes = args[..<size]
        guard let pathEnd = bytes[head...].firstIndex(of: 0),
              var cursor = bytes[pathEnd...].firstIndex(where: { $0 != 0 }) else { return nil }
        for _ in 0..<argc {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            cursor = end + 1
        }
        var foundThread = false, foundBash = bashEntries == nil
        while cursor < size, bytes[cursor] != 0 {
            guard let end = bytes[cursor...].firstIndex(of: 0) else { return nil }
            let entry = bytes[cursor..<end]
            if !foundThread { foundThread = threadEntries.contains { entry.elementsEqual($0) } }
            if !foundBash, entry.starts(with: Self.bashPrefix), bashEntries?.contains(Array(entry)) == true { foundBash = true }
            if foundThread && foundBash { return true }
            cursor = end + 1
        }
        return false
    }

    private static let bashPrefix = Array("\(bashKey)=".utf8)

    /// Called off the server queue. No wait and no scan on successful Bash return.
    func run() async -> Report {
        var found = Set<UInt64>(), attempted = Set<UInt64>(), forced = Set<UInt64>()
        var survivors = [audit_token_t]()
        var report = Report()
        var trackedMatches = Set<UInt64>()
        // A TERM handler can fork. Sweep once more, then require an empty final scan for close.
        for _ in 0..<2 {
            guard let matches = matchingProcesses(incomplete: &report.incompleteInspection, trackedMatches: &trackedMatches) else {
                report.enumerated = false
                break
            }
            let targets = survivors + matches.filter { !found.contains(Self.identityKey($0)) }
            if targets.isEmpty { break }
            found.formUnion(targets.map(Self.identityKey))
            for target in targets where Self.signal(SIGTERM, to: target) == 0 {
                attempted.insert(Self.identityKey(target))
            }
            let remaining = await Self.waitForExit(targets, until: .now + .seconds(1))
            for target in remaining where Self.signal(SIGKILL, to: target) == 0 {
                forced.insert(Self.identityKey(target))
                attempted.insert(Self.identityKey(target))
            }
            survivors = await Self.waitForExit(remaining, until: .now + .seconds(1))
        }
        var alive = Set(survivors.filter(Self.live).map(Self.identityKey))
        if let matches = matchingProcesses(incomplete: &report.incompleteInspection, trackedMatches: &trackedMatches) {
            alive.formUnion(matches.map(Self.identityKey))
        } else {
            report.enumerated = false
        }
        found.formUnion(alive)
        report.found = found.subtracting(trackedMatches).count
        report.exited = attempted.subtracting(alive).subtracting(trackedMatches).count
        report.forced = forced.subtracting(trackedMatches).count
        report.trackedMatches = trackedMatches.count
        report.unconfirmed = alive.count
        return report
    }

    private static func identityKey(_ token: audit_token_t) -> UInt64 {
        UInt64(token.val.5) << 32 | UInt64(token.val.7)
    }

    private static func waitForExit(_ processes: [audit_token_t], until deadline: ContinuousClock.Instant) async -> [audit_token_t] {
        var live = processes.filter(Self.live)
        while !live.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
            live = live.filter(Self.live)
        }
        return live
    }
}
