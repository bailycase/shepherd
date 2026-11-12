import Foundation
import ShepherdCore

/// The "Sending with uncommitted changes" card (FleetStates): work on its way to another Mac with the checkout's edits and files,
/// drawn from the dispatch record alone. It is `FleetDispatchCard.sending`: the dispatch's card in the thread that sent the work and on
/// the Fleet page shows its progress while the record is `preparing`.
public struct FleetSendingCard: Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// The Mac it is going to, as its tag names it.
    public var host: String
    /// "Starting": the word on the pill.
    public var state: String
    /// "Sent payments-api at 4e1c9a2 plus 3 uncommitted files. The Mac mini applies them to a new worktree and checks they match before the agent starts."
    public var summary: String
    /// How much of the snapshot's contents has gone, 0...1; nil before it is known.
    public var fraction: Double?
    /// "1.8 of 2.8 MB", or "nothing to send" when the Mac already holds it all.
    public var progress: String
    /// A line when the snapshot is above the warning size: it sends, and says so.
    public var warning: String?

    public var accessibilityLabel: String { "\(title), sending to \(host), \(progress). \(summary)" }

    /// The card for `record`, or nil when it isn't sending a snapshot now.
    public static func make(_ record: FleetDispatchRecord) -> FleetSendingCard? {
        guard record.state == .preparing, let bytes = record.snapshotBytes else { return nil }
        let host = record.targetHostName ?? "the other Mac"
        let sent = min(record.snapshotProgress ?? 0, bytes)
        let repo = record.repoKey.split(separator: "/").last.map(String.init) ?? record.repoKey
        var words = "Sent \(repo)"
        if let sha = record.commitSHA { words += " at \(sha.prefix(7))" }
        if let files = record.snapshotFiles, files > 0 { words += " plus \(files) uncommitted \(files == 1 ? "file" : "files")" }
        words += ". \(host) applies \(record.snapshotFiles ?? 0 > 0 ? "them" : "it") to a new worktree and checks they match before the agent starts."
        return FleetSendingCard(
            id: record.id, title: record.title.isEmpty ? "Untitled" : record.title, host: host, state: "Starting", summary: words,
            fraction: bytes == 0 ? 1 : Double(sent) / Double(bytes),
            progress: bytes == 0 ? "nothing to send" : Self.progress(sent, of: bytes),
            warning: record.sendWarning ? "Over \(size(FleetSnapshotCap.warnAbove)), so this will take a while." : nil)
    }

    /// "1.8 of 2.8 MB": the unit once when both share it.
    static func progress(_ sent: UInt64, of total: UInt64) -> String {
        let (a, b) = (size(sent), size(total))
        guard let unit = b.split(separator: " ").last, a.hasSuffix(" " + unit) else { return "\(a) of \(b)" }
        return "\(a.dropLast(unit.count + 1)) of \(b)"
    }

    /// "1.8 MB": decimal units, one digit.
    public static func size(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value >= 1e9 { return String(format: "%.1f GB", value / 1e9) }
        if value >= 1e6 { return String(format: "%.1f MB", value / 1e6) }
        return "\(Int((value / 1e3).rounded(.up))) KB"
    }

    /// Why a dispatch was refused for its size, in words: "Too big to send (6.2 GB), mostly node_modules/big.bin (3.1 GB)".
    /// `detail` is the record's `failureDetail` for `snapshot_too_large`: the total, then each of the biggest as `path:bytes`.
    public static func tooLargeWords(_ detail: String?) -> String {
        let fields = (detail ?? "").split(separator: ";").map(String.init)
        guard let total = fields.first.flatMap(UInt64.init) else { return "Too big to send" }
        var words = "Too big to send (\(size(total)))"
        let biggest = fields.dropFirst().compactMap { field -> (String, UInt64)? in
            guard let colon = field.lastIndex(of: ":"), let bytes = UInt64(field[field.index(after: colon)...]) else { return nil }
            return (String(field[..<colon]), bytes)
        }
        if let first = biggest.first { words += ", mostly \(first.0) (\(size(first.1)))" }
        return words
    }
}
