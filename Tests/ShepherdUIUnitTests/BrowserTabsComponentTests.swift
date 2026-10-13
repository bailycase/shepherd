import Foundation
import Testing
@testable import ShepherdUI

@Suite("Browser tabs components")
struct BrowserTabsComponentTests {
    @Test func theBoardsMeasures() {
        #expect(NWBrowserTabsMetrics.stripHeight == 38 && NWBrowserTabsMetrics.tabHeight == 26)
        #expect(NWBrowserTabsMetrics.menuWidth == 260 && NWBrowserTabsMetrics.favicon == 12 && NWBrowserTabsMetrics.unseenDot == 6)
        #expect(NWBrowserTabsMetrics.agentBarHeight == NWBrowserMetrics.consoleBarHeight, "the agent's bar is as tall as the console's")
        #expect(NWBrowserTabsMetrics.closeWidth >= 24, "a close button meets the desktop hit area")
    }

    @Test(arguments: [(NWBrowserTabSource.user, nil as String?), (.agent, "Agent"), (.link, "Link")])
    func theListTagsHowATabOpened(source: NWBrowserTabSource, tag: String?) {
        #expect(source.tag == tag)
    }

    @Test(arguments: [("docs.stripe.com", "stripe", "S"), ("grafana.internal:3000", "grafana", "G"), ("staging.acme.dev", "acme", "A"),
                      ("localhost:3000", "localhost", "L"), ("127.0.0.1:5173", "127.0.0.1", "1"), ("[::1]:8080", "[::1]", "1"), ("[::1]", "[::1]", "1"),
                      ("[2001:db8::1]:443", "[2001:db8::1]", "2"), ("", "", "·")])
    func theTileNamesTheSite(host: String, name: String, letter: String) {
        #expect(NWBrowserTabTint.siteName(host: host) == name)
        #expect(NWBrowserTabTint.initial(host: host) == letter)
    }

    @Test func aSiteKeepsItsColorAndLoopbackIsRunning() {
        #expect(NWBrowserTabTint.forHost("docs.stripe.com") == NWBrowserTabTint.forHost("dashboard.stripe.com"), "one site, one color")
        for loopback in ["localhost:3000", "127.0.0.1:5173", "[::1]:8080", "[::1]", "LOCALHOST"] { #expect(NWBrowserTabTint.forHost(loopback) == .running) }
        let others = Set(["stripe.com", "grafana.internal", "acme.dev", "github.com", "example.org", "mozilla.org"].map(NWBrowserTabTint.forHost))
        #expect(!others.contains(.running), "only loopback is running")
        #expect(others.count > 1, "other sites spread over the other three")
    }

    @Test func aTabSpeaksItsTitleThenWhatIsWorthKnowing() {
        let id = UUID()
        func item(unseen: Bool, active: Bool) -> NWBrowserTabItem {
            NWBrowserTabItem(id: id, title: "Checkout", address: "localhost:3000/checkout", letter: "C", tint: .running, source: .agent,
                             agentActive: active, unseen: unseen)
        }
        #expect(item(unseen: false, active: false).spoken == "Checkout")
        #expect(item(unseen: true, active: false).spoken == "Checkout, new")
        #expect(item(unseen: false, active: true).spoken == "Checkout, agent is using it")
        #expect(item(unseen: false, active: false).tooltip == "localhost:3000/checkout · opened by the agent")
    }
}
