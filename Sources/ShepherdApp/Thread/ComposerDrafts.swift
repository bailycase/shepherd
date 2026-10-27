import AppKit
import Foundation

/// Unsent composer drafts, kept across relaunches: one defaults entry of agent id → text, written
/// a moment after typing stops, and dropped when a draft is sent or emptied. Switching agents
/// already keeps a draft (the deck keeps its store); this keeps it through quit, crash and update.
@MainActor
final class ComposerDrafts {
    static let key = "shepherd.composerDrafts"
    /// Typing writes nothing; the pause after it does.
    static let delay: Duration = .milliseconds(500)
    /// A draft past this is a document, not a message: it is not kept.
    static let maxLength = 64 * 1024

    private let defaults: UserDefaults
    private var drafts: [String: String]
    private var pending: Task<Void, Never>?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        drafts = defaults.dictionary(forKey: Self.key) as? [String: String] ?? [:]
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

    /// Writes now.
    func flush() {
        pending?.cancel()
        pending = nil
        if drafts.isEmpty { defaults.removeObject(forKey: Self.key) } else { defaults.set(drafts, forKey: Self.key) }
    }
}
