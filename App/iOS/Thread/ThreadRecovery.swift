import Foundation
import ShepherdCore
import ShepherdRemote

/// A send this device kept because it did not go through, saved so a quit or crash does not
/// lose it: its text only (never image bytes or anything else it carried), how many images went
/// with it, and whether the host refused it or its outcome is unknown.
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

    /// Tolerant: a record from another version without `images` counts none, and a state it
    /// does not know is unknown (never restorable).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        typed = try c.decode(String.self, forKey: .typed)
        state = (try? c.decode(State.self, forKey: .state)) ?? .uncertain
        images = (try? c.decodeIfPresent(Int.self, forKey: .images)) ?? 0
    }
}

/// Where a thread's unresolved sends are kept between launches (`ThreadStores` saves them as the
/// store's submissions change), apart from its draft (`NativeDraftKey`), so new typing never
/// overwrites them nor they it. The store keeps submissions in memory only and clears the
/// composer when it captures one; without this a quit before the host answered lost the text.
enum ThreadRecovery {
    /// The same bounds as the store's own records.
    static let maximumRecords = NativeThreadStore.maximumRetainedSubmissions
    static let maximumBytes = NativeThreadStore.maximumRetainedSubmissionBytes
    static let prefix = "shepherd.ios.recovery."

    static func key(_ ref: AgentRef) -> String { prefix + ref.host.uuidString + "." + ref.agent.rawValue }

    /// The records an earlier launch saved; a value that does not decode is dropped.
    static func load(_ ref: AgentRef, defaults: UserDefaults) -> [ThreadRecoveryRecord] {
        guard let data = defaults.data(forKey: key(ref)) else { return [] }
        guard let records = try? JSONDecoder().decode([ThreadRecoveryRecord].self, from: data) else {
            defaults.removeObject(forKey: key(ref))
            return []
        }
        return records
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

    /// Whether one more send of `typed` may be captured with these already kept: refused here,
    /// before the store takes it out of the composer, so nothing is ever dropped to make room.
    static func admits(_ typed: String, recovered: [ThreadRecoveryRecord], submissions: [NativeThreadSubmission]) -> Bool {
        let kept = records(recovered: recovered, submissions: submissions)
        return kept.count < maximumRecords && bytes(kept) + typed.utf8.count <= maximumBytes
    }

    /// A forgotten host's records, every thread of it.
    static func forget(host: UUID, defaults: UserDefaults) {
        let hostPrefix = prefix + host.uuidString + "."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(hostPrefix) { defaults.removeObject(forKey: key) }
    }
}
