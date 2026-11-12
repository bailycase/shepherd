import Foundation
import ShepherdProtocol

/// One superseded or losing value of a unit, kept so it can be put back (`history/<unit>/<hlc>.json`).
struct FleetHistoryEntry: Codable, Equatable {
    var unit: String
    var mac: UUID
    var macName: String
    var seq: UInt64
    var hlc: FleetHLC
    var change: FleetChange
    /// Epoch milliseconds when it was set aside.
    var recordedAt: Double
    /// Why: "superseded", "lost" (an older write arrived late), "replaced" (a copy this Mac held
    /// that the first sync replaced).
    var reason: String
}

/// Fleet's store (`<support>/fleet/store/`): one append only op log per origin Mac, content
/// addressed blobs, and the history of what each unit used to hold. Every file is mode 0600.
///
/// Not thread safe: it belongs to the server queue, like the rest of the fleet's state. The
/// files are small (settings, two instruction files), so reads and writes happen in place.
/// Nothing here writes a real file of the user's: only `FleetMaterializer` does that.
final class FleetStore {
    /// Versions of a unit kept in `history/`, and for how long.
    static let historyLimit = 100
    static let historyLifetime: TimeInterval = 30 * 24 * 3600

    enum Received: Equatable {
        /// Stored. `won`: it now decides its unit.
        case stored(won: Bool)
        case duplicate
        /// It skips an op of its origin: the sender has to send the ones in between first.
        case gap
        case invalid
    }

    let directory: URL
    let mac: UUID
    private let clock: @Sendable () -> Date

    private(set) var vector = FleetVersionVector()
    private var logs: [UUID: [FleetOp]] = [:]
    private var winners: [String: FleetOp] = [:]
    private var lastHLC = FleetHLC(wallMs: 0)

    init(directory: URL, mac: UUID, clock: @escaping @Sendable () -> Date = Date.init) throws {
        self.directory = directory
        self.mac = mac
        self.clock = clock
        try Self.makeDirectory(directory)
        try Self.makeDirectory(blobsDirectory)
        try Self.makeDirectory(historyDirectory)
        load()
    }

    // MARK: Reading

    /// The op that decides `unit` now.
    func winner(of unit: String) -> FleetOp? { winners[unit] }

    var units: [String] { Array(winners.keys) }

    /// The ops of every origin that `other` lacks, in order per origin, at most `limit` of them and about `bytes` encoded.
    func ops(after other: FleetVersionVector, limit: Int = FleetSyncProtocol.maxBatchOps, bytes: Int = FleetSyncProtocol.maxBatchBytes) -> [FleetOp] {
        var batch: [FleetOp] = [], size = 0
        for (origin, log) in logs.sorted(by: { $0.key.uuidString < $1.key.uuidString }) {
            for op in log.dropFirst(Int(min(other[origin], UInt64(log.count)))) {
                let cost = (try? JSONEncoder().encode(op).count) ?? 0
                if !batch.isEmpty, size + cost > bytes || batch.count >= limit { return batch }
                batch.append(op)
                size += cost
            }
        }
        return batch
    }

    /// Whether another Mac's op of `unit` ever carried exactly `content`: a copy the fleet already has.
    func otherMacsHeld(_ content: Data, in unit: String) -> Bool {
        let hash = FleetSyncProtocol.hash(content)
        return logs.contains { origin, log in
            origin != mac && log.contains { op in
                guard op.unit == unit else { return false }
                switch op.change {
                case .value(let text): return Data(text.utf8) == content
                case .blob(let named, _): return named == hash
                case .deletion: return false
                }
            }
        }
    }

    /// This Mac's newest op of `unit`.
    func lastOwnOp(of unit: String) -> FleetOp? { logs[mac]?.last { $0.unit == unit } }

    // MARK: Writing ops

    /// Records a change this Mac made, with the next clock reading.
    @discardableResult
    func appendLocal(unit: String, change: FleetChange, seed: Bool, name: String) -> FleetOp? {
        let now = UInt64(max(0, clock().timeIntervalSince1970 * 1000))
        let hlc = lastHLC.next(now: now)
        let op = FleetOp(mac: mac, seq: vector[mac] + 1, hlc: hlc, unit: unit, change: change, seed: seed, macName: name)
        guard persist(op) else { return nil }
        accept(op)
        return op
    }

    /// Takes an op another Mac sent (or relayed). Ops of one origin arrive in order, so `seq` is
    /// always the next one; a skipped one is a `gap` and the sender resends from the vector.
    func receive(_ op: FleetOp) -> Received {
        guard op.isWellFormed else { return .invalid }
        if op.seq <= vector[op.mac] { return .duplicate }
        guard op.seq == vector[op.mac] + 1 else { return .gap }
        guard persist(op) else { return .invalid }
        return .stored(won: accept(op))
    }

