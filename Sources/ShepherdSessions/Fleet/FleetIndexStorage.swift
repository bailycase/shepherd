import Foundation
import ShepherdCore

/// A content index on disk (`<support>/fleet/index/roots/<id>/`): a snapshot of every entry, a journal of
/// the changes since, and a small meta file holding what is needed to trust them (the root, the exclusion rules
/// it was made under, the FSEvents id it is current as of and the volume that id belongs to). A change appends
/// a few lines to the journal; the snapshot is written again only when the journal has grown past the entries.
/// Mode 0600, like the rest of the fleet's files.
struct FleetIndexStorage {
    static let version = 1

    struct Meta: Codable, Equatable {
        var version: Int
        var root: String
        var rules: String
        var eventID: UInt64?
        var volume: String?
    }

    /// One line of the snapshot or the journal. A line with `x` removes the path.
    private struct Row: Codable {
        var p: String
        var x: Bool?
        var k: UInt8?
        var s: UInt64?
        var m: Int64?
        var h: FleetHash?
        var g: FleetGitBlobID?
        var c: UInt8?
    }

    let directory: URL
    private var snapshotURL: URL { directory.appendingPathComponent("snapshot.ndjson") }
    private var journalURL: URL { directory.appendingPathComponent("journal.ndjson") }
    private var metaURL: URL { directory.appendingPathComponent("meta.json") }

    init(directory: URL) { self.directory = directory }

    /// The entries saved, with the journal applied; nil when there is no usable index (none, or written for other rules or another root).
    func load(root: String, rules: String) -> (meta: Meta, entries: [String: FleetIndexEntry], journalLines: Int)? {
        guard let data = try? Data(contentsOf: metaURL), let meta = try? JSONDecoder().decode(Meta.self, from: data),
              meta.version == Self.version, meta.root == root, meta.rules == rules,
              let snapshot = try? Data(contentsOf: snapshotURL) else { return nil }
        var entries: [String: FleetIndexEntry] = [:]
        let decoder = JSONDecoder()
        var journalLines = 0
        for (file, isJournal) in [(snapshot, false), ((try? Data(contentsOf: journalURL)) ?? Data(), true)] {
            for line in file.split(separator: 10, omittingEmptySubsequences: true) {
                guard let row = try? decoder.decode(Row.self, from: Data(line)) else {
                    // A line cut short by a crash ends the journal; one in the snapshot makes it unusable.
                    if isJournal { break }
                    return nil
                }
                if isJournal { journalLines += 1 }
                if row.x == true { entries[row.p] = nil; continue }
                guard let k = row.k, let kind = FleetEntryKind(rawValue: k), let s = row.s, let m = row.m, let h = row.h, let g = row.g,
                      let c = row.c, let state = FleetGitClass(rawValue: c) else { return nil }
                entries[row.p] = FleetIndexEntry(kind: kind, size: s, modified: m, hash: h, gitID: g, state: state)
            }
        }
        return (meta, entries, journalLines)
    }

    private static func row(_ path: String, _ entry: FleetIndexEntry) -> Row {
        Row(p: path, x: nil, k: entry.kind.rawValue, s: entry.size, m: entry.modified, h: entry.hash, g: entry.gitID, c: entry.state.rawValue)
    }

    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    }

    private static func lines(_ rows: some Sequence<Row>) -> Data {
        let encoder = JSONEncoder()
        var out = Data()
        for row in rows {
            guard let line = try? encoder.encode(row) else { continue }
            out.append(line)
            out.append(10)
        }
        return out
    }

    /// Writes every entry as the new snapshot and empties the journal.
    func writeSnapshot(_ entries: [String: FleetIndexEntry]) throws {
        try prepare()
        let data = Self.lines(entries.map { Self.row($0.key, $0.value) })
        try data.write(to: snapshotURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
        try? FileManager.default.removeItem(at: journalURL)
    }

    /// Appends the changes: each path with its entry now, or removed.
    func appendJournal(_ paths: Set<String>, entries: [String: FleetIndexEntry]) throws {
        try prepare()
        let data = Self.lines(paths.sorted().map { path in entries[path].map { Self.row(path, $0) } ?? Row(p: path, x: true) })
        if !FileManager.default.fileExists(atPath: journalURL.path) {
            guard FileManager.default.createFile(atPath: journalURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
        }
        let handle = try FileHandle(forWritingTo: journalURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    func writeMeta(_ meta: Meta) throws {
        try prepare()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(meta).write(to: metaURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metaURL.path)
    }

    /// The bytes the index takes on disk.
    var bytesOnDisk: Int {
        [snapshotURL, journalURL, metaURL].reduce(0) { $0 + ((try? FileManager.default.attributesOfItem(atPath: $1.path)[.size] as? Int) ?? 0) }
    }

    func remove() { try? FileManager.default.removeItem(at: directory) }
}
