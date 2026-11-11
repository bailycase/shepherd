import ShepherdProtocol
@testable import ShepherdRemote
import Testing

@Suite("Prose in the store")
@MainActor
struct ProseStoreTests {
    typealias F = Fixture

    @Test func aGrowingReplyReusesFinishedProseAndParsesOnlyTheTailOfItsFinalText() async {
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
        // streaming=false, exposing the header that streaming held for a delimiter row. The cached
        // state advances into the other mode: a tail parse, not another full one.
        host.snapshot = snapshot(7, 6, streaming: false)
        await store.refresh()
        #expect(store.proseParses == 7 && store.tailParses == 1)
        #expect(prose() == [[.paragraph("**Checking** the config.")],
                           [.paragraph(answer), .paragraph("| Area | Tools |")]])
    }

    /// A long reply parses off main once, cold. The appends after it advance the state it left, on the
    /// main actor: the text shows at once, with no stale blocks meanwhile.
    @Test func aLongStreamingReplyParsesOffMainOnceAndGrowsOnTheMainActor() async {
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
        #expect(store.proseParses == 0 && store.offMainParses == 1, "cold oversized prose parses off main")
        await until { prose() == [.paragraph(long.trimmingCharacters(in: .whitespaces))] }

        host.snapshot = snapshot(2, long + "\n\nmore")
        await store.refresh()
        #expect(store.proseParses == 0 && store.offMainParses == 1 && store.tailParses == 1)
        #expect(prose()?.count == 2 && prose()?.last == .paragraph("more"), "the new text shows at once")
        #expect(store.mainActorLargeParses == 0)

        // The same text asked for again is not parsed again; a newer one is.
        await store.refresh()
        #expect(store.tailParses == 1)
        host.snapshot = snapshot(3, long + "\n\nmore\n\nand more")
        await store.refresh()
        #expect(store.tailParses == 2 && store.offMainParses == 1)
        #expect(prose()?.last == .paragraph("and more"))
    }

    /// A 20 KB reply and fifty appends of a paragraph each: only the first parse is off main, and each
    /// append parses its tail, a few hundred bytes, not the reply.
    @Test func aLongStreamingReplyParsesOnlyItsTailOnTheMainActor() async {
        let user = F.user("write it up", id: "u")
        var text = (0..<130).map { "Paragraph \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n\n")
        #expect(text.utf8.count >= 20_000)
        func snapshot(_ revision: UInt64) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user], provisional: [F.assistant(text, status: "streaming", id: "live")])
        }
        let host = FakeHost(snapshot(1))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        await store.waitForProse()
        #expect(store.offMainParses == 1 && store.proseParses == 0, "the cold parse")

        for index in 0..<50 {
            text += "\n\nAppended \(index) " + String(repeating: "word ", count: 14)
            host.snapshot = snapshot(UInt64(index + 2))
            await store.refresh()
        }
        await store.waitForProse()
        #expect(store.offMainParses == 1 && store.proseParses == 0)
        #expect(store.tailParses == 50)
        #expect(store.mainParsedBytes <= 50 * 2 * 1024, "\(store.mainParsedBytes) bytes parsed on the main actor")
        let blocks = store.rows.last?.presentation?.items.compactMap { if case .prose(_, _, let prose) = $0 { prose.blocks } else { nil } }.last
        #expect(blocks == nativeMarkdownParse(text, streaming: true).blocks)
    }

    @Test func aGrowingReplyDerivesOncePerPull() async {
        let user = F.user("write it up", id: "u")
        var text = (0..<130).map { "Paragraph \($0) " + String(repeating: "word ", count: 30) }.joined(separator: "\n\n")
        func snapshot(_ revision: UInt64) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user], provisional: [F.assistant(text, status: "streaming", id: "live")])
        }
        let host = FakeHost(snapshot(1))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        await store.waitForProse()
        let derived = store.derivations
        for index in 1...20 {
            text += "\n\nAppended \(index) " + String(repeating: "word ", count: 14)
            host.snapshot = snapshot(UInt64(index + 1))
            await store.refresh()
            await store.waitForProse()
            #expect(store.derivations == derived + index, "pull \(index)")
        }
    }

    /// A tail past the on-main budget parses off main. A parse that lands after the text moved on is still the
    /// base of the newest one: the reply shows it, and the newest text is parsed once more from there.
    @Test func aSlowParseOfATailPastTheBudgetLandsAsTheBaseOfTheNewestText() async {
        let user = F.user("write it up", id: "u")
        var text = "Start " + String(repeating: "word ", count: NativeThreadStore.onMainTailBytes / 4)
        #expect(text.utf8.count > NativeThreadStore.onMainTailBytes)
        func snapshot(_ revision: UInt64) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user], provisional: [F.assistant(text, status: "streaming", id: "live")])
        }
        let (gate, release) = AsyncStream<Void>.makeStream()
        let store = manualStore()
        store.beforeProseParse = { for await _ in gate {} }
        let host = FakeHost(snapshot(1))
        let task = await start(store, host)
        defer { release.finish(); task.cancel(); store.stop() }
        for index in 0..<20 {
            text += "more "
            host.snapshot = snapshot(UInt64(index + 2))
            await store.refresh()
        }
        #expect(store.offMainParses == 1 && store.tailParses == 0, "one cold parse is running; the rest wait for it")
        release.finish()
        await store.waitForProse()
        let blocks = store.rows.last?.presentation?.items.compactMap { if case .prose(_, _, let prose) = $0 { prose.blocks } else { nil } }.last
        #expect(blocks == nativeMarkdownParse(text, streaming: true).blocks)
        #expect(store.offMainParses == 2 && store.tailParses == 0, "the late parse is the base the newest text is parsed from")
        #expect(store.proseParses == 0 && store.activeProseTasks == 0)
    }

    /// The reply finishes: the same text in the other mode. The frozen prefix is final in both, so the
    /// turn end parses the tail alone, and the chunks before it are the very ones that streamed.
    @Test func aTurnEndParsesOnlyTheTailAndKeepsItsChunks() async throws {
        let user = F.user("write it up", id: "u")
        let paragraphs = (0..<60).map { "Paragraph \($0) " + String(repeating: "word ", count: 250) }
        let text = paragraphs.joined(separator: "\n\n") + "\n\n| Area | Tools |"
        #expect(text.utf8.count > 64 * 1024)
        func snapshot(_ revision: UInt64, streaming: Bool) -> NativeThreadSnapshot {
            F.snapshot(revision: revision, running: true, messages: [user],
                       provisional: [F.assistant(text, status: streaming ? "streaming" : nil, id: "live")])
        }
        func prose() -> NativeProse? {
            store.rows.last?.presentation?.items.compactMap { if case .prose(_, _, let prose) = $0 { prose } else { nil } }.last
        }
        let host = FakeHost(snapshot(1, streaming: true))
        let store = manualStore()
        let task = await start(store, host)
        defer { task.cancel() }
        await store.waitForProse()
        let streamed = try #require(prose())
        #expect(streamed.chunks.count >= 4)
        let (parses, offMain, tails) = (store.proseParses, store.offMainParses, store.tailParses)

        host.snapshot = snapshot(2, streaming: false)
        await store.refresh()
        await store.waitForProse()
        #expect(store.proseParses == parses && store.offMainParses == offMain, "no full parse, on or off main")
        #expect(store.tailParses == tails + 1)
        let finished = try #require(prose())
        #expect(finished.blocks == nativeMarkdownParse(text, streaming: false).blocks)
        #expect(finished.blocks.last == .paragraph("| Area | Tools |"), "the held header shows once the reply is final")
        #expect(finished.chunks.count == streamed.chunks.count)
        for index in 0..<finished.chunks.count - 2 {
            #expect(finished.chunks[index].sharesStorage(with: streamed.chunks[index]), "chunk \(index)")
        }
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
