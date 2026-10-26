import Foundation
import Testing
@testable import ShepherdUI

@Suite("Browser tabs components")
struct BrowserTabsComponentTests {
    @Test func theBoardsMeasures() {
        #expect(SHBrowserTabsMetrics.stripHeight == 38 && SHBrowserTabsMetrics.tabHeight == 26)
        #expect(SHBrowserTabsMetrics.menuWidth == 260 && SHBrowserTabsMetrics.favicon == 12 && SHBrowserTabsMetrics.unseenDot == 6)
        #expect(SHBrowserTabsMetrics.agentBarHeight == SHBrowserMetrics.consoleBarHeight, "the agent's bar is as tall as the console's")
        #expect(SHBrowserTabsMetrics.closeWidth >= 24, "a close button meets the desktop hit area")
    }

    @Test(arguments: [(SHBrowserTabSource.user, nil as String?), (.agent, "Agent"), (.link, "Link")])
    func theListTagsHowATabOpened(source: SHBrowserTabSource, tag: String?) {
        #expect(source.tag == tag)
    }

    @Test(arguments: [("docs.stripe.com", "stripe", "S"), ("grafana.internal:3000", "grafana", "G"), ("staging.acme.dev", "acme", "A"),
                      ("localhost:3000", "localhost", "L"), ("127.0.0.1:5173", "127.0.0.1", "1"), ("[::1]:8080", "[::1]", "1"), ("[::1]", "[::1]", "1"),
                      ("[2001:db8::1]:443", "[2001:db8::1]", "2"), ("", "", "·")])
    func theTileNamesTheSite(host: String, name: String, letter: String) {
        #expect(SHBrowserTabTint.siteName(host: host) == name)
        #expect(SHBrowserTabTint.initial(host: host) == letter)
    }

    @Test func aSiteKeepsItsColorAndLoopbackIsRunning() {
        #expect(SHBrowserTabTint.forHost("docs.stripe.com") == SHBrowserTabTint.forHost("dashboard.stripe.com"), "one site, one color")
        for loopback in ["localhost:3000", "127.0.0.1:5173", "[::1]:8080", "[::1]", "LOCALHOST"] { #expect(SHBrowserTabTint.forHost(loopback) == .running) }
        let others = Set(["stripe.com", "grafana.internal", "acme.dev", "github.com", "example.org", "mozilla.org"].map(SHBrowserTabTint.forHost))
        #expect(!others.contains(.running), "only loopback is running")
        #expect(others.count > 1, "other sites spread over the other three")
    }

    @Test func aTabSpeaksItsTitleThenWhatIsWorthKnowing() {
        let id = UUID()
        func item(unseen: Bool, active: Bool) -> SHBrowserTabItem {
            SHBrowserTabItem(id: id, title: "Checkout", address: "localhost:3000/checkout", letter: "C", tint: .running, source: .agent,
                             agentActive: active, unseen: unseen)
        }
        #expect(item(unseen: false, active: false).spoken == "Checkout")
        #expect(item(unseen: true, active: false).spoken == "Checkout, new")
        #expect(item(unseen: false, active: true).spoken == "Checkout, agent is using it")
        #expect(item(unseen: false, active: false).tooltip == "localhost:3000/checkout · opened by the agent")
    }
}
