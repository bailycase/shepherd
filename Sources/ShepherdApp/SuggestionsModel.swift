import Foundation
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions

/// Settings ▸ Experiments ▸ Suggested instructions on the Mac: the
/// experiment's settings and the lines this Mac's agents suggested, kept by the server's
/// `SuggestionsStore` (the background host's, as its client). Adding a line, or taking one back, changes This Mac's instructions, which
/// the host's sync then carries to every Mac in the fleet.
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

    @ObservationIgnored private let request: (RemoteSuggestionsRequest) async throws -> SuggestionsSnapshot
    @ObservationIgnored private let instructions: InstructionsModel

    /// `store`: a test's own file for This Mac while no host is connected; the app's is its host's.
    init(store: SuggestionsStore? = nil, instructions: InstructionsModel, remoteHosts: RemoteHostStore) {
        request = { request in
            if let host = try await remoteHosts.thisMacHost() { return try await host.suggestions(request) }
            guard let store else { throw BackgroundHostClient.HostStarting() }
            // The store's file work runs off the main actor.
            return try await Task.detached(priority: .userInitiated) { try Self.perform(request, on: store) }.value
        }
        self.instructions = instructions
    }

    /// `request` on this Mac's own store, as a host serves it.
    nonisolated private static func perform(_ request: RemoteSuggestionsRequest, on store: SuggestionsStore) throws -> SuggestionsSnapshot {
        switch request {
        case .fetch: store.snapshot()
        case .configure(let settings): try store.configure(settings)
        case .add(let id, let line, let file): try store.add(id, line: line, file: file)
        case .addAll: try store.addAll()
        case .dismiss(let id): try store.dismiss(id)
        case .undo(let id): try store.undo(id)
        }
    }

    var settings: SuggestedInstructionsSettings { snapshot.settings }

    /// Reads the suggestions afresh (the page opening).
    func refresh() async {
        if let snapshot = try? await request(.fetch) { adopt(snapshot) }
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
            self.adopt(try await self.request(.add(id: suggestion.id, line: line, file: file)))
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
            for (id, line, file) in waiting { self.adopt(try await self.request(.add(id: id, line: line, file: file))) }
            await self.instructionsChanged()
        }
    }

    /// Drops a waiting line; the same lesson is never suggested again.
    func dismiss(_ suggestion: InstructionSuggestion) async {
        await run {
            self.adopt(try await self.request(.dismiss(id: suggestion.id)))
        }
    }

    /// Takes an added line back out of its file.
    func undo(_ added: AddedSuggestion) async {
        await run {
            self.adopt(try await self.request(.undo(id: added.id)))
            await self.instructionsChanged()
        }
    }

    func dismissProblem() {
        problem = nil
    }

    // MARK: Private

    private func configure(_ settings: SuggestedInstructionsSettings) async {
        await run {
            self.adopt(try await self.request(.configure(settings)))
        }
    }

    /// Takes the store's snapshot, and forgets edits and targets of lines no longer waiting.
    private func adopt(_ snapshot: SuggestionsSnapshot) {
        self.snapshot = snapshot
        let waiting = Set(snapshot.waiting.map(\.id))
        edits = edits.filter { waiting.contains($0.key) }
        targets = targets.filter { waiting.contains($0.key) }
    }

    /// This Mac's files changed: the Instructions page follows (the host's sync carries them to every Mac).
    private func instructionsChanged() async {
        await instructions.localFilesChanged()
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
}
