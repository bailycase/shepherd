import AppKit
import Foundation
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

@Suite("Background SwiftUI layout", .mainActorExclusive)
@MainActor
struct BackgroundLayoutTests {
    @Test func tableCacheCanBeBuiltOffMain() async {
        await #expect(processExitsWith: .success) {
            await recordingErrors { try await Self.table() }
        }
    }

    private static func table() async throws {
        let app = try AppHarness()
        defer { app.stop() }
        let table = SHProseTable(alignments: [.leading], header: [AttributedString("Identifier")], rows: [], markdown: "")
        let layout = SHTableLayout(columns: 1, fitting: true, table: table, size: .regular)
        let scheduled = Locked(false)
        let measured = Locked<[CGFloat]?>(nil)
        let window = OffscreenWindow(size: CGSize(width: 200, height: 100), dark: true,
            CaptureLayout(capture: { subviews in
                let first = scheduled.withValue { value in
                    guard !value else { return false }
                    value = true
                    return true
                }
                guard first else { return }
                // LayoutSubviews is Sendable. An empty slice keeps this check focused on
                // cache construction, not SwiftUI's subview measurement implementation.
                let empty = subviews[subviews.endIndex..<subviews.endIndex]
                DispatchQueue.global().async {
                    #expect(!Thread.isMainThread)
                    let cache = layout.makeCache(subviews: empty)
                    measured.withValue { $0 = cache.words }
                }
            }) {
                Color.clear.frame(width: 1, height: 1)
            })
        defer { window.close() }
        try await eventuallyOnMain("the background table cache to finish") {
            window.layout()
            return measured.current != nil
        }
        let words = try #require(measured.current)
        #expect(words.count == 1 && words[0].isFinite && words[0] > 0)
    }
}

private struct CaptureLayout: Layout {
    let capture: @Sendable (LayoutSubviews) -> Void

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        capture(subviews)
        return proposal.replacingUnspecifiedDimensions()
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {}
}
