import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct StreamingProseTests {
    @Test func aSlowParseCoalescesChunksAndEventuallyShowsTheNewestReply() async {
        let store = manualStore()
        let (gate, release) = AsyncStream<Void>.makeStream()
        store.beforeProseParse = { for await _ in gate {} }
        // The reply is already past 8 KB when the thread opens: its cold parse is the slow one.
        var text = "Beginning " + String(repeating: "word ", count: 2_000)
        let host = FakeHost(Fixture.snapshot(running: true, provisional: [
            Fixture.assistant(text, status: "streaming", id: "reply")
        ]))
        let loop = await start(store, host)
        defer { release.finish(); loop.cancel(); store.stop() }
        func show(_ text: String) async {
            host.snapshot.revision += 1
            host.snapshot.provisional = [Fixture.assistant(text, status: "streaming", id: "reply")]
            await store.refresh()
        }
        for _ in 0..<100 {
            text += "more "
            await show(text)
        }
        #expect(store.offMainParses == 1, "Only one parse may run for this reply")
        let expected = nativeMarkdownParse(text, streaming: true).blocks
        release.finish()
        await until {
            guard case .prose(_, _, let prose)? = store.rows.last?.presentation?.items.last else { return false }
            return prose.blocks == expected
        }
        #expect(store.offMainParses == 1, "The cold parse that landed late is the base: no second one starts")
        #expect(store.tailParses >= 1, "The newest text arrives as one tail parse on the main actor")
    }
}
