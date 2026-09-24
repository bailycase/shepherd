import AppKit
import Darwin
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import SwiftUI
@testable import ShepherdApp

/// A `ThreadView` in an off-screen window whose pi is an in-process closure: it answers each
/// snapshot request with `snapshot` (or `starting`), and accepts every action. Tests change
/// what it serves and have the store pull, as a poll would.
@MainActor
final class FakeThread {
    /// Whether the thread is on screen, and whether its layout is the visible one.
    @MainActor @Observable final class Visibility {
        var active = true
        var motionPaused = false
    }

    private struct Hosted: View {
        let visibility: Visibility
        let store: NativeThreadStore
        let request: NativeThreadStore.Request

        var body: some View {
            ThreadView(store: store, active: visibility.active, isFocused: false, request: request, commandKey: "fake")
                .environment(\.nwMotionPaused, visibility.motionPaused)
        }
    }

    let store: NativeThreadStore
    let visibility = Visibility()
    var snapshot: NativeThreadSnapshot
    /// While true, snapshot requests answer that pi is still starting.
    var starting = false
    private(set) var snapshotRequests = 0
    let window: OffscreenWindow

    init(_ snapshot: NativeThreadSnapshot, starting: Bool = false, store: NativeThreadStore = NativeThreadStore(),
         size: CGSize = CGSize(width: 900, height: 800), dark: Bool = true) {
        self.snapshot = snapshot
        self.starting = starting
        self.store = store
        window = OffscreenWindow(size: size, dark: dark)
        let request: NativeThreadStore.Request = { [weak self] value in
            guard let self else { return .failure(code: "gone", message: "harness released") }
            switch value {
            case .snapshot:
                self.snapshotRequests += 1
                if self.starting { return .failure(code: NativeThreadCode.starting, message: "pi is starting.") }
                return .snapshot(value: self.snapshot)
            case .send(_, _, let operation, _, _, _), .abort(_, _, let operation), .answer(_, _, let operation, _, _),
                 .setModel(_, _, let operation, _), .setThinking(_, _, let operation, _),
                 .subagentCommand(_, _, let operation, _, _, _, _):
                return .accepted(operationID: operation)
            default:
                return .failure(code: "x", message: "unscripted")
            }
        }
        window.show(Hosted(visibility: visibility, store: store, request: request))
    }

    /// Serves `next` and has the store pull it now, outside any animation.
    func serve(_ next: NativeThreadSnapshot) async {
        snapshot = next
        await store.refresh()
    }

    func waitUntilReady() async throws {
        let store = store
        try await eventuallyOnMain("the thread to load") { store.ready }
        ListPerf.settle(window)
    }

    func close() {
        store.stop()
        window.close()
    }
}

/// An off-screen window (as `OffscreenWindow`: borderless, far off every screen, ordered back)
/// whose hosting view counts its layout passes: a view that animates through SwiftUI lays the
/// host out on every frame, one the render server animates never does.
@MainActor
final class LayoutCountingWindow {
    final class Host: NSHostingView<AnyView> {
        var layouts = 0

        override func layout() {
            layouts += 1
            super.layout()
        }
    }

    let window: NSWindow
    let host: Host

    init(size: CGSize, dark: Bool = true, _ view: some View) {
        _ = NSApplication.shared
        window = NSWindow(contentRect: NSRect(origin: CGPoint(x: -30_000, y: -30_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host = Host(rootView: AnyView(view))
        host.appearance = window.appearance
        window.contentView = host
        window.orderBack(nil)
        window.layoutIfNeeded()
        host.layoutSubtreeIfNeeded()
    }

    func close() {
        window.orderOut(nil)
        window.contentView = nil
    }
}

/// The main thread's own CPU time: what a change or an idle stretch costs the thread that
/// draws, whatever else the machine runs. Read it on the main thread.
@MainActor
enum MainThreadCPU {
    static func now() -> Duration {
        .nanoseconds(Int64(clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID)))
    }

    /// Main-thread milliseconds spent while `work` runs (and awaits).
    static func milliseconds(_ work: () async throws -> Void) async rethrows -> Double {
        let start = now()
        try await work()
        return ListPerf.milliseconds(now() - start)
    }

    /// The median of `values`.
    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted.count.isMultiple(of: 2) ? (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2 : sorted[sorted.count / 2]
    }
}

/// Snapshots for the thread fixtures in this target's cost tests.
enum ThreadFixture {
    static let answer = Array(repeating: "Answer paragraph with enough words to wrap a line or two in the column, like a real reply.",
                              count: 3).joined(separator: "\n\n")

    static func user(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
    }

    static func assistant(_ id: String, _ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], truncated: false)
    }

    static func streaming(_ text: String) -> NativeThreadMessage {
        NativeThreadMessage(entryID: "provisional:assistant:1", role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)],
                            status: "streaming", truncated: false)
    }

    /// `count` messages, alternating a question and its answer.
    static func history(_ count: Int, prefix: String = "m") -> [NativeThreadMessage] {
        (0..<count).map { i in i % 2 == 0 ? user("\(prefix)\(i)", "Question \(i / 2)") : assistant("\(prefix)\(i)", "Answer \(i / 2). " + answer) }
    }

    static func snapshot(_ messages: [NativeThreadMessage], provisional: [NativeThreadMessage] = [], running: Bool = false,
                         revision: UInt64 = 1, olderCursor: String? = nil, stats: NativeThreadStats? = nil,
                         dialogs: [NativeThreadDialog] = [], model: String = "anthropic/claude-opus-4-5") -> NativeThreadSnapshot {
        NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: revision, running: running, model: model,
                             thinking: "medium", supportedActions: ["send", "abort", "answer", "setModel", "setThinking", "subagents"],
                             dialogsSupported: true, dialogs: dialogs, messages: messages, olderCursor: olderCursor,
                             provisional: provisional, clipped: false, runtime: "rpc", stats: stats,
                             commands: [NativeCommand(name: "review", description: "Review the working tree", source: "prompt")])
    }
}
