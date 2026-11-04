import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdSessions
@testable import ShepherdApp

/// Settings › Hooks' rows and the composer's hook glyph, from a catalog snapshot (no files read).
@MainActor
struct HooksModelTests {
    static let home = "/Users/sam"
    static let space = "/Users/sam/code/payments"

    static func entry(_ file: String, scope: HookScope, event: String, matcher: String = "", command: String,
                      index: Int = 0, on: Bool = true) -> HookEntry {
        let handler = HookHandler.command(command)
        let canonical = handler.raw.canonical
        return HookEntry(slot: HookCanonical.slot(file: file, event: event, group: index, handler: 0), scope: scope, file: file, format: .shepherd,
                         event: event, matcher: matcher, groupIndex: index, handlerIndex: 0, handler: handler,
                         hash: HookCanonical.hash(file: file, event: event, matcher: matcher, canonical: canonical), canonical: canonical,
                         editable: true, on: on)
    }

    static var snapshot: HookCatalogSnapshot {
        let mac = home + "/.shepherd/hooks.json", spaceFile = space + "/.shepherd/hooks.json", claude = space + "/.claude/settings.json"
        return HookCatalogSnapshot(
            sources: [
                HookSource(path: mac, scope: .mac, format: .shepherd, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: home + "/.claude/settings.json", scope: .mac, format: .claude, isTOML: false, state: .readerOff),
                HookSource(path: home + "/.codex/hooks.json", scope: .mac, format: .codex, isTOML: false, state: .notFound),
                HookSource(path: spaceFile, scope: .space(root: space), format: .shepherd, isTOML: false, state: .loaded(count: 2)),
                HookSource(path: claude, scope: .space(root: space), format: .claude, isTOML: false, state: .unreadable(line: 14, message: "expected “,”")),
                HookSource(path: "/Users/sam/code/ledger/.claude/settings.json", scope: .space(root: "/Users/sam/code/ledger"), format: .claude, isTOML: false, state: .loaded(count: 0)),
            ],
            entries: [
                entry(mac, scope: .mac, event: "PreToolUse", matcher: "Bash", command: "~/.shepherd/hooks/confirm-rm.sh"),
                entry(spaceFile, scope: .space(root: space), event: "PostToolUse", matcher: "Edit|Write", command: "npx prettier --write"),
                entry(spaceFile, scope: .space(root: space), event: "Stop", command: "npm test --silent", index: 1, on: false),
            ],
            settings: HookSettings())
    }

    @Test func theGlyphCountsThisMacAndTheThreadsSpaceAndNothingElse() {
        let model = HooksModel(home: Self.home, support: URL(fileURLWithPath: "/nonexistent-support"))
        model.apply(Self.snapshot, roots: ["/Users/sam/code/payments/src": Self.space, "/Users/sam/code/ledger": "/Users/sam/code/ledger"])
        let inSpace = model.indicator(forCwd: "/Users/sam/code/payments/src")
        #expect(inSpace == HookIndicator(HookSummary(running: 2), spaceRoot: Self.space))
        #expect(inSpace?.help == "2 hooks run in this space", "the off one doesn't count")
        #expect(model.indicator(forCwd: "/Users/sam/code/ledger")?.help == "1 hook runs in this space", "This Mac's hook runs everywhere")
        #expect(model.indicator(forCwd: "/elsewhere") == nil)
        #expect(HookIndicator(HookSummary(running: 0), spaceRoot: nil) == nil, "no hooks, no glyph")
    }

    @Test func rowsGroupByEventWithSourcesAndSwitches() {
        let model = HooksModel(home: Self.home, support: URL(fileURLWithPath: "/nonexistent-support"))
        model.apply(Self.snapshot)
        #expect(model.rail.map(\.label) == ["All hooks", "Before a tool runs", "After a tool runs", "When the agent finishes"])
        #expect(model.rail.map(\.count) == [3, 1, 1, 1] && model.emptyEvents == 9)
        let rows = model.groups.flatMap(\.rows)
        #expect(rows.map(\.source) == ["This Mac · ~/.shepherd/hooks.json", "payments · .shepherd/hooks.json", "payments · .shepherd/hooks.json"])
        #expect(rows.map(\.locked) == [false, false, false] && rows.map(\.on) == [true, true, false])
        #expect(rows[2].matcher == "always" && rows[2].matcherIsAny && rows[0].matcher == "Bash")
        model.filter = "Stop"
        #expect(model.groups.map(\.event) == ["Stop"])
    }

    @Test func sourcesSayEachFilesStateAndOfferItsAction() {
        let model = HooksModel(home: Self.home, support: URL(fileURLWithPath: "/nonexistent-support"))
        model.apply(Self.snapshot)
        #expect(model.sections.map(\.name) == ["This Mac", "payments", "ledger"])
        #expect(model.fileCount == 5, "a file that isn't there isn't counted")
        let mac = model.sections[0].files
        #expect(mac.map(\.shownPath) == ["~/.shepherd/hooks.json", "~/.claude/settings.json"])
        #expect(mac[1].state == "Not read: switched off above" && mac[1].dimmed)
        let payments = model.sections[1].files
        #expect(payments[0].state == "Loaded" && payments[0].count == "2 hooks" && payments[0].action == nil)
        #expect(payments[1].tone == .failed && payments[1].action == .openFile && payments[1].state == "Couldn't read: line 14, expected “,”")
        #expect(model.sections[2].note == "~/code/ledger" && model.sections[1].note == "~/code/payments")
    }

    /// A proposal's Edit…: saving answers the proposal ("Added in Settings"); Cancel leaves it pending.
    @Test func savingAProposalsEditAnswersItAndCancelDoesNot() async throws {
        let dir = URL(fileURLWithPath: PiHome.canonical(FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString)").path))
        defer { try? FileManager.default.removeItem(at: dir) }
        let home = dir.appendingPathComponent("home").path
        let model = HooksModel(home: home, support: dir.appendingPathComponent("support"))
        var answers = 0
        let draft = HookDraft(event: "Stop", handler: .command("npm test"))
        model.add(draft: draft, saved: { answers += 1 })
        model.editor = nil // Cancel
        #expect(answers == 0)

        model.add(draft: draft, saved: { answers += 1 })
        let editor = try #require(model.editor)
        editor.handlers[0].command = "npm test --silent"
        #expect(await editor.save(with: model))
        #expect(answers == 1)
        #expect(try String(contentsOfFile: home + "/.shepherd/hooks.json", encoding: .utf8).contains("npm test --silent"))
        #expect(await editor.save(with: model) && answers == 1, "answered once")
    }

    /// JSON that doesn't read keeps the pane open with the person's text and the line that failed.
    @Test func jsonThatDoesNotReadStaysOpenWithItsError() {
        let entry = Self.snapshot.entries[0]
        let editor = HookEditorModel(editing: entry, targets: [], label: "This Mac", home: Self.home)
        editor.pane = .json
        editor.jsonText = "{\n  \"hooks\": {"
        editor.pane = .form
        #expect(editor.pane == .json)
        #expect(editor.jsonText == "{\n  \"hooks\": {")
        #expect(editor.jsonError?.hasPrefix("Line ") == true)
    }
}
