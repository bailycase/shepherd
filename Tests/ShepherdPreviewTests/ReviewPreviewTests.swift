import AppKit
import Foundation
import ShepherdCore
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The docked review pane and its Night Watch parts (Review board), in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ReviewPreviewTests
@Suite("Review previews", .serialized, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
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

    /// Loading, no changes, and a failed load, side by side.
    @Test func reviewPaneStates() async throws {
        let loading = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, isLoading: true)
        let empty = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: "main..HEAD")
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

    /// The board's parts on their own: the strip (M, A, D, selection, viewed, touched), file
    /// headers, a diff with a fold, a comment and an open editor, and the composer.
    @Test func reviewComponents() async throws {
        try await Preview.render("review-components", size: CGSize(width: 1100, height: 620)) {
            ReviewBoard()
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
