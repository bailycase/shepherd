import AppKit
import Observation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp

/// One agent's store, two thread views (the deck's ordinary thread and a Mission station's embedded one).
/// Hiding or removing one view must not stop the other's polling or freeze its actions; hiding every view
/// still stops the store cleanly.
@Suite("A thread store shared by two views", .mainActorExclusive)
@MainActor
struct SharedThreadStoreLifecycleTests {
    @Observable @MainActor final class Views {
        var firstActive = true
        var firstMounted = true
        var secondActive = true
    }

    struct Host: View {
        let store: NativeThreadStore
        let views: Views
        let first: NativeThreadStore.Request, second: NativeThreadStore.Request
        var body: some View {
            VStack {
                if views.firstMounted {
                    ThreadView(store: store, active: views.firstActive, isFocused: false, request: first, listModels: { .empty })
                }
                ThreadView(store: store, active: views.secondActive, isFocused: false, request: second, listModels: { .empty })
            }
        }
    }

    final class Pulls { var first = 0, second = 0; var actions = ["images"] }

    enum Leaves: String, CaseIterable { case hidden, removed }

    @Test(arguments: Leaves.allCases)
    func theOtherViewKeepsPollingAndItsActionsStayCurrent(leaves: Leaves) async throws {
        // Fast polling, so "still polling" is observable within the test's waits.
        let store = NativeThreadStore(pause: { _ in try await Task.sleep(for: .milliseconds(20)) })
        let pulls = Pulls(), views = Views()
        let snapshot = { (actions: [String]) -> NativeThreadResult in
            var value = ComposerThread.snapshot(messages: 0, commands: [])
            value.supportedActions = actions
            return .snapshot(value: value)
        }
        let first: NativeThreadStore.Request = { _ in pulls.first += 1; return snapshot(["images"]) }
        let second: NativeThreadStore.Request = { _ in pulls.second += 1; return snapshot(pulls.actions) }
        let window = OffscreenWindow(size: CGSize(width: 800, height: 900))
        defer { store.stop(); window.close() }
        // The first view starts the store; the second is mounted after it and takes over the poll loop.
        views.secondActive = false
        window.show(Host(store: store, views: views, first: first, second: second))
        try await eventuallyOnMain("first view polls") { window.layout(); return pulls.first > 0 && store.ready }
        views.secondActive = true
        try await eventuallyOnMain("second view polls") { window.layout(); return pulls.second > 0 }
        // The first view leaves: hidden by the deck, or taken off screen.
        switch leaves {
        case .hidden: views.firstActive = false
        case .removed: views.firstMounted = false
        }
        window.layout()
        let before = pulls.second
        pulls.actions = ["images", "send"]
        try await eventuallyOnMain("the visible view keeps polling", timeout: .seconds(5)) { window.layout(); return pulls.second > before + 2 }
        #expect(store.isLive, "the store is still on screen")
        #expect(store.supports("send"), "the visible view's newest actions reached the store")
        // Every view hidden: the store stops.
        views.secondActive = false
        if leaves == .hidden { views.firstActive = false }
        try await eventuallyOnMain("all hidden, the store stops") { window.layout(); return !store.isLive }
        let stopped = pulls.second
        try await eventuallyOnMain("no further pulls") { window.layout(); return pulls.second == stopped }
    }
}
