import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The preferences the host owns, as the host keeps them (`HostSettingsStore`). Not the wire reply:
/// `HostSettings` is built per request from these and live facts (listener, versions, extensions).
///
/// Each field is declared once, with its default as the property's initial value. A file that lacks a
/// field (an older release's, or a group not moved here yet) reads that field as its default
/// (`decode`). Groups move here one at a time; `agents`, `worktrees` and `experiments` have so far.
public struct StoredHostPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version = currentVersion
    public var agents = Agents()
    public var worktrees = Worktrees()
    public var experiments = Experiments()

    public init() {}

    /// Settings ▸ Agents: the `shepherd.agent.*` keys of the preferences domain. The host keeps them in
    /// its file and, for the previous release to read, in those keys.
    public struct Agents: Codable, Equatable, Sendable {
        /// Empty means "whatever pi picks".
        public var defaultModel = ""
        public var defaultThinking = ThinkingLevel.medium
        public var defaultServiceTier = ServiceTier.standard
        public var textGenerationModel = ""
        public var visionModel = ""
        public var queueDelivery = NativeQueueMode.all
        public var trimToolOutput = true
        public var notifyOnTurnFinished = true
        public var deferTools = true
        public var threadsStartThreads = false
        public var subThreadPlace = SpawnPlace.checkout
        public var codemode = true
        /// nil is pi's own default.
        public var compactAtPercent: Int?

        public init() {}
    }

    /// Settings ▸ Worktrees (the page labelled Git): the `shepherd.worktree.*` keys, kept in the file and the keys like Agents.
    public struct Worktrees: Codable, Equatable, Sendable {
        public var baseMode = WorktreeBaseMode.fresh
        public var fetchBeforeCreate = true
        public var generatePRDescription = true
        public var closeOnMerge = false
        public var deleteAction = HostSettings.WorktreeDeleteAction.ask

        public init() {}
    }

    /// Settings ▸ Experiments: the `shepherd.experiments.*` keys, kept in the file and the keys like Agents. All off by default.
    public struct Experiments: Codable, Equatable, Sendable {
        public var goals = false
        public var projects = false
        public var designTool = false
        public var computerUse = false

        public init() {}
    }

    /// Reads a file written by any release: what it lacks, at any depth, is this type's default.
    public static func decode(_ data: Data) throws -> StoredHostPreferences {
        let defaults = try JSONSerialization.jsonObject(with: JSONEncoder().encode(StoredHostPreferences()))
        let stored = try JSONSerialization.jsonObject(with: data)
        return try JSONDecoder().decode(StoredHostPreferences.self, from: JSONSerialization.data(withJSONObject: overlay(stored, on: defaults)))
    }

    private static func overlay(_ top: Any, on base: Any) -> Any {
        guard let top = top as? [String: Any], let base = base as? [String: Any] else { return top }
        return base.merging(top) { overlay($1, on: $0) }
    }
}

/// The host's preferences in one file (`host-preferences.json` beside `state.json`). Every change
/// reaches the file here; the caller also writes the old UserDefaults key the previous release reads
/// (`AppSettings`), and while that release can still run, those keys win at the host's start: the file
/// is rebuilt from them (`AppSettings.adoptHostPreferences`), so a change the old release made in
/// between is not lost. A file that cannot be read starts from defaults and is written over, for the same reason,
/// and a write that fails is tried again at the next `update`, changed or not.
public final class HostSettingsStore: @unchecked Sendable {
    private let file: URL
    private let lock = NSLock()
    private var stored: StoredHostPreferences
    /// Whether the file holds `stored`, or at least a copy this release can read. False until a write succeeds
    /// when the file was missing or unreadable.
    private var fileIsCurrent: Bool

    public init(file: URL) {
        self.file = file
        let read = (try? Data(contentsOf: file)).flatMap { try? StoredHostPreferences.decode($0) }
        stored = read ?? StoredHostPreferences()
        fileIsCurrent = read != nil
    }

    public var preferences: StoredHostPreferences { lock.withLock { stored } }

    /// Changes the preferences and writes the file, when something changed or the file is not current.
    public func update(_ change: (inout StoredHostPreferences) -> Void) {
        lock.withLock {
            var next = stored
            change(&next)
            next.version = StoredHostPreferences.currentVersion
            guard next != stored || !fileIsCurrent else { return }
            stored = next
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            do {
                try encoder.encode(next).write(to: file, options: .atomic)
                fileIsCurrent = true
            } catch {
                fileIsCurrent = false
                ShepherdLog.warning("Host preferences could not be saved: \(error)")
            }
        }
    }
}
