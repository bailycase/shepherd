import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// A turn streaming into the thread on screen: what each revision the thread adopts redraws,
/// and how often a pushed revision reaches the screen.
@Suite("Thread streaming", .serialized, .mainActorExclusive)
@MainActor
struct ThreadStreamingTests {
    /// A real pi's turn streaming between its two pauses (stub pi `slow`): each revision the
    /// thread adopts redraws the thread once, and the composer not at all.
    @Test func eachAdoptedRevisionRedrawsTheThreadOnceAndTheComposerNever() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let (vm, window, agents) = try await MountedWorkspace.open(1, in: app)
        defer { window.close() }
        let store = vm.threadStores.store(for: agents[0].agent.id)

        await store.send(text: "slow")
        try await eventuallyOnMain("the reply to pause after its first words", timeout: .seconds(30)) {
            store.running && !store.busy && Self.streamed(store).contains { $0.blocks.contains { $0.text.contains("Hello") } }
        }
        ListPerf.settle(window)

        let adoptions = Adoptions(store)
        NWRenderProbe.start()
        FileManager.default.createFile(atPath: app.dir.appendingPathComponent("continue-1").path, contents: nil)
        try await eventuallyOnMain("the reply to pause in its tool call", timeout: .seconds(30)) {
            Self.streamed(store).contains { $0.toolName == "bash" && $0.role != "assistant" }
        }
        ListPerf.settle(window)
        let counts = NWRenderProbe.stop()
        adoptions.stop()

        #expect(adoptions.count >= 1)
        #expect(counts["thread.view", default: 0] == adoptions.count, "\(adoptions.count) adopted: \(counts)")
        #expect(counts["composer.body", default: 0] == 0, "\(counts)")
    }

    /// A host whose revision moves every 20 ms, each one pushed: the thread takes them at about
    /// 30 Hz instead of once per half-second poll.
    @Test(.timingSensitive) func pushedRevisionsReachTheScreenAtAboutThirtyHertz() async throws {
        var changes: [Int] = [], gaps: [Double] = []
        for _ in 0..<3 {
            let thread = FakeThread(ThreadFixture.snapshot(ThreadFixture.history(50) + [ThreadFixture.user("u", "Go on")],
                                                           provisional: [ThreadFixture.streaming("Streaming")], running: true))
            try await thread.waitUntilReady()
            let adoptions = Adoptions(thread.store)
            try await thread.stream(for: .seconds(4), push: true)
            adoptions.stop()
            changes.append(adoptions.count)
            gaps.append(adoptions.medianGap)
            thread.close()
        }
        #expect(changes.sorted()[1] >= 60, "on-screen changes in 4 s: \(changes)")
        #expect(MainThreadCPU.median(gaps) <= 50, "median gap: \(gaps) ms")
    }

    private static func streamed(_ store: NativeThreadStore) -> [NativeThreadMessage] {
        guard let snapshot = store.snapshot else { return [] }
        return snapshot.messages + snapshot.provisional
    }
}
