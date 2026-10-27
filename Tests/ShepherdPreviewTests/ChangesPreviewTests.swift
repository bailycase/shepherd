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

/// The Changes pane and its Shepherd Design parts (ChangesSplit, ChangesScope, ChangesBase,
/// ChangesUnified, ChangesLastTurn, ChangesWide, ChangesStates), in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ChangesPreviewTests
@Suite("Changes previews", .serialized, .mainActorExclusive, .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct ChangesPreviewTests {
    /// The side pane's width on the Changes boards.
    static let boardWidth: CGFloat = 1040
    static let boardHeight: CGFloat = 852

    init() {
        // Compile the grammars up front so the pane's off-main highlighting lands before the
        // capture.
        _ = CodeHighlight.highlightLines(["let warm = 1"], path: "warm.swift", style: .theme)
        _ = CodeHighlight.highlightLines(["package warm"], path: "warm.go", style: .theme)
    }

    /// The pane at the boards' width (1040pt: split), with a state opened on its model.
    private func pane(_ session: ReviewSession, width: CGFloat = boardWidth, height: CGFloat = boardHeight,
                      maximized: Bool = false, setUp: (ReviewPaneModel) -> Void = { _ in }) -> some View {
        let model = ReviewPaneModel(session: session, actions: Reviews.actions)
        setUp(model)
        return ReviewPaneContent(model: model, maximized: maximized)
            .frame(width: width, height: height)
    }

    private var boardSize: CGSize { CGSize(width: Self.boardWidth, height: Self.boardHeight) }

    /// ChangesSplit: Branch vs origin/main, split, two files viewed, a comment waiting to send.
    @Test func changesSplit() async throws {
        let session = ChangesBoard.session()
        try await Preview.render("changes-split", size: boardSize) { pane(session) }
    }

    /// ChangesScope: the scope menu with the Commits submenu open.
    @Test func changesScope() async throws {
        let session = ChangesBoard.session(comment: false)
        try await Preview.render("changes-scope", size: boardSize) { pane(session) { $0.menu = .commits } }
    }

    /// ChangesBase: the base picker under the compare row.
    @Test func changesBase() async throws {
        let session = ChangesBoard.session(comment: false)
        try await Preview.render("changes-base", size: boardSize) { pane(session) { $0.menu = .base } }
    }

    /// ChangesUnified: unified with word diffs, Diff options open.
    @Test func changesUnified() async throws {
        let session = ChangesBoard.session(comment: false)
        session.layoutChoice = .unified
        try await Preview.render("changes-unified", size: boardSize) { pane(session) { $0.menu = .options } }
    }

    /// ChangesLastTurn: just the agent's last turn, a comment being written on line 103.
    @Test func changesLastTurn() async throws {
        let session = ChangesBoard.lastTurnSession()
        let file = session.files[0]
        let line = try #require(file.hunks.flatMap(\.lines).first { $0.newLine == 103 })
        try await Preview.render("changes-last-turn", size: boardSize) {
            pane(session) { $0.editing = ReviewSession.CommentKey(fileID: file.id, lineID: line.id) }
        }
    }

    /// ChangesWide: maximized, with the file list.
    @Test func changesWide() async throws {
        let session = ChangesBoard.session()
        try await Preview.render("changes-wide", size: CGSize(width: 1548, height: Self.boardHeight)) {
            pane(session, width: 1548, maximized: true) { $0.currentFile = session.files[0].id }
        }
    }

    /// Under 900pt the pane is unified until the reader picks split.
    @Test func changesNarrow() async throws {
        let session = ChangesBoard.session()
        try await Preview.render("changes-narrow", size: CGSize(width: AppLayout.paneDefaultWidth, height: 720)) {
            pane(session, width: AppLayout.paneDefaultWidth, height: 720)
        }
    }

    /// Narrow and unified with Wrap lines on: long lines wrap under their numbers.
    @Test func changesWrapped() async throws {
        let session = ChangesBoard.session()
        session.wrapLines = true
        try await Preview.render("changes-wrapped", size: CGSize(width: AppLayout.paneDefaultWidth, height: 720)) {
            pane(session, width: AppLayout.paneDefaultWidth, height: 720)
        }
    }

    /// Scrolled into the first file: its header stays pinned over the diff.
    @Test func changesScrolled() async throws {
        let session = ChangesBoard.session()
        let probe = ViewProbe()
        try await Preview.render("changes-scrolled", size: CGSize(width: Self.boardWidth, height: 560),
                                 afterReady: { probe.scrollDiff(by: 150) }) {
            pane(session, height: 560).background(probe)
        }
    }

    /// Loading, no changes, a scope with nothing to compare, and a legacy review (an older host)
    /// side by side at the pane's minimum width.
    @Test func changesStates() async throws {
        let none = ChangesBoard.listed([], scope: .uncommitted, comparison: ChangesComparison(head: "Working tree", base: "HEAD"))
        let loading = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, isLoading: true)
        loading.engine = ChangesBoard.engine([], list: none)
        let empty = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil)
        empty.engine = loading.engine
        empty.list = none
        let failed = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp", reference: nil, loadError: "No turn yet.")
        failed.engine = loading.engine
        failed.scope = .lastTurn
        failed.loadErrorIsNotice = true
        let legacy = Reviews.session()
        try await Preview.render("changes-states", size: CGSize(width: 4 * AppLayout.paneMinWidth, height: 520)) {
            HStack(spacing: 0) {
                ForEach([loading, empty, failed, legacy]) { session in
                    ReviewPane(session: session, actions: Reviews.actions).frame(width: AppLayout.paneMinWidth - 1)
                    SHHairline(.vertical)
                }
            }
        }
    }

    /// The ChangesStates board's parts: the toolbar and compare row, the send bar, the thread's
    /// card in its three states, the menus, split rows with hatching and word diffs, a fold, and
    /// file headers viewed and not.
    @Test func changesComponents() async throws {
        try await Preview.render("changes-components", size: CGSize(width: 1380, height: 1000)) {
            ChangesComponentsBoard()
        }
    }

    /// A long file (a lockfile): five- and six-digit line numbers fit their 34pt gutters.
    @Test func changesLargeLineNumbers() async throws {
        let code: [(SHDiffLineKind, Int?, Int?, String)] = [
            (.context, 9_998, 9_998, #"    "node_modules/zod": {"#),
            (.removed, 9_999, nil, #"      "version": "3.23.8","#),
            (.added, nil, 9_999, #"      "version": "3.24.1","#),
            (.context, 10_000, 10_000, #"      "license": "MIT""#),
            (.context, 123_456, 123_456, "    }"),
        ]
        let rows: [SHChangesRow] = code.enumerated().map { index, line in
            .line(SHDiffLineContent(id: "l\(index)", key: index, kind: line.0, oldNumber: line.1, newNumber: line.2,
                                    text: AttributedString(line.3), source: line.3))
        }
        try await Preview.render("changes-large-line-numbers", size: CGSize(width: 480, height: 160)) {
            VStack(spacing: 0) {
                SHFileHeader(path: "package-lock.json", status: .modified, added: 1, removed: 1, isExpanded: true, isViewed: false,
                             toggle: {}, toggleViewed: {})
                SHDiffView(rows, onReveal: { _, _ in })
            }
            .frame(maxHeight: .infinity, alignment: .top)
            .background(Color.sh.bgWindow)
        }
    }
}

/// The ChangesStates board's parts, laid out like the board.
private struct ChangesComponentsBoard: View {
    @State private var draft = "Wrap the error with the refund id too, the on-call runbook greps for it."
    @State private var on = true
    @State private var off = false
    @FocusState private var editorFocused: Bool

    private static let files: [SHFileStrip.Item] = [
        .init(id: "a", path: "ledger/outbox.go", status: .modified, added: 21, removed: 8),
        .init(id: "b", path: "ledger/refund.go", status: .added, added: 64, removed: 0, isViewed: true),
        .init(id: "c", path: "ledger/refund_test.go", status: .added, added: 96, removed: 0),
        .init(id: "d", path: "migrations/0042_refund_events.sql", status: .added, added: 18, removed: 0, isViewed: true),
    ]

    private static func line(_ id: Int, _ kind: SHDiffLineKind, _ old: Int?, _ new: Int?, _ code: String, word: String? = nil) -> SHDiffLineContent {
        var text = CodeHighlight.highlightLines([code], path: "outbox.go", style: .theme).first ?? AttributedString(code)
        if let word, let range = text.range(of: word) { text[range].backgroundColor = kind == .added ? Color.sh.doneTint : Color.sh.failedTint }
        return SHDiffLineContent(id: "l\(id)", key: id, kind: kind, oldNumber: old, newNumber: new, text: text, source: code)
    }

    private static let split: [SHChangesRow] = [
        .pair(id: "p1", old: line(1, .context, 37, 40, "type Outbox struct {"), new: line(1, .context, 37, 40, "type Outbox struct {")),
        .pair(id: "p2", old: line(2, .context, 38, 41, "\tdb    *sql.DB"), new: line(2, .context, 38, 41, "\tdb    *sql.DB")),
        .pair(id: "p3", old: line(3, .removed, 39, nil, "\tnow func() time.Time", word: "now"),
              new: line(4, .added, nil, 42, "\tnow   func() time.Time", word: "now  ")),
        .pair(id: "p4", old: nil, new: line(5, .added, nil, 43, "\tcodec events.Codec")),
        .pair(id: "p5", old: line(6, .context, 40, 44, "}"), new: line(6, .context, 40, 44, "}")),
        .fold(SHDiffFold(id: "f", count: 28)),
    ]

    private static let cardFiles = [
        SHChangedFile(path: "ledger/outbox.go", directory: "ledger/", name: "outbox.go", status: .modified, added: 21, removed: 8),
        SHChangedFile(path: "ledger/refund.go", directory: "ledger/", name: "refund.go", status: .added, added: 64, removed: 0),
        SHChangedFile(path: "ledger/refund_test.go", directory: "ledger/", name: "refund_test.go", status: .added, added: 96, removed: 0),
    ]

    var body: some View {
        let sh = Color.sh
        VStack(alignment: .leading, spacing: SH.Space.xxl) {
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                VStack(spacing: 0) {
                    HStack(spacing: 10) {
                        SHScopeButton(title: "Branch", glyph: .branch, isOpen: false) {}
                        SHDiffStat(added: 200, removed: 8, font: .sh(.code))
                        Spacer()
                        SHViewedPill(viewed: 2, total: 5)
                        Button {} label: { Label("Commit…", systemImage: "smallcircle.filled.circle") }.buttonStyle(.sh(.secondary, size: .s))
                    }
                    .padding(.horizontal, SH.Space.l)
                    .frame(height: SHChangesMetrics.toolbarHeight)
                    SHCompareRow(head: "agent/refund-events", base: "origin/main", note: "merge base 3f2a91c") {}
                    SHFileStrip(Self.files, selection: "a") { _ in }
                }
                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                .frame(width: 620)
                SHReviewSendBar(count: "2 comments", detail: "on outbox.go, not sent yet", onDiscard: {}, onSend: {})
                    .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                    .frame(width: 620)
            }
            HStack(alignment: .top, spacing: SH.Space.xxl) {
                SHChangesCard(title: "Edited 5 files", added: 200, removed: 8, files: Self.cardFiles, total: 5,
                              onReview: {}, onOpen: { _ in }, onUndo: {})
                    .frame(width: 420)
                SHChangesCard(title: "Undid the agent’s edits to 5 files", added: 200, removed: 8, files: [], total: 5, phase: .undone,
                              onRedo: {})
                    .frame(width: 420)
                SHChangesCard(title: "Edited 2 files", added: 12, removed: 3, files: Array(Self.cardFiles.prefix(2)),
                              notice: "Didn’t undo: outbox.go changed after the turn. Nothing was touched.", onReview: {}, onUndo: {})
                    .frame(width: 420)
            }
            HStack(alignment: .top, spacing: SH.Space.xl) {
                SHChangesMenu(width: SHChangesMenuMetrics.scopeWidth) {
                    SHChangesMenuRow("Last turn", subtitle: "What the agent changed since your last message",
                                     systemImage: SHChangesScopeGlyph.lastTurn.systemImage, trailing: .stat(added: 12, removed: 3)) {}
                    SHChangesMenuDivider()
                    SHChangesMenuRow("Uncommitted", systemImage: SHChangesScopeGlyph.uncommitted.systemImage, trailing: .stat(added: 33, removed: 11)) {}
                    SHChangesMenuRow("Unstaged", systemImage: nil, trailing: .stat(added: 21, removed: 8)) {}
                    SHChangesMenuRow("Staged", systemImage: nil, trailing: .stat(added: 12, removed: 3)) {}
                    SHChangesMenuDivider()
                    SHChangesMenuRow("Commits", systemImage: SHChangesScopeGlyph.commits.systemImage, trailing: .text("4"), hasSubmenu: true) {}
                    SHChangesMenuRow("Branch", subtitle: "agent/refund-events vs origin/main", systemImage: SHChangesScopeGlyph.branch.systemImage,
                                     trailing: .stat(added: 200, removed: 8), checked: true) {}
                    SHChangesMenuRow("Pull request", systemImage: SHChangesScopeGlyph.pullRequest.systemImage, trailing: .text("#31 draft")) {}
                }
                SHChangesMenu(width: SHChangesMenuMetrics.optionsWidth) {
                    SHChangesMenuTitle("Diff")
                    SHChangesMenuToggle("Word diffs", systemImage: "text.word.spacing", isOn: $on)
                    SHChangesMenuToggle("Hide whitespace changes", systemImage: "space", isOn: $off)
                    SHChangesMenuToggle("Load full files", subtitle: "Expand past folds without a round trip", systemImage: "folder", isOn: $on)
                    SHChangesMenuDivider()
                    SHChangesMenuRow("Copy git apply command", systemImage: "terminal") {}
                    SHChangesMenuRow("Copy as patch", systemImage: "doc.on.doc") {}
                    SHChangesMenuRow("Open in your editor", systemImage: "arrow.up.forward.square", trailing: .text("⇧⌘O")) {}
                }
                VStack(spacing: 0) {
                    SHFileHeader(path: "ledger/outbox.go", status: .modified, added: 21, removed: 8, isExpanded: true, isViewed: false,
                                 toggle: {}, toggleViewed: {}, comment: {}, open: {})
                    SHDiffView(Self.split, notes: [5: true], onComment: { _ in }, onReveal: { _, _ in }) { _, _ in
                        SHCommentEditor(text: $draft, isFocused: $editorFocused, context: "on line 43", onSave: {}, onCancel: {})
                    }
                    SHFileHeader(path: "ledger/refund.go", status: .added, added: 64, removed: 0, isExpanded: false, isViewed: true,
                                 toggle: {}, toggleViewed: {}, comment: {}, open: {})
                }
                .clipShape(RoundedRectangle(cornerRadius: SH.Radius.m))
                .shBorder(sh.lineSubtle, radius: SH.Radius.m)
                .frame(width: 600)
            }
        }
        .padding(SH.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(sh.bgWindow)
    }
}
