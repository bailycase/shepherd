import AppKit
import CoreText
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

@Suite("Folded review widths", .mainActorExclusive)
@MainActor
struct ReviewFoldedWidthTests {
    private func file(repetitions: Int) -> DiffFile {
        var lines = (0..<64).map {
            DiffLine(kind: .context, text: "unchanged", oldLine: $0 + 1, newLine: $0 + 1, id: $0)
        }
        lines.append(DiffLine(kind: .removed, text: String(repeating: "old 🐑\t界 ", count: repetitions), oldLine: 65, newLine: nil, id: 64))
        lines.append(DiffLine(kind: .added, text: String(repeating: "new 🐑\t界 ", count: repetitions + 10), oldLine: nil, newLine: 65, id: 65))
        return DiffFile(oldPath: "wide.txt", newPath: "wide.txt", displayPath: "wide.txt", isNew: false, isDeleted: false,
                        isRenamed: false, isBinary: false, hunks: [DiffHunk(header: "@@ -1,65 +1,65 @@", lines: lines)])
    }

    /// Independently measure expected text, without warming the model's width cache/probe.
    private func widths(_ file: DiffFile, scale: CGFloat) -> (old: CGFloat, new: CGFloat) {
        let font = NSFont(name: "GeistMono-Regular", size: SHTextStyle.code.size * scale)
            ?? .monospacedSystemFont(ofSize: SHTextStyle.code.size * scale, weight: .regular)
        var old: CGFloat = 0, new: CGFloat = 0
        for line in file.hunks.flatMap(\.lines) {
            let text = NSAttributedString(string: line.text, attributes: [.font: font])
            let width = ceil(CGFloat(CTLineGetTypographicBounds(CTLineCreateWithAttributedString(text), nil, nil, nil)))
            if line.kind != .added { old = max(old, width) }
            if line.kind != .removed { new = max(new, width) }
        }
        return (old, new)
    }

    private func limitsMatch(_ scroll: SHSplitDiffScroll, widths: (old: CGFloat, new: CGFloat),
                             viewport: CGFloat, split: Bool) -> Bool {
        let available = split
            ? max(0, (viewport - 1) / 2 - SHDiffMetrics.splitCodeLeading - SHDiffMetrics.commentSlotWidth)
            : max(0, viewport - SHDiffMetrics.codeLeading - SHDiffMetrics.commentSlotWidth)
        let old = split ? max(0, widths.old - available) : 0
        let new = max(0, (split ? widths.new : max(widths.old, widths.new)) - available)
        return abs(scroll.oldLimit - old) < 1 && abs(scroll.newLimit - new) < 1
    }

    private func requestCount(_ model: ReviewPaneModel) -> Int {
        #if DEBUG
        model.widthRequests
        #else
        0
        #endif
    }

    private func settleWidthRequest(_ window: OffscreenWindow, model: ReviewPaneModel, after count: Int) async throws {
        try await eventuallyOnMain("fold/unfold width lifecycle callback") {
            ListPerf.settle(window)
            #if DEBUG
            return model.widthRequests > count
            #else
            return true
            #endif
        }
    }

    @Test(arguments: [false, true], [false, true])
    func foldedFilesDeferWidthsAndUnfoldUsingTheirActualViewport(viewed: Bool, split: Bool) async throws {
        let originalScale = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = originalScale }
        let first = file(repetitions: 40)
        let session = ReviewSession(agentID: AgentID(), paneID: PaneID(), cwd: "/tmp/folded-widths", reference: nil, files: [first])
        session.layoutChoice = split ? .split : .unified
        let model = ReviewPaneModel(session: session, actions: ReviewActions(setPullRequest: { _ in }, requestChanges: {}, commit: {}, close: {}))
        if viewed { session.viewed = [first.id] } else { model.collapsed = [first.id] }
        let scroll = model.splitScroll(for: first.id)
        // Existing offsets/limits must not be zeroed merely because the section is folded.
        scroll.resize(oldWidth: 5_000, newWidth: 5_000, viewport: 100)
        scroll.move(to: 40, old: false)
        let firstWidths = widths(first, scale: originalScale)
        // Maximized adds a file-list column: model.width is NOT the diff header's viewport.
        let window = OffscreenWindow(size: CGSize(width: 1_100, height: 700), dark: false,
                                     ReviewPaneContent(model: model, maximized: true)
                                        .environment(\._accessibilityReduceMotion, true))
        defer { window.close() }
        try await eventuallyOnMain("folded header geometry arrives") {
            ListPerf.settle(window)
            #if DEBUG
            return model.width > 0 && model.widthRequests > 0
            #else
            return model.width > 0 && model.highlights[first.id] != nil
            #endif
        }
        #if DEBUG
        try #require(model.widthMeasurements == 0, "initially folded/viewed files must do no CoreText width pass")
        #endif
        #expect(scroll.newOffset == 40 && scroll.newLimit == 4_900)
        let vertical = try #require(ListPerf.scrollView(in: window, trailing: true))
        #expect(vertical.contentView.bounds.width < model.width - 100, "fixture includes the separate file-list column")

        model.toggleFolded(first.id)
        try await eventuallyOnMain("unfold measures both sides using the diff viewport") {
            ListPerf.settle(window)
            return limitsMatch(scroll, widths: firstWidths, viewport: vertical.contentView.bounds.width, split: split)
        }
        #if DEBUG
        #expect(model.widthMeasurements == 1)
        #endif
        #expect(scroll.newOffset == 40, "opening preserves the retained horizontal position")

        var requests = requestCount(model)
        if viewed { model.toggleViewed(first.id) } else { model.toggleFolded(first.id) }
        try await settleWidthRequest(window, model: model, after: requests)
        let oldLimits = (scroll.oldLimit, scroll.newLimit)
        let oldOffsets = (scroll.oldOffset, scroll.newOffset)
        let oldViewport = vertical.contentView.bounds.width
        let changed = file(repetitions: 60)
        let changedScale = originalScale * 1.2
        let changedWidths = widths(changed, scale: changedScale)
        session.files = [changed]
        ThemeStore.shared.textScale = changedScale
        window.window.setContentSize(CGSize(width: 900, height: 700))
        try await eventuallyOnMain("folded content, font and viewport updates settle") {
            ListPerf.settle(window)
            return abs(model.width - 900) < 1 && vertical.contentView.bounds.width < oldViewport
        }
        #if DEBUG
        #expect(model.widthMeasurements == 1, "all three invalidations defer their expensive work while shut")
        #endif
        #expect(scroll.oldLimit == oldLimits.0 && scroll.newLimit == oldLimits.1)
        #expect(scroll.oldOffset == oldOffsets.0 && scroll.newOffset == oldOffsets.1)

        model.toggleFolded(first.id)
        try await eventuallyOnMain("reopening uses the new content, scale and measured viewport") {
            ListPerf.settle(window)
            return limitsMatch(scroll, widths: changedWidths, viewport: vertical.contentView.bounds.width, split: split)
        }
        #if DEBUG
        #expect(model.widthMeasurements == 2, "only the newly invalidated file is measured again")
        #endif
        #expect(scroll.newOffset == oldOffsets.1)

        requests = requestCount(model)
        model.toggleFolded(first.id)
        try await settleWidthRequest(window, model: model, after: requests)
        requests = requestCount(model)
        model.toggleFolded(first.id)
        try await settleWidthRequest(window, model: model, after: requests)
        #if DEBUG
        #expect(model.widthMeasurements == 2, "an unchanged fold/unfold keeps the existing width cache")
        #endif
        #expect(scroll.newOffset == oldOffsets.1)
    }
}
