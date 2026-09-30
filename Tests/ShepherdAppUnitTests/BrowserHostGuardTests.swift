import Foundation
import Testing
import ShepherdProtocol
import ShepherdRemote
@testable import ShepherdApp

/// What a host's agent may ask of a page on the viewer's Mac (docs/browser.md › Remote › What a
/// host's agent can make this Mac do), decided without a web view: the address it may open, and the
/// page it may read or act on. The resolver is injected, so nothing is looked up.
@Suite("Browser host guard")
struct BrowserHostGuardTests {
    private let guardian = BrowserHostGuard(policy: BrowserViewerPolicy(
        resolver: { ["app.example": ["93.184.216.34"], "evil.example": ["127.0.0.1"]][$0] }, localAddresses: { [] }))

    private func refusal(_ outcome: BrowserOutcome?) -> (code: String, message: String)? {
        if case .failure(let code, let message)? = outcome { return (code, message) }
        return nil
    }

    private func url(_ text: String) -> URL { URL(string: text)! }

    // MARK: browser_open

    @Test(arguments: [
        "http://localhost:5173/", "http://127.0.0.1:3000/x", "http://[::1]:8080/", "https://app.example/login", "http://93.184.216.34/",
        "localhost:5173/checkout", "about:blank",
    ])
    func theHostsLoopbackAndPublicAddressesOpen(_ address: String) async {
        #expect(await guardian.refusal(for: .open(url: address, note: nil), page: nil, historyTarget: nil) == nil)
    }

    @Test(arguments: [
        "http://192.168.1.1/", "http://10.0.0.4:8080/", "http://169.254.169.254/", "http://127.0.0.2:5173/", "http://0.0.0.0/", "http://printer/",
        "http://x.local/", "https://evil.example/", "http://[fd00::1]/", "http://2130706433/", "192.168.1.1:8080", "router.local/admin",
    ])
    func anAddressOnTheViewersNetworkIsRefusedWithARefusedUrl(_ address: String) async {
        let refused = refusal(await guardian.refusal(for: .open(url: address, note: nil), page: nil, historyTarget: nil))
        #expect(refused?.code == "refused_url" && refused?.message.contains("network of the Mac showing this page") == true, "\(address): \(String(describing: refused))")
    }

    @Test func anAddressTheDriverItselfRefusesIsLeftToTheDriver() async {
        // `file:` and the like are BrowserURLPolicy's own refusal, worded there.
        #expect(await guardian.refusal(for: .open(url: "file:///etc/hosts", note: nil), page: nil, historyTarget: nil) == nil)
        #expect(await guardian.refusal(for: .open(url: "", note: nil), page: nil, historyTarget: nil) == nil)
    }

    @Test func openingIsAllowedFromAPageThatIsOnTheViewersNetwork() async {
        // It leaves that page, which is what the agent needs to do.
        let page = url("http://192.168.1.1/admin")
        #expect(await guardian.refusal(for: .open(url: "http://localhost:5173/", note: nil), page: page, historyTarget: nil) == nil)
    }

    // MARK: Every other request reads or acts on the page open now

    static let others: [BrowserRequest] = [
        .read(selector: nil, maxChars: nil), .click(ref: "e1", double: false, note: nil), .type(ref: "e1", text: "x", clear: false, submit: false, note: nil),
        .press(key: "Enter", note: nil), .scroll(direction: "down", amount: nil, ref: nil, note: nil), .wait(text: "x", ref: nil, gone: false, ms: nil, timeout: nil),
        .screenshot(ref: nil), .console(clear: false), .eval(expression: "document.title", note: nil), .back(note: nil), .forward(note: nil), .reload(note: nil),
    ]

    @Test(arguments: others)
    func anAgentReadsAndActsOnlyOnAPageItMayBeShown(_ request: BrowserRequest) async {
        let allowed = [url("http://localhost:5173/checkout"), url("https://app.example/"), url("about:blank"), url("blob:https://app.example/x")]
        for page in allowed { #expect(await guardian.refusal(for: request, page: page, historyTarget: nil) == nil, "\(page)") }
        let refused = [url("http://192.168.1.1/admin"), url("file:///Users/me/notes.txt"), url("https://evil.example/"), url("http://printer/"),
                       url("http://127.0.0.2:5173/"), url("data:text/html,hi"), url("blob:http://10.0.0.1/x")]
        for page in refused {
            let outcome = refusal(await guardian.refusal(for: request, page: page, historyTarget: nil))
            #expect(outcome?.code == "refused_url" && outcome?.message == BrowserHostGuard.pageMessage, "\(request) on \(page)")
            #expect(outcome?.message.contains(page.absoluteString) == false, "nothing of the page's address goes to the agent")
        }
    }

    @Test func aHistoryStepIsRefusedWhenItWouldLandOnTheViewersNetwork() async {
        let page = url("http://localhost:5173/")
        let private1 = url("http://192.168.1.1/admin")
        for step in [BrowserRequest.back(note: nil), .forward(note: nil)] {
            let outcome = refusal(await guardian.refusal(for: step, page: page, historyTarget: private1))
            #expect(outcome?.code == "refused_url" && outcome?.message.contains("network of the Mac showing this page") == true)
            #expect(await guardian.refusal(for: step, page: page, historyTarget: url("https://app.example/")) == nil)
            #expect(await guardian.refusal(for: step, page: page, historyTarget: nil) == nil)
        }
    }

    @Test func noPageReadsNothingAndIsLeftToTheDriversNoPageAnswer() async {
        #expect(await guardian.refusal(for: .read(selector: nil, maxChars: nil), page: nil, historyTarget: nil) == nil)
        #expect(await guardian.pageRefusal(nil) == nil)
    }

    @Test func aPageTheAgentMayNotBeShownIsRefusedAfterAnActionToo() async {
        #expect(await guardian.pageRefusal(url("http://localhost:5173/")) == nil)
        #expect(refusal(await guardian.pageRefusal(url("http://192.168.1.1/")))?.code == "refused_url")
        #expect(BrowserHostGuard.pageMessage.contains("browser_open") && BrowserHostGuard.pageMessage.contains("localhost or a public address"))
    }

    @Test func aHistoryRequestNamesItsStep() {
        #expect(BrowserHostGuard.historyStep(of: .back(note: nil)) == .back)
        #expect(BrowserHostGuard.historyStep(of: .forward(note: nil)) == .forward)
        #expect(BrowserHostGuard.historyStep(of: .reload(note: nil)) == .reload)
        #expect(BrowserHostGuard.historyStep(of: .read(selector: nil, maxChars: nil)) == nil)
        #expect(BrowserHostGuard.historyStep(of: .open(url: "http://localhost/", note: nil)) == nil)
    }

    // MARK: The result

    @Test func aBlockedNavigationIsSaidInTheResultsTrailer() {
        let events = BrowserEvents(blocked: ["That address is on the network of the Mac showing this page, not this host's."])
        #expect(!events.isEmpty)
        #expect(BrowserReport.trailer(events) == ["A navigation was blocked: That address is on the network of the Mac showing this page, not this host's."])
        #expect(BrowserReport.trailer(BrowserEvents()).isEmpty)
        let text = BrowserReport.compose(title: "Frames", url: "http://localhost:5173/frames", body: "- heading \"Frames\"", events: events)
        #expect(text.hasSuffix("A navigation was blocked: That address is on the network of the Mac showing this page, not this host's."))
    }

    @Test func aHostsAgentMayHaveAHandfulOfThePagesPorts() {
        #expect(BrowserHostGuard.maxForwardedPorts == 8)
    }
}
