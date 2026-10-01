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

    /// Only thinking with something to open is a disclosure with a chevron: live "Thinking…"
    /// and a thought the model kept back are plain lines, whatever they carry.
    @Test(arguments: [
        (live: true, blocks: [], kind: .live),
        (live: true, blocks: [.paragraph("hmm")], kind: .live),
        (live: false, blocks: [], kind: .plain),
        (live: false, blocks: [.paragraph("**Inspecting SSH config**")], kind: .disclosure),
    ] as [(live: Bool, blocks: [NWProseBlock], kind: NWThinking.Kind)])
    func thinkingOpensOnlyOntoText(live: Bool, blocks: [NWProseBlock], kind: NWThinking.Kind) {
        #expect(NWThinking.Kind(live: live, blocks: blocks) == kind)
        #expect(NWThinking.Kind(live: live, blocks: blocks).opens == (kind == .disclosure))
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
