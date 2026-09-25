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

/// The docked review pane and its Night Watch parts (Review board), in light and dark:
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

    /// The board's review: a modified file with a folded removed run and an inline comment, a
    /// second modified file the agent is editing, an added file, and a deleted file.
    @Test func reviewPane() async throws {
        let session = BoardReview.session()
        try await Preview.render("review-pane", size: CGSize(width: AppLayout.paneDefaultWidth, height: 900)) {
            ReviewPane(session: session, actions: Reviews.actions, touchedPaths: ["App/iOS/ThreadView.swift"])
        }
    }

    /// Scrolled into the first file: its header stays pinned over the diff.
    @Test func reviewPaneScrolled() async throws {
        let session = BoardReview.session()
        let probe = ViewProbe()
        try await Preview.render("review-pane-scrolled", size: CGSize(width: AppLayout.paneDefaultWidth, height: 560),
                                 afterReady: { probe.scrollDiff(by: 150) }) {
            ReviewPane(session: session, actions: Reviews.actions).background(probe)
        }
    }

    /// At the pane's minimum width, with the older two-file fixture (M and A) and a summary.
    @Test func reviewPaneNarrow() async throws {
        let session = Reviews.session()
        try await Preview.render("review-pane-narrow", size: CGSize(width: AppLayout.paneMinWidth, height: 720)) {
            ReviewPane(session: session, actions: Reviews.actions)
        }
    }

    /// Loading, no changes (in a worktree other than the agent's, which the header names), and a
    /// failed load, side by side.
    @Test func reviewPaneStates() async throws {
        let loading = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, isLoading: true)
        let empty = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/shepherd-worktree", agentCwd: "/tmp/shepherd",
                                  reference: "main..HEAD")
        let failed = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil,
                                   loadError: "git diff failed: not a git repository")
        try await Preview.render("review-pane-states", size: CGSize(width: 1440, height: 420)) {
            HStack(spacing: 0) {
                ForEach([loading, empty, failed]) { session in
                    ReviewPane(session: session, actions: Reviews.actions)
                    NWHairline(.vertical)
                }
            }
        }
    }

    /// A host that commits from review: Commit… beside Ask agent to commit, at the pane's
    /// narrowest.
    @Test func reviewPaneWithCommit() async throws {
        let session = Reviews.session()
        var actions = Reviews.actions
        actions.canCommitDirectly = { true }
        try await Preview.render("review-pane-commit", size: CGSize(width: AppLayout.paneMinWidth, height: 720)) {
            ReviewPane(session: session, actions: actions)
        }
    }

    /// The Commit… sheet (derived from the iPadCommit board): the drafted message, three files
    /// with one left out, and the options; drafting; an agent still working; a checkout it
    /// refuses; then the host's steps running, done with a pull request, stopped at a push, and
    /// a commit the host no longer knows (after a restart).
    @Test(arguments: ["form", "drafting", "working", "blocked", "pr-default", "running", "done", "failed", "unknown"])
    func commitSheet(_ state: String) async throws {
        let store = await CommitBoard.store(state)
        try await Preview.render("sheet-commit-\(state)", size: CGSize(width: AppLayout.commitSheetWidth, height: 720)) {
            ReviewCommitSheet(store: store, askAgent: {}, close: {}, staged: true)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Color.nw.bgWindow)
        }
    }

    /// The board's parts on their own: the strip (M, A, D, selection, viewed, touched), file
    /// headers, a diff with a fold, a comment and an open editor, and the composer.
    @Test func reviewComponents() async throws {
        try await Preview.render("review-components", size: CGSize(width: 1100, height: 620)) {
            ReviewBoard()
        }
    }

    /// A long file (a lockfile): five- and six-digit line numbers fit their 36pt gutters.
    @Test func reviewDiffLargeLineNumbers() async throws {
        let code: [(NWDiffLineKind, Int?, Int?, String)] = [
            (.context, 9_998, 9_998, #"    "node_modules/zod": {"#),
            (.removed, 9_999, nil, #"      "version": "3.23.8","#),
            (.added, nil, 9_999, #"      "version": "3.24.1","#),
            (.context, 10_000, 10_000, #"      "license": "MIT""#),
            (.context, 123_456, 123_456, "    }"),
        ]
        let rows: [NWDiffRow] = [.hunk(id: "h", header: "@@ -9998,5 +9998,5 @@")] + code.enumerated().map { index, line in
            .line(NWDiffLineContent(id: "l\(index)", key: index, kind: line.0, oldNumber: line.1, newNumber: line.2,
                                    text: AttributedString(line.3), source: line.3))
        }
        try await Preview.render("review-diff-large-line-numbers", size: CGSize(width: 480, height: 150)) {
            VStack(spacing: 0) {
                NWFileHeader(path: "package-lock.json", hunkCount: 1, isExpanded: true, isViewed: false, toggle: {}, toggleViewed: {})
                NWDiffView(rows, onExpand: { _ in })
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.nw.bgWindow)
        }
    }
}

/// The Review board's FleetView change as a real diff.
private enum BoardReview {
    static let diff: String = {
        let removed = [
            "        Section {",
            "          if let configuration = connection.configuration {",
            "            LabeledContent(\"Host\", value: configuration.host)",
            "            LabeledContent(\"Port\", value: \"\\(configuration.port)\")",
            "            LabeledContent(\"Token\", value: \"••••••\")",
            "            LabeledContent(\"Phase\", value: connection.phase.label)",
            "            if let error = connection.lastError {",
            "              Text(error).foregroundStyle(.red)",
            "            }",
            "            if connected {",
            "              LabeledContent(\"Agents\", value: \"\\(connection.agents.count)\")",
            "              LabeledContent(\"Latency\", value: connection.latency.formatted())",
            "            }",
            "          } else {",
            "            ContentUnavailableView(\"No host\", systemImage: \"desktopcomputer\")",
            "          }",
            "          HStack {",
            "            Spacer()",
            "              Button(\"reconnect\") { connection.reconnect() }",
        ].map { "-" + $0 }.joined(separator: "\n")
        return """
        diff --git a/App/iOS/FleetView.swift b/App/iOS/FleetView.swift
        index 1111111..2222222 100644
        --- a/App/iOS/FleetView.swift
        +++ b/App/iOS/FleetView.swift
        @@ -12,26 +12,10 @@ struct FleetView: View {
             let connected = connection.phase == .connected
             var body: some View {
               List {
        \(removed)
        +        Section {
        +          HostCard(connection: connection)
        +        }
                 Section {
                   ForEach(connection.agents) { agent in
        @@ -80,4 +64,6 @@ struct FleetView: View {
               .navigationTitle("Fleet")
        -      .toolbar { refreshButton }
        +      .toolbar {
        +        ToolbarItem { refreshButton }
        +      }
             }
        diff --git a/App/iOS/ThreadView.swift b/App/iOS/ThreadView.swift
        index 3333333..4444444 100644
        --- a/App/iOS/ThreadView.swift
        +++ b/App/iOS/ThreadView.swift
        @@ -40,5 +40,6 @@ struct ThreadView: View {
             var body: some View {
        -        ScrollView {
        +        ScrollView(.vertical) {
        +            HostCard(connection: connection)
                     LazyVStack(alignment: .leading, spacing: 0) {
        diff --git a/App/iOS/HostCard.swift b/App/iOS/HostCard.swift
        new file mode 100644
        index 0000000..5555555
        --- /dev/null
        +++ b/App/iOS/HostCard.swift
        @@ -0,0 +1,8 @@
        +import SwiftUI
        +
        +struct HostCard: View {
        +    let connection: RemoteConnection
        +    var body: some View {
        +        LabeledContent("Host", value: connection.host)
        +    }
        +}
        diff --git a/App/iOS/MobileTokens.swift b/App/iOS/MobileTokens.swift
        deleted file mode 100644
        index 6666666..0000000
        --- a/App/iOS/MobileTokens.swift
        +++ /dev/null
        @@ -1,4 +0,0 @@
        -enum MobileTokens {
        -    static let rowHeight: CGFloat = 44
        -    static let radius: CGFloat = 10
        -}
        """
    }()

    @MainActor static func session() -> ReviewSession {
        let files = GitDiff.parse(diff)
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/Shepherd", reference: nil)
        session.files = files
        if let file = files.first, let line = file.hunks.first?.lines.last(where: { $0.kind == .removed }) {
            session.comments = [ReviewComment(fileID: file.id, lineID: line.id, filePath: file.displayPath, lineNumber: line.oldLine ?? 0,
                                              marker: "-", content: line.text,
                                              text: "Keep reconnect reachable from the row — flaky Wi-Fi users lose the one-tap retry.")]
        }
        return session
    }
}

/// The board's parts, laid out like the board.
private struct ReviewBoard: View {
    @State private var draft = "Name this constant"
    @State private var summary = ""
    @FocusState private var editorFocused: Bool
    @FocusState private var composerFocused: Bool

    private static let files: [NWFileStrip.Item] = [
        .init(id: "a", path: "App/iOS/FleetView.swift", status: .modified, added: 10, removed: 54),
        .init(id: "b", path: "App/iOS/ThreadView.swift", status: .modified, added: 48, removed: 3, isTouched: true),
        .init(id: "c", path: "App/iOS/HostCard.swift", status: .added, added: 31, removed: 0),
        .init(id: "d", path: "App/iOS/MobileTokens.swift", status: .deleted, added: 0, removed: 88, isViewed: true),
    ]

    @MainActor private static let rows: [NWDiffRow] = {
        let code: [(NWDiffLineKind, Int?, Int?, String)] = [
            (.context, 12, 12, "    let connected = connection.phase == .connected"),
            (.removed, 15, nil, "        Section {"),
            (.removed, 16, nil, "          if let configuration = connection.configuration {"),
            (.removed, 33, nil, "              Button(\"reconnect\") { connection.reconnect() }"),
            (.added, nil, 15, "        Section {"),
            (.added, nil, 16, "          HostCard(connection: connection)"),
            (.context, 60, 17, "        Section {"),
        ]
        let colored = CodeHighlight.highlightLines(code.map(\.3), path: "FleetView.swift", style: .theme)
        var rows: [NWDiffRow] = [.hunk(id: "h", header: "@@ -12,55 +12,10 @@ struct FleetView: View {")]
        for (index, line) in code.enumerated() {
            if index == 3 { rows.append(.fold(id: "f", count: 13, kind: .removed, range: "18–32")) }
            rows.append(.line(NWDiffLineContent(id: "l\(index)", key: index, kind: line.0, oldNumber: line.1, newNumber: line.2,
                                                text: colored[index], source: line.3)))
        }
        return rows
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: NW.Space.xxl) {
            NWFileStrip(Self.files, selection: "a") { _ in }
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                .frame(width: 720)
            HStack(alignment: .top, spacing: NW.Space.xxl) {
                VStack(spacing: 0) {
                    NWFileHeader(path: "App/iOS/FleetView.swift", hunkCount: 2, commentCount: 1, isExpanded: true, isViewed: false,
                                 toggle: {}, toggleViewed: {}, revert: {}, open: {})
                    NWDiffView(Self.rows, onComment: { _ in }, onExpand: { _ in }) { line in
                        if line.key == 3 {
                            NWInlineComment(initial: ReviewAuthor.initial, author: "You", meta: "line 33 · just now",
                                            text: "Keep reconnect reachable from the row — flaky Wi-Fi users lose the one-tap retry.",
                                            onEdit: {}, onDelete: {})
                        } else if line.key == 5 {
                            NWCommentEditor(text: $draft, isFocused: $editorFocused, onSave: {}, onCancel: {})
                        }
                    }
                    NWFileHeader(path: "README.md", hunkCount: 1, isExpanded: false, isViewed: true, toggle: {}, toggleViewed: {})
                }
                .clipShape(RoundedRectangle(cornerRadius: NW.Radius.m))
                .nwBorder(Color.nw.lineSubtle, radius: NW.Radius.m)
                .frame(width: 560)
                VStack(alignment: .leading, spacing: NW.Space.xxl) {
                    NWReviewComposer(text: $summary, isFocused: $composerFocused, inlineCount: 1, canCommit: true, canRequestChanges: true,
                                     onCommit: {}, onRequestChanges: {})
                    NWReviewComposer(text: .constant("Close — one structural note."), isFocused: $composerFocused, inlineCount: 0,
                                     canCommit: false, canRequestChanges: false, onCommit: {}, onRequestChanges: {})
                }
                .frame(width: 440)
            }
        }
        .padding(NW.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.nw.bgWindow)
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
        case "drafting": store.stage(info(), drafting: true)
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
private final class ViewProbeBox {
    weak var view: NSView?
}

private struct ViewProbe: NSViewRepresentable {
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
