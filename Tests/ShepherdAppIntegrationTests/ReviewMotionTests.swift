import AppKit
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// The Changes pane in motion, recorded from off-screen windows (`MotionProbe`): folds and
/// comments ease open and shut (a big file, or one read under its pinned header, folds at once),
/// one side's diff cross-fades into the other's, a reload of the same side lands at once,
/// ticking a file viewed pops its check, and keyboard navigation lands at once where a click
/// scrolls.
@Suite("Review motion", .mainActorExclusive, .timingSensitive)
@MainActor
struct ReviewMotionTests {
    private static let size = CGSize(width: 600, height: 500)
    /// The diff below the pane's toolbar (44pt), compare row (32pt) and file strip (38pt), from
    /// its first file header down.
    private static let diff = CGRect(x: 0, y: 114, width: 600, height: 300)
    /// A column clear of the code, where unchanged lines draw nothing.
    private static let margin = CGRect(x: 560, y: diff.minY, width: 1, height: diff.height)

    /// A modified file of `count` lines, alternating added and unchanged so that no run folds:
    /// one row per line under its hunk header. Each file's code names the file.
    private static func file(_ name: String, lines count: Int) -> DiffFile {
        let stem = name.split(separator: ".").first.map(String.init) ?? name
        let lines = (0..<count).map { index in
            DiffLine(kind: index.isMultiple(of: 2) ? .added : .context, text: "let \(stem)Value\(index) = compute(\(index))",
                     oldLine: index.isMultiple(of: 2) ? nil : index, newLine: index + 1, id: index)
        }
        return DiffFile(oldPath: name, newPath: name, displayPath: name, isNew: false, isDeleted: false, isRenamed: false, isBinary: false,
                        hunks: [DiffHunk(header: "@@ -1,\(count) +1,\(count) @@", lines: lines)])
    }

