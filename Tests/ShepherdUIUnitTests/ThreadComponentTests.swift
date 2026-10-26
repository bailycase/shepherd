import AppKit
import Foundation
import SwiftUI
import Testing
@testable import ShepherdUI

@Suite("Thread components")
struct ThreadComponentTests {
    @Test(arguments: [false, true])
    @MainActor func nativeCodeKeepsUnicodeAndSyntaxColorsWhenTheAppearanceChanges(dark: Bool) throws {
        var keyword = AttributedString("let")
        keyword.foregroundColor = Color.nw.synKeyword
        let source = keyword + AttributedString(" sheep = \"🐑\"\nlet tail")
        let font = NSFont.monospacedSystemFont(ofSize: NWTextStyle.code.size, weight: .regular)
        let native = NWNativeCodeText.attributedCode(String(source.characters), highlighted: source,
                                                    font: font, lineSpacing: 4)
        #expect(native.string == "let sheep = \"🐑\"\nlet tail")
        #expect(source.runs.first?.foregroundColor == Color.nw.synKeyword, "cached highlights stay untouched")
        #expect(native.attribute(.font, at: 0, effectiveRange: nil) as? NSFont == font)
        let color = try #require(native.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor)
        let plain = try #require(native.attribute(.foregroundColor, at: 4, effectiveRange: nil) as? NSColor)
        // Resolve the same native attributes in both appearances, as a retained block does.
        for appearance in [dark, !dark] {
            let theme = appearance ? ThemeDefinition.nightWatch.dark : ThemeDefinition.nightWatch.light
            let expected = try #require(HexColor(theme.syntax.keyword))
            let expectedPlain = try #require(HexColor(theme.colors.textPrimary))
            NSAppearance(named: appearance ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
                for (actual, role) in [(color, expected), (plain, expectedPlain)] {
                    let rgb = actual.usingColorSpace(.sRGB)!
                    #expect(abs(rgb.redComponent - role.red) < 0.002)
                    #expect(abs(rgb.greenComponent - role.green) < 0.002)
                    #expect(abs(rgb.blueComponent - role.blue) < 0.002)
                }
            }
        }
    }

    @Test(arguments: [false, true])
    @MainActor func nativeCodeConversionMatchesTheGeneralBridge(extraAttributes: Bool) {
        var keyword = AttributedString("let")
        keyword.foregroundColor = Color.nw.synKeyword
        var value = AttributedString("e\u{301} 👩🏾‍💻 🐑")
        value.foregroundColor = Color.nw.synString
        if extraAttributes { value.link = URL(string: "https://example.com/code") }
        let source = keyword + AttributedString(" value = \"") + value + AttributedString("\"\n") + keyword
        let untouched = source
        let font = NSFont.monospacedSystemFont(ofSize: NWTextStyle.code.size, weight: .regular)
        let actual = NWNativeCodeText.attributedCode(String(source.characters), highlighted: source, font: font, lineSpacing: 4)

        // The original Foundation bridge is the reference, including attributes that the
        // syntax-only fast path must leave to it. Compare UTF-16 runs, not just visible words.
        let expected = NSMutableAttributedString(attributedString: NSAttributedString(source))
        let range = NSRange(location: 0, length: expected.length)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 4
        paragraph.lineBreakMode = .byClipping
        expected.addAttributes([.font: font, .foregroundColor: NSColor(Color.nw.textPrimary),
                                .paragraphStyle: paragraph], range: range)
        let key = NSAttributedString.Key(AttributeScopes.SwiftUIAttributes.ForegroundColorAttribute.name)
        expected.enumerateAttribute(key, in: range) { value, run, _ in
            if let color = value as? Color { expected.addAttribute(.foregroundColor, value: NSColor(color), range: run) }
        }
        expected.removeAttribute(key, range: range)
        #expect(actual == expected)
        #expect(source == untouched)
    }

