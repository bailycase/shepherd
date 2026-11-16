import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// The low row-height estimate a Mac thread sizes its eager tail by while its window is being
/// live-resized, and the count the store walks to cover a window with it.
@Suite("Row height estimate")
@MainActor
struct NativeRowHeightTests {
    @Test func textWrapsBreaksAndCountsWideScalarsAsTwo() {
        #expect(NativeRowHeight.textHeight("") == 0)
        #expect(NativeRowHeight.textHeight("hello") == NativeRowHeight.textLine)
        #expect(NativeRowHeight.textHeight("a\nb\nc") == 3 * NativeRowHeight.textLine)
        #expect(NativeRowHeight.textHeight(String(repeating: "a", count: 250)) > NativeRowHeight.textHeight(String(repeating: "a", count: 50)))
        #expect(NativeRowHeight.textHeight(String(repeating: "界", count: 60)) == NativeRowHeight.textHeight(String(repeating: "a", count: 120)))
    }

    @Test func blocksGrowWithTheirContentAndRenderedOnesCountAsNothing() {
        let threeLines = NativeRowHeight.block(.code("a\nb\nc", language: "swift"))
        let thirtyLines = NativeRowHeight.block(.code((0..<30).map { "line \($0)" }.joined(separator: "\n"), language: "swift"))
        #expect(thirtyLines > threeLines)
        #expect(NativeRowHeight.block(.code("graph TD\nA-->B", language: "mermaid")) == 0)
        func table(_ rows: Int) -> NativeMarkdownBlock {
            .table(NativeMarkdownTable(alignments: [.leading], header: ["H"], rows: Array(repeating: ["x"], count: rows), source: ""))
        }
        #expect(NativeRowHeight.block(table(10)) > NativeRowHeight.block(table(1)))
    }

    private func message(_ id: String, _ role: String, _ text: String, status: String? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: role, blocks: [NativeThreadBlock(kind: .text, text: text)], status: status, truncated: false)
    }

    private func store(_ messages: [NativeThreadMessage], running: Bool = false) -> NativeThreadStore {
        let store = NativeThreadStore()
        store.preview(NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: running,
                                           supportedActions: [], dialogsSupported: true, dialogs: [], messages: messages,
                                           provisional: [], clipped: false))
        return store
    }

    private func pairs(_ count: Int) -> [NativeThreadMessage] {
        (0..<count).flatMap { i in [message("u\(i)", "user", "Hi"), message("a\(i)", "assistant", "OK.")] }
    }

    @Test func eagerCountCoversStopsAndCaps() {
        let store = store(pairs(10))
        let cover = store.eagerRowCount(coveringHeight: 200, maxRows: 30)
        #expect(cover >= 2 && cover < 20, "a few short rows cover 200 pt: \(cover)")
        #expect(store.eagerRowCount(coveringHeight: 100_000, maxRows: 3) == 3, "never past the cap")
        #expect(store.eagerRowCount(coveringHeight: 100_000, maxRows: 30) { $0.isUser } == 10, "skipped rows do not count")
    }

    @Test func eagerCountReachesTheLiveReplyPastAQueuedRow() async throws {
        let snapshot = NativeThreadSnapshot(piSessionID: "s", generation: "g", revision: 1, running: true,
                                            supportedActions: [], dialogsSupported: true, dialogs: [],
                                            messages: [message("u0", "user", "Hi"), message("a0", "assistant", "Working."),
                                                       message("u1", "user", "Later.", status: "queued")],
                                            provisional: [], clipped: false)
        let store = NativeThreadStore()
        let polling = Task { await store.run(request: { request in
            if case .snapshot = request { return .snapshot(value: snapshot) }
            return .failure(code: "x", message: "unscripted")
        }) }
        defer { polling.cancel() }
        for _ in 0..<100 where store.liveRowID == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(store.liveRowID != nil && store.rows.contains(where: \.live))
        #expect(store.eagerRowCount(coveringHeight: 1, maxRows: 30) == 2, "the queued row and the live reply above it")
    }
}
