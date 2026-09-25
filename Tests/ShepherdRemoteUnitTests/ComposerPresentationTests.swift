import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// What a touch composer and thread header draw: the meta line, Up next rows, slash matches,
/// model choices, thinking levels and question options.
@Suite("Composer presentation")
struct ComposerPresentationTests {
    private static let a = UUID(uuidString: "00000000-0000-4000-8000-00000000000A")!
    private static let b = UUID(uuidString: "00000000-0000-4000-8000-00000000000B")!
    private static let c = UUID(uuidString: "00000000-0000-4000-8000-00000000000C")!

    private func message(_ id: UUID, _ text: String, state: NativeQueuedMessage.State = .queued, images: [String?] = []) -> NativeQueuedMessage {
        NativeQueuedMessage(id: id, text: text, images: images.map { NativeQueuedImage(mimeType: "image/png", name: $0) }, sentAt: 0,
                            state: state)
    }

    // MARK: Header

    @Test func theMetaCountsTurnsAndContextAtRest() {
        let meta = NativeThreadMeta(turns: 17, contextTokens: 42_300, runningSince: nil, now: 0)
        #expect(meta.compact == ["17 turns", "42k"])
        #expect(meta.counters == ["17 turns", "42k ctx"])
        #expect(meta.elapsed == nil)
    }

    @Test func aRunningTurnShowsItsElapsedTimeInPlaceOfTheCounts() {
        let meta = NativeThreadMeta(turns: 3, contextTokens: 1_000, runningSince: 10_000, now: 31_000)
        #expect(meta.compact == ["21s"])
        #expect(meta.counters == ["3 turns", "1k ctx"])
    }

    @Test func unknownCountsAreLeftOut() {
        let meta = NativeThreadMeta(turns: nil, contextTokens: 0, runningSince: nil, now: 0)
        #expect(meta.compact.isEmpty)
        #expect(meta.counters.isEmpty)
        #expect(NativeThreadMeta(turns: 1, contextTokens: nil, runningSince: nil, now: 0).compact == ["1 turn"])
    }

    // MARK: Up next

    @Test func steeringRowsComeFirstAndQueuedRowsAreNumberedInOrder() {
        let rows = NativeQueueStack.rows([message(Self.a, "Don't touch the migrations", state: .steering),
                                          message(Self.b, "Also cover partial refunds"),
                                          message(Self.c, "Then open a draft PR", images: [nil, "shot.png"])])
        #expect(rows.map(\.kind) == [.steering, .queued(number: 1), .queued(number: 2)])
        #expect(rows.map(\.message) == [Self.a, Self.b, Self.c])
        #expect(rows[2].images == ["Image", "shot.png"])
        #expect(rows.map(\.canMoveToTop) == [false, false, true])
    }

    @Test func anUndoRowStandsWhereItsMessageWas() {
        let deleted = message(Self.b, "Deleted one")
        let undo = NativeQueueUndo(messages: [deleted], index: 1, cleared: false)
        let rows = NativeQueueStack.rows([message(Self.a, "first"), message(Self.c, "third")], undo: [undo])
        #expect(rows.map(\.kind) == [.queued(number: 1), .deleted, .queued(number: 2)])
        #expect(rows[1].text == "Deleted one")
        #expect(rows[1].id == Self.b.uuidString)
    }

    @Test func anUndoWhoseMessagesAreBackIsDropped() {
        let undo = NativeQueueUndo(messages: [message(Self.a, "back")], index: 0, cleared: false)
        #expect(NativeQueueStack.rows([message(Self.a, "back")], undo: [undo]).map(\.kind) == [.queued(number: 1)])
    }

    @Test func aClearedQueueLeavesOneUndoRowAfterTheSteeringOnes() {
        let undo = NativeQueueUndo(messages: [message(Self.b, "x"), message(Self.c, "y")], index: 0, cleared: true)
        let rows = NativeQueueStack.rows([message(Self.a, "steer", state: .steering)], undo: [undo])
        #expect(rows.map(\.kind) == [.steering, .cleared(count: 2)])
    }

    @Test(arguments: [(true, "Steer now"), (false, "Send now")])
    func aRowSteersWhilePiWorksAndSendsWhileItIsIdle(running: Bool, label: String) {
        #expect(NativeQueueStack.steerLabel(running: running) == label)
    }

    // MARK: Slash commands

    private let commands = [
        NativeCommand(name: "review", description: "Open the review pane", source: "extension"),
        NativeCommand(name: "resume", description: "Pick a previous session"),
        NativeCommand(name: "release-notes", description: "Draft release notes", source: "prompt"),
        NativeCommand(name: "prerelease", source: "skill"),
        NativeCommand(name: "compact"),
    ]

