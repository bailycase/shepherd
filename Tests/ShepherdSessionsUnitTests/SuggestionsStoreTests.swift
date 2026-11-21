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
        #expect(try host.suggestions.snapshot() == SuggestionsSnapshot())
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
        let waiting = try host.suggestions.snapshot().waiting
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
        #expect(try host.suggestions.snapshot().waiting.isEmpty)
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

    @Test(arguments: ["add", "retarget", "addAll"])
    func addingAnExistingLessonNeverOffersToUndoUserContent(action: String) throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        _ = try host.suggest("Ask for join keys first.")
        let id = try #require(host.suggestions.snapshot().waiting.first?.id)
        let file: InstructionFile = action == "retarget" ? .appendSystem : .agents
        let original = "# My instructions\n- ASK for join keys first\n"
        try host.instructions.save(file, content: original)
        let before = host.instructions.snapshot()
        let added = try action == "addAll" ? host.suggestions.addAll() : host.suggestions.add(id, file: file)
        #expect(added.waiting.isEmpty)
        #expect(added.added.isEmpty)
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.undo(id) }
        #expect(host.instructions.snapshot() == before)
        #expect(host.instructions.snapshot()[file] == original)
    }

    @Test func aLineCanBeEditedAndRetargetedFirst() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        _ = try host.suggest("Ask for join keys.")
        let id = try #require(host.suggestions.snapshot().waiting.first?.id)
        try host.suggestions.add(id, line: "Ask for join keys before adding an event.", file: .appendSystem)
        #expect(host.instructions.snapshot().agents.isEmpty)
        #expect(host.instructions.snapshot().appendSystem == "- Ask for join keys before adding an event.\n")
        #expect(try host.suggestions.snapshot().added.first?.file == .appendSystem)
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

    @Test(arguments: [
        "{truncated",
        #"{"version":1,"settings":{"enabled":false,"files":["AGENTS.md"],"sources":["thread"]},"waiting":[{}],"added":[],"dismissed":[]}"#,
        #"{"version":2,"settings":{"enabled":false,"files":["AGENTS.md"],"sources":["thread"]},"waiting":[],"added":[],"dismissed":[]}"#,
        #"{"version":2,"value":{"version":1,"settings":{"enabled":false,"files":["AGENTS.md"],"sources":["thread"]},"waiting":[],"added":[],"dismissed":[]}}"#,
    ])
    func damageRefusesEveryMutationAndPreservesTheFile(json: String) throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        let store = host.suggestions
        _ = try host.suggest("Prefer explicit joins.")
        let added = try #require(store.snapshot().waiting.first?.id)
        try store.add(added)
        _ = try host.suggest("Add fixtures for exports.")
        let waiting = try #require(store.snapshot().waiting.first?.id)
        let instructions = host.instructions.snapshot()
        let bytes = Data(json.utf8)
        try bytes.write(to: store.url)
        let refusal = SuggestionsStore.StoreError.damaged(store.url)

        #expect(throws: refusal) { try store.snapshot() }
        #expect(throws: refusal) { try store.configure(.init(enabled: true)) }
        #expect(throws: refusal) { try host.suggest("Document export columns.") }
        #expect(throws: refusal) { try store.add(waiting) }
        #expect(throws: refusal) { try store.addAll() }
        #expect(throws: refusal) { try store.dismiss(waiting) }
        #expect(throws: refusal) { try store.undo(added) }
        #expect(try Data(contentsOf: store.url) == bytes)
        #expect(host.instructions.snapshot() == instructions)
    }

    @Test func aHealthyFileRewrittenAsUTF16IsDamagedNotRewritten() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        let store = host.suggestions
        _ = try host.suggest("Prefer explicit joins.")
        let utf16 = try #require(String(decoding: Data(contentsOf: store.url), as: UTF8.self).data(using: .utf16))
        try utf16.write(to: store.url)
        let refusal = SuggestionsStore.StoreError.damaged(store.url)
        #expect(throws: refusal) { try store.snapshot() }
        #expect(throws: refusal) { try store.configure(.init(enabled: true)) }
        #expect(try Data(contentsOf: store.url) == utf16)
    }

    @Test func aV1EnvelopeReadsButWritesTheLegacyShape() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        let store = host.suggestions
        let input = #"{"value":{"dismissed":["prefer explicit joins"],"waiting":[],"added":[],"settings":{"files":["AGENTS.md"],"since":null,"sources":["thread"],"enabled":true},"version":1},"version":1}"#
        try Data(input.utf8).write(to: store.url)
        let snapshot = try store.snapshot()
        #expect(snapshot.settings.enabled)
        #expect(snapshot.settings.since == nil)
        #expect(try host.suggest("Prefer explicit joins.") == .dismissed)
        try store.configure(snapshot.settings, now: Self.start)

        struct LegacyFile: Decodable {
            let version: Int
            let settings: SuggestedInstructionsSettings
            let dismissed: [String]
        }
        let disk = try JSONDecoder().decode(LegacyFile.self, from: Data(contentsOf: store.url))
        #expect(disk.version == 1)
        #expect(disk.settings.since == 1_000)
        #expect(disk.dismissed == ["prefer explicit joins"])
    }

    @Test func aDanglingLinkIsNotMissingButMovingItAllowsWrites() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        let store = host.suggestions
        let destination = host.dir.appendingPathComponent("acme-missing.json")
        let moved = host.dir.appendingPathComponent("acme-backup.json")
        try FileManager.default.createSymbolicLink(at: store.url, withDestinationURL: destination)
        #expect(throws: SuggestionsStore.StoreError.damaged(store.url)) { try store.snapshot() }
        #expect(throws: SuggestionsStore.StoreError.damaged(store.url)) { try store.configure(.init(enabled: true)) }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: store.url.path) == destination.path)

        try FileManager.default.moveItem(at: store.url, to: moved)
        #expect(try store.snapshot() == SuggestionsSnapshot())
        #expect(try store.configure(.init(enabled: true)).settings.enabled)
        #expect(try store.snapshot().settings.enabled)
    }

    @Test func aSuggestionNoLongerWaitingCantBeActedOn() throws {
        let host = try Host()
        defer { try? FileManager.default.removeItem(at: host.dir) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.add(UUID()) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.dismiss(UUID()) }
        #expect(throws: SuggestionsStore.StoreError.noSuchSuggestion) { try host.suggestions.undo(UUID()) }
    }
}
