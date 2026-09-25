import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
import ShepherdSessions
import ShepherdTestKit
@testable import ShepherdApp

/// Settings ▸ Experiments ▸ Suggested instructions on the Mac: a line goes into its file as edited
/// and retargeted, and the Instructions page follows every change to This Mac's files.
@Suite("Suggestions model")
@MainActor
struct SuggestionsModelTests {
    let instructionsStore: InstructionsStore
    let store: SuggestionsStore
    let defaults = Fixture.defaults()

    init() throws {
        let directory = try makeScratchDirectory("suggestions")
        instructionsStore = InstructionsStore(directory: directory)
        store = SuggestionsStore(url: directory.appendingPathComponent("suggestions.json"), instructions: instructionsStore)
    }

    /// The page's two models, with `lines` waiting (the first one the newest).
    func makeModels(waiting lines: [String] = []) async throws -> (SuggestionsModel, InstructionsModel) {
        for (offset, line) in lines.reversed().enumerated() {
            _ = try store.suggest(line: line, reason: "It failed twice.", file: .agents,
                                  source: SuggestionSource(kind: .thread, name: "Ledger cleanup"),
                                  now: Date(timeIntervalSince1970: Double(1_000 + offset)))
        }
        let instructions = InstructionsModel(store: instructionsStore, remoteHosts: RemoteHostStore(defaults: defaults), defaults: defaults)
        await instructions.refresh()
        let model = SuggestionsModel(store: store, instructionsStore: instructionsStore, instructions: instructions)
        await model.refresh()
        return (model, instructions)
    }

    @Test func addingALineWritesItAndTheInstructionsPageFollows() async throws {
        let (model, instructions) = try await makeModels(waiting: ["Ask for join keys first."])
        let suggestion = try #require(model.snapshot.waiting.first)
        await model.add(suggestion)
        #expect(instructionsStore.snapshot().agents == "- Ask for join keys first.\n")
        #expect(instructions.saved(.agents, on: .local) == "- Ask for join keys first.\n")
        #expect(model.snapshot.waiting.isEmpty)
        #expect(model.snapshot.added.map(\.line) == ["- Ask for join keys first."])

        await model.undo(try #require(model.snapshot.added.first))
        #expect(instructionsStore.snapshot().agents.isEmpty)
        #expect(instructions.saved(.agents, on: .local) == "")
    }

    @Test func aLineGoesInAsEditedAndRetargeted() async throws {
        let (model, _) = try await makeModels(waiting: ["Ask for join keys."])
        let suggestion = try #require(model.snapshot.waiting.first)
        model.edit(suggestion)
        #expect(model.edits[suggestion.id] == "- Ask for join keys.")
        model.setEdit("- Ask for join keys before adding an event.", for: suggestion)
        model.retarget(suggestion, to: .appendSystem)
        #expect(model.file(for: suggestion) == .appendSystem)
        await model.add(suggestion)
        #expect(instructionsStore.snapshot().appendSystem == "- Ask for join keys before adding an event.\n")
        #expect(instructionsStore.snapshot().agents.isEmpty)
        // Nothing of the line lingers once it is added.
        #expect(model.edits.isEmpty && model.targets.isEmpty)
    }

    @Test func anEditOfMoreThanOneLineIsRefused() async throws {
        let (model, _) = try await makeModels(waiting: ["Ask for join keys."])
        let suggestion = try #require(model.snapshot.waiting.first)
        model.edit(suggestion)
        model.setEdit("- One.\n- Two.", for: suggestion)
        await model.add(suggestion)
        #expect(model.problem == "Suggest one line at a time.")
        #expect(instructionsStore.snapshot().agents.isEmpty)
        #expect(model.snapshot.waiting.count == 1)
    }

    @Test func addAllKeepsEachLinesEditAndOrder() async throws {
        let (model, _) = try await makeModels(waiting: ["Second lesson.", "First lesson."])
        let second = try #require(model.snapshot.waiting.first)
        model.edit(second)
        model.setEdit("- Second lesson, edited.", for: second)
        await model.addAll()
        #expect(instructionsStore.snapshot().agents == "- First lesson.\n- Second lesson, edited.\n")
        #expect(model.snapshot.waiting.isEmpty)
    }

    @Test func turningTheExperimentOffDropsWhatWaits() async throws {
        let (model, _) = try await makeModels()
        await model.setEnabled(true)
        #expect(model.settings.enabled && model.settings.since != nil)
        _ = try store.suggest(line: "Kept?", reason: "", file: .agents, source: SuggestionSource(kind: .thread, name: "a"))
        await model.refresh()
        #expect(model.snapshot.waiting.count == 1)
        await model.setLearns(from: .automation, false)
        #expect(model.settings.sources == [.thread])
        await model.setSuggests(for: .appendSystem, true)
        #expect(model.settings.files == [.agents, .appendSystem])
        await model.setEnabled(false)
        #expect(model.snapshot.waiting.isEmpty)
    }
}
