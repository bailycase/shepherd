import AppKit
import ShepherdProtocol
import ShepherdRemote
import Foundation
import ShepherdCore
import ShepherdUI
import SwiftUI
import ShepherdTestSupport
import Testing
@testable import ShepherdApp

/// The Commit… sheet, in light and dark (the Changes pane's own renders are `ChangesPreviewTests`):
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ReviewPreviewTests
@Suite("Review previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ReviewPreviewTests {
    init() {
        // Compile the Swift grammar up front so the pane's off-main highlighting lands before the
        // capture.
        _ = CodeHighlight.highlightLines(["let warm = 1"], path: "warm.swift", style: .theme)
    }

    /// The Commit… sheet (derived from the iPadCommit board): the message drafted for two of
    /// three files, the third left out, and the options; the message written from the file list, following the
    /// ticked files; drafting; the draft kept while it is drafted again for the ticked files; an
    /// edited message that may mention an unticked file; an agent still working; a checkout it
    /// refuses; then the host's steps running, done with a pull request, stopped at a push, and
    /// a commit the host no longer knows (after a restart).
    @Test(arguments: ["form", "written", "drafting", "redrafting", "edited", "working", "blocked", "pr-default", "running", "done", "failed",
                      "unknown"])
    func commitSheet(_ state: String) async throws {
        let store = await CommitBoard.store(state)
        try await Preview.render("sheet-commit-\(state)", size: CGSize(width: AppLayout.commitSheetWidth, height: 720)) {
            ReviewCommitSheet(store: store, askAgent: {}, close: {}, staged: true)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    /// The message arriving after the sheet appeared grows the description to every line: the
    /// host's two-line plain message once the checkout is read ("loaded"), and a three-line draft
    /// replacing a one-line message ("drafted"). The host answers only once the sheet has drawn
    /// its loading (or drafting) state.
    @Test(arguments: ["loaded", "drafted"])
    func commitSheetMessageArrivingLater(_ state: String) async throws {
        let files = state == "loaded" ? Array(CommitBoard.files.prefix(2)) : [CommitBoard.files[1]]
        let plain = reviewCommitFallbackMessage(files)
        let info = RemoteCommitInfo(repository: "/Users/ada/Developer/Shepherd", branch: "feat/tool-rows", head: "abc",
                                    upstream: "origin/feat/tool-rows", pushRemote: "origin", defaultBranch: "main", files: files,
                                    title: plain.title, body: plain.body, draftsMessage: state == "drafted", agentWorking: false, blocked: nil)
        // A fresh store and host for each appearance, so each render sees the message arrive.
        var store = ReviewCommitStore()
        var gate = HostGate()
        func fresh() -> ReviewCommitStore {
            let host = HostGate()
            gate = host
            store = ReviewCommitStore { query in
                switch query {
                case .commitInfo:
                    if state == "loaded" { await host.wait() }
                    return .commitInfo(info)
                default:
                    await host.wait()
                    return .commitMessage(title: CommitBoard.title, body: "- Tool rows preview the command or path.\n- Adds NativePresentationTests.\n- Keeps the old text for unknown tools.", drafted: true)
                }
            }
            return store
        }
        try await Preview.render("sheet-commit-late-\(state)", size: CGSize(width: AppLayout.commitSheetWidth, height: 720), ready: {
            // The waiting sheet has been laid out by now: let the host answer.
            if gate.waiting { gate.open() }
            return gate.opened && store.stage == .form && !store.drafting
        }) {
            // Sized to its content, as a sheet's window is.
            ReviewCommitSheet(store: fresh(), askAgent: {}, close: {})
                .background(Color.nw.bgWindow)
        }
    }

}

/// The iPadCommit board's commit: three files, the message drafted from the diff.
@MainActor
enum CommitBoard {
    static let files = [
        RemoteCommitFile(path: "Sources/ShepherdApp/DesktopNativeThreadView.swift", status: "M", added: 58, removed: 41, fingerprint: "a"),
        RemoteCommitFile(path: "App/iOS/FleetView.swift", status: "M", added: 9, removed: 7, fingerprint: "b"),
        RemoteCommitFile(path: "Tests/ShepherdAppTests/NativePresentationTests.swift", status: "A", added: 30, removed: 0, fingerprint: "c"),
    ]

    static func info(branch: String = "feat/tool-rows", upstream: String? = "origin/feat/tool-rows", working: Bool = false,
                     blocked: String? = nil) -> RemoteCommitInfo {
        let plain = reviewCommitFallbackMessage(files)
        return RemoteCommitInfo(repository: "/Users/ada/Developer/Shepherd", branch: branch, head: "abc", upstream: upstream,
                                pushRemote: "origin", defaultBranch: "main", files: files, title: plain.title, body: plain.body,
                                draftsMessage: true, agentWorking: working, blocked: blocked)
    }

    static let title = "Show commands and paths in tool rows"
    static let body = "Tool rows now preview the command or path instead of \u{201C}complete\u{201D}. Adds NativePresentationTests to cover the preview text on macOS and iOS."

    static func store(_ state: String) async -> ReviewCommitStore {
        let store = ReviewCommitStore()
        let operationID = UUID()
        switch state {
        case "written":
            store.stage(info())
            store.toggle("App/iOS/FleetView.swift")
        case "drafting": store.stage(info(), drafting: true)
        case "redrafting":
            // A host that drafts, and a pause that never ends: the redraft stays asked for.
            store.stage(info(), title: title, body: body, drafted: true)
            store.query = { _ in throw ReviewCommitRefusal("The preview asks the host nothing.") }
            store.pause = { _ in throw CancellationError() }
            store.toggle("App/iOS/FleetView.swift")
        case "edited":
            store.stage(info(), title: title, body: body + " FleetView keeps its rows.", drafted: true)
            store.body += "\n\nEdited by hand."
            store.toggle("App/iOS/FleetView.swift")
        case "working": store.stage(info(working: true), title: title, body: body, drafted: true)
        case "blocked": store.stage(info(blocked: "A rebase is in progress in this checkout. Finish or abort it first."))
        case "pr-default":
            store.stage(info(branch: "main", upstream: "origin/main"), title: title, body: body, drafted: true)
            store.pullRequest = true
        case "running":
            store.stage(info(), title: title, body: body, drafted: true)
            store.adopt(RemoteWorktreeOperation(id: operationID, progress: [
                "check the checkout: on feat/tool-rows", "commit 3 files: committed 1a2b3c4", "push to origin/feat/tool-rows: working…",
                "open a pull request into main: pending",
            ]))
        case "done":
            store.stage(info(), title: title, body: body, drafted: true)
            store.adopt(RemoteWorktreeOperation(id: operationID, finished: true, progress: [
                "check the checkout: on feat/tool-rows", "commit 3 files: committed 1a2b3c4", "push to origin/feat/tool-rows: pushed",
                "open a pull request into main: https://github.com/ada/shepherd/pull/131",
            ], prURL: "https://github.com/ada/shepherd/pull/131"))
        case "failed":
            store.stage(info(), title: title, body: body, drafted: true)
            let rejected = WorktreeFinalizer.failureDetail(.init(status: 1, stdout: "", stderr: """
                To github.com:ada/shepherd.git
                 ! [rejected]        HEAD -> feat/tool-rows (fetch first)
                error: failed to push some refs to 'github.com:ada/shepherd.git'
                """))
            store.adopt(RemoteWorktreeOperation(id: operationID, finished: true,
                                                error: "Committed 1a2b3c4 on feat/tool-rows; the push failed. Nothing else changed.",
                                                progress: ["check the checkout: on feat/tool-rows", "commit 3 files: committed 1a2b3c4",
                                                           "push to origin/feat/tool-rows: failed: \(rejected)"]))
        case "unknown":
            store.stage(info(), title: title, body: body, drafted: true)
            store.adopt(RemoteWorktreeOperation(id: operationID, progress: ["check the checkout: on feat/tool-rows", "commit 3 files: working…"]))
            // The Mac host's answer for an operation it never took, read as the sheet reads it.
            store.query = { _ in
                throw ReviewCommitRefusal("Operation is unknown. It may predate a host restart. Check the repository before committing again.")
            }
            await store.pollOnce()
            store.query = nil
        default:
            store.stage(info(), title: title, body: body, drafted: true)
            store.toggle("App/iOS/FleetView.swift")
        }
        return store
    }
}

/// Finds the diff's scroll view from inside the rendered window and scrolls it, as a reader
/// would with the wheel (no events are posted).
@MainActor
final class ViewProbeBox {
    weak var view: NSView?
}

struct ViewProbe: NSViewRepresentable {
    let box = ViewProbeBox()

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        box.view = view
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    @MainActor func scrollDiff(by offset: CGFloat) {
        guard let root = box.view?.window?.contentView else { return }
        let scrollView = Self.scrollViews(in: root).max { $0.documentView?.frame.height ?? 0 < $1.documentView?.frame.height ?? 0 }
        guard let scrollView else { return }
        scrollView.contentView.scroll(to: NSPoint(x: 0, y: offset))
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    private static func scrollViews(in view: NSView) -> [NSScrollView] {
        let nested = view.subviews.flatMap(scrollViews(in:))
        guard let scrollView = view as? NSScrollView else { return nested }
        return [scrollView] + nested
    }
}


/// A host's answer held until the test opens it.
@MainActor
final class HostGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var opened = false
    var waiting: Bool { !continuations.isEmpty }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { continuations.append($0) }
    }

    func open() {
        opened = true
        continuations.forEach { $0.resume() }
        continuations = []
    }
}