    @Test @MainActor func recreatedCodeCachesReuseValuesButNotDifferentStyles() {
        let font = NSFont.monospacedSystemFont(ofSize: NWTextStyle.code.size, weight: .regular)
        let content = NWNativeCodeText.Content(code: "// shared-cache fixture 🐑", highlighted: nil,
                                               font: font, lineSpacing: 4, foreground: Color.nw.textPrimary)
        let original = NWNativeCodeText.Cache()
        let value = original.value(for: content)
        original.intrinsicSize = CGSize(width: 220, height: 20)
        let recreated = NWNativeCodeText.Cache()
        #expect(recreated.value(for: content) === value)
        #expect(recreated.intrinsicSize == original.intrinsicSize)

        let changed = NWNativeCodeText.Content(code: content.code, highlighted: content.highlighted,
                                               font: font, lineSpacing: 8, foreground: content.foreground)
        #expect(recreated.value(for: changed) !== value)
        #expect(recreated.intrinsicSize == nil, "a same-text cache hit must not reuse different geometry")
        #expect(original.intrinsicSize == CGSize(width: 220, height: 20), "existing views keep their own valid entry")
    }

    @Test @MainActor func oversizedCodeIsNotRetainedAcrossViews() {
        let font = NSFont.monospacedSystemFont(ofSize: NWTextStyle.code.size, weight: .regular)
        let content = NWNativeCodeText.Content(code: String(repeating: "x", count: 3 * 1024 * 1024), highlighted: nil,
                                               font: font, lineSpacing: 4, foreground: Color.nw.textPrimary)
        let first = NWNativeCodeText.Cache().value(for: content)
        let second = NWNativeCodeText.Cache().value(for: content)
        #expect(first !== second, "an entry over the estimated byte budget is owned only by its live view")
    }

    /// Only thinking with something to open is a disclosure with a chevron: live "Thinking…" with
    /// nothing shared yet and a thought the model kept back are plain lines; live thinking whose
    /// summary arrived opens onto it (ResponseVisibility › B).
    @Test(arguments: [
        (live: true, blocks: [], kind: .live),
        (live: true, blocks: [.paragraph("hmm")], kind: .liveDisclosure),
        (live: false, blocks: [], kind: .plain),
        (live: false, blocks: [.paragraph("**Inspecting SSH config**")], kind: .disclosure),
    ] as [(live: Bool, blocks: [NWProseBlock], kind: NWThinking.Kind)])
    func thinkingOpensOnlyOntoText(live: Bool, blocks: [NWProseBlock], kind: NWThinking.Kind) {
        #expect(NWThinking.Kind(live: live, blocks: blocks) == kind)
        #expect(NWThinking.Kind(live: live, blocks: blocks).opens == (kind == .disclosure || kind == .liveDisclosure))
    }

    /// Plain-text thinking (no Markdown read) is a paragraph per blank-line run, with no empty
    /// paragraph where a run of blank lines was.
    @Test(arguments: [
        ("", []),
        ("\n\n", []),
        ("One.", ["One."]),
        ("One.\n\n\n\nTwo.\n\n", ["One.", "Two."]),
    ] as [(String, [String])])
    @MainActor func plainTextThinkingIsItsParagraphs(text: String, paragraphs: [String]) {
        let thinking = NWThinking("Thought", text: text, isExpanded: .constant(true))
        #expect(thinking.blocks == paragraphs.map { .paragraph(AttributedString($0)) })
    }

    /// A message's time and a turn's footer are hidden at rest. The pointer over the message
    /// shows them, and so does keyboard focus on one of their controls, a copy confirming, or
    /// VoiceOver running, so they are always reachable.
    @Test(arguments: [
        (hovering: false, focused: false, confirming: false, voiceOver: false, shown: false),
        (hovering: true, focused: false, confirming: false, voiceOver: false, shown: true),
        (hovering: false, focused: true, confirming: false, voiceOver: false, shown: true),
        (hovering: false, focused: false, confirming: true, voiceOver: false, shown: true),
        (hovering: false, focused: false, confirming: false, voiceOver: true, shown: true),
    ])
    func messageDetailsShowOnlyWhenTheMessageIsHoveredOrReachedAnotherWay(
        hovering: Bool, focused: Bool, confirming: Bool, voiceOver: Bool, shown: Bool
    ) {
        #expect(NWMessageDetails.shown(hovering: hovering, focused: focused, confirming: confirming, voiceOver: voiceOver) == shown)
    }
}
