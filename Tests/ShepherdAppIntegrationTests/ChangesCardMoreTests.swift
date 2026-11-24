import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing

/// A turn that changed a hundred files: the card lists three, each "Show N more" lists the next
/// ten in place, and only past the files the host sent does the row open Review.
@Suite("Changes card paging", .integrationTimeLimit)
struct ChangesCardMoreTests {
    @Test func showMorePagesThroughTheFilesThenOpensReview() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.paging() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor static func paging() async throws {
        AccessibilityNode.enable()
        let files = (1...20).map { index in
            SHChangedFile(path: "src/file\(index).swift", directory: "src/", name: "file\(index).swift", status: .modified, added: index, removed: 0)
        }
        var reviewed = 0
        let window = OffscreenWindow(size: CGSize(width: 520, height: 900), dark: false,
            SHChangesCard(title: "Edited 120 files", added: 210, removed: 0, files: files, total: 120,
                          onReview: { reviewed += 1 }, onOpen: { _ in }).padding(SH.Space.xl))
        defer { window.close() }
        func listed() -> Int { window.controls().filter { $0.label?.hasPrefix("src/file") == true }.count }

        #expect(listed() == 3)
        try window.press("Show 10 more files")
        try await eventuallyOnMain("ten more files") { listed() == 13 }
        try window.press("Show 7 more files")
        try await eventuallyOnMain("the rest of the listed files") { listed() == 20 }
        #expect(reviewed == 0)
        try window.press("100 more files")
        #expect(reviewed == 1)
    }
}
