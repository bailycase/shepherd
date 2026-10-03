import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdTestKit
import ShepherdUI
import Testing
@testable import ShepherdApp

/// The Browser tab's rules (docs/design/side-pane-changes.md › Side pane › Browser): the address field, the viewport
/// widths, the dev servers a repository offers, what the page's scripts report, and where a
/// picked element's popover goes.
@Suite("Browser")
struct BrowserTests {
    // MARK: Address

    @Test(arguments: [
        ("localhost:5173/checkout", "http://localhost:5173/checkout"),
        (":5173", "http://localhost:5173"),
        (":5173/cart", "http://localhost:5173/cart"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("192.168.1.20:3000/x", "http://192.168.1.20:3000/x"),
        ("acme.test", "http://acme.test"),
        ("app.local:4000", "http://app.local:4000"),
        ("acme.dev", "https://acme.dev"),
        ("github.com/bailycase/shepherd", "https://github.com/bailycase/shepherd"),
        ("https://example.com/a?b=c", "https://example.com/a?b=c"),
        ("HTTP://Example.com", "HTTP://Example.com"),
        ("about:blank", "about:blank"),
        ("  localhost:3000  ", "http://localhost:3000"),
    ])
    func theAddressTakesAURL(_ input: String, _ url: String) {
        #expect(BrowserAddress.resolve(input)?.absoluteString == url)
    }

    @Test(arguments: [
        ("swiftui lazy stack", "https://www.google.com/search?q=swiftui%20lazy%20stack"),
        ("vite", "https://www.google.com/search?q=vite"),
        ("a&b=c", "https://www.google.com/search?q=a%26b%3Dc"),
        ("1.2", "https://www.google.com/search?q=1.2"),
    ])
    func anythingElseIsASearch(_ input: String, _ url: String) {
        #expect(BrowserAddress.resolve(input)?.absoluteString == url)
    }

    @Test func nothingOpensNothing() {
        #expect(BrowserAddress.resolve("   ") == nil)
    }

    @Test(arguments: [
        ("http://localhost:5173/checkout", "localhost:5173", "/checkout"),
        ("http://localhost:5173/", "localhost:5173", ""),
        ("https://acme.dev/cart?promo=FALL24#pay", "acme.dev", "/cart?promo=FALL24#pay"),
        ("http://[::1]:8080/x", "[::1]:8080", "/x"),
        ("file:///tmp/a.html", "file:///tmp/a.html", ""),
    ])
    func theCapsuleShowsTheHostThenThePath(_ url: String, _ host: String, _ path: String) throws {
        let shown = try #require(BrowserAddress.display(URL(string: url)))
        #expect(shown.host == host && shown.path == path)
    }

    @Test func noPageShowsThePlaceholder() {
        #expect(BrowserAddress.display(nil) == nil)
        #expect(BrowserAddress.display(URL(string: "about:blank")) == nil)
        #expect(BrowserAddress.editingText(nil).isEmpty)
        #expect(BrowserAddress.editingText(URL(string: "http://localhost:5173/a")) == "http://localhost:5173/a")
    }

    // MARK: Viewport

    @Test func theMenuOffersTheBoardsWidthsInOrder() {
        #expect(BrowserViewport.allCases.map(\.option) == [
            NWViewportOption(id: "fit", title: "Fit the pane"),
            NWViewportOption(id: "phone", title: "iPhone 16", width: "393"),
            NWViewportOption(id: "tablet", title: "iPad mini", width: "744"),
            NWViewportOption(id: "laptop", title: "Laptop", width: "1280"),
        ])
    }

    @Test(arguments: [
        // viewport, available → width, zoom, framed
        (BrowserViewport.fit, 600.0, 600.0, 1.0, false),
        (.phone, 600, 393, 1, true),
        (.tablet, 600, 576, 576.0 / 744, true),
        (.laptop, 1400, 1280, 1, true),
        (.laptop, 600, 576, 576.0 / 1280, true),
        (.phone, 393, 369, 369.0 / 393, true),
    ] as [(BrowserViewport, Double, Double, Double, Bool)])
    func aChosenWidthSitsInAFrameAndShrinksToFit(_ viewport: BrowserViewport, available: Double, width: Double, zoom: Double, framed: Bool) {
        let layout = viewport.layout(available: available, margin: 12)
        #expect(Double(layout.width) == width)
        #expect(abs(Double(layout.zoom) - zoom) < 0.0001)
        #expect(layout.framed == framed)
    }

    // MARK: What the page reports

    @Test func aPickBecomesAnElementOfThePage() throws {
        let body: [String: Any] = ["kind": "pick", "selector": "main > button.pay", "label": "button.pay", "source": "src/Checkout.tsx:88",
                                   "html": "<button class=\"pay\">Pay</button>",
                                   "rect": ["x": 10.4, "y": 20, "width": 240.2, "height": 43.6]]
        let message = try #require(BrowserScriptMessage(picker: body, page: "http://localhost:5173/checkout"))
        guard case .pick(let element, let rect) = message else { Issue.record("not a pick"); return }
        #expect(element == BrowserElement(page: "http://localhost:5173/checkout", selector: "main > button.pay", label: "button.pay",
                                          source: "src/Checkout.tsx:88", width: 240, height: 44, html: "<button class=\"pay\">Pay</button>"))
        #expect(rect == CGRect(x: 10.4, y: 20, width: 240.2, height: 43.6))
    }

    @Test func aPickWithoutASourceHasNone() throws {
        let body: [String: Any] = ["kind": "pick", "selector": "#promo", "label": "input#promo", "source": NSNull(),
                                   "rect": ["x": 0, "y": 0, "width": 1, "height": 1]]
        guard case .pick(let element, _) = try #require(BrowserScriptMessage(picker: body, page: "p")) else { Issue.record("not a pick"); return }
        #expect(element.source == nil && element.sourceShort == nil)
    }

    @Test func theOtherReportsParse() {
        #expect(BrowserScriptMessage(picker: ["kind": "network", "count": 24], page: "") == .network(count: 24))
        #expect(BrowserScriptMessage(picker: ["kind": "cancel"], page: "") == .cancel)
        #expect(BrowserScriptMessage(picker: ["kind": "rect", "rect": ["x": 1, "y": 2, "width": 3, "height": 4]], page: "")
                == .moved(rect: CGRect(x: 1, y: 2, width: 3, height: 4)))
        #expect(BrowserScriptMessage(console: ["level": "warning", "text": "careful"]) == .console(level: .warning, text: "careful"))
        #expect(BrowserScriptMessage(console: ["level": "error", "text": "boom"]) == .console(level: .error, text: "boom"))
        #expect(BrowserScriptMessage(console: ["level": "debug", "text": "hi"]) == .console(level: .log, text: "hi"))
    }

    @Test(arguments: [
        #"{"kind": "pick", "selector": "", "label": "x", "rect": {"x": 0, "y": 0, "width": 1, "height": 1}}"#,
        #"{"kind": "pick", "selector": "a", "label": "a"}"#,
        #"{"kind": "network", "count": -1}"#,
        #"{"kind": "rect", "rect": {"x": "a"}}"#,
        #"{"kind": "open"}"#,
        #"{"selector": "a"}"#,
    ])
    func malformedReportsAreDropped(_ json: String) throws {
        let body = try JSONSerialization.jsonObject(with: Data(json.utf8))
        #expect(BrowserScriptMessage(picker: body, page: "p") == nil)
    }

    @Test func aConsoleLineIsCutAndCounted() {
        #expect(BrowserScriptMessage(console: ["text": String(repeating: "a", count: 5000)])
                == .console(level: .log, text: String(repeating: "a", count: BrowserConsoleLog.maxTextLength)))
        #expect(BrowserScriptMessage(console: ["level": "log"]) == nil)
    }

    /// An error line shows (and counts) as a warning: no board draws a separate error count or
    /// red rows.
    @MainActor @Test func theConsoleKeepsItsNewestLinesAndCountsErrorsAsWarnings() {
        let log = BrowserConsoleLog()
        let at = Date(timeIntervalSince1970: 0)
        log.append(.warning, "w", at: at)
        log.append(.error, "e", at: at)
        for index in 0..<BrowserConsoleLog.maxLines { log.append(.log, "\(index)", at: at) }
        #expect(log.lines.count == BrowserConsoleLog.maxLines)
        #expect(log.lines.first?.text == "0" && log.warnings == 2)
        #expect(Set(log.lines.map(\.id)).count == log.lines.count, "ids stay unique")
        log.setNetwork(24)
        #expect(log.network == 24)
        log.clear()
        #expect(log.lines.isEmpty && log.warnings == 0 && log.network == 0)
    }

    @MainActor @Test func anErrorLineDrawsAsAWarningRow() {
        let log = BrowserConsoleLog()
        log.append(.error, "boom", at: Date(timeIntervalSince1970: 0))
        #expect(log.lines.map(\.level) == [.warning])
    }

    @Test func aTimeReadsOnATwentyFourHourClock() {
        var parts = DateComponents()
        (parts.year, parts.month, parts.day, parts.hour, parts.minute, parts.second) = (2026, 9, 29, 14, 2, 11)
        let date = Calendar.current.date(from: parts)!
        #expect(BrowserConsoleLog.time(date) == "14:02:11")
    }

    // MARK: Popover

    @Test(arguments: [
        // element (CSS px), zoom, area → popover origin
        (CGRect(x: 20, y: 100, width: 240, height: 44), 1.0, CGSize(width: 600, height: 700), CGPoint(x: 272, y: 100)),
        // No room on the right: to its left.
        (CGRect(x: 380, y: 100, width: 200, height: 44), 1, CGSize(width: 600, height: 700), CGPoint(x: 180, y: 100)),
        // No room on either side: under it.
        (CGRect(x: 10, y: 100, width: 560, height: 44), 1, CGSize(width: 600, height: 700), CGPoint(x: 12, y: 156)),
        // Kept inside the area at the bottom.
        (CGRect(x: 20, y: 680, width: 100, height: 10), 1, CGSize(width: 600, height: 700), CGPoint(x: 132, y: 598)),
        // A zoomed page: 1280 wide in 576.
        (CGRect(x: 100, y: 100, width: 200, height: 40), 0.45, CGSize(width: 600, height: 700), CGPoint(x: 12 + 135 + 12, y: 45 + 12)),
    ] as [(CGRect, Double, CGSize, CGPoint)])
    func thePopoverSitsBesideTheElementInsideThePage(_ rect: CGRect, _ zoom: Double, _ area: CGSize, _ origin: CGPoint) {
        let pageOrigin = zoom == 1 ? CGPoint.zero : CGPoint(x: 12, y: 12)
        let placed = BrowserPopoverPlacement.origin(for: rect, pageOrigin: pageOrigin, zoom: zoom, popover: CGSize(width: 188, height: 90),
                                                    area: area, gap: 12)
        #expect(abs(placed.x - origin.x) < 0.001 && abs(placed.y - origin.y) < 0.001, "\(placed)")
    }

    // MARK: Data stores

    @Test(arguments: [
        (26, nil, false), (26, "com.bailycase.shepherd", true), (26, "com.bailycase.shepherd.nightly", true),
        (27, nil, true), (27, "com.bailycase.shepherd", true),
    ] as [(Int, String?, Bool)])
    func theBundledAppPersistsWebsiteDataOnEverySupportedOS(_ major: Int, _ bundleIdentifier: String?, _ identified: Bool) {
        #expect(BrowserDataStores.usesIdentifiedStores(
            osVersion: OperatingSystemVersion(majorVersion: major, minorVersion: 0, patchVersion: 0),
            bundleIdentifier: bundleIdentifier) == identified)
    }

    @Test func savedDataFollowsTheProjectNotItsNameThreadOrWorktree() {
        let project = Space(id: SpaceID(rawValue: "project"), name: "app", path: "/projects/app")
        let other = Space(id: SpaceID(rawValue: "other"), name: "app", path: "/other/app")
        let a = Agent(id: AgentID(rawValue: "a"), name: "a", spaceID: project.id, tabID: TabID(rawValue: "a"))
        let b = Agent(id: AgentID(rawValue: "b"), name: "b", spaceID: project.id, tabID: TabID(rawValue: "b"), worktreePath: "/worktrees/b")
        let c = Agent(id: AgentID(rawValue: "c"), name: "c", spaceID: other.id, tabID: TabID(rawValue: "c"))
        var state = ShepherdState(spaces: [project, other], agents: [a, b, c])
        let identifier = BrowserDataStores.identifier(for: a, in: state)
        #expect(identifier == BrowserDataStores.identifier(for: b, in: state))
        #expect(identifier != BrowserDataStores.identifier(for: c, in: state))
        state.spaces[0].name = "renamed"
        state.spaces[0].path = "/moved/app"
        #expect(identifier == BrowserDataStores.identifier(for: a, in: state))
        let host = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let remote = BrowserDataStores.identifier(for: a, in: state, hostID: host)
        #expect(remote == BrowserDataStores.identifier(for: b, in: state, hostID: host))
        #expect(remote != identifier)
        #expect(remote != BrowserDataStores.identifier(for: a, in: state,
            hostID: UUID(uuidString: "00000000-0000-0000-0000-000000000002")!))
    }

    @Test func automationRunsShareOnlyTheProjectHoldingTheirFolder() {
        let project = Space(id: SpaceID(rawValue: "project"), name: "app", path: "/projects/app")
        let reserved = Space(id: SpaceID(rawValue: "reserved"), name: "automations", path: "/", hidden: true)
        let thread = Agent(id: AgentID(rawValue: "thread"), name: "thread", spaceID: project.id, tabID: TabID(rawValue: "thread"))
        let run = Agent(id: AgentID(rawValue: "run"), name: "run", spaceID: reserved.id, tabID: TabID(rawValue: "run"))
        let other = Agent(id: AgentID(rawValue: "outside"), name: "outside", spaceID: reserved.id, tabID: TabID(rawValue: "outside"))
        let state = ShepherdState(spaces: [project, reserved], agents: [thread, run, other], automations: [
            Automation(id: AutomationID(rawValue: "watch"), name: "watch", prompt: "", cwd: "/projects/app/subfolder", agentID: run.id),
            Automation(id: AutomationID(rawValue: "outside"), name: "outside", prompt: "", cwd: "/projects/app-other", agentID: other.id),
        ])
        #expect(BrowserDataStores.identifier(for: run, in: state) == BrowserDataStores.identifier(for: thread, in: state))
        #expect(BrowserDataStores.identifier(for: other, in: state) == BrowserDataStores.identifier(for: other.id))
    }

    // MARK: Nothing open

    @Test func nothingOpenSaysWhatItWaitsFor() {
        #expect(BrowserEmptyWords.message(waiting: URL(string: "http://localhost:5173"))
                == "Waiting for localhost:5173 to answer. Its page opens here when it does.")
        #expect(BrowserEmptyWords.message(waiting: nil)
                == "The agent opens pages here when it starts a dev server. Ports on remote hosts are forwarded for you.")
    }
}
