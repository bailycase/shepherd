import AppKit
import SwiftUI
import Testing
@testable import ShepherdUI

/// The palette, type ramp, scales, and `AgentState`. Text scale and density live on the shared
/// `ThemeStore`, so the suite is serialized and restores the defaults.
@Suite("Night Watch tokens", .serialized)
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
        let pairs: [String: (KeyPath<NWPalette, Color>, KeyPath<ThemeColors, String>)] = [
            "bgWindow": (\.bgWindow, \.bgWindow), "lantern": (\.lantern, \.lantern),
            "textSecondary": (\.textSecondary, \.textSecondary), "bgSelected": (\.bgSelected, \.bgSelected),
            "failedTint": (\.failedTint, \.failedTint),
        ]
        let (token, role) = try #require(pairs[name])
        let palette = NWPalette(.nightWatch)
        #expect(close(resolved(palette[keyPath: token], dark: true), HexColor(ThemeDefinition.nightWatch.dark.colors[keyPath: role])!))
        #expect(close(resolved(palette[keyPath: token], dark: false), HexColor(ThemeDefinition.nightWatch.light.colors[keyPath: role])!))
    }

    @Test func syntaxColorsResolveToTheThemesSyntaxRoles() {
        let palette = NWPalette(.nightWatch)
        #expect(close(resolved(palette.synKeyword, dark: true), HexColor(ThemeDefinition.nightWatch.dark.syntax.keyword)!))
        #expect(close(resolved(palette.synString, dark: false), HexColor(ThemeDefinition.nightWatch.light.syntax.string)!))
    }

    /// The Composer board puts the command palette "over a 30% scrim".
    @Test(arguments: [false, true])
    func theScrimIsBlackAtThirtyPercent(dark: Bool) {
        #expect(close(resolved(NWPalette(.nightWatch).scrim, dark: dark), HexColor(red: 0, green: 0, blue: 0, alpha: 0.3)))
    }

    /// A pane divider bordering the focused pane is running at 34%, a derived color rather than
    /// an alpha picked in the view.
    @Test(arguments: [false, true])
    func theFocusedPanesDividerIsRunningAtThirtyFourPercent(dark: Bool) throws {
        let colors = dark ? ThemeDefinition.nightWatch.dark.colors : ThemeDefinition.nightWatch.light.colors
        let running = try #require(HexColor(colors.running))
        #expect(close(resolved(NWPalette(.nightWatch).focusDivider, dark: dark),
                      HexColor(red: running.red, green: running.green, blue: running.blue, alpha: 0.34)))
    }

    /// The theme is resolved once: reads share one palette until another theme is selected.
    @Test func theStoreResolvesEachThemeOnce() {
        let store = ThemeStore()
        let first = store.palette
        #expect(store.palette === first)
        store.select(.nightWatch)
        #expect(store.palette === first, "selecting the same theme keeps the palette")
        var other = ThemeDefinition.nightWatch
        other.id = "other"
        other.dark.colors.lantern = "#ff0000"
        store.select(other)
        #expect(store.palette !== first)
        #expect(close(resolved(store.palette.lantern, dark: true), HexColor("#ff0000")!))
    }

    @Test func theBundledFacesAreRegistered() {
        #expect(NWFonts.isAvailable)
        for name in ["Geist-Regular", "Geist-Medium", "Geist-SemiBold", "Geist-Bold", "Geist-Italic", "GeistMono-Regular", "GeistMono-Medium"] {
            let font = CTFontCreateWithName(name as CFString, 12, nil)
            #expect(CTFontCopyPostScriptName(font) as String == name)
        }
    }

    /// The Foundations board's ramp.
    @Test func theTypeRampMatchesTheBoard() {
        let spec: [NWTextStyle: (CGFloat, Font.Weight, CGFloat, Bool)] = [
            .display: (28, .semibold, 1.15, false), .title: (15, .semibold, 1.3, false),
            .headline: (13.5, .semibold, 1.35, false), .body: (13.5, .regular, 1.6, false),
            .ui: (12.5, .medium, 1.3, false), .caption: (11.5, .regular, 1.35, false),
            .code: (12, .regular, 1.55, true), .mono: (11.5, .regular, 1.3, true), .micro: (10.5, .medium, 1.2, true),
        ]
        for style in NWTextStyle.allCases {
            let (size, weight, lineHeight, mono) = spec[style]!
            #expect(style.size == size && style.weight == weight && style.lineHeight == lineHeight && style.isMonospaced == mono, "\(style)")
        }
    }

    /// A side transcript (the subagent inspector) sets prose one step under the thread: `.body`
    /// at the `.ui` size, still at the body's line height.
    @Test func smallProseIsOneStepUnderTheThread() {
        let ramp = NWTypeRamp(scale: 1)
        #expect(NWProseSize.regular.step == 0 && NWProseSize.small.step == NWTextStyle.body.size - NWTextStyle.ui.size)
        #expect(ramp.font(.body) == Font.custom("Geist-Regular", size: 13.5, relativeTo: .body))
        #expect(ramp.font(.body, size: .small) == Font.custom("Geist-Regular", size: 12.5, relativeTo: .body))
        #expect(ramp.font(.headline, size: .small) == Font.custom("Geist-SemiBold", size: 12.5, relativeTo: .headline))
        #expect(ramp.lineSpacing(.body, size: .small) > 0 && ramp.lineSpacing(.body, size: .small) <= ramp.lineSpacing(.body))
    }

    @Test(arguments: [1.0, 1.25])
    func leadingScalesWithTextSize(scale: Double) {
        let saved = ThemeStore.shared.textScale
        defer { ThemeStore.shared.textScale = saved }
        ThemeStore.shared.textScale = 1
        let base = NWTextStyle.body.lineSpacing
        ThemeStore.shared.textScale = CGFloat(scale)
        #expect(ThemeStore.shared.typeRamp.scale == CGFloat(scale))
        #expect(NWTextStyle.body.lineSpacing >= base)
        #expect(NWTextStyle.body.lineSpacing > NWTextStyle.ui.lineSpacing, "prose is looser than controls")
    }

    @Test(arguments: [(1.0, 22.0, 28.0, 36.0), (0.85, 19.0, 24.0, 31.0), (1.2, 26.0, 34.0, 43.0)])
    func rowHeightsScaleWithDensityAndRoundToWholePoints(density: Double, compact: Double, row: Double, comfortable: Double) {
        let saved = ThemeStore.shared.density
        defer { ThemeStore.shared.density = saved }
        ThemeStore.shared.density = CGFloat(density)
        #expect(NW.Height.rowCompact == CGFloat(compact))
        #expect(NW.Height.row == CGFloat(row))
        #expect(NW.Height.rowComfortable == CGFloat(comfortable))
        #expect(NW.Height.controlS == 24 && NW.Height.controlM == 28 && NW.Height.controlL == 32 && NW.Height.touch == 44)
    }

    @Test func theScalesMatchTheBoard() {
        #expect([NW.Space.xxs, NW.Space.xs, NW.Space.s, NW.Space.m, NW.Space.l, NW.Space.xl, NW.Space.xxl, NW.Space.xxxl]
            == [2, 4, 6, 8, 12, 16, 24, 32])
        #expect([NW.Radius.xs, NW.Radius.s, NW.Radius.m, NW.Radius.l] == [4, 6, 8, 12])
        #expect(NW.hairline(2) == 0.5 && NW.hairline(1) == 1)
    }

    @Test func motionHonorsReduceMotion() {
        #expect(NW.Motion.glow.duration == 1.6 && NW.Motion.spin.duration == 1)
        #expect(NW.Motion.hover.duration == 0.12 && NW.Motion.pane.duration == 0.18 && NW.Motion.sheet.duration == 0.24)
        #expect(NW.Motion.glow.animation(reduceMotion: true) == nil)
        #expect(NW.Motion.spin.animation(reduceMotion: true) == nil)
        #expect(NW.Motion.pane.animation(reduceMotion: true) != nil, "panes still cross-fade")
    }

    @Test func theGlowPulsesBetweenFullAndDim() {
        let start = Date(timeIntervalSinceReferenceDate: 0)
        #expect(abs(NWPhase.glowOpacity(start) - 1) < 1e-9)
        #expect(abs(NWPhase.glowOpacity(start.addingTimeInterval(0.8)) - 0.35) < 1e-9)
    }

    @Test func agentStatesHaveTheirWordsAndOnlyAttentionGlows() {
        #expect(AgentState.allCases.map(\.label) == ["Running", "Needs you", "Done", "Failed", "Stuck", "Queued", "Idle"])
        #expect(AgentState.allCases.filter(\.glows) == [.attention])
        #expect(AgentState.allCases.filter(\.isHollow) == [.queued])
    }

    @Test func agentStatesUseTheirStateColors() {
        let nw = Color.nw
        #expect(AgentState.running.color == nw.running && AgentState.attention.color == nw.lantern)
        #expect(AgentState.done.color == nw.done && AgentState.failed.color == nw.failed && AgentState.stuck.color == nw.failed)
        #expect(AgentState.attention.textColor == nw.lanternText && AgentState.attention.tint == nw.lanternTint)
        #expect(AgentState.idle.tint == nil && AgentState.queued.tint == nil)
    }
}
