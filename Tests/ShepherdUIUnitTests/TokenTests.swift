import AppKit
import SwiftUI
import Testing
@testable import ShepherdUI

/// The palette, type ramp, scales, and `AgentState`. Text scale and density live on the shared
/// `ThemeStore`, so the suite is serialized and restores the defaults.
@Suite("Shepherd Design tokens", .serialized)
@MainActor
struct TokenTests {
    private func resolved(_ color: Color, dark: Bool) -> HexColor {
        var components = (0.0, 0.0, 0.0, 0.0)
        NSAppearance(named: dark ? .darkAqua : .aqua)!.performAsCurrentDrawingAppearance {
            let ns = NSColor(color).usingColorSpace(.sRGB)!
            components = (ns.redComponent, ns.greenComponent, ns.blueComponent, ns.alphaComponent)
        }
        return HexColor(red: components.0, green: components.1, blue: components.2, alpha: components.3)
    }

    private func close(_ a: HexColor, _ b: HexColor) -> Bool {
        abs(a.red - b.red) < 0.002 && abs(a.green - b.green) < 0.002 && abs(a.blue - b.blue) < 0.002 && abs(a.alpha - b.alpha) < 0.002
    }

    /// Each palette color follows the appearance it is drawn in.
    @Test(arguments: ["bgWindow", "lantern", "textSecondary", "bgSelected", "failedTint"])
    func paletteColorsResolveToTheThemeInEachAppearance(_ name: String) throws {
        let pairs: [String: (KeyPath<SHPalette, Color>, KeyPath<ThemeColors, String>)] = [
            "bgWindow": (\.bgWindow, \.bgWindow), "lantern": (\.lantern, \.lantern),
            "textSecondary": (\.textSecondary, \.textSecondary), "bgSelected": (\.bgSelected, \.bgSelected),
            "failedTint": (\.failedTint, \.failedTint),
        ]
        let (token, role) = try #require(pairs[name])
        let palette = SHPalette(.shepherdDesign)
        #expect(close(resolved(palette[keyPath: token], dark: true), HexColor(ThemeDefinition.shepherdDesign.dark.colors[keyPath: role])!))
        #expect(close(resolved(palette[keyPath: token], dark: false), HexColor(ThemeDefinition.shepherdDesign.light.colors[keyPath: role])!))
    }

    @Test func syntaxColorsResolveToTheThemesSyntaxRoles() {
        let palette = SHPalette(.shepherdDesign)
        #expect(close(resolved(palette.synKeyword, dark: true), HexColor(ThemeDefinition.shepherdDesign.dark.syntax.keyword)!))
        #expect(close(resolved(palette.synString, dark: false), HexColor(ThemeDefinition.shepherdDesign.light.syntax.string)!))
    }

    /// The Composer board puts the command palette "over a 30% scrim".
    @Test(arguments: [false, true])
    func theScrimIsBlackAtThirtyPercent(dark: Bool) {
        #expect(close(resolved(SHPalette(.shepherdDesign).scrim, dark: dark), HexColor(red: 0, green: 0, blue: 0, alpha: 0.3)))
    }

