import Foundation

/// What a client shows for a thread rename the person just submitted, until its host says otherwise.
/// A presentation overlay: the host's snapshot is never edited, so a stale or late snapshot cannot
/// overwrite the person's intent, and the intent never overwrites the host. At most one request per
/// thread is in flight; a newer submit replaces the intent and is sent when the one in flight ends,
/// so the host always ends on the latest name.
public struct PendingAgentRenames<Key: Hashable & Sendable>: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        /// The latest intent: what the thread presents.
        var name: String
        /// The name of the request in flight, if any.
        var sent: String?
        /// The latest intent was accepted; the overlay waits for the host's snapshot to show it.
        var settled = false
        /// Every name this intent chain has seen on the host or sent. A snapshot showing one of them
        /// is older than the host's answer; any other name is somebody else's rename.
        var known: Set<String>
    }

    public enum Completion: Equatable, Sendable {
        /// Send this name next: a newer intent arrived while the last request was in flight.
        case resend(String)
        /// The latest intent was accepted; the overlay stays until a snapshot catches up.
        case settled
        /// The latest intent was refused: the thread shows the host's name again.
        case reverted
        /// Nothing waits on this request.
        case ignored
    }

    var entries: [Key: Entry] = [:]

    public init() {}

    public var isEmpty: Bool { entries.isEmpty }

    /// The name to show: the latest submitted one, else the host's.
    public func presented(_ key: Key, hostName: String) -> String {
        entries[key]?.name ?? hostName
    }

    public func isPending(_ key: Key) -> Bool { entries[key] != nil }

    /// A new intent. Returns whether a request should start now (`beginSend`); false when one is
    /// already in flight and will send this name when it ends.
    @discardableResult
    public mutating func submit(_ key: Key, name: String, hostName: String) -> Bool {
        var entry = entries[key] ?? Entry(name: name, known: [hostName])
        entry.name = name
        entry.settled = false
        entry.known.insert(name)
        entries[key] = entry
        return entry.sent == nil
    }

    /// The name to send now, marking it in flight; nil when nothing waits or one is in flight.
    public mutating func beginSend(_ key: Key) -> String? {
        guard var entry = entries[key], entry.sent == nil, !entry.settled else { return nil }
        entry.sent = entry.name
        entries[key] = entry
        return entry.name
    }

    /// The request for `sent` ended. Only the latest intent's failure reverts the thread; an older
    /// request's outcome is superseded by the next send.
    public mutating func completed(_ key: Key, sent: String, failed: Bool) -> Completion {
        guard var entry = entries[key], entry.sent == sent else { return .ignored }
        entry.sent = nil
        if entry.name != sent {
            entry.sent = entry.name
            entries[key] = entry
            return .resend(entry.name)
        }
        if failed {
            entries[key] = nil
            return .reverted
        }
        entry.settled = true
        entries[key] = entry
        return .settled
    }

    /// A snapshot arrived: `hostName` is the thread's name in it, nil when the thread is gone. An
    /// accepted rename leaves once the host shows it, or a name nobody here chose; a snapshot with an
    /// older name is held off. While a request is in flight the overlay stays whatever arrives.
    public mutating func observe(_ key: Key, hostName: String?) {
        guard let entry = entries[key] else { return }
        guard let hostName else { entries[key] = nil; return }
        if entry.settled, hostName == entry.name || !entry.known.contains(hostName) { entries[key] = nil }
    }

    /// Drops the overlays of threads `isLive` no longer holds.
    public mutating func prune(isLive: (Key) -> Bool) {
        for key in entries.keys where !isLive(key) { entries[key] = nil }
    }

    public var keys: [Key] { Array(entries.keys) }
}
