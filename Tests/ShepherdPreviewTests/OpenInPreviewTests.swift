import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// A file row's Open in (OpenInD): a read call's row and a changes card's row with the pointer over them, on real files in a
/// scratch repository, each naming the app this Mac opens its type in. In light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter OpenInPreviewTests
@Suite("Open in previews", .serialized, .mainActorExclusive,
       .enabled(if: Preview.enabled && !Preview.liveModel, "set SHEPHERD_PREVIEW_DIR (without SHEPHERD_LIVE_MODEL) to render previews"))
@MainActor
struct OpenInPreviewTests {
    @Test func fileRowsOnHover() async throws {
        let repo = FileManager.default.temporaryDirectory.appending(path: "openin-preview-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: repo) }
        for folder in [".git", "docs", "src/components"] {
            try FileManager.default.createDirectory(at: repo.appending(path: folder), withIntermediateDirectories: true)
        }
        for file in ["docs/RELEASING.md", "docs/checkout-release.md", "src/components/Checkout.tsx", "src/components/PromoField.tsx"] {
            try Data("x\n".utf8).write(to: repo.appending(path: file))
        }
        let rows = [
            SHActivityCallRow(id: "1", label: "read", detail: "src/components/Checkout.tsx", isPath: true, stat: "160 lines",
                              filePath: "src/components/Checkout.tsx"),
            SHActivityCallRow(id: "2", label: "read", detail: "docs/RELEASING.md", isPath: true, stat: "48 lines", filePath: "docs/RELEASING.md"),
            SHActivityCallRow(id: "3", label: "grep", detail: "\"promo\" in src", stat: "6 matches"),
        ]
        let files = [
            SHChangedFile(path: "docs/checkout-release.md", directory: "docs/", name: "checkout-release.md", status: .added, added: 58, removed: 0),
            SHChangedFile(path: "src/components/PromoField.tsx", directory: "src/components/", name: "PromoField.tsx", status: .modified,
                          added: 11, removed: 7),
            SHChangedFile(path: "src/components/Checkout.tsx", directory: "src/components/", name: "Checkout.tsx", status: .modified,
                          added: 2, removed: 2),
        ]
        // The menu lists this Mac's apps for the type, the one it opens in among them.
        for file in ["docs/RELEASING.md", "src/components/PromoField.tsx"] {
            let url = repo.appending(path: file)
            let target = SHOpenIn.app.target(url)
            #expect(!target.app.id.isEmpty && SHOpenIn.app.choices(url).contains { $0.id == target.app.id }, "\(file)")
        }
        let size = CGSize(width: 820, height: 340)
        try await Preview.render("open-in-file-rows", size: size) {
            VStack(alignment: .leading, spacing: SH.Space.xxl) {
                SHActivityCalls(rows, onSelect: { _ in }, onShowAll: { _ in })
                    .environment(\.shOpenInHoverPath, "docs/RELEASING.md")
                SHChangesCard(title: "Edited 3 files", added: 71, removed: 9, files: files, onReview: {}, onOpen: { _ in })
                    .environment(\.shOpenInHoverPath, "src/components/PromoField.tsx")
                Spacer(minLength: 0)
            }
            .environment(\.shProseFileRoot, repo)
            .environment(\.shOpenIn, .app)
            .padding(32)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.sh.bgWindow)
        }
    }
}