    /// Adds `op` to memory; true when it decides its unit now. A previous winner it replaces, and an
    /// op that loses, go to history.
    @discardableResult
    private func accept(_ op: FleetOp) -> Bool {
        logs[op.mac, default: []].append(op)
        vector[op.mac] = op.seq
        lastHLC = max(lastHLC, op.hlc)
        guard let current = winners[op.unit] else {
            winners[op.unit] = op
            return true
        }
        if op.supersedes(current) {
            winners[op.unit] = op
            record(current, reason: "superseded")
            return true
        }
        record(op, reason: "lost")
        return false
    }

    // MARK: Blobs

    private var blobsDirectory: URL { directory.appendingPathComponent("blobs", isDirectory: true) }
    private var historyDirectory: URL { directory.appendingPathComponent("history", isDirectory: true) }

    func hasBlob(_ hash: String) -> Bool {
        FleetSyncProtocol.isHash(hash) && FileManager.default.fileExists(atPath: blobURL(hash).path)
    }

    func blob(_ hash: String) -> Data? {
        FleetSyncProtocol.isHash(hash) ? try? Data(contentsOf: blobURL(hash)) : nil
    }

    /// Bytes `offset ..< offset + length` of a blob, and its size.
    func blobChunk(_ hash: String, offset: Int, length: Int) -> (data: Data, total: Int)? {
        guard let data = blob(hash), offset >= 0, offset <= data.count else { return nil }
        return (data.subdata(in: offset..<min(data.count, offset + length)), data.count)
    }

    /// Stores `data` under its own hash.
    @discardableResult
    func putBlob(_ data: Data) -> String? {
        guard data.count <= FleetSyncProtocol.maxBlobBytes else { return nil }
        let hash = FleetSyncProtocol.hash(data)
        if hasBlob(hash) { return hash }
        return Self.write(data, to: blobURL(hash)) ? hash : nil
    }

    /// Stores `data` only if it is the blob called `hash`.
    func putBlob(_ data: Data, named hash: String) -> Bool {
        FleetSyncProtocol.hash(data) == hash && putBlob(data) == hash
    }

    /// The blobs this Mac needs and doesn't hold, to fetch from a peer: the winners' (to write them)
    /// and the history's (a version set aside is only kept if its text is).
    func missingBlobs() -> [(hash: String, size: Int)] {
        var wanted: [String: Int] = [:]
        for op in winners.values { if case .blob(let hash, let size) = op.change { wanted[hash] = size } }
        for (hash, size) in keptBlobs { wanted[hash] = size }
        return wanted.filter { !hasBlob($0.key) }.map { ($0.key, $0.value) }.sorted { $0.hash < $1.hash }
    }

    /// Blobs named by history entries made here (a loser that arrived without its text), until held or pruned.
    private var keptBlobs: [String: Int] = [:]

    private func blobURL(_ hash: String) -> URL { blobsDirectory.appendingPathComponent(hash) }

    // MARK: History

    /// Sets aside a copy of `unit` this Mac held and the sync is about to replace.
    func preserve(unit: String, content: Data, storingInline: Bool, name: String) {
        let change: FleetChange
        if storingInline {
            change = .value(String(decoding: content, as: UTF8.self))
        } else if let hash = putBlob(content) {
            change = .blob(hash: hash, size: content.count)
        } else { return }
        let now = UInt64(max(0, clock().timeIntervalSince1970 * 1000))
        lastHLC = lastHLC.next(now: now)
        record(FleetOp(mac: mac, seq: 0, hlc: lastHLC, unit: unit, change: change, macName: name), reason: "replaced")
    }

    /// The saved versions of `unit`, newest first.
    func history(of unit: String) -> [FleetHistoryEntry] {
        let folder = historyFolder(unit)
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        return files.compactMap { try? JSONDecoder().decode(FleetHistoryEntry.self, from: Data(contentsOf: folder.appendingPathComponent($0))) }
            .sorted { ($0.hlc, $0.mac.uuidString) > ($1.hlc, $1.mac.uuidString) }
    }

    private func record(_ op: FleetOp, reason: String) {
        let entry = FleetHistoryEntry(unit: op.unit, mac: op.mac, macName: op.macName, seq: op.seq, hlc: op.hlc, change: op.change,
                                      recordedAt: (clock().timeIntervalSince1970 * 1000).rounded(), reason: reason)
        let folder = historyFolder(op.unit)
        try? Self.makeDirectory(folder)
        let name = String(format: "%016llx-%08x", op.hlc.wallMs, op.hlc.counter) + "-\(op.mac.uuidString.prefix(8))-\(op.seq).json"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(entry), Self.write(data, to: folder.appendingPathComponent(name)) else { return }
        if case .blob(let hash, let size) = op.change { keptBlobs[hash] = size }
        prune(folder)
    }

