import Foundation
import ShepherdCore
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
