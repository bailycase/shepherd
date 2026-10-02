import AppKit
import Foundation
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// Whatever a thread holds fits its column. A row that cannot shrink to it (a label set to its
/// ideal width, a line that never truncates) widens the one stack every row shares: each paragraph
/// then wraps at the wider width, and the thread runs off the edge of its pane under a scroll view
/// that clips what no longer fits (docs/design/thread.md › Activity lines).
///
/// Each kind of row in `LongThreads` is drawn through the real store and formatters in a thread
/// of each width a thread meets: a design's chat (`AppLayout.designChatWidth`), the thread
/// column's narrowest (`AppLayout.threadMinWidth`), and a phone's. The thread keeps a gutter on
/// both sides and draws nothing in it, so a row that reaches the right gutter has outgrown its
/// column.
@Suite("Thread rows fit their column", .serialized, .mainActorExclusive)
@MainActor
struct ThreadFitTests {
    nonisolated static let widths: [CGFloat] = [AppLayout.designChatWidth, AppLayout.threadMinWidth, 320]

    /// How many pixels of the thread's right gutter, beside the rows, hold anything but the
    /// thread's background.
    static func pixelsInTheRightGutter(of row: LongThreads.Row, width: CGFloat, designChat: Bool, dark: Bool = false,
                                       textScale: CGFloat = 1) async throws -> Int {
        // The Mac's largest Text size is 1.3. The test is main-actor exclusive, so nothing else
        // draws while the scale is up, and it is put back before the next test runs.
        let original = ThemeStore.shared.textScale
        ThemeStore.shared.textScale = textScale
        defer { ThemeStore.shared.textScale = original }
        let cards = designChat ? DesignChatFixture.cards() : nil
        let thread = FakeThread(snapshot(row, designChat: designChat), size: CGSize(width: width, height: 1400), dark: dark, designCards: cards)
        defer { thread.close() }
        for id in row.opensSummaries { thread.store.compactions.expand(id) }
        try await thread.waitUntilReady()
        try await eventuallyOnMain("the rows to be drawn") { !thread.store.rows.isEmpty }
        ListPerf.settle(thread.window)
        let scroll = try #require(thread.scrollView)
        let rows = try #require(scroll.documentView).frame.height
        let host = thread.window.host
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        // Text that fills the column to its edge may touch the gutter's first points; a row that
        // outgrew its column runs well into it.
        let gutter = Int(((AppLayout.threadGutter(width: width) - 4) * scale).rounded(.down))
        let right = bitmap.pixelsWide
        let rowsEnd = Int((rows * scale).rounded(.up))
        // The thread's own background, below the last row.
        let background = try #require(bitmap.colorAt(x: right - 1, y: min(bitmap.pixelsHigh - 1, rowsEnd + Int(40 * scale)))?.usingColorSpace(.sRGB))
        func same(_ a: NSColor, _ b: NSColor) -> Bool {
            abs(a.redComponent - b.redComponent) < 0.02 && abs(a.greenComponent - b.greenComponent) < 0.02 && abs(a.blueComponent - b.blueComponent) < 0.02
        }
        var count = 0
        for x in (right - gutter)..<right {
            for y in 0..<min(rowsEnd, bitmap.pixelsHigh) {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), !same(color, background) else { continue }
                count += 1
            }
        }
        return count
    }

    static func snapshot(_ row: LongThreads.Row, designChat: Bool) -> NativeThreadSnapshot {
        var messages = row.messages
        if designChat, let first = messages.indices.first { messages[first].origin = .designComment(id: LongThreads.commentID) }
        return ThreadFixture.snapshot(messages)
    }

    /// One kind of row at one width and one text size (the Mac's largest is 1.3).
    struct Fit: Sendable, CustomStringConvertible {
        var row: LongThreads.Row
        var width: CGFloat
        var textScale: CGFloat
        var description: String { "\(row) at \(width)pt, text scale \(textScale)" }
    }

    nonisolated static func cases(widths: [CGFloat]) -> [Fit] {
        LongThreads.rows.flatMap { row in widths.flatMap { width in [1, 1.3].map { Fit(row: row, width: width, textScale: $0) } } }
    }

    @Test(arguments: cases(widths: widths))
    func anOrdinaryThreadsRowsFitItsColumn(_ fit: Fit) async throws {
        let marks = try await Self.pixelsInTheRightGutter(of: fit.row, width: fit.width, designChat: false, textScale: fit.textScale)
        #expect(marks == 0, "\(fit): \(marks) pixels in the right gutter of the thread")
    }

    @Test(arguments: cases(widths: [AppLayout.designChatWidth]))
    func aDesignChatsRowsFitItsColumnWithTheCommentCardAround(_ fit: Fit) async throws {
        let marks = try await Self.pixelsInTheRightGutter(of: fit.row, width: fit.width, designChat: true, textScale: fit.textScale)
        #expect(marks == 0, "\(fit): \(marks) pixels in the right gutter of the design chat")
    }
}

