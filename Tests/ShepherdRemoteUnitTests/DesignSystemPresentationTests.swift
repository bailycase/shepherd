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
}
