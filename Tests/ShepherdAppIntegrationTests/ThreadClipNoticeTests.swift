import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import Testing
@testable import ShepherdApp
@testable import ShepherdSessions

/// What the thread says about what a snapshot shortened (docs/native-thread.md › RPCThreadState › Clipped), through
/// the real workspace over a real server and the stub pi: older pages to scroll up to and a long
/// reply say nothing, a turn's hidden output says so while the turn runs and stops when it ends.
@Suite("Thread clip notice over a real server", .serialized, .mainActorExclusive)
@MainActor
struct ThreadClipNoticeTests {
    @Test func olderPagesToLoadAreNeverClippedAndLoadingThemKeepsItSo() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let seed = app.dir.appendingPathComponent("history.json")
        try ThreadHeavySnapshotTests.history(pairs: 40, bytes: 3000).write(to: seed)
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app, env: { _ in ["STUB_PI_MESSAGES_FILE": seed.path] })
        defer { window.close() }
        let store = vm.threadStores.store(for: agents[0].agent.id)
        try await eventuallyOnMain("the newest page of the history", timeout: .seconds(30)) { store.ready && store.messages.count >= 20 }
        let older = try #require(store.olderCursor, "eighty messages are more than a page")
        #expect(store.clipNotice == nil, "older pages are a scroll away from \(older), not clipped")

        await store.loadOlder()
        #expect(store.messages.count > 20 && store.clipNotice == nil)
    }

    @Test func aLongReplyIsMarkedOnItsRowAndRaisesNoBanner() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        let store = vm.threadStores.store(for: agents[0].agent.id)
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-1").path, contents: nil)
        await store.send(text: "tools:1 a long answer long:300")
        try await eventuallyOnMain("the long reply", timeout: .seconds(30)) {
            !store.running && store.messages.contains { $0.role == "assistant" && $0.truncated }
        }
        #expect(store.clipNotice == nil, "the row says its own text was shortened; the thread has nothing missing")
        #expect(store.snapshot?.clipped == false && store.snapshot?.clips == nil)
    }

    @Test func aTurnsHiddenOutputIsSaidWhileItRunsAndStopsWhenItEnds() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        let store = vm.threadStores.store(for: agents[0].agent.id)
        // Every call but the last has its gate open: more calls than a page of the live run holds.
        let calls = RPCThreadState.pageSize + 6
        for call in 1..<calls { FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-\(call)").path, contents: nil) }
        await store.send(text: "tools:\(calls) a long run")
        try await eventuallyOnMain("the run to hide its oldest output", timeout: .seconds(60)) {
            store.running && store.clipNotice?.lines == [NativeClipNotice.live]
        }
        #expect(store.snapshot?.clips?.live ?? 0 > 0 && store.snapshot?.clipped == true)

        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("tool-\(calls)").path, contents: nil)
        try await eventuallyOnMain("the turn to end", timeout: .seconds(60)) { !store.running && store.messages.last?.role == "assistant" }
        #expect(store.clipNotice == nil, "the finished turn is whole in the history")
        #expect(store.snapshot?.clipped == false)
    }
}
