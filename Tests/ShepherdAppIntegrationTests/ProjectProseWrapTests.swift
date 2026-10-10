import AppKit
import ShepherdTestSupport
import ShepherdUI
import SwiftUI
import Testing
@testable import ShepherdApp

/// ProjectLead-ThreadRunning wraps a worker's paragraph greedily (CSS): in the 447pt pane column "Building a quick interactive mockup of
/// the widget a partner would" is one line (405.9pt in Geist 13.5) and "embed." the next. SwiftUI's `Text` moves "would" down to avoid a
/// one-word last line, so a plain Project paragraph is drawn by `NWPlainParagraph`; an ordinary thread's prose keeps `Text`.
@Suite("Project prose wraps as the boards do", .mainActorExclusive)
@MainActor
struct ProjectProseWrapTests {
    private static let words = "Building a quick interactive mockup of the widget a partner would embed."

    /// The right edge (pt) of each line's ink, top to bottom, in either appearance at a text scale.
    private func lineEdges(halfLeading: Bool, width: CGFloat, dark: Bool, scale: CGFloat) -> [CGFloat] {
        let original = ThemeStore.shared.textScale
        ThemeStore.shared.textScale = scale
        defer { ThemeStore.shared.textScale = original }
        let window = OffscreenWindow(size: CGSize(width: width + 40, height: 160), dark: dark,
                                     Prose(text: Self.words, maxWidth: width).equatable()
                                         .environment(\.nwProseHalfLeading, halfLeading)
                                         .padding(20).frame(width: width + 40, height: 160).background(Color.nw.bgWindow)
                                         .environment(\.colorScheme, dark ? .dark : .light))
        defer { window.close() }
        window.layout()
        let rep = window.host.bitmapImageRepForCachingDisplay(in: window.host.bounds)!
        window.host.cacheDisplay(in: window.host.bounds, to: rep)
        let density = CGFloat(rep.pixelsWide) / window.host.bounds.width
        let background = rep.colorAt(x: Int(10 * density), y: Int(80 * density))?.usingColorSpace(.sRGB)?.brightnessComponent ?? 0
        var edges: [CGFloat] = [], current: CGFloat = -1
        // Only the padded column: the window's own edge is not the text's background.
        let inset = Int(20 * density)
        for y in 0..<rep.pixelsHigh {
            var right = -1
            for x in inset..<(rep.pixelsWide - inset) where abs((rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB)?.brightnessComponent ?? background) - background) > 0.35 { right = x }
            if right >= 0 { current = max(current, CGFloat(right)) } else if current >= 0 { edges.append(current / density - 20); current = -1 }
        }
        if current >= 0 { edges.append(current / density - 20) }
        return edges
    }

    /// Core Text's own greedy break of the same words at the same face, size and width: the line the boards' CSS fills.
    private func greedyFirstLine(width: CGFloat, scale: CGFloat) -> (words: String, width: CGFloat) {
        let font = NSFont(name: "Geist-Regular", size: 13.5 * scale)!
        let text = NSAttributedString(string: Self.words, attributes: [.font: font])
        let typesetter = CTTypesetterCreateWithAttributedString(text)
        let count = CTTypesetterSuggestLineBreak(typesetter, 0, Double(width))
        let line = CTTypesetterCreateLine(typesetter, CFRange(location: 0, length: count))
        let trimmed = (Self.words as NSString).substring(to: count).trimmingCharacters(in: .whitespaces)
        return (trimmed, CTLineGetTypographicBounds(line, nil, nil, nil) - CTLineGetTrailingWhitespaceWidth(line))
    }

    @Test(arguments: [(false, CGFloat(1)), (true, CGFloat(1)), (false, CGFloat(1.3)), (true, CGFloat(1.3))])
    func aWorkerParagraphFillsItsFirstLineAsCoreTextDoesAndAnOrdinaryThreadsIsUnchanged(dark: Bool, scale: CGFloat) {
        _ = NWFonts.isAvailable ? () : NWFonts.register()
        let expected = greedyFirstLine(width: 447, scale: scale)
        let project = lineEdges(halfLeading: true, width: 447, dark: dark, scale: scale)
        #expect(project.count >= 2, "wraps (dark \(dark), scale \(scale)): \(project)")
        #expect(abs((project.first ?? 0) - expected.width) < 4, "line 1 ends \(project.first ?? 0), Core Text's greedy line \"\(expected.words)\" is \(expected.width) wide")
        if scale == 1 {
            #expect(expected.words.hasSuffix("would"), "the board's line 1: \(expected.words)")
            let ordinary = lineEdges(halfLeading: false, width: 447, dark: dark, scale: scale)
            #expect((ordinary.first ?? 0) < expected.width - 20, "an ordinary thread keeps SwiftUI's own wrap: \(ordinary)")
        }
    }

    @Test func theLabelIsOneStaticTextAndGrowsAsItsColumnNarrows() async {
        let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) { await completingScenario { await Self.labelScenario() } }
        expectScenarioCompleted(result)
    }

    private static func labelScenario() async {
        AccessibilityNode.enable()
        let window = OffscreenWindow(size: CGSize(width: 487, height: 200), dark: true,
                                     Prose(text: words, maxWidth: 447).equatable().environment(\.nwProseHalfLeading, true).padding(20))
        defer { window.close() }
        let texts = window.elements().filter { $0.role == "AXStaticText" && $0.value == words }
        #expect(texts.count == 1, "one static text carrying the words: \(window.elements().map { "\($0.role ?? "")|\($0.value ?? "")" })")
        let wide = window.elements().first { $0.value == words }?.frame.height ?? 0
        window.show(Prose(text: words, maxWidth: 200).equatable().environment(\.nwProseHalfLeading, true).padding(20))
        let tall = window.elements().first { $0.value == words }?.frame.height ?? 0
        #expect(tall > wide, "it wraps to more lines when the column narrows: \(wide) then \(tall)")
        // One unbroken token far wider than the column (a path, a hash) wraps inside it; it is never measured at its own width.
        let token = String(repeating: "x", count: 300)
        window.show(Prose(text: token, maxWidth: 200).equatable().environment(\.nwProseHalfLeading, true).padding(20))
        let node = window.elements().first { $0.value == token }
        #expect((node?.frame.width ?? .infinity) <= 200, "the label stays in its column: \(String(describing: node?.frame))")
        #expect((node?.frame.height ?? 0) > tall, "and wraps over more lines than the sentence: \(String(describing: node?.frame.height))")
    }
}
