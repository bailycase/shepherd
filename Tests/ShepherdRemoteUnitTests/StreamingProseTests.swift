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
        let host = FakeHost(Fixture.snapshot(running: true, provisional: [
            Fixture.assistant("Beginning", status: "streaming", id: "reply")
        ]))
        let loop = await start(store, host)
        defer { release.finish(); loop.cancel(); store.stop() }
        func show(_ text: String) async {
            host.snapshot.revision += 1
            host.snapshot.provisional = [Fixture.assistant(text, status: "streaming", id: "reply")]
            await store.refresh()
        }
        var text = "Beginning " + String(repeating: "word ", count: 2_000)
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
        #expect(store.offMainParses == 2, "Skip intermediate snapshots and parse only the newest text next")
    }
}
