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
                if case .prose(_, _, let prose) = $0 { prose.blocks } else { nil }
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
                if case .prose(_, _, let prose) = $0 { prose.blocks } else { nil }
            }.last
        }
        let host = FakeHost(snapshot(1, long))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        #expect(store.proseParses == 0 && store.offMainParses == 1, "cold oversized prose also parses off main")
        await until { prose() == [.paragraph(long.trimmingCharacters(in: .whitespaces))] }

        host.snapshot = snapshot(2, long + "\n\nmore")
        await store.refresh()
        #expect(store.proseParses == 0 && store.offMainParses == 2)
        #expect(prose() == [.paragraph(long.trimmingCharacters(in: .whitespaces))], "the last parse stands meanwhile")

        await until { prose()?.count == 2 }
        #expect(prose()?.last == .paragraph("more"))
        #expect(store.proseParses == 0 && store.mainActorLargeParses == 0)

        // The same text asked for again is not parsed again; a newer one is.
        await store.refresh()
        #expect(store.offMainParses == 2)
        host.snapshot = snapshot(3, long + "\n\nmore\n\nand more")
        await store.refresh()
        #expect(store.offMainParses == 3)
        await until { prose()?.count == 3 }
        #expect(prose()?.last == .paragraph("and more"))
    }

    /// The store hands the prose it holds to the parse of a newer text, so a chunk the new text leaves
    /// alone keeps its storage and comparing the two stays cheap.
    @Test func aReplyGrownAtItsEndKeepsTheStorageOfTheChunksBeforeIt() async throws {
        let user = F.user("write it up", id: "u")
        let paragraphs = (0..<48).map { "Paragraph \($0) " + String(repeating: "word ", count: 200) }
        func text(_ last: String) -> String { (paragraphs.dropLast() + [last]).joined(separator: "\n\n") }
        #expect(text("x").utf8.count >= NativeThreadStore.offMainProseBytes)
        func snapshot(_ revision: UInt64, _ text: String) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user], provisional: [F.assistant(text, status: "streaming", id: "live")])
        }
        func prose() -> NativeProse? {
            store.rows.last?.presentation?.items.compactMap { if case .prose(_, _, let prose) = $0 { prose } else { nil } }.last
        }
        let host = FakeHost(snapshot(1, text("The end.")))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        await until { prose()?.blockCount == 48 }
        let old = try #require(prose())
        #expect(old.chunks.count > 1)

        host.snapshot = snapshot(2, text("The end, written on."))
        await store.refresh()
        await until { prose()?.blocks.last == .paragraph("The end, written on.") }
        let new = try #require(prose())
        #expect(new.chunks.count == old.chunks.count)
        for index in 0..<new.chunks.count - 1 { #expect(new.chunks[index].sharesStorage(with: old.chunks[index]), "chunk \(index)") }
        #expect(!new.chunks[new.chunks.count - 1].sharesStorage(with: old.chunks[old.chunks.count - 1]))
    }
}
