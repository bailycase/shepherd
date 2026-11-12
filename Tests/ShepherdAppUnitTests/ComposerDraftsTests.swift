import Foundation
import ShepherdCore
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// Unsent composer drafts survive a relaunch: written to defaults a moment after typing stops,
/// restored into the agent's store when it is next made, and dropped once sent.
@Suite("Composer drafts")
@MainActor
struct ComposerDraftsTests {
    let defaults = Fixture.defaults()

    @Test func aDraftIsKeptPerAgentAndDroppedWhenEmptied() {
        let drafts = ComposerDrafts(defaults: defaults)
        drafts.note("a", draft: "Half a thought")
        drafts.note("b", draft: "Another")
        drafts.flush()
        #expect(defaults.dictionary(forKey: ComposerDrafts.key) as? [String: String] == ["a": "Half a thought", "b": "Another"])

        let relaunched = ComposerDrafts(defaults: defaults)
        #expect(relaunched.restore("a") == "Half a thought")
        relaunched.note("a", draft: "")
        relaunched.note("b", draft: String(repeating: "x", count: ComposerDrafts.maxLength + 1))
        relaunched.flush()
        #expect(defaults.object(forKey: ComposerDrafts.key) == nil, "a sent draft and a document-sized one are not kept")
    }

    @Test func aDocumentSizedDraftIsDroppedWhenWrittenAndNeverRestored() {
        let drafts = ComposerDrafts(defaults: defaults)
        drafts.note("short", draft: "Another agent's words")
        drafts.note("replaced", draft: "Saved earlier")
        drafts.flush()

        let document = String(repeating: "x", count: ComposerDrafts.maxLength + 1)
        drafts.note("long", draft: document)
        drafts.note("replaced", draft: document)
        #expect(drafts.restore("long") == nil, "an over-length draft is not handed back before its write either")
        #expect(drafts.restore("replaced") == nil)
        #expect(drafts.restore("short") == "Another agent's words")

        drafts.flush()
        #expect(defaults.dictionary(forKey: ComposerDrafts.key) as? [String: String] == ["short": "Another agent's words"])
        #expect(ComposerDrafts(defaults: defaults).restore("long") == nil)
    }

    @Test func aDraftIsCountedInCharactersNotBytes() {
        let drafts = ComposerDrafts(defaults: defaults)
        // Two bytes each: 128 KB, but exactly the limit in Characters.
        let atLimit = String(repeating: "é", count: ComposerDrafts.maxLength)
        drafts.note("limit", draft: atLimit)
        drafts.note("over", draft: atLimit + "é")
        // Typed past the limit and back under it before the write: the short words are the draft.
        drafts.note("trimmed", draft: atLimit + "é")
        drafts.note("trimmed", draft: "Trimmed")
        drafts.flush()
        #expect(defaults.dictionary(forKey: ComposerDrafts.key) as? [String: String] == ["limit": atLimit, "trimmed": "Trimmed"])
    }

    /// Typing notes the draft on every key, so noting costs nothing in its length: the check
    /// belongs to the write, which a pause (not a key) brings.
    @Test(.timingSensitive) func notingADraftOnEveryKeystrokeCountsNothing() {
        let drafts = ComposerDrafts(defaults: defaults)
        // 1 MB, 500K Characters: counting them takes milliseconds.
        let draft = String(repeating: "é", count: 500_000)
        let best = (0..<3).map { _ in
            ContinuousClock().measure { for _ in 0..<200 { drafts.note("agent", draft: draft) } }
        }.min() ?? .zero
        drafts.flush()
        #expect(best < .milliseconds(10), "200 keystrokes noted in \(best)")
        #expect(defaults.object(forKey: ComposerDrafts.key) == nil, "the document-sized draft is dropped when written")
    }

    @Test func aStoreRestoresItsAgentsDraftAndNotesWhatIsTyped() async throws {
        let id = AgentID()
        let kept = ComposerDrafts(defaults: defaults)
        kept.note(id.rawValue, draft: "Before the quit")
        kept.flush()

        let stores = NativeThreadStores<AgentID>()
        stores.drafts = ComposerDrafts(defaults: defaults)
        let store = stores.store(for: id)
        #expect(store.draft == "Before the quit")

        store.draft = "Before the quit, and after"
        // The change is noted on the main actor after the store's willSet; the write itself waits for the pause.
        for _ in 0..<10 where stores.drafts?.restore(id.rawValue) != store.draft { await Task.yield() }
        #expect(stores.drafts?.restore(id.rawValue) == "Before the quit, and after")
        stores.drafts?.flush()
        #expect(ComposerDrafts(defaults: defaults).restore(id.rawValue) == "Before the quit, and after")

        // A key with no string identity (a remote ref) keeps nothing and asks for nothing.
        let remote = NativeThreadStores<Int>()
        remote.drafts = ComposerDrafts(defaults: defaults)
        #expect(remote.store(for: 7).draft.isEmpty)
    }
}