/// An activity line opened to its calls fits the column too: each call's kind (the tool's name)
/// sits in a column as wide as the longest of them, so a tool with a long name must not take the
/// room its detail and stat need.
@Suite("Opened activity lines fit their column", .serialized, .mainActorExclusive)
@MainActor
struct OpenedActivityFitTests {
    /// The thread's text column in a design chat, in the thread at its narrowest, and on a phone.
    nonisolated static let columns: [CGFloat] = [388, 368, 288]

    static func bursts(_ row: LongThreads.Row) -> [NativeActivityBurst] {
        nativeActivityBursts(row.messages.filter { $0.toolName != nil }.map(NativeActivityCall.init))
    }

    @Test(arguments: LongThreads.rows.filter { $0.messages.contains { $0.toolName != nil } }, columns)
    func aLineOpenedToItsCallsFitsItsColumn(_ row: LongThreads.Row, _ column: CGFloat) async throws {
        let bursts = Self.bursts(row)
        let calls = Set(bursts.flatMap(\.calls).map(\.id))
        let margin: CGFloat = 200
        let window = OffscreenWindow(size: CGSize(width: column + margin, height: 900), dark: false)
        defer { window.close() }
        window.show(
            VStack(alignment: .leading, spacing: 6) {
                ForEach(bursts) { burst in ActivityLineView(burst: burst, expanded: true, expandedCalls: calls) }
            }
            .frame(width: column)
            .frame(width: column + margin, height: 900, alignment: .topLeading)
            .background(Color.nw.bgWindow))
        ListPerf.settle(window)
        let host = window.host
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let scale = Double(bitmap.pixelsWide) / host.bounds.width
        let background = try #require(bitmap.colorAt(x: bitmap.pixelsWide - 1, y: bitmap.pixelsHigh - 1)?.usingColorSpace(.sRGB))
        var marks = 0
        for x in Int((column + 2) * scale)..<bitmap.pixelsWide {
            for y in 0..<bitmap.pixelsHigh {
                guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(color.redComponent - background.redComponent) > 0.02 || abs(color.greenComponent - background.greenComponent) > 0.02
                    || abs(color.blueComponent - background.blueComponent) > 0.02 { marks += 1 }
            }
        }
        #expect(marks == 0, "\(row): \(marks) pixels past the \(column)pt column")
    }
}

/// The comment a design chat's first message carries, and its card as the design screen derives it.
@MainActor
enum DesignChatFixture {
    static func cards() -> DesignCommentCards {
        let comment = DesignComment(id: LongThreads.commentID, number: 1, board: DesignPath("withdrawals-mobile-approve.dc.html")!, tid: 4, path: [1, 1],
                                    label: "Details", target: "Details and Claims", text: LongThreads.prompt,
                                    createdAt: LongThreads.start)
        let cards = DesignCommentCards()
        cards.set(DesignScreenModel.cards([comment], now: Date(timeIntervalSince1970: LongThreads.start / 1000 + 300)))
        return cards
    }
}
