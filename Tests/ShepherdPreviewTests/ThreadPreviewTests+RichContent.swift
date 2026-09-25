import AppKit
import Foundation
import ImageIO
import ShepherdProtocol
import ShepherdRemote
import ShepherdTestSupport
@testable import ShepherdUI
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import ShepherdApp

/// Rich content in prose (DESIGN.md › Thread › Rich content in prose): tables, task lists,
/// nested lists, footnotes, images, disclosures, and diagram and math fences, in light and dark:
///
///     SHEPHERD_PREVIEW_DIR=/tmp/previews swift test --filter ThreadPreviewTests
extension ThreadPreviewTests {
    private static func reply(_ text: String) -> NativeThreadSnapshot {
        let t0 = ActivityThreads.now - 3 * 60_000
        return ActivityThreads.snapshot([
            ActivityThreads.user("u1", "Which tools does Shepherd expose to its agents?", at: t0),
            ActivityThreads.assistant("a1", text, thinking: "List them by area.", seconds: 3, at: t0 + 20_000),
        ])
    }

    /// The reported reply: its table draws as a table at the prose width, the long column
    /// wrapping, code spans as the thread styles them.
    @Test func threadRichTable() async throws {
        try await renderThread("thread-rich-table", Self.reply(MarkdownFixtures.toolsReply), size: CGSize(width: 1180, height: 820))
    }

    /// The same reply in a thread narrower than the prose measure: columns shrink and wrap.
    @Test func threadRichTableNarrow() async throws {
        try await renderThread("thread-rich-table-narrow", Self.reply(MarkdownFixtures.toolsReply), size: CGSize(width: 460, height: 1100))
    }

    /// Task list, three-level nested list, strikethrough and an autolink, a local image drawn
    /// as a thumbnail and a remote one as a chip, a collapsed disclosure, and footnotes.
    @Test func threadRichStructure() async throws {
        let folder = try makeScratchDirectory("rich")
        let image = folder.appendingPathComponent("thread-table.png")
        try Self.writeScreenshot(to: image)
        let fixture = ThreadFixture(Self.reply(MarkdownFixtures.structureReply(image: "thread-table.png")))
        defer { fixture.store.stop() }
        try await Preview.render("thread-rich-structure", size: CGSize(width: 1180, height: 1180),
                                 ready: { fixture.store.ready && !fixture.store.rows.isEmpty && NWProseThumbnails.cached(image) != nil }) {
            fixture.thread(workingDirectory: folder.path)
        }
    }

    /// A table wider than the thread scrolls inside its card; a keycap; mermaid and math fences
    /// drawn as labelled source.
    @Test func threadRichWide() async throws {
        try await renderThread("thread-rich-wide", Self.reply(MarkdownFixtures.wideReply), size: CGSize(width: 1180, height: 820))
    }

    /// Every part on its own, at the prose measure: the table's header and hairlines, alignment,
    /// the open disclosure, footnotes, the image chip, and the fences' headers.
    @Test func proseRichParts() async throws {
        let text = """
        | Left | Center | Right |
        |:--|:-:|--:|
        | `code` and **bold** | *italic* | 1,024 |
        | ~~struck~~ \\| piped | [link](https://example.com) | 7 |

        - [x] Done task
        - [ ] Open task
          - nested under it
            - and deeper

        > A quote with **bold** and a list:
        > - one
        > - two

        Inline <kbd>⌘</kbd><kbd>K</kbd>, a note,[^1] H<sub>2</sub>O and x<sup>2</sup>, and `Array<Int>` stays code while <Int> stays text.

        ![Remote chart](https://example.com/chart.png)

        ![Missing file](/nowhere/shot.png)

        [^1]: A footnote at the end of the message.
        """
        let blocks = Prose.proseBlocks(nativeMarkdownBlocks(text))
        let details = Prose.proseBlocks(nativeMarkdownBlocks("- Opened by default here\n- Its blocks sit on the rule\n\n```swift\nlet open = true\n```"))
        let size = CGSize(width: 720, height: 1100)
        try await Preview.render("prose-rich-parts", size: size) {
            VStack(alignment: .leading, spacing: NW.Space.l) {
                NWAgentProse(blocks)
                NWProseDetails(summary: "An open disclosure", blocks: details, depth: 0, open: true) { NWCodeBlock($0, language: $1) }
                NWCodeBlock("graph TD\n  A --> B", language: "mermaid")
                NWCodeBlock("E = mc^2", language: "math")
                Spacer(minLength: 0)
            }
            .padding(NW.Space.xxxl)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .background(Color.nw.bgWindow)
        }
    }

    private func renderThread(_ surface: String, _ snapshot: NativeThreadSnapshot, size: CGSize) async throws {
        let fixture = ThreadFixture(snapshot)
        defer { fixture.store.stop() }
        try await Preview.render(surface, size: size, ready: { fixture.store.ready && !fixture.store.rows.isEmpty }) {
            fixture.thread()
        }
    }

    /// A small picture of a thread with a table, as a PNG an agent might link.
    private static func writeScreenshot(to url: URL) throws {
        let view = VStack(alignment: .leading, spacing: 10) {
            RoundedRectangle(cornerRadius: 6).fill(Color(red: 0.16, green: 0.18, blue: 0.2)).frame(width: 220, height: 14)
            VStack(spacing: 0) {
                ForEach(0..<5, id: \.self) { row in
                    HStack(spacing: 0) {
                        Rectangle().fill(row == 0 ? Color(red: 0.1, green: 0.11, blue: 0.13) : .clear).frame(width: 150)
                        Rectangle().fill(row == 0 ? Color(red: 0.1, green: 0.11, blue: 0.13) : .clear)
                    }
                    .frame(height: 26)
                    .overlay(alignment: .leading) {
                        RoundedRectangle(cornerRadius: 3).fill(Color(red: 0.48, green: 0.65, blue: 1).opacity(row == 0 ? 0.5 : 0.8))
                            .frame(width: 90 - CGFloat(row * 7), height: 8).padding(.leading, 12)
                    }
                    Rectangle().fill(Color(red: 0.14, green: 0.15, blue: 0.17)).frame(height: 1)
                }
            }
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(red: 0.2, green: 0.22, blue: 0.24)))
        }
        .padding(24)
        .frame(width: 520, height: 240, alignment: .topLeading)
        .background(Color(red: 0.05, green: 0.055, blue: 0.063))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}
