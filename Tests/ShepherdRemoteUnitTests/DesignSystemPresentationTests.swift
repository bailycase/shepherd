import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// A design system's words on its page: how fresh it is, what it holds, and where each token
/// came from.
@Suite("Design system presentation")
struct DesignSystemPresentationTests {
    static let now = Date(timeIntervalSince1970: 1_790_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: [
        (30.0, "synced just now"), (4 * 60.0, "synced 4m ago"), (3 * 3_600.0, "synced 3h ago"),
    ])
    func syncedSaysHowLongAgo(_ seconds: Double, _ text: String) {
        let info = DesignSystemInfo(namespace: "acme-web", title: "acme-web", createdAt: 0,
                                    syncedAt: (Self.now.timeIntervalSince1970 - seconds) * 1000)
        #expect(DesignSystemPresentation.synced(info, now: Self.now, locale: Locale(identifier: "en_US"), timeZone: Self.utc) == text)
    }

    @Test func aSystemNeverReadFromAProjectSaysNothing() {
        #expect(DesignSystemPresentation.synced(DesignSystemInfo(namespace: "night-watch", title: "Night Watch", createdAt: 0)) == nil)
    }

    @Test func countsAndDetailsReadAsThePageShowsThem() {
        #expect(DesignSystemPresentation.counts(DesignSystemCounts(colors: 11, type: 4, lengths: 7, components: 9))
                == "11 colors, 4 type styles, 7 spacing and radius steps, 9 components")
        #expect(DesignSystemPresentation.counts(DesignSystemCounts(colors: 1, type: 1, lengths: 1, components: 1))
                == "1 color, 1 type style, 1 spacing and radius step, 1 component")
        let accent = DesignSystemTokens.Color(name: "--accent", value: "#4f46e5", source: .init(file: "web/static/tokens.css", line: 8))
        #expect(DesignSystemPresentation.detail(accent) == "#4f46e5 · tokens.css:8")
        #expect(DesignSystemPresentation.detail(DesignSystemTokens.Color(name: "ink", value: "#111")) == "#111")
        #expect(DesignSystemPresentation.detail(DesignSystemTokens.TypeStyle(name: "display", size: 26, weight: 700)) == "26/700")
        #expect(DesignSystemPresentation.detail(DesignSystemTokens.TypeStyle(name: "body", size: 13.5)) == "13.5")
        #expect(DesignSystemPresentation.detail(DesignSystemTokens.Length(name: "--space-4", px: 16, source: .init(file: "tokens.css", line: 20)))
                == "16px · tokens.css:20")
    }

    // MARK: Colors

    @Test(arguments: [
        ("#4F46E5", "#4f46e5"), ("#abc", "#aabbcc"), ("#4f46e5ff", "#4f46e5"), ("#4f46e580", "#4f46e580"),
        ("rgb(79, 70, 229)", "#4f46e5"), ("rgb(79 70 229 / 50%)", "#4f46e580"), ("rgba(0,0,0,0.3)", "#0000004d"),
    ])
    func aColorReadsAsItsHex(_ value: String, _ hex: String) {
        #expect(DesignSystemPresentation.hex(value) == hex)
    }

    @Test(arguments: ["hsl(240 50% 50%)", "white", "var(--accent)", "rgb(300, 0, 0)", "rgb(1, 2)", "#12", "rgbx(1, 2, 3)", ""])
    func anythingElseIsNoHex(_ value: String) {
        #expect(DesignSystemPresentation.hex(value) == nil)
    }

    /// The card's four: accent, text, background and a status color by their names (the
    /// shortest name of each), then the rest in order; a color that isn't a hex is left out.
    @Test func swatchesStandForTheSystem() {
        let tokens = DesignSystemTokens(colors: [
            .init(name: "--accent", value: "#4f46e5"), .init(name: "--accent-soft", value: "#eef2ff"),
            .init(name: "--text", value: "#0f172a", dark: "#f8fafc"), .init(name: "--muted", value: "#64748b"),
            .init(name: "--bg", value: "#f8fafc"), .init(name: "--surface", value: "#ffffff"),
            .init(name: "--shadow", value: "0 1px 2px black"), .init(name: "--success", value: "#059669"),
        ])
        let swatches = DesignSystemPresentation.swatches(tokens, count: 4)
        #expect(swatches.map(\.light) == ["#4f46e5", "#0f172a", "#f8fafc", "#059669"])
        #expect(swatches[1].dark == "#f8fafc" && swatches[0].dark == "#4f46e5", "a color without a dark variant keeps its own")
        #expect(DesignSystemPresentation.swatches(tokens, count: 6).map(\.light).suffix(2) == ["#eef2ff", "#64748b"])
        #expect(DesignSystemPresentation.swatches(nil, count: 4).isEmpty)
        #expect(DesignSystemPresentation.background(tokens)?.light == "#f8fafc")
        #expect(DesignSystemPresentation.background(DesignSystemTokens(colors: [.init(name: "--ink", value: "#000")])) == nil)
    }

    @Test func aCardSaysWhereItsSystemWasRead() {
        #expect(DesignSystemPresentation.source(project: "dashboard-web", sources: ["web/static/tokens.css", "web/a.css"])
                == "dashboard-web · tokens.css")
        #expect(DesignSystemPresentation.source(project: "dashboard-web", sources: []) == "dashboard-web")
        #expect(DesignSystemPresentation.source(project: nil, sources: ["tokens.css"]) == "tokens.css")
        #expect(DesignSystemPresentation.source(project: nil, sources: []) == nil)
    }
}
