import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Settings ▸ Experiments ▸ Suggested instructions on the Mac (DESIGN.md › Experiments): the
/// experiment's settings and the lines this Mac's agents suggested, kept by the server's
/// `SuggestionsStore`. Adding a line, or taking one back, changes This Mac's instructions, which
/// `InstructionsModel` then sends to every host while Same on every host is on.
@MainActor
@Observable
final class SuggestionsModel {
    private(set) var snapshot = SuggestionsSnapshot()
    /// Lines edited before they are added, by suggestion.
    private(set) var edits: [UUID: String] = [:]
    /// The file a suggestion goes to when it was retargeted from its own.
    private(set) var targets: [UUID: InstructionFile] = [:]
    private(set) var busy = false
    /// What went wrong with the last change, in words.
    private(set) var problem: String?

    @ObservationIgnored private let store: SuggestionsStore
    @ObservationIgnored private let instructionsStore: InstructionsStore
    @ObservationIgnored private let instructions: InstructionsModel

    init(store: SuggestionsStore, instructionsStore: InstructionsStore, instructions: InstructionsModel) {
        self.store = store
        self.instructionsStore = instructionsStore
        self.instructions = instructions
    }

    var settings: SuggestedInstructionsSettings { snapshot.settings }

    /// Reads the suggestions afresh (the page opening).
    func refresh() async {
        if let snapshot = try? await detached({ $0.snapshot() }) { adopt(snapshot) }
    }

    /// An agent suggested a line, or a remote client acted on the suggestions.
    func serverChanged(_ snapshot: SuggestionsSnapshot) {
        adopt(snapshot)
    }

    // MARK: Settings

    func setEnabled(_ enabled: Bool) async {
        var settings = settings
        settings.enabled = enabled
        await configure(settings)
    }

    func setLearns(from kind: SuggestionSource.Kind, _ on: Bool) async {
        var settings = settings
        if on { settings.sources.insert(kind) } else { settings.sources.remove(kind) }
        await configure(settings)
    }

    func setSuggests(for file: InstructionFile, _ on: Bool) async {
        var settings = settings
        if on { settings.files.insert(file) } else { settings.files.remove(file) }
        await configure(settings)
    }

    // MARK: Lines

    /// The file a suggestion goes to: its own, unless it was retargeted.
    func file(for suggestion: InstructionSuggestion) -> InstructionFile {
        targets[suggestion.id] ?? suggestion.file
    }

    func retarget(_ suggestion: InstructionSuggestion, to file: InstructionFile) {
        targets[suggestion.id] = file == suggestion.file ? nil : file
    }

    func edit(_ suggestion: InstructionSuggestion) {
        edits[suggestion.id] = suggestion.line
    }

    func setEdit(_ line: String, for suggestion: InstructionSuggestion) {
        edits[suggestion.id] = line
    }

    func cancelEdit(_ suggestion: InstructionSuggestion) {
        edits[suggestion.id] = nil
    }

    /// Adds a waiting line to its file, as edited and retargeted.
    func add(_ suggestion: InstructionSuggestion) async {
        let line = edits[suggestion.id], file = targets[suggestion.id]
        if let line, let problem = InstructionsText.suggestionProblem(line) {
            self.problem = problem
            return
        }
        await run {
            let snapshot = try await self.detached { try $0.add(suggestion.id, line: line, file: file) }
            self.adopt(snapshot)
            await self.instructionsChanged()
        }
    }

    /// Adds every waiting line, oldest first, each as edited and retargeted.
    func addAll() async {
        let waiting = snapshot.waiting.reversed().map { ($0.id, edits[$0.id], targets[$0.id]) }
        if let problem = waiting.compactMap({ $0.1 }).lazy.compactMap(InstructionsText.suggestionProblem).first {
            self.problem = problem
            return
        }
        await run {
            let snapshot = try await self.detached { store in
                var snapshot = store.snapshot()
                for (id, line, file) in waiting { snapshot = try store.add(id, line: line, file: file) }
                return snapshot
            }
            self.adopt(snapshot)
            await self.instructionsChanged()
        }
    }

    /// Drops a waiting line; the same lesson is never suggested again.
    func dismiss(_ suggestion: InstructionSuggestion) async {
        await run {
            let snapshot = try await self.detached { try $0.dismiss(suggestion.id) }
            self.adopt(snapshot)
        }
    }

    /// Takes an added line back out of its file.
    func undo(_ added: AddedSuggestion) async {
        await run {
            let snapshot = try await self.detached { try $0.undo(added.id) }
            self.adopt(snapshot)
            await self.instructionsChanged()
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private func configure(_ settings: SuggestedInstructionsSettings) async {
        await run {
            let snapshot = try await self.detached { try $0.configure(settings) }
            self.adopt(snapshot)
        }
    }

    /// Takes the store's snapshot, and forgets edits and targets of lines no longer waiting.
    private func adopt(_ snapshot: SuggestionsSnapshot) {
        self.snapshot = snapshot
        let waiting = Set(snapshot.waiting.map(\.id))
        edits = edits.filter { waiting.contains($0.key) }
        targets = targets.filter { waiting.contains($0.key) }
    }

    /// This Mac's files changed: the Instructions page follows, and with Same on every host on
    /// so does every host.
    private func instructionsChanged() async {
        let store = instructionsStore
        let snapshot = await Task.detached(priority: .userInitiated) { store.snapshot() }.value
        instructions.localChanged(snapshot)
    }

    private func run(_ body: @escaping () async throws -> Void) async {
        busy = true
        problem = nil
        defer { busy = false }
        do {
            try await body()
        } catch let failure as SuggestionsStore.StoreError {
            problem = failure.description
        } catch let failure as InstructionsStore.StoreError {
            problem = failure.description
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The store's file work runs off the main actor.
    private func detached<T: Sendable>(_ work: @escaping @Sendable (SuggestionsStore) throws -> T) async throws -> T {
        let store = store
        return try await Task.detached(priority: .userInitiated) { try work(store) }.value
    }
}
