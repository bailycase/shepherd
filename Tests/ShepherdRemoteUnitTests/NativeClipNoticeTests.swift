import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// What a thread says when its snapshot shortened something (docs/native-thread.md › RPCThreadState › Clipped):
/// one line per fact the host reported, gone with the fact, and never about older pages.
@Suite("Clip notice")
@MainActor
struct NativeClipNoticeTests {
    typealias F = Fixture

    private func snapshot(_ clips: NativeThreadClips? = nil, clipped: Bool? = nil, older: String? = nil, running: Bool = false) -> NativeThreadSnapshot {
        var value = F.snapshot(running: running, messages: [F.assistant("hi", id: "a")], olderCursor: older)
        value.clips = clips
        value.clipped = clipped ?? (clips != nil)
        return value
    }

    // MARK: Each cause

    @Test func anUnreadHistorySaysMessagesAreMissingAndWhenTheyReturn() {
        let notice = NativeClipNotice(snapshot(NativeThreadClips(history: true)), running: false)
        #expect(notice?.lines == [NativeClipNotice.history])
        #expect(NativeClipNotice.history.contains("couldn't be read") && NativeClipNotice.history.contains("next reply"))
    }

    @Test func aTurnsHiddenOutputIsSaidOnlyWhileItRuns() {
        let clips = NativeThreadClips(live: 4)
        #expect(NativeClipNotice(snapshot(clips, running: true), running: true)?.lines == [NativeClipNotice.live])
        #expect(NativeClipNotice(snapshot(clips), running: false) == nil, "the finished turn shows its rows, so there is nothing to say")
    }

    @Test(arguments: [(1, NativeClipNotice.oneQuestion), (2, NativeClipNotice.questions(2)), (7, NativeClipNotice.questions(7))])
    func questionsTooLargeToShowAreCountedInPlainWords(count: Int, line: String) {
        #expect(NativeClipNotice(snapshot(NativeThreadClips(questions: count)), running: true)?.lines == [line])
    }

    @Test func severalCausesEachGetTheirOwnLineInOneOrder() {
        let notice = NativeClipNotice(snapshot(NativeThreadClips(history: true, live: 2, questions: 3), running: true), running: true)
        #expect(notice?.lines == [NativeClipNotice.history, NativeClipNotice.live, NativeClipNotice.questions(3)])
        #expect(notice?.text == [NativeClipNotice.history, NativeClipNotice.live, NativeClipNotice.questions(3)].joined(separator: "\n"))
    }

    // MARK: Nothing missing

    @Test func olderPagesToLoadAreNeverClippedWhateverTheHostSays() {
        #expect(NativeClipNotice(snapshot(older: "m:40"), running: false) == nil)
        #expect(NativeClipNotice(snapshot(older: "m:40"), running: true) == nil)
        #expect(NativeClipNotice(snapshot(clipped: true, older: "m:40"), running: false) == nil, "an older host sets the flag for this alone")
    }

    @Test func aSnapshotThatShortenedNothingSaysNothing() {
        #expect(NativeClipNotice(snapshot(), running: true) == nil)
        #expect(NativeClipNotice(snapshot(NativeThreadClips()), running: true) == nil, "an empty set of facts is not a fact")
        #expect(NativeClipNotice(nil, running: true) == nil)
    }

    // MARK: Older hosts

    @Test func anOlderHostsFlagWithNothingOlderToLoadSaysOnlyThatSomethingIsClipped() {
        #expect(NativeClipNotice(snapshot(clipped: true), running: false)?.lines == [NativeClipNotice.unknown])
        #expect(NativeClipNotice(snapshot(clipped: true), running: true)?.lines == [NativeClipNotice.unknown])
    }

    @Test func aHostThatNamesWhatItClippedIsBelievedOverItsFlag() {
        let notice = NativeClipNotice(snapshot(NativeThreadClips(questions: 1), clipped: true), running: false)
        #expect(notice?.lines == [NativeClipNotice.oneQuestion], "the legacy line never joins a named one")
    }

    // MARK: Through the store

    private func started(_ value: NativeThreadSnapshot) async -> (NativeThreadStore, FakeHost, Task<Void, Never>) {
        let host = FakeHost(value)
        let store = manualStore()
        let task = await start(store, host)
        return (store, host, task)
    }

    @Test func theNoticeAppearsWithTheHostsReportAndClearsWhenTheFetchLands() async {
        var value = snapshot(NativeThreadClips(history: true))
        let (store, host, task) = await started(value)
        defer { task.cancel() }
        #expect(store.clipNotice?.lines == [NativeClipNotice.history])

        value.clips = nil
        value.clipped = false
        value.revision += 1
        host.snapshot = value
        await store.refresh()
        #expect(store.clipNotice == nil)
    }

    @Test func theRunningTurnsLineGoesWhenTheTurnEnds() async {
        var value = snapshot(NativeThreadClips(live: 3), running: true)
        let (store, host, task) = await started(value)
        defer { task.cancel() }
        #expect(store.running && store.clipNotice?.lines == [NativeClipNotice.live])

        value.running = false
        value.clips = nil
        value.clipped = false
        value.revision += 1
        host.snapshot = value
        await store.refresh()
        #expect(store.clipNotice == nil, "the host's snapshot of the finished turn carries no clips, and the notice follows it at once")
    }

    @Test func loadingOlderPagesNeitherRaisesTheNoticeNorClearsAnother() async {
        let m2 = F.assistant("two", id: "m2"), m3 = F.assistant("three", id: "m3")
        var value = F.snapshot(messages: [m2, m3], olderCursor: "m2")
        let (store, host, task) = await started(value)
        defer { task.cancel() }
        #expect(store.olderCursor == "m2" && store.clipNotice == nil, "older pages to load are not a clip")

        var page = F.snapshot(messages: [F.user("zero", id: "m0"), F.assistant("one", id: "m1"), m2], olderCursor: "m0")
        page.clipped = true
        host.next = [.success(.snapshot(value: page))]
        await store.loadOlder()
        #expect(store.messages.map(\.entryID) == ["m0", "m1", "m2", "m3"] && store.clipNotice == nil, "a page's own flag is not the thread's")

        value.revision += 1
        value.clips = NativeThreadClips(history: true)
        value.clipped = true
        host.snapshot = value
        await store.refresh()
        #expect(store.clipNotice?.lines == [NativeClipNotice.history])
        host.next = [.success(.snapshot(value: F.snapshot(messages: [F.user("start", id: "m-1")], olderCursor: nil)))]
        await store.loadOlder()
        #expect(store.clipNotice?.lines == [NativeClipNotice.history], "loading history does not stand in for the host's next fetch")
    }
}