    @Test(arguments: [
        ("/", ["review", "resume", "release-notes", "prerelease", "compact"]),
        ("/re", ["review", "resume", "release-notes", "prerelease"]),
        ("/REL", ["release-notes", "prerelease"]),
        ("/zzz", []),
    ])
    func aSlashDraftMatchesPrefixesFirstThenContainedNames(draft: String, names: [String]) throws {
        let matches = try #require(NativeSlashMatches(draft: draft, commands: commands))
        #expect(matches.commands.map(\.name) == names)
        #expect(matches.total == 5)
    }

    @Test(arguments: ["", "review", "/review now", "/re\nx", " /re"])
    func onlyASlashWordStillBeingTypedOpensTheList(draft: String) {
        #expect(NativeSlashMatches(draft: draft, commands: commands) == nil)
    }

    @Test func noCommandsMeansNoList() {
        #expect(NativeSlashMatches(draft: "/", commands: []) == nil)
    }

    @Test func choosingACommandLeavesItsNameAndASpace() {
        #expect(NativeSlashMatches.completion(commands[0]) == "/review ")
        #expect(commands.map(NativeSlashMatches.tag) == [nil, nil, "prompt", "skill", nil])
    }

    // MARK: Model and thinking

    @Test func modelsGroupByProviderInTheHostsOrder() {
        let sections = NativeModelChoices.sections(["anthropic/claude-opus", "openai/gpt-5", "anthropic/claude-sonnet"],
                                                   current: "anthropic/claude-sonnet")
        #expect(sections.map(\.title) == ["anthropic", "openai"])
        #expect(sections[0].models.map(\.title) == ["claude-opus", "claude-sonnet"])
        #expect(sections[0].models.map(\.isCurrent) == [false, true])
    }

    @Test func theCurrentModelIsListedEvenWhenTheCatalogLacksIt() {
        let sections = NativeModelChoices.sections(["openai/gpt-5"], current: "local/llama")
        #expect(sections.map(\.title) == ["local", "openai"])
        #expect(sections[0].models.first?.isCurrent == true)
    }

    @Test func aQueryFiltersByAnyPartOfTheID() {
        let sections = NativeModelChoices.sections(["anthropic/claude-opus", "openai/gpt-5", "openai/o3"], current: nil, query: " GPT ")
        #expect(sections.flatMap(\.models).map(\.id) == ["openai/gpt-5"])
        #expect(NativeModelChoices.shortName("model") == "model")
        #expect(NativeModelChoices.provider("model") == "Other")
    }

    @Test(arguments: [("medium", "Medium"), ("off", "Off"), ("xhigh", "Xhigh")])
    func thinkingLevelsReadAsTheirTitles(level: String, title: String) {
        #expect(NativeThinkingLevel.title(level) == title)
    }

    /// The thinking chip goes with a level pi can set, unless the host says the thread's model
    /// takes none; before the catalog arrives, or from an older host, it stays.
    @Test(arguments: [
        ("off", ["setThinking"], "qa/plain", true, false),
        ("medium", ["setThinking"], "qa/deep", true, true),
        ("medium", ["setThinking"], "qa/plain", false, true),
        ("medium", ["setThinking"], nil, true, true),
        (nil, ["setThinking"], "qa/deep", true, false),
        ("medium", [], "qa/deep", true, false),
    ] as [(String?, Set<String>, String?, Bool, Bool)])
    func theThinkingChipGoesOnlyWithAModelThatTakesALevel(thinking: String?, actions: Set<String>, model: String?,
                                                          catalogLoaded: Bool, offered: Bool) {
        let listing = ModelListing(models: ["qa/plain", "qa/deep"], defaultModel: "qa/plain", withoutThinking: ["qa/plain"])
        #expect(NativeThinkingLevel.offered(thinking: thinking, supportedActions: actions, model: model,
                                            listing: catalogLoaded ? listing : nil) == offered)
    }

    // MARK: Questions

    @Test func optionsAreNumberedAndKeepTheValueAsOffered() {
        let dialog = NativeThreadDialog(id: "d", kind: .select, title: "Where?", options: [
            "Compare, keep what's unique (Recommended)\nNew branch and PR for anything not merged.",
            "Leave Horizon alone",
            "Deploy — recommended",
        ])
        let options = NativeQuestionOption.options(dialog)
        #expect(options.map(\.number) == [1, 2, 3])
        #expect(options[0].title == "Compare, keep what's unique")
        #expect(options[0].detail == "New branch and PR for anything not merged.")
        #expect(options[0].recommended)
        #expect(options[0].value == dialog.options?[0])
        #expect(options[1].recommended == false)
        #expect(options[1].detail == nil)
        // Only the asker's own "(Recommended)" marks one.
        #expect(options[2].recommended == false)
        #expect(options[2].title == "Deploy — recommended")
    }
}
