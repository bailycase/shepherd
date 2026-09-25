import Foundation

/// The views showing one thread, sharing its store's poll loop: a thread open in two iPad
/// windows at once. `NativeThreadStore.run` serves one caller (a second run ends the first), so
/// each view runs the store through this instead.
///
/// The newest view to come on screen drives the loop, as a single view always did. The others
/// wait; when the loop stops without them (the driving window closed, went to the background,
/// or showed another thread), one of them takes it over. A view that can't run the thread
/// (`rest`) suspends it only once no other view is left to run it.
@MainActor
public final class NativeThreadViewers {
    public let store: NativeThreadStore

    /// Views running or waiting to run the loop, oldest first.
    private var viewers: [UUID] = []
    /// The view whose loop runs, and the loop's task.
    private var driver: UUID?
    private var runner: Task<Void, Never>?
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    /// What a view that couldn't run the thread asked for while others still could: applied when
    /// the last of them leaves. True stops the store (its connection is gone), false suspends it.
    private var pendingRest: Bool?

    public init(store: NativeThreadStore) {
        self.store = store
    }

    /// How many views run or wait to run the thread.
    public var count: Int { viewers.count }

    /// Runs the thread's poll loop for one view until its task is cancelled: at once, taking the
    /// loop over from any other view, and again whenever the loop stops while this view still
    /// shows the thread.
    public func run(request: @escaping NativeThreadStore.Request, preview: NativeThreadStore.Preview? = nil) async {
        guard !Task.isCancelled else { return }
        let viewer = UUID()
        viewers.append(viewer)
        pendingRest = nil
        defer { leave(viewer) }
        drive(viewer, request: request, preview: preview)
        while !Task.isCancelled {
            await wait(viewer)
            if !Task.isCancelled, driver == nil, !store.isLive {
                drive(viewer, request: request, preview: preview)
            }
        }
    }

    /// A view showing the thread can't run it now (it went off screen, the app went inactive,
    /// or the host is gone). The store suspends, or stops when `detached`, unless another view
    /// still runs it; then that happens once the last of them leaves.
    public func rest(detached: Bool) {
        guard viewers.isEmpty else {
            pendingRest = (pendingRest ?? false) || detached
            return
        }
        if detached { store.stop() } else { store.suspend() }
    }

    private func drive(_ viewer: UUID, request: @escaping NativeThreadStore.Request, preview: NativeThreadStore.Preview?) {
        // The store's own run ends the one before it; cancelling the old task only ends its wait.
        runner?.cancel()
        driver = viewer
        runner = Task { [weak self] in
            await self?.store.run(request: request, preview: preview)
            self?.ended(viewer)
        }
    }

    /// A view's loop returned: it was cancelled, or the store was stopped or run by someone else.
    private func ended(_ viewer: UUID) {
        if driver == viewer {
            driver = nil
            runner = nil
        }
        wakeAll()
    }

    private func leave(_ viewer: UUID) {
        viewers.removeAll { $0 == viewer }
        if driver == viewer {
            runner?.cancel()
            runner = nil
            driver = nil
        }
        if viewers.isEmpty, let detached = pendingRest {
            pendingRest = nil
            if detached { store.stop() } else { store.suspend() }
        }
        // Everyone still here looks again: the loop may have stopped with the view that left.
        wakeAll()
    }

    private func wakeAll() {
        let woken = waiters
        waiters.removeAll()
        for waiter in woken.values { waiter.resume() }
    }

    private func wait(_ viewer: UUID) async {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                if Task.isCancelled { waiter.resume() } else { waiters[viewer] = waiter }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.waiters.removeValue(forKey: viewer)?.resume() }
        }
    }
}
