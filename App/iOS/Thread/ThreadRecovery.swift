import Foundation
import ShepherdCore
import ShepherdRemote

/// A send this device kept because it did not go through, saved so it comes back after the app
/// relaunches: its text only (never image bytes or anything else it carried), how many images
/// went with it, and whether the host refused it or its outcome is unknown. Saved in
/// UserDefaults, which writes to disk on its own schedule: an orderly quit or relaunch keeps it;
/// there is no fsync-grade assurance against a crash or power loss right after a change.
struct ThreadRecoveryRecord: Codable, Equatable, Identifiable, Sendable {
    enum State: String, Codable, Sendable {
        case failed, uncertain
    }

    let id: UUID
    let typed: String
    var state: State
    let images: Int

    init(id: UUID, typed: String, state: State, images: Int) {
        self.id = id
        self.typed = typed
        self.state = state
        self.images = images
    }

    private enum CodingKeys: String, CodingKey { case id, typed, state, images }

    /// Tolerant: a record from another version without `images` (or a negative count) counts
    /// none, and a state it does not know is unknown (never restorable).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Its text is what matters: one without a readable id gets a new one rather than going.
        id = (try? c.decode(UUID.self, forKey: .id)) ?? UUID()
        typed = try c.decode(String.self, forKey: .typed)
        state = (try? c.decode(State.self, forKey: .state)) ?? .uncertain
        images = max(0, (try? c.decodeIfPresent(Int.self, forKey: .images)) ?? 0)
    }
}

/// Where a thread's unresolved sends are kept between launches (`ThreadStores` saves them as the
/// store's submissions change), apart from its draft (`NativeDraftKey`), so new typing never
/// overwrites them nor they it. The store keeps submissions in memory only and clears the
/// composer when it captures one; without this a relaunch before the host answered lost the text.
enum ThreadRecovery {
    /// The same bounds as the store's own records.
    static let maximumRecords = NativeThreadStore.maximumRetainedSubmissions
    static let maximumBytes = NativeThreadStore.maximumRetainedSubmissionBytes
    static let prefix = "shepherd.ios.recovery."

    static func key(_ ref: AgentRef) -> String { prefix + ref.host.uuidString + "." + ref.agent.rawValue }

    /// Saved values set aside whole (`load`): kept on the device, untouched, until the host is
    /// forgotten. Outside `prefix`, so pruning a deleted thread's records never reaches them.
    static let asidePrefix = "shepherd.ios.recovery-aside."

    static func asideKeys(_ ref: AgentRef, defaults: UserDefaults) -> [String] {
        let start = asidePrefix + ref.host.uuidString + "." + ref.agent.rawValue + "."
        return defaults.dictionaryRepresentation().keys.filter { $0.hasPrefix(start) }
    }

    /// The records an earlier launch saved, checked before anything shows them: each readable
    /// record (a repeated id gets a new one, so restoring one never takes another), at most
    /// `maximumRecords` and `maximumBytes` of text. A value past those bounds, or not a list at
    /// all, is first set aside whole and untouched (`asidePrefix`); then the records that fit,
    /// oldest first, show. `setAside` says one was.
    static func load(_ ref: AgentRef, defaults: UserDefaults) -> (records: [ThreadRecoveryRecord], setAside: Bool) {
        guard let data = defaults.data(forKey: key(ref)) else { return ([], false) }
        func setAside() {
            defaults.set(data, forKey: asidePrefix + ref.host.uuidString + "." + ref.agent.rawValue + "." + UUID().uuidString)
        }
        guard let items = try? JSONDecoder().decode([Lossy].self, from: data) else {
            setAside()
            defaults.removeObject(forKey: key(ref))
            return ([], true)
        }
        var seen = Set<UUID>()
        let all = items.compactMap(\.record).map { record in
            seen.insert(record.id).inserted ? record
                : ThreadRecoveryRecord(id: UUID(), typed: record.typed, state: record.state, images: record.images)
        }
        guard all.count > maximumRecords || bytes(all) > maximumBytes else { return (all, false) }
        setAside()
        var fitting: [ThreadRecoveryRecord] = []
        for record in all where fitting.count < maximumRecords && bytes(fitting) + record.typed.utf8.count <= maximumBytes {
            fitting.append(record)
        }
        return (fitting, true)
    }

    /// One element of the saved list, nil where it is not a record.
    private struct Lossy: Decodable {
        let record: ThreadRecoveryRecord?
        init(from decoder: Decoder) throws { record = try? ThreadRecoveryRecord(from: decoder) }
    }

    static func save(_ records: [ThreadRecoveryRecord], for ref: AgentRef, defaults: UserDefaults) {
        if records.isEmpty {
            defaults.removeObject(forKey: key(ref))
        } else if let data = try? JSONEncoder().encode(records) {
            defaults.set(data, forKey: key(ref))
        }
    }

    /// What a restart must keep: earlier launches' records, then this launch's sends the host
    /// has not taken. One still in flight is saved as unknown: by the next launch it may have
    /// been taken, so it is never offered back to restore or sent again.
    static func records(recovered: [ThreadRecoveryRecord], submissions: [NativeThreadSubmission]) -> [ThreadRecoveryRecord] {
        recovered + submissions.map {
            ThreadRecoveryRecord(id: $0.id, typed: $0.typed, state: $0.state == .failed ? .failed : .uncertain, images: $0.images.count)
        }
    }

    static func bytes(_ records: [ThreadRecoveryRecord]) -> Int { records.reduce(0) { $0 + $1.typed.utf8.count } }

    /// What is kept with `capturing` added, or nil when that would pass the bounds: checked on
    /// the exact send the store is about to capture (`NativeThreadStore.captureAdmission`), so
    /// nothing is ever dropped to make room.
    static func admitting(_ capturing: NativeThreadSubmission, recovered: [ThreadRecoveryRecord],
                          submissions: [NativeThreadSubmission]) -> [ThreadRecoveryRecord]? {
        let kept = records(recovered: recovered, submissions: submissions + [capturing])
        return kept.count <= maximumRecords && bytes(kept) <= maximumBytes ? kept : nil
    }

    /// A forgotten host's records, every thread of it.
    static func forget(host: UUID, defaults: UserDefaults) {
        let prefixes = [prefix, asidePrefix].map { $0 + host.uuidString + "." }
        for key in defaults.dictionaryRepresentation().keys where prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
