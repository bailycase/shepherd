import ShepherdProtocol
@testable import ShepherdRemote
import Testing

@Suite("Prose in the store")
@MainActor
struct ProseStoreTests {
    typealias F = Fixture

    @Test func aGrowingReplyReusesFinishedProseAndParsesItsFinalTextAgain() async {
        let messages = [F.user("check the runner", id: "u"),
                        F.assistant("**Checking** the config.", id: "a"),
                        F.tool("read", args: #"{"path":"config"}"#, id: "r", callID: "r")]
        func text(_ count: Int) -> String {
            "Answer" + String(repeating: " grows", count: count) + "\n\n| Area | Tools |"
        }
        func snapshot(_ revision: UInt64, _ count: Int, streaming: Bool = true) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: messages,
                       provisional: [F.assistant(text(count), status: streaming ? "streaming" : nil, id: "live")])
        }
        let host = FakeHost(snapshot(1, 1))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        #expect(store.proseParses == 2)

        for index in 2...6 {
            host.snapshot = snapshot(UInt64(index), index)
            await store.refresh()
            #expect(store.proseParses == index + 1, "only the growing prose is parsed")
        }
        func prose() -> [[NativeMarkdownBlock]]? {
            store.rows.last?.presentation?.items.compactMap {
                if case .prose(_, _, let blocks, _) = $0 { blocks } else { nil }
            }
        }
        let answer = "Answer" + String(repeating: " grows", count: 6)
        #expect(prose() == [[.paragraph("**Checking** the config.")], [.paragraph(answer)]])

        // The message finishes before the turn settles; identical text must now parse with
        // streaming=false, exposing the header that streaming held for a delimiter row.
        host.snapshot = snapshot(7, 6, streaming: false)
        await store.refresh()
        #expect(store.proseParses == 8)
        #expect(prose() == [[.paragraph("**Checking** the config.")],
                           [.paragraph(answer), .paragraph("| Area | Tools |")]])
    }

    /// A long reply still being written parses off main: the poll that grows it keeps the last
    /// parse (a prefix of the text) on the main actor, and the new one lands with a derivation of
    /// its own. A text that moved on meanwhile is parsed again, once.
    @Test func aLongStreamingReplyParsesOffMainAndLandsWhenItsTextStillStands() async {
        let user = F.user("write it up", id: "u")
        let long = String(repeating: "word ", count: NativeThreadStore.offMainProseBytes / 5 + 1)
        func snapshot(_ revision: UInt64, _ text: String) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user], provisional: [F.assistant(text, status: "streaming", id: "live")])
        }
        func prose() -> [NativeMarkdownBlock]? {
            store.rows.last?.presentation?.items.compactMap {
                if case .prose(_, _, let blocks, _) = $0 { blocks } else { nil }
            }.last
        }
        let host = FakeHost(snapshot(1, long))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        #expect(store.proseParses == 1 && store.offMainParses == 0, "the first text of an item parses in place")

        host.snapshot = snapshot(2, long + "\n\nmore")
        await store.refresh()
        #expect(store.proseParses == 1 && store.offMainParses == 1)
        #expect(prose() == [.paragraph(long.trimmingCharacters(in: .whitespaces))], "the last parse stands meanwhile")

        await until { prose()?.count == 2 }
        #expect(prose()?.last == .paragraph("more"))
        #expect(store.proseParses == 1)

        // The same text asked for again is not parsed again; a newer one is.
        await store.refresh()
        #expect(store.offMainParses == 1)
        host.snapshot = snapshot(3, long + "\n\nmore\n\nand more")
        await store.refresh()
        #expect(store.offMainParses == 2)
        await until { prose()?.count == 3 }
        #expect(prose()?.last == .paragraph("and more"))
    }
}