    /// A pane divider bordering the focused pane is running at 34%, a derived color rather than
    /// an alpha picked in the view.
    @Test(arguments: [false, true])
    func theFocusedPanesDividerIsRunningAtThirtyFourPercent(dark: Bool) throws {
        let colors = dark ? ThemeDefinition.shepherdDesign.dark.colors : ThemeDefinition.shepherdDesign.light.colors
        let running = try #require(HexColor(colors.running))
        #expect(close(resolved(SHPalette(.shepherdDesign).focusDivider, dark: dark),
                      HexColor(red: running.red, green: running.green, blue: running.blue, alpha: 0.34)))
    }

    /// The theme is resolved once: reads share one palette until another theme is selected.
    @Test func theStoreResolvesEachThemeOnce() {
        let store = ThemeStore()
        let first = store.palette
        #expect(store.palette === first)
        store.select(.shepherdDesign)
        #expect(store.palette === first, "selecting the same theme keeps the palette")
        var other = ThemeDefinition.shepherdDesign
        other.id = "other"
        other.dark.colors.lantern = "#ff0000"
        store.select(other)
        #expect(store.palette !== first)
        #expect(close(resolved(store.palette.lantern, dark: true), HexColor("#ff0000")!))
    }

    @Test func settingsGlyphsUseEverySuppliedVectorAsset() throws {
        for glyph in SHGlyph.Settings.allCases where glyph.systemSymbolName == nil {
            let svg = try String(contentsOf: #require(glyph.resourceURL), encoding: .utf8)
            #expect(svg.contains("<svg") && svg.contains("stroke="))
            #expect(!svg.contains("<script") && !svg.contains("href="))
        }
    }

    /// A user saw a lumpy, hand-traced gear on Advanced; it is the system `gearshape` the board draws.
    @Test func advancedDrawsTheSystemGear() throws {
        #expect(SHGlyph.Settings.advanced.systemSymbolName == "gearshape")
        #expect(SHGlyph.Settings.advanced.resourceURL == nil)
        #expect(NSImage(systemSymbolName: try #require(SHGlyph.Settings.advanced.systemSymbolName), accessibilityDescription: nil) != nil)
        #expect(SHGlyph.Settings.allCases.filter { $0.systemSymbolName != nil } == [.advanced])
    }

    @Test func theBundledFacesAreRegistered() {
        #expect(SHFonts.isAvailable)
        for name in ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold", "Geist-Italic", "GeistMono-Regular", "GeistMono-Medium"] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name)
        }
    }

    /// The Foundations board's ramp.
    @Test func theTypeRampMatchesTheBoard() {
        let spec: [SHTextStyle: (CGFloat, Font.Weight, CGFloat, Bool)] = [
            .display: (28, .semibold, 1.15, false), .title: (15, .semibold, 1.3, false),
            .headline: (13.5, .semibold, 1.35, false), .body: (13.5, .regular, 1.6, false),
            .ui: (12.5, .medium, 1.3, false), .caption: (11.5, .regular, 1.35, false),
            .code: (12, .regular, 1.55, true), .mono: (11.5, .regular, 1.3, true), .micro: (10.5, .medium, 1.2, true),
        ]
        for style in SHTextStyle.allCases {
            let (size, weight, lineHeight, mono) = spec[style]!
            #expect(style.size == size && style.weight == weight && style.lineHeight == lineHeight && style.isMonospaced == mono, "\(style)")
        }
    }

    /// A side transcript (the subagent inspector) sets prose one step under the thread: `.body`
    /// at the `.ui` size, still at the body's line height.
    @Test func smallProseIsOneStepUnderTheThread() {
        let ramp = SHTypeRamp(scale: 1)
        #expect(SHProseSize.regular.step == 0 && SHProseSize.small.step == SHTextStyle.body.size - SHTextStyle.ui.size)
        #if os(macOS)
        #expect(ramp.font(.body) == Font.custom("Geist-Regular", fixedSize: 13.5))
        #expect(ramp.font(.body, size: .small) == Font.custom("Geist-Regular", fixedSize: 12.5))
        #expect(ramp.font(.headline, size: .small) == Font.custom("Geist-SemiBold", fixedSize: 12.5))
        #else
        #expect(ramp.font(.body) == Font.custom("Geist-Regular", size: 13.5, relativeTo: .body))
        #expect(ramp.font(.body, size: .small) == Font.custom("Geist-Regular", size: 12.5, relativeTo: .body))
        #expect(ramp.font(.headline, size: .small) == Font.custom("Geist-SemiBold", size: 12.5, relativeTo: .headline))
        #endif
        #expect(ramp.lineSpacing(.body, size: .small) > 0 && ramp.lineSpacing(.body, size: .small) <= ramp.lineSpacing(.body))
    }

    @Test(arguments: [1.0, 1.25])
    func leadingScalesWithTextSize(scale: Double) {
        let saved = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = saved }
        ThemeStore.shared.textScale = 1
        let base = SHTextStyle.body.lineSpacing
        ThemeStore.shared.textScale = CGFloat(scale)
        #expect(ThemeStore.shared.typeRamp.scale == CGFloat(scale))
        #expect(SHTextStyle.body.lineSpacing >= base)
        #expect(SHTextStyle.body.lineSpacing > SHTextStyle.ui.lineSpacing, "prose is looser than controls")
    }

    @Test(arguments: [(1.0, 22.0, 28.0, 36.0), (0.85, 19.0, 24.0, 31.0), (1.2, 26.0, 34.0, 43.0)])
    func rowHeightsScaleWithDensityAndRoundToWholePoints(density: Double, compact: Double, row: Double, comfortable: Double) {
        let saved = ThemeStore.shared.density
        defer { ThemeStore.shared.density = saved }
        ThemeStore.shared.density = CGFloat(density)
        #expect(SH.Height.rowCompact == CGFloat(compact))
        #expect(SH.Height.row == CGFloat(row))
        #expect(SH.Height.rowComfortable == CGFloat(comfortable))
        #expect(SH.Height.controlS == 24 && SH.Height.controlM == 28 && SH.Height.controlL == 32 && SH.Height.touch == 44)
    }

    @Test func theScalesMatchTheBoard() {
        #expect([SH.Space.xxs, SH.Space.xs, SH.Space.s, SH.Space.m, SH.Space.l, SH.Space.xl, SH.Space.xxl, SH.Space.xxxl]
            == [2, 4, 6, 8, 12, 16, 24, 32])
        #expect([SH.Radius.xs, SH.Radius.s, SH.Radius.m, SH.Radius.l] == [4, 6, 8, 12])
        #expect(SH.hairline(2) == 0.5 && SH.hairline(1) == 1)
    }

    @Test func agentStatesHaveTheirWordsAndOnlyAttentionGlows() {
        #expect(AgentState.allCases.map(\.label) == ["Running", "Needs you", "Done", "Failed", "Stuck", "Queued", "Idle"])
        #expect(AgentState.allCases.filter(\.glows) == [.attention])
        #expect(AgentState.allCases.filter(\.isHollow) == [.queued])
    }

    @Test func agentStatesUseTheirStateColors() {
        let sh = Color.sh
        #expect(AgentState.running.color == sh.running && AgentState.attention.color == sh.lantern)
        #expect(AgentState.done.color == sh.done && AgentState.failed.color == sh.failed && AgentState.stuck.color == sh.failed)
        #expect(AgentState.attention.textColor == sh.lanternText && AgentState.attention.tint == sh.lanternTint)
        #expect(AgentState.idle.tint == nil && AgentState.queued.tint == nil)
    }
}
