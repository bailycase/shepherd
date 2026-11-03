import AppKit
import Foundation
import ShepherdRemote

/// Unsent composer drafts, kept across relaunches: one defaults entry of agent id → text, written
/// a moment after typing stops, and dropped when a draft is sent or emptied. Switching agents
/// already keeps a draft (the deck keeps its store); this keeps it through quit, crash and update.
///
/// A send's words leave the draft when the store captures them; until the host accepts them they
/// are kept here too, as recovery records (`NativeRecoveredSubmission`, text only), written at once
/// and before the emptied draft is. After a relaunch they come back as of unknown outcome, beside
/// whatever draft was typed since, and are never sent again on their own.
@MainActor
final class ComposerDrafts {
    static let key = "shepherd.composerDrafts"
    static let recoveriesKey = "shepherd.composerRecoveries"
    /// Typing writes nothing; the pause after it does.
    static let delay: Duration = .milliseconds(500)
    /// A draft past this is a document, not a message: it is not kept.
    static let maxLength = 64 * 1024

    private let defaults: UserDefaults
    private var drafts: [String: String]
    private var recoveries: [String: [NativeRecoveredSubmission]]
    /// The saved records as they were, when some could not be taken in (unreadable, repeated ids, past the budget).
    private let quarantine: Data?
    static let quarantineKey = "shepherd.composerRecoveries.quarantine"
    private var pending: Task<Void, Never>?
    /// Told after each defaults write (tests check that no single write leaves the words nowhere).
    var onWrite: (() -> Void)?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
        let loaded = Self.load(defaults.data(forKey: Self.recoveriesKey))
        recoveries = loaded.0
        quarantine = loaded.1
        // What could not be taken in whole is kept as it was, beside the records, never truncated away.
        if let quarantine, defaults.data(forKey: Self.quarantineKey) == nil { defaults.set(quarantine, forKey: Self.quarantineKey) }
        // A quit does not wait for the pause.
        NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.flush() }
        }
    }

    /// What `id` had typed when the app last ran, if anything.
    func restore(_ id: String) -> String? { drafts[id] }

    /// The draft as it is now; written after `delay`.
    func note(_ id: String, draft: String) {
        if draft.isEmpty || draft.count > Self.maxLength { drafts.removeValue(forKey: id) } else { drafts[id] = draft }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.delay)
            guard !Task.isCancelled else { return }
            self?.flush()
        }
    }

    /// The saved records, each agent's within the store's own bounds (`NativeThreadStore.maximumRetainedSubmissions`
    /// and bytes, one record per id, first kept). The whole saved value is returned for quarantine when anything was
    /// left out or it could not be read.
    static func load(_ data: Data?) -> ([String: [NativeRecoveredSubmission]], Data?) {
        guard let data else { return ([:], nil) }
        guard let decoded = try? JSONDecoder().decode([String: [NativeRecoveredSubmission]].self, from: data) else { return ([:], data) }
        var kept: [String: [NativeRecoveredSubmission]] = [:]
        var dropped = false
        for (id, records) in decoded {
            var seen = Set<UUID>(), bytes = 0, list: [NativeRecoveredSubmission] = []
            for record in records {
                let cost = record.typed.utf8.count + 128
                guard !seen.contains(record.id), list.count < NativeThreadStore.maximumRetainedSubmissions,
                      bytes + cost <= NativeThreadStore.maximumRetainedSubmissionBytes else { dropped = true; continue }
                seen.insert(record.id)
                bytes += cost
                list.append(record)
            }
            if !list.isEmpty { kept[id] = list }
        }
        return (kept, dropped ? data : nil)
    }

    /// The sends `id` had captured but not seen accepted when the app last ran.
    func recovered(_ id: String) -> [NativeRecoveredSubmission] { recoveries[id] ?? [] }

    /// `id`'s captured sends now, written at once. A new record whose words are the saved draft
    /// takes them out of the draft (they are kept once, as the record).
    /// Ordered so no single write loses the words: a capture writes its record before the draft without
    /// them; a record leaving (restored into the draft, accepted, discarded) writes the draft first.
    func saveRecoveries(_ id: String, _ records: [NativeRecoveredSubmission]) {
        let known = Set(recoveries[id]?.map(\.id) ?? [])
        let captured = records.contains { !known.contains($0.id) }
        for record in records where !known.contains(record.id) && drafts[id] == record.typed { drafts.removeValue(forKey: id) }
        if records.isEmpty { recoveries.removeValue(forKey: id) } else { recoveries[id] = records }
        flush(recordsFirst: captured)
    }

    /// Writes now. `recordsFirst` writes the recovery records before the drafts (a capture); otherwise the
    /// drafts go first (words restored into a draft are saved before their record is dropped).
    /// UserDefaults order, not a durability guarantee: the system persists defaults on its own schedule.
    func flush(recordsFirst: Bool = true) {
        pending?.cancel()
        pending = nil
        func writeRecords() {
            if recoveries.isEmpty { defaults.removeObject(forKey: Self.recoveriesKey) }
            else if let data = try? JSONEncoder().encode(recoveries) { defaults.set(data, forKey: Self.recoveriesKey) }
            onWrite?()
        }
        func writeDrafts() {
            if drafts.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(drafts, forKey: Self.key) }
            onWrite?()
        }
        if recordsFirst { writeRecords(); writeDrafts() } else { writeDrafts(); writeRecords() }
    }
}