    private static func pane(_ files: [DiffFile], reduceMotion: Bool = false) -> (ReviewPaneModel, OffscreenWindow) {
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/repo", reference: nil, files: files)
        let model = ReviewPaneModel(session: session, actions: ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}))
        let window = OffscreenWindow(size: size, dark: false,
                                     ReviewPaneContent(model: model).environment(\._accessibilityReduceMotion, reduceMotion))
        return (model, window)
    }

    // MARK: Folds

    @Test func foldingAFileEasesItShut() async {
        let (model, window) = Self.pane([Self.file("a.txt", lines: 6), Self.file("b.txt", lines: 6)])
        defer { window.close() }

        let recording = await MotionProbe.record(window, region: Self.diff) { model.toggleFolded("a.txt") }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the file folds")
        #expect(!recording.inBetween.isEmpty, "the rows ease away")
    }

    /// Rule 3 of the motion pass: past `ReviewPaneModel.easedRowLimit` rows the diff changes at
    /// once, and only the chevron turns.
    @Test func aBigFileFoldsAtOnceWhileItsChevronStillTurns() async {
        let (model, window) = Self.pane([Self.file("big.txt", lines: ReviewPaneModel.easedRowLimit + 10), Self.file("b.txt", lines: 6)])
        defer { window.close() }
        let recording = await MotionProbe.record(window, region: Self.diff) { model.toggleFolded("big.txt") }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the file folds")
        #expect(!recording.inBetween.isEmpty, "the chevron turns")
        let moving = recording.inBetween.compactMap { $0.lastColumn(differingFrom: recording.settled) }
        #expect(moving.allSatisfy { $0 < Int(NWDiffMetrics.numberWidth) }, "only the chevron moves: columns up to \(moving.max() ?? -1)")
    }

    @Test(arguments: [false, true])
    func aCommentEditorOpensUnderItsLineAndOnlyFadesUnderReduceMotion(reduceMotion: Bool) async throws {
        let (model, window) = Self.pane([Self.file("a.txt", lines: 6)], reduceMotion: reduceMotion)
        defer { window.close() }

        // Under an added line, so the unchanged line below it leaves the margin empty.
        let recording = await MotionProbe.record(window, region: Self.margin) { model.startComment(fileID: "a.txt", lineID: 0) }

        #expect(!recording.inBetween.isEmpty, "the editor eases open")
        let rest = try #require(recording.settled.firstRow(differingFrom: recording.before), "the editor opens")
        let above = recording.inBetween.filter { ($0.firstRow(differingFrom: recording.settled) ?? .max) < rest }
        if reduceMotion {
            #expect(above.isEmpty, "the editor fades in where it rests (\(rest))")
        } else {
            #expect(!above.isEmpty, "the editor nudges down into place (\(rest))")
        }
    }

    /// Folding the file being read, under its pinned header, moves the diff under the reader
    /// (the next files take the folded rows' place): easing that only shows blank gaps and
    /// fading rows, so it lands at once, and only the chevron may turn.
    @Test func foldingAFileReadUnderItsPinnedHeaderLandsAtOnce() async throws {
        let (model, window) = Self.pane((0..<5).map { Self.file("f\($0).txt", lines: 16) })
        defer { window.close() }
        let scroll = try #require(Self.diffScroll(window))
        // Into the middle of the third file, its header pinned over its rows.
        scroll.contentView.scroll(to: NSPoint(x: 0, y: (scroll.documentView?.frame.height ?? 0) * 0.45))
        scroll.reflectScrolledClipView(scroll.contentView)
        _ = await MotionProbe.record(window, region: Self.diff, timeout: 0.5) {}

        let recording = await MotionProbe.record(window, region: Self.diff) { model.toggleFolded("f2.txt") }

        #expect(recording.settled.firstRow(differingFrom: recording.before) != nil, "the file folds")
        let moving = recording.inBetween.compactMap { $0.lastColumn(differingFrom: recording.settled) }
        #expect(moving.allSatisfy { $0 < Int(NWDiffMetrics.numberWidth) }, "only the chevron moves: columns up to \(moving.max() ?? -1)")
    }

    private static func diffScroll(_ window: OffscreenWindow) -> NSScrollView? {
        func all(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(all) }
        return all(window.host).max { ($0.documentView?.frame.height ?? 0) < ($1.documentView?.frame.height ?? 0) }
    }

    // MARK: Local | PR

    @Test func switchingToThePRDiffCrossFadesTheWholeDiffInPlace() async throws {
        let (model, window) = Self.pane([Self.file("local.txt", lines: 4)])
        defer { window.close() }
        let session = model.session
        // Asking for the PR diff reloads it; the local diff stays until the PR's lands.
        session.isPRMode = true
        session.isLoading = true
        window.layout()
        let body = CGRect(x: 100, y: Self.diff.minY + 40, width: 400, height: Self.diff.height - 40)

        let recording = await MotionProbe.record(window, region: body) {
            session.files = [Self.file("pr.txt", lines: 4), Self.file("shared.txt", lines: 2)]
            session.isLoading = false
        }

        #expect(!recording.inBetween.isEmpty, "the diffs cross-fade")
        let empty = (x: 0, y: Int(body.height) - 1)
        let away = recording.inBetween.flatMap { $0.columnsAway(from: recording.before, recording.settled, empty: empty) }
        #expect(away.isEmpty, "nothing slides: \(Set(away).sorted().prefix(8))")
    }

    /// A reload of the same side (here after a Revert) lands at once in the diff: easing its
    /// sections under a pinned header mid-scroll opens blank gaps. The strip closes up over the
    /// chip that left.
    @Test func aRevertedFileLeavesTheDiffAtOnceWhileTheStripClosesUp() async {
        let files = [Self.file("a.txt", lines: 4), Self.file("b.txt", lines: 4), Self.file("c.txt", lines: 4)]
        let (model, window) = Self.pane(files)
        defer { window.close() }
        let strip = Self.strip

        let diff = await MotionProbe.record(window, region: Self.diff, timeout: 1) { model.session.files = files.filter { $0.id != "a.txt" } }
        #expect(diff.settled.firstRow(differingFrom: diff.before) != nil, "the file leaves")
        #expect(diff.inBetween.isEmpty, "the diff lands at once")

        let chips = await MotionProbe.record(window, region: strip) { model.session.files = files.filter { $0.id == "c.txt" } }
        #expect(!chips.inBetween.isEmpty, "the chips close up")
    }

    // MARK: Beside the thread

    /// Motion the pane starts as it opens (its strip revealing the first file) must not carry
    /// the thread's own first layout with it: the thread opens at its tail.
    @Test func aReviewOpeningBesideTheThreadLeavesTheThreadAtItsTail() async throws {
        let answer = Array(repeating: "A paragraph long enough to wrap onto a second line in a narrow thread column.", count: 3)
            .joined(separator: "\n\n")
        let messages = (0..<12).map { index in
            NativeThreadMessage(entryID: "m\(index)", role: index.isMultiple(of: 2) ? "user" : "assistant",
                                blocks: [NativeThreadBlock(kind: .text, text: index.isMultiple(of: 2) ? "Question \(index)" : answer)])
        }
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: false, supportedActions: ["send"],
                                            dialogsSupported: true, dialogs: [], messages: messages, provisional: [], clipped: false)
        let store = NativeThreadStore()
        let request: NativeThreadStore.Request = { _ in .snapshot(value: snapshot) }
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/repo", reference: nil,
                                    files: [Self.file("a.txt", lines: 4), Self.file("b.txt", lines: 4)])
        let actions = ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {})
        let window = OffscreenWindow(size: CGSize(width: ShellLayout.paneDockThreshold, height: 700), dark: false,
                                     RightPaneSplit(state: RightPaneState(), showPane: true) {
                                         ThreadView(store: store, active: true, isFocused: false, request: request, commandKey: "review")
                                     } pane: {
                                         ReviewPane(session: session, actions: actions)
                                     })
        defer {
            store.stop()
            window.close()
        }
        func scroll() -> NSScrollView? {
            func all(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(all) }
            // The thread's scroll view: the leftmost of the tall ones.
            return all(window.host).filter { $0.frame.height > 300 }.min { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
        }
        try await eventuallyOnMain("the thread to load") { store.ready }
        let thread = try #require(scroll())
        var last = CGFloat.infinity, still = 0
        try await eventuallyOnMain("the thread to come to rest", poll: .milliseconds(30)) {
            window.layout()
            let clip = thread.contentView
            let now = (thread.documentView?.bounds.height ?? 0) - (clip.bounds.origin.y + clip.bounds.height - thread.contentInsets.bottom)
            still = abs(now - last) < 0.5 ? still + 1 : 0
            last = now
            return still >= 10
        }
        #expect((thread.documentView?.bounds.height ?? 0) > thread.frame.height, "the thread scrolls")
        #expect(abs(last) < 2, "the thread rests at its tail: \(last) from it")
    }

    // MARK: Viewed

    @Test(arguments: [false, true])
    func markingAFileViewedPopsItsCheckUnlessReduceMotion(reduceMotion: Bool) async throws {
        let (model, window) = Self.pane([Self.file("a.txt", lines: 6)], reduceMotion: reduceMotion)
        defer { window.close() }
        // Folded already, so marking it viewed changes nothing but the check.
        model.toggleFolded("a.txt")
        // The first file's header: its Viewed checkbox.
        let trailing = CGRect(x: Self.size.width - 140, y: Self.diff.minY, width: 140, height: 36)
        _ = await MotionProbe.record(window, region: trailing, timeout: 1) {}

        let recording = await MotionProbe.record(window, region: trailing) { model.toggleViewed("a.txt") }

        let first = try #require(recording.settled.firstColumn(differingFrom: recording.before), "the check turns done")
        let last = try #require(recording.settled.lastColumn(differingFrom: recording.before))
        let outside = recording.inBetween.filter { frame in
            (frame.firstColumn(differingFrom: recording.settled).map { $0 < first } ?? false)
                || (frame.lastColumn(differingFrom: recording.settled).map { $0 > last } ?? false)
        }
        if reduceMotion {
            #expect(outside.isEmpty, "the check only recolors")
        } else {
            #expect(!outside.isEmpty, "the check swells past its size")
        }
    }

    // MARK: Navigation

    @Test func aKeyboardFileJumpLandsAtOnceWhereAClickScrolls() async throws {
        let (model, window) = Self.pane((0..<6).map { Self.file("f\($0).txt", lines: 20) })
        defer { window.close() }

        let key = await MotionProbe.record(window, region: Self.diff) { _ = model.handleKey("j") }
        #expect(key.settled.firstRow(differingFrom: key.before) != nil, "j moves to the next file")
        #expect(key.inBetween.isEmpty, "j lands at once")

        let click = await MotionProbe.record(window, region: Self.diff) { model.select("f4.txt") }
        #expect(click.settled.firstRow(differingFrom: click.before) != nil, "a click moves to its file")
        if !NW.Motion.systemReduceMotion {
            #expect(!click.inBetween.isEmpty, "a click scrolls there")
        }
    }

    /// The file strip's chips, under the toolbar and the compare row.
    private static let strip = CGRect(x: 0, y: 76, width: size.width, height: 38)

    @Test(arguments: [false, true])
    func theStripsSelectionSlidesToAClickedFileAndJumpsForAKey(reduceMotion: Bool) async throws {
        let (model, window) = Self.pane((0..<4).map { Self.file("f\($0).txt", lines: 4) }, reduceMotion: reduceMotion)
        defer { window.close() }
        // The first file's selection lands as the pane opens.
        _ = await MotionProbe.record(window, region: Self.strip, timeout: 0.5) {}
        let empty = (x: Int(Self.size.width) - 2, y: 2)

        let key = await MotionProbe.record(window, region: Self.strip) { _ = model.handleKey("j") }
        #expect(key.settled.firstColumn(differingFrom: key.before) != nil, "j selects the next chip")
        #expect(key.inBetween.isEmpty, "at once")

        let click = await MotionProbe.record(window, region: Self.strip) { model.select("f3.txt") }
        #expect(!click.inBetween.isEmpty, "the selection moves over time")
        // The selected fill is faint: a few levels from the strip's own background.
        let away = click.inBetween.flatMap { $0.columnsAway(from: click.before, click.settled, empty: empty, emptyTolerance: 1, drawnThreshold: 6) }
        if reduceMotion {
            #expect(away.isEmpty, "the selection fades from chip to chip: \(Set(away).sorted().prefix(8))")
        } else {
            #expect(!away.isEmpty, "the selection slides from chip to chip")
        }
    }
}
