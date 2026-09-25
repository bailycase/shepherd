import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// One thread on screen in two windows: the store's poll loop is shared, joined rather than
/// restarted over the same connection, handed over when the driving window leaves, and suspended
/// only once no window is left to run it.
@Suite("Thread viewers", .timeLimit(.minutes(1)))
@MainActor
struct NativeThreadViewersTests {
    typealias F = Fixture

    /// Starts a viewer's run through `viewers` and returns once its first snapshot was asked for
    /// and the store is ready: a viewer that drives the loop.
    private func view(_ viewers: NativeThreadViewers, _ host: FakeHost, connection: String = "a",
                      request: NativeThreadStore.Request? = nil) async -> Task<Void, Never> {
        var task: Task<Void, Never>?
        let request = request ?? { try host.handle($0) }
        await withCheckedContinuation { (served: CheckedContinuation<Void, Never>) in
            host.onRequest = { _ in
                host.onRequest = nil
                served.resume()
            }
            task = Task { await viewers.run(connection: connection, request: request) }
        }
        await until { viewers.store.ready }
        return task!
    }

    /// Starts a viewer's run and returns once it has joined the viewers, without waiting for it
    /// to ask anything.
    private func join(_ viewers: NativeThreadViewers, _ host: FakeHost, connection: String = "a") async -> Task<Void, Never> {
        let before = viewers.count
        let task = Task { await viewers.run(connection: connection) { try host.handle($0) } }
        await until { viewers.count > before }
        return task
    }

    @Test func aSecondWindowOnTheSameConnectionJoinsTheLoopWithoutRestartingIt() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let first = FakeHost(F.snapshot(messages: []))
        let second = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, first)
        defer { a.cancel() }
        let b = await join(viewers, second)
        defer { b.cancel() }
        #expect(viewers.count == 2)
        #expect(viewers.store.isLive)
        #expect(first.requests.count == 1)
        await viewers.store.refresh()
        #expect(first.requests.count == 2)
        #expect(second.requests.isEmpty)
    }

    @Test func aWindowJoiningLeavesAnotherWindowsSendInFlight() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let host = FakeHost(F.snapshot(messages: []))
        host.acceptAll()
        let sending = FirstPullGate()
        let (released, release) = AsyncStream<Void>.makeStream()
        let a = await view(viewers, host) { request in
            if case .send = request {
                sending.asked = true
                for await _ in released { break }
            }
            return try host.handle(request)
        }
        defer { a.cancel() }
        viewers.store.draft = "Use these boards as the spec."
        let send = Task { await viewers.store.send() }
        await until { sending.asked }
        let b = await join(viewers, FakeHost(F.snapshot(messages: [])))
        defer { b.cancel() }
        release.yield()
        release.finish()
        await send.value
        #expect(viewers.store.notice == nil)
        #expect(host.actions.count == 1)
    }

    @Test func aWindowOnANewerConnectionTakesTheLoopOver() async {
        let viewers = NativeThreadViewers(store: manualStore())
        let first = FakeHost(F.snapshot(messages: []))
        let second = FakeHost(F.snapshot(messages: []))
        let a = await view(viewers, first)
        defer { a.cancel() }
        let b = await view(viewers, second, connection: "b")
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
        let b = await join(viewers, second)
        defer { b.cancel() }
        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            second.onRequest = { _ in
                second.onRequest = nil
                resumed.resume()
            }
            a.cancel()
        }
        await a.value
        #expect(viewers.count == 1)
        #expect(viewers.store.isLive)
        #expect(second.requests.count == 1)
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
        let b = await join(viewers, second)
        defer { b.cancel() }
        await withCheckedContinuation { (resumed: CheckedContinuation<Void, Never>) in
            second.onRequest = { _ in
                second.onRequest = nil
                resumed.resume()
            }
            a.cancel()
        }
        await a.value
        #expect(viewers.store.isLive)
        #expect(viewers.store.ready)
    }
}
