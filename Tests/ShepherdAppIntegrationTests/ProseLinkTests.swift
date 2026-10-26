import Foundation
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Prose links", .mainActorExclusive)
@MainActor
struct ProseLinkTests {
    @Test func markdownFileLinkReachesTheOpenerAsAnAbsoluteFileURL() async throws {
        let root = try makeScratchDirectory("prose-links")
        let folder = root.appendingPathComponent("temporal", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("PLAN.md")
        try "# Plan".write(to: file, atomically: true, encoding: .utf8)
        let markdown = SHProseInline.styled("[temporal/PLAN.md](temporal/PLAN.md)")
        let link = try #require(markdown.runs.first?.link)
        #expect(link.scheme == nil) // The original handoff passed this URL straight to macOS.
        let web = try #require(URL(string: "https://example.com/plan"))
        let task = try #require(URL(string: "shepherd-project-task://project/task"))

        for dark in [false, true] {
            var opened: [URL] = []
            // Exercise the actual prose environment without launching an app or taking focus.
            let window = OffscreenWindow(size: CGSize(width: 400, height: 200), dark: dark,
                SHAgentProse([.paragraph(markdown), .code("", language: nil)]) { _, _ in
                    LinkProbe(urls: [link, web, task])
                }
                .environment(\.shProseFileRoot, root)
                .environment(\.openURL, OpenURLAction { url in
                    opened.append(url)
                    return .handled
                }))
            defer { window.close() }
            try await eventuallyOnMain("prose links to reach the inherited opener") { opened.count == 3 }
            #expect(opened == [file, web, task])
            #expect(try String(contentsOf: opened[0], encoding: .utf8) == "# Plan")
        }
    }
}

private struct LinkProbe: View {
    let urls: [URL]
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear.onAppear { for url in urls { openURL(url) } }
    }
}
