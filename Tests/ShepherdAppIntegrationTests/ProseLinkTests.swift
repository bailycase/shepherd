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

    /// A remote image is a chip, and pressing it hands its address to the opener the prose inherits, through the router.
    @Test func aRemoteImageChipPressesThroughTheLinkRouter() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.pressedImageChip() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func pressedImageChip() async throws {
        AccessibilityNode.enable()
        var opened: [URL] = []
        let window = OffscreenWindow(size: CGSize(width: 400, height: 200), dark: false,
            SHAgentProse([.image(SHProseImage(alt: "Build status", source: "https://ci.example.com/badge.png"))])
                .environment(\.openURL, OpenURLAction { url in
                    opened.append(url)
                    return .handled
                }))
        defer { window.close() }
        try window.press("Image, Build status")
        try await eventuallyOnMain("the chip to reach the opener") { opened.count == 1 }
        #expect(opened.map(\.absoluteString) == ["https://ci.example.com/badge.png"])
    }

    /// A new opener above a prose view does not redraw what reads the action prose gives its links: the action is made once
    /// per prose view and the opener is only handed to it, so a streaming reply under a conversation that rebuilds its
    /// opener on every body redraws no link, image chip or task chip once the window has settled. Run in its own process:
    /// SwiftUI's comparison of the environment is what is measured.
    @Test func aNewOpenerAboveProseRedrawsNothingThatReadsItsLinkAction() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
            await completingScenario { try await Self.readerBesideChangingOpeners() }
        }
        expectScenarioCompleted(result)
    }

    @MainActor private static func readerBesideChangingOpeners() async throws {
        let ticks = OpenerTicks()
        SHRenderProbe.start()
        let window = OffscreenWindow(size: CGSize(width: 400, height: 200), dark: false, OpenerHost(ticks: ticks))
        defer {
            window.close()
            SHRenderProbe.stop()
        }
        ListPerf.settle(window)
        var drawn = SHRenderProbe.count("prose.linkReader")
        #expect(drawn >= 1, "the reader was drawn")
        // SwiftUI draws a reader again on the first few updates of a new window, and how many depends on how busy the
        // machine is; a reader of an action that is stable draws nothing after that, one of a new action draws on every pull.
        var quiet = 0
        var pulls = 0
        while quiet < 5, pulls < 40 {
            pulls += 1
            ticks.count += 1
            ListPerf.settle(window)
            let now = SHRenderProbe.count("prose.linkReader")
            quiet = now == drawn ? quiet + 1 : 0
            drawn = now
        }
        #expect(quiet == 5, "the reader was still drawn on pull \(pulls) (\(drawn) times)")
    }
}

/// A host that hands prose a new opener on every body, as a Project conversation does, and prose that draws
/// the same blocks each time.
@MainActor @Observable
private final class OpenerTicks {
    var count = 0
}

private struct OpenerHost: View {
    let ticks: OpenerTicks

    var body: some View {
        let count = ticks.count
        SHAgentProse([.paragraph(AttributedString("A link to follow.")), .code("", language: nil)]) { _, _ in
            LinkReader()
        }
        .environment(\.openURL, OpenURLAction { _ in
            _ = count
            return .handled
        })
    }
}

/// Reads the action prose gives its links, and counts how often it is drawn.
private struct LinkReader: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        let _ = SHRenderProbe.tick("prose.linkReader")
        let _ = openURL
        Color.clear.frame(width: 4, height: 4)
    }
}

private struct LinkProbe: View {
    let urls: [URL]
    @Environment(\.openURL) private var openURL

    var body: some View {
        Color.clear.onAppear { for url in urls { openURL(url) } }
    }
}