    /// Keeps the newest `historyLimit` versions younger than `historyLifetime`; the blob of one
    /// dropped goes with it unless a winner or another version still names it.
    private func prune(_ folder: URL) {
        let manager = FileManager.default
        let names = ((try? manager.contentsOfDirectory(atPath: folder.path)) ?? []).sorted(by: >)
        let cutoff = (clock().timeIntervalSince1970 - Self.historyLifetime) * 1000
        for (index, name) in names.enumerated() {
            let url = folder.appendingPathComponent(name)
            let entry = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(FleetHistoryEntry.self, from: $0) }
            guard index >= Self.historyLimit || (entry.map { $0.recordedAt < cutoff } ?? false) else { continue }
            try? manager.removeItem(at: url)
            if case .blob(let hash, _)? = entry?.change, !isReferenced(hash) {
                try? manager.removeItem(at: blobURL(hash))
                keptBlobs[hash] = nil
            }
        }
    }

    private func isReferenced(_ hash: String) -> Bool {
        if winners.values.contains(where: { $0.blobHash == hash }) { return true }
        let manager = FileManager.default
        for unit in (try? manager.contentsOfDirectory(atPath: historyDirectory.path)) ?? [] {
            let folder = historyDirectory.appendingPathComponent(unit, isDirectory: true)
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                if let entry = (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap({ try? JSONDecoder().decode(FleetHistoryEntry.self, from: $0) }),
                   case .blob(let named, _) = entry.change, named == hash { return true }
            }
        }
        return false
    }

    /// `history/<unit>/`: the unit's name with anything outside a file name's safe set escaped.
    private func historyFolder(_ unit: String) -> URL {
        let safe = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        let name = unit.unicodeScalars.map { safe.contains($0) ? String($0) : String(format: "%%%02X", $0.value & 0xFF) }.joined()
        return historyDirectory.appendingPathComponent(name, isDirectory: true)
    }

    // MARK: Persistence

    private func logURL(_ origin: UUID) -> URL { directory.appendingPathComponent("ops-\(origin.uuidString).ndjson") }

    private func persist(_ op: FleetOp) -> Bool {
        guard var line = try? JSONEncoder().encode(op) else { return false }
        line.append(0x0A)
        let url = logURL(op.mac)
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        return line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, line.count) } == line.count
    }

    /// Reads every origin's log. A log is only ever read up to its first line that isn't the next
    /// op of its origin, so a torn last line from a crash is dropped and rewritten by the peer.
    private func load() {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix("ops-") && name.hasSuffix(".ndjson") {
            guard let origin = UUID(uuidString: String(name.dropFirst(4).dropLast(7))),
                  let text = try? String(contentsOf: directory.appendingPathComponent(name), encoding: .utf8) else { continue }
            var expected: UInt64 = 1
            var validBytes = 0
            for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                guard let op = try? JSONDecoder().decode(FleetOp.self, from: Data(line.utf8)), op.mac == origin, op.seq == expected, op.isWellFormed else { break }
                logs[origin, default: []].append(op)
                lastHLC = max(lastHLC, op.hlc)
                expected += 1
                validBytes += line.utf8.count + 1
            }
            vector[origin] = expected - 1
            // Drop a torn tail so the next append continues the log.
            if validBytes < text.utf8.count, let handle = try? FileHandle(forWritingTo: directory.appendingPathComponent(name)) {
                try? handle.truncate(atOffset: UInt64(validBytes))
                try? handle.close()
            }
        }
        for log in logs.values {
            for op in log where winners[op.unit].map({ op.supersedes($0) }) ?? true { winners[op.unit] = op }
        }
        // History entries whose text never arrived are still wanted.
        let manager = FileManager.default
        for unit in (try? manager.contentsOfDirectory(atPath: historyDirectory.path)) ?? [] {
            let folder = historyDirectory.appendingPathComponent(unit, isDirectory: true)
            for name in (try? manager.contentsOfDirectory(atPath: folder.path)) ?? [] {
                guard let entry = (try? Data(contentsOf: folder.appendingPathComponent(name))).flatMap({ try? JSONDecoder().decode(FleetHistoryEntry.self, from: $0) }),
                      case .blob(let hash, let size) = entry.change, !hasBlob(hash) else { continue }
                keptBlobs[hash] = size
            }
        }
    }

    static func makeDirectory(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    /// Writes by temp file and rename, mode 0600.
    @discardableResult
    static func write(_ data: Data, to url: URL) -> Bool {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).tmp")
        guard FileManager.default.createFile(atPath: temporary.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return false }
        guard rename(temporary.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            return false
        }
        return true
    }
}
