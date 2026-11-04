import Foundation
import Testing
@testable import ShepherdSessions
@testable import ShepherdApp

/// Settings › Hooks' rows and the composer's hook glyph, from a catalog snapshot (no files read).
@MainActor
struct HooksModelTests {
    static let home = "/Users/sam"
    static let space = "/Users/sam/code/payments"

    static func entry(_ file: String, scope: HookScope, event: String, matcher: String = "", command: String,
                      index: Int = 0, review: HookReview) -> HookEntry {
        let handler = HookHandler.command(command)
        let canonical = handler.raw.canonical
        return HookEntry(slot: HookCanonical.slot(file: file, event: event, group: index, handler: 0), scope: scope, file: file, format: .shepherd,
                         event: event, matcher: matcher, groupIndex: index, handlerIndex: 0, handler: handler,
                         hash: HookCanonical.hash(file: file, event: event, matcher: matcher, canonical: canonical), canonical: canonical,
                         editable: true, review: review)
    }

    static var snapshot: HookCatalogSnapshot {
        let mac = home + "/.shepherd/hooks.json", spaceFile = space + "/.shepherd/hooks.json", claude = space + "/.claude/settings.json"
        let previous = HookTrust.Record(slot: "x", entry: #"{"command":"git-guard","type":"command"}"#, matcher: "Bash", at: "2026-01-01T00:00:00Z", by: "review")
        return HookCatalogSnapshot(
            sources: [
                HookSource(path: mac, scope: .mac, format: .shepherd, isTOML: false, state: .loaded(count: 1)),
                HookSource(path: home + "/.claude/settings.json", scope: .mac, format: .claude, isTOML: false, state: .readerOff),
                HookSource(path: home + "/.codex/hooks.json", scope: .mac, format: .codex, isTOML: false, state: .notFound),
                HookSource(path: spaceFile, scope: .space(root: space), format: .shepherd, isTOML: false, state: .loaded(count: 2)),
                HookSource(path: claude, scope: .space(root: space), format: .claude, isTOML: false, state: .unreadable(line: 14, message: "expected “,”")),
                HookSource(path: "/Users/sam/code/ledger/.claude/settings.json", scope: .space(root: "/Users/sam/code/ledger"), format: .claude, isTOML: false, state: .spaceNotTrusted),
            ],
            entries: [
                entry(mac, scope: .mac, event: "PreToolUse", matcher: "Bash", command: "~/.shepherd/hooks/confirm-rm.sh", review: .on),
                entry(spaceFile, scope: .space(root: space), event: "PostToolUse", matcher: "Edit|Write", command: "npx prettier --write", review: .new),
                entry(spaceFile, scope: .space(root: space), event: "Stop", command: "npm test --silent", index: 1, review: .changed(previous: previous)),
            ],
            trust: HookTrust())
    }

    @Test func theGlyphCountsThisMacAndTheThreadsSpaceAndNothingElse() {
        let model = HooksModel(home: Self.home, support: URL(fileURLWithPath: "/nonexistent-support"))
        model.apply(Self.snapshot, roots: ["/Users/sam/code/payments/src": Self.space, "/Users/sam/code/ledger": "/Users/sam/code/ledger"])
        let inSpace = model.indicator(forCwd: "/Users/sam/code/payments/src")
        #expect(inSpace == HookIndicator(HookSummary(running: 1, needingReview: 2), spaceRoot: Self.space))
        #expect(inSpace?.help == "1 hook runs in this space, 2 waiting for review")
        #expect(model.indicator(forCwd: "/Users/sam/code/ledger")?.help == "1 hook runs in this space", "This Mac's hook runs everywhere")
        #expect(model.indicator(forCwd: "/elsewhere") == nil)
        #expect(HookIndicator(HookSummary(running: 0, needingReview: 0), spaceRoot: nil) == nil, "no hooks, no glyph")
        #expect(HookIndicator(HookSummary(running: 3, needingReview: 0), spaceRoot: nil)?.help == "3 hooks run in this space")
    }

    @Test func rowsGroupByEventWithBadgesSourcesAndLocks() {
        let model = HooksModel(home: Self.home, support: URL(fileURLWithPath: "/nonexistent-support"))
        model.apply(Self.snapshot)
        #expect(model.needingReview == 2)
        #expect(model.rail.map(\.label) == ["All hooks", "Before a tool runs", "After a tool runs", "When the agent finishes"])
        #expect(model.rail.map(\.count) == [3, 1, 1, 1] && model.emptyEvents == 9)
        let rows = model.groups.flatMap(\.rows)
        #expect(rows.map(\.source) == ["This Mac · ~/.shepherd/hooks.json", "payments · .shepherd/hooks.json", "payments · .shepherd/hooks.json"])
        #expect(rows.map(\.badge) == [nil, .new, .changed] && rows.map(\.locked) == [false, true, true] && rows.map(\.on) == [true, false, false])
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
        #expect(payments[0].state == "Loaded · 1 new, 1 changed, waiting for review" && payments[0].action == .review)
        #expect(payments[1].tone == .failed && payments[1].action == .openFile && payments[1].state == "Couldn't read: line 14, expected “,”")
        #expect(model.sections[2].files[0].state == "Skipped: ledger isn’t a trusted space" && model.sections[2].files[0].action == .trustSpace)
        #expect(model.sections[2].note == "Not trusted · ~/code/ledger")
    }

    @Test func theReviewItemDiffsAChangedCommand() {
        let entries = Self.snapshot.entries
        let changed = HookReviewItem(entries[2], file: "payments · .shepherd/hooks.json")
        #expect(changed.changed && changed.commandLabel == "Command, changed")
        #expect(changed.lines.map(\.text) == ["- matcher Bash", "+ matcher –", "- git-guard", "+ npm test --silent"])
        #expect(changed.timeout == "60 s (default)")
        let new = HookReviewItem(entries[1], file: "f")
        #expect(!new.changed && new.lines.map(\.text) == ["npx prettier --write"] && new.matcher == "Edit|Write")
    }
}
