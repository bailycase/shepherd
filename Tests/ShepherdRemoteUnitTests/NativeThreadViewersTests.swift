import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// One thread on screen in two windows: the store's poll loop is shared, handed over when the
/// driving window leaves, and suspended only once no window is left to run it.
@Suite("Thread viewers", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadViewersTests {
    typealias F = Fixture

    /// Starts a viewer's run through `viewers` and returns once its first snapshot was asked for
    /// and the store is ready.
    private func view(_ viewers: NativeThreadViewers, _ host: FakeHost) async -> Task<Void, Never> {
        var task: Task<Void, Never>?
        await withCheckedContinuation { (served: CheckedContinuation<Void, Never>) in
            host.onRequest = { _ in
                host.onRequest = nil
                served.resume()
            }
            task = Task { await viewers.run { try host.handle($0) } }
        }
        await until { viewers.store.ready }
        return task!
    }

    @Test func theNewestWindowTakesTheLoopOverAndTheOtherWaits() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let first = FakeHost(F.snapshot(messages: []))
        let second = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, first)
        defer { a.cancel() }
        let b = await view(viewers, second)
        defer { b.cancel() }
        #expect(viewers.count == 2)
        #expect(viewers.store.isLive)
        await viewers.store.refresh()
        #expect(second.requests.count == 2)
        #expect(first.requests.count == 1)
    }

    @Test func whenTheDrivingWindowLeavesTheOtherRunsTheThread() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let first = FakeHost(F.snapshot(messages: []))
        let second = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, first)
        defer { a.cancel() }
        let b = await view(viewers, second)
        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            first.onRequest = { _ in
                first.onRequest = nil
                resumed.resume()
            }
            b.cancel()
        }
        await b.value
        #expect(viewers.count == 1)
        #expect(viewers.store.isLive)
        #expect(first.requests.count == 2)
    }

    @Test func aWindowThatCantRunTheThreadLeavesItToTheOther() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let host = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, host)
        defer { a.cancel() }
        viewers.rest(detached: false)
        #expect(viewers.store.isLive)
        #expect(viewers.store.ready)
    }

    @Test func theLastWindowToLeaveAppliesARestAskedMeanwhile() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let host = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, host)
        viewers.rest(detached: true)
        a.cancel()
        await a.value
        #expect(viewers.count == 0)
        #expect(!viewers.store.isLive)
        #expect(!viewers.store.ready)
    }

    @Test func withNoWindowLeftARestAppliesAtOnce() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let host = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, host)
        a.cancel()
        await a.value
        #expect(viewers.store.ready)
        viewers.rest(detached: true)
        #expect(!viewers.store.ready)
    }

    @Test func aWindowComingBackCancelsARestAskedWhileItWasAway() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let first = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, first)
        viewers.rest(detached: true)
        let second = FakeHost(F.snapshot(messages: []))
        let b = await view(viewers, second)
        defer { b.cancel() }
        a.cancel()
        await a.value
        #expect(viewers.store.isLive)
        #expect(viewers.store.ready)
    }
}
