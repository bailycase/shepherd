import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions

/// How a host keeps suggested instructions: what waits for the user, what the user added and can
/// take back, and what is never suggested again. The unit under test is the files.
@Suite("Suggestions store")
struct SuggestionsStoreTests {
    static let start = Date(timeIntervalSince1970: 1_000)
    static let thread = SuggestionSource(kind: .thread, name: "Fix flaky ledger test")

    struct Host {
        let dir: URL
        let instructions: InstructionsStore
        let suggestions: SuggestionsStore

        init() throws {
            dir = try makeTempDirectory()
            instructions = InstructionsStore(directory: dir)
            suggestions = SuggestionsStore(url: dir.appendingPathComponent("suggestions.json"), instructions: instructions)
        }

        func suggest(_ line: String, file: InstructionFile = .agents, at time: Double = 1_000) throws -> SuggestionOutcome {
            try suggestions.suggest(line: line, reason: "  It failed twice. ", file: file, source: SuggestionsStoreTests.thread,
                                    now: Date(timeIntervalSince1970: time)).outcome
        }
    }

    @Test func theExperimentIsOffUntilTurnedOn() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        #expect(host.suggestions.snapshot() == SuggestionsSnapshot())
        var settings = SuggestedInstructionsSettings(enabled: true)
        let on = try host.suggestions.configure(settings, now: Self.start)
        #expect(on.settings.since == 1_000)
        // Changing what it learns from keeps "on since".
        settings.sources = [.automation]
        #expect(try host.suggestions.configure(settings, now: Self.start.addingTimeInterval(60)).settings.since == 1_000)
    }

    @Test func aSuggestionWaitsAsAListItemNewestFirst() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        #expect(try host.suggest("Ask for join keys first.", at: 1_000) == .waiting)
        #expect(try host.suggest("- Never skip a flaky test.", at: 2_000) == .waiting)
        let waiting = host.suggestions.snapshot().waiting
        #expect(waiting.map(\.line) == ["- Never skip a flaky test.", "- Ask for join keys first."])
        #expect(waiting.first?.reason == "It failed twice.")
        #expect(waiting.first?.source == Self.thread)
        #expect(waiting.first?.suggestedAt == 2_000)
        // Nothing is written until the user adds it.
        #expect(host.instructions.snapshot().agents.isEmpty)
    }

    @Test func aLessonIsSuggestedOnce() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        try host.instructions.save(.agents, content: "- Prefer the standard library.\n")
        #expect(try host.suggest("prefer the standard library") == .inFile)
        #expect(try host.suggest("- Ask for join keys first.") == .waiting)
        #expect(try host.suggest("Ask for join keys first") == .alreadyWaiting)
        try host.suggestions.dismiss(try #require(host.suggestions.snapshot().waiting.first?.id))
        #expect(try host.suggest("- Ask for join keys first.") == .dismissed)
        #expect(host.suggestions.snapshot().waiting.isEmpty)
    }

    @Test func addingWritesTheLineToItsFileAndUndoTakesItBack() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        try host.instructions.save(.agents, content: "# How I work\n")
        _ = try host.suggest("Ask for join keys first.")
        let id = try #require(host.suggestions.snapshot().waiting.first?.id)
        let added = try host.suggestions.add(id, now: Self.start)
        #expect(host.instructions.snapshot().agents == "# How I work\n- Ask for join keys first.\n")
        #expect(host.instructions.snapshot().history.first?.origin == Self.thread.name)
        #expect(added.waiting.isEmpty)
        #expect(added.added == [AddedSuggestion(id: id, line: "- Ask for join keys first.", file: .agents,
                                                 sourceName: Self.thread.name, addedAt: 1_000)])
        let undone = try host.suggestions.undo(id)
        #expect(undone.added.isEmpty)
        #expect(host.instructions.snapshot().agents == "# How I work\n")
    }

    @Test func aLineCanBeEditedAndRetargetedFirst() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        _ = try host.suggest("Ask for join keys.")
        let id = try #require(host.suggestions.snapshot().waiting.first?.id)
        try host.suggestions.add(id, line: "Ask for join keys before adding an event.", file: .appendSystem)
        #expect(host.instructions.snapshot().agents.isEmpty)
        #expect(host.instructions.snapshot().appendSystem == "- Ask for join keys before adding an event.\n")
        #expect(host.suggestions.snapshot().added.first?.file == .appendSystem)
    }

    @Test func addAllWritesTheOldestFirst() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        _ = try host.suggest("First lesson.", at: 1_000)
        _ = try host.suggest("Second lesson.", at: 2_000)
        _ = try host.suggest("Rules win.", file: .appendSystem, at: 3_000)
        let snapshot = try host.suggestions.addAll(now: Self.start)
        #expect(snapshot.waiting.isEmpty)
        #expect(snapshot.added.count == 3)
        #expect(host.instructions.snapshot().agents == "- First lesson.\n- Second lesson.\n")
        #expect(host.instructions.snapshot().appendSystem == "- Rules win.\n")
    }

    @Test func turningTheExperimentOffDropsWhatWaitsAndKeepsWhatWasAdded() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        try host.suggestions.configure(SuggestedInstructionsSettings(enabled: true), now: Self.start)
        _ = try host.suggest("Kept.")
        try host.suggestions.add(try #require(host.suggestions.snapshot().waiting.first?.id))
        _ = try host.suggest("Dropped.")
        let off = try host.suggestions.configure(SuggestedInstructionsSettings(enabled: false))
        #expect(off.waiting.isEmpty)
        #expect(off.added.map(\.line) == ["- Kept."])
        #expect(off.settings.since == nil)
        #expect(host.instructions.snapshot().agents == "- Kept.\n")
    }

    @Test func undoingALineEditedAwayOnlyLeavesTheList() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        _ = try host.suggest("Ask for join keys first.")
        let id = try #require(host.suggestions.snapshot().waiting.first?.id)
        try host.suggestions.add(id)
        try host.instructions.save(.agents, content: "- Something else.\n")
        #expect(try host.suggestions.undo(id).added.isEmpty)
        #expect(host.instructions.snapshot().agents == "- Something else.\n")
    }

    @Test func aSuggestionNoLongerWaitingCantBeActedOn() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.add(UUID()) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.dismiss(UUID()) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.undo(UUID()) }
    }
}
