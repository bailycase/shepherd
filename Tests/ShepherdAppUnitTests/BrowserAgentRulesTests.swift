import CoreGraphics
import Foundation
import ImageIO
import Testing
import ShepherdProtocol
import ShepherdUI
@testable import ShepherdApp

/// The rules of an agent's browser tools (docs/browser.md): which URLs open, what the user's take
/// over allows, how a result and the card are worded, keys, limits and the screenshot clamp.
@Suite("Browser agent rules")
struct BrowserAgentRulesTests {
    // MARK: URL policy

    @Test(arguments: [
        ("http://localhost:5173/checkout", "http://localhost:5173/checkout"),
        ("https://example.com/a?b=1#c", "https://example.com/a?b=1#c"),
        ("  https://example.com  ", "https://example.com"),
        ("HTTP://LOCALHOST:3000", "HTTP://LOCALHOST:3000"),
        ("localhost:5173/x", "http://localhost:5173/x"),
        ("127.0.0.1:8080", "http://127.0.0.1:8080"),
        ("app.test/login", "http://app.test/login"),
        ("acme.dev/docs", "https://acme.dev/docs"),
        ("about:blank", "about:blank"),
        ("ABOUT:BLANK", "about:blank"),
    ])
    func webPagesAndAboutBlankOpen(input: String, opened: String) throws {
        let url = try BrowserURLPolicy.agentURL(input).get()
        #expect(url.absoluteString == opened)
    }

    @Test(arguments: [
        ("file:///etc/hosts", "file"), ("FILE:///etc/hosts", "file"), ("javascript:alert(1)", "javascript"),
        ("JavaScript:void(0)", "javascript"), ("data:text/html,<b>hi</b>", "data"), ("blob:http://localhost/1234", "blob"),
        ("ftp://example.com/x", "ftp"), ("mailto:a@b.co", "mailto"), ("x-custom://open", "x-custom"), ("about:config", "about"),
        ("chrome://settings", "chrome"), ("ws://localhost:1/", "ws"),
    ])
    func everythingButWebPagesIsRefused(input: String, scheme: String) {
        #expect(BrowserURLPolicy.agentURL(input) == .failure(.scheme(scheme)))
        #expect(BrowserURLPolicy.Refusal.scheme(scheme).message.contains("http"))
    }

    @Test(arguments: ["", "   ", "not a url", "http://", "https:///path", "just words here"])
    func aNonURLIsRefused(input: String) {
        if case .success(let url) = BrowserURLPolicy.agentURL(input) { Issue.record("\(input) opened \(url)") }
    }

    @Test(arguments: [
        ("localhost:5173", nil as String?), ("localhost:5173/x", nil), ("http://a.b", "http"), ("file:///x", "file"),
        ("javascript:1", "javascript"), ("ftp://x", "ftp"), ("noscheme", nil), ("192.168.1.2:80/a", nil), ("c3:", "c3"),
    ])
    func theSchemeATextNames(text: String, scheme: String?) {
        #expect(BrowserURLPolicy.explicitScheme(of: text) == scheme)
    }

    @Test(arguments: [
        ("https://a.b/", true), ("http://localhost:1/", true), ("about:blank", true), ("blob:http://a.b/uuid", true),
        ("file:///etc/hosts", false), ("javascript:alert(1)", false), ("data:text/html,x", false), ("x-app://go", false),
        ("ftp://a.b/", false),
    ])
    func aPageMayNavigateItselfOnlyToWebPages(url: String, allowed: Bool) throws {
        #expect(BrowserURLPolicy.allowsPageNavigation(to: try #require(URL(string: url))) == allowed)
    }

    // MARK: Where a page nobody looks at sits

    private static let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let size = CGSize(width: 700, height: 500)

    /// The pixels of `frame` that lie on some screen.
    private static func overlap(_ frame: CGRect, _ screens: [CGRect]) -> [CGRect] {
        screens.map { $0.intersection(frame) }.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
    }

    @Test func aLoneScreenGetsTheWindowOnItsBottomRightCornerByOnePixel() {
        let frame = BrowserParkPlacement.frame(size: Self.size, screens: [Self.screen])
        #expect(frame.size == Self.size)
        let touching = Self.overlap(frame, [Self.screen])
        #expect(touching == [CGRect(x: 1439, y: 0, width: 1, height: 1)], "one pixel, the corner's: \(touching)")
    }

    @Test func aNeighbouringScreenMovesTheWindowToACornerThatFacesOutside() {
        let right = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
        let below = CGRect(x: 0, y: -1080, width: 1440, height: 1080)
        for screens in [[Self.screen, right], [Self.screen, below], [Self.screen, right, below]] {
            let frame = BrowserParkPlacement.frame(size: Self.size, screens: screens)
            let touching = Self.overlap(frame, screens)
            #expect(frame.origin != BrowserParkPlacement.farAway, "a corner still faces outside")
            #expect(touching.count == 1 && touching[0].width <= 1 && touching[0].height <= 1, "\(screens): \(touching)")
        }
    }

    @Test func withNoFreeCornerOrNoScreenItGoesFarAway() {
        let ring = [Self.screen,
                    CGRect(x: 1440, y: 0, width: 4000, height: 900), CGRect(x: -4000, y: 0, width: 4000, height: 900),
                    CGRect(x: -4000, y: 900, width: 9440, height: 4000), CGRect(x: -4000, y: -4000, width: 9440, height: 4000)]
        #expect(BrowserParkPlacement.frame(size: Self.size, screens: ring).origin == BrowserParkPlacement.farAway)
        #expect(BrowserParkPlacement.frame(size: Self.size, screens: []).origin == BrowserParkPlacement.farAway)
        #expect(BrowserParkPlacement.frame(size: CGSize(width: 0, height: 0), screens: [Self.screen]).origin == BrowserParkPlacement.farAway)
    }

    // MARK: Taking over

    private static let observations: [BrowserRequest] = [
        .read(selector: nil, maxChars: nil), .wait(text: "x", ref: nil, gone: false, ms: nil, timeout: nil),
        .screenshot(ref: nil), .console(clear: false),
    ]
    private static let actions: [BrowserRequest] = [
        .open(url: "http://localhost:1/", note: nil), .click(ref: "e1", double: false, note: nil),
        .type(ref: "e1", text: "x", clear: false, submit: false, note: nil), .press(key: "Enter", note: nil),
        .scroll(direction: "down", amount: nil, ref: nil, note: nil), .eval(expression: "1", note: nil),
        .back(note: nil), .forward(note: nil), .reload(note: nil),
    ]

    @Test func everyActionIsRefusedWhileTheUserHasControlAndEveryReadingIsNot() {
        var presence = BrowserAgentPresence()
        for request in Self.observations + Self.actions { #expect(presence.permits(request)) }
        presence.takeOver()
        for request in Self.observations { #expect(presence.permits(request), "\(request) still works") }
        for request in Self.actions { #expect(!presence.permits(request), "\(request) is refused") }
        #expect(Set((Self.observations + Self.actions).map(\.action)) == Set(BrowserRequest.Action.allCases), "the table covers every tool")
        presence.handBack()
        for request in Self.actions { #expect(presence.permits(request)) }
    }

    @Test func theRefusalTellsTheAgentWhatToDo() {
        let message = BrowserAgentPresence.takenOverMessage
        #expect(message.hasPrefix("The user took over the browser. Wait for their next message"))
        #expect(message.contains("browser_read") && message.contains("browser_screenshot") && message.contains("browser_console"))
    }

    // MARK: The card's lifetime

    @Test func theCardShowsWhileAnActionRunsAndLingersAFewSecondsThenGoes() {
        var presence = BrowserAgentPresence()
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(!presence.isShown(now: start))
        presence.begin(note: "clicking through checkout")
        #expect(presence.isShown(now: start) && presence.note == "clicking through checkout")
        #expect(presence.isShown(now: start.addingTimeInterval(3_600)), "as long as the action runs")
        #expect(presence.expiry == nil)
        presence.end(now: start.addingTimeInterval(2))
        #expect(presence.isShown(now: start.addingTimeInterval(2 + BrowserAgentPresence.linger - 0.1)))
        #expect(!presence.isShown(now: start.addingTimeInterval(2 + BrowserAgentPresence.linger + 0.1)))
        #expect(presence.expiry == start.addingTimeInterval(2 + BrowserAgentPresence.linger))
    }

    @Test func aSecondActionKeepsTheCardUpUntilTheLastEnds() {
        var presence = BrowserAgentPresence()
        let start = Date(timeIntervalSince1970: 1_000)
        presence.begin(note: "one")
        presence.begin(note: "two")
        presence.end(now: start)
        #expect(presence.isShown(now: start.addingTimeInterval(60)) && presence.note == "two")
        presence.end(now: start.addingTimeInterval(1))
        #expect(!presence.isShown(now: start.addingTimeInterval(1 + BrowserAgentPresence.linger + 1)))
        presence.end(now: start.addingTimeInterval(2))
        #expect(!presence.isShown(now: start.addingTimeInterval(100)), "an unmatched end goes nowhere")
    }

    @Test func takingOverClearsTheCardAndThePointerAndHandingBackDoesNotBringThemBack() {
        var presence = BrowserAgentPresence()
        let now = Date(timeIntervalSince1970: 1_000)
        presence.begin(note: "clicking")
        presence.point(at: CGPoint(x: 10, y: 20))
        presence.takeOver()
        #expect(presence.userHasControl && !presence.isShown(now: now) && presence.pointer == nil)
        presence.begin(note: "typing")
        #expect(!presence.isShown(now: now), "nothing is drawn while the user has control")
        presence.handBack()
        #expect(!presence.userHasControl)
        presence.end(now: now)
        presence.end(now: now)
        #expect(!presence.isShown(now: now.addingTimeInterval(BrowserAgentPresence.linger + 1)))
    }

    @Test func aNewDocumentTakesThePointerAway() {
        var presence = BrowserAgentPresence()
        presence.begin(note: "clicking")
        presence.point(at: CGPoint(x: 1, y: 2))
        presence.documentChanged()
        #expect(presence.pointer == nil)
        presence.describe("clicking “Pay”")
        #expect(presence.note == "clicking “Pay”")
    }

    // MARK: What the card says

    @Test(arguments: [
        ("clicking through checkout", "clicking through checkout"),
        ("  Agent is filling in the form.  ", "filling in the form"),
        ("agent is  reading\nthe docs…", "reading the docs"),
        ("The agent is logging in", "logging in"),
        ("", nil), ("   ", nil), ("Agent is ", nil),
    ])
    func aNoteIsOneShortLine(input: String, expected: String?) {
        #expect(BrowserNote.sanitized(input) == expected)
    }

    @Test func aLongNoteIsCutAtSixtyCharacters() throws {
        let note = try #require(BrowserNote.sanitized(String(repeating: "abcdefghij ", count: 12)))
        #expect(note.count == BrowserNote.maxLength && note.hasSuffix("…"))
    }

    @Test func withoutANoteThePhraseIsDerivedFromTheActionAndWhatItPointsAt() {
        let pay = BrowserTarget(role: "button", name: "Pay $148.00")
        let email = BrowserTarget(role: "textbox", name: "Email")
        #expect(BrowserNote.phrase(for: .click(ref: "e1", double: false, note: nil), target: pay) == "clicking “Pay $148.00”")
        #expect(BrowserNote.phrase(for: .click(ref: "e1", double: true, note: nil), target: pay) == "double-clicking “Pay $148.00”")
        #expect(BrowserNote.phrase(for: .click(ref: "e1", double: false, note: nil), target: BrowserTarget(role: "link", name: nil)) == "clicking a link")
        #expect(BrowserNote.phrase(for: .click(ref: "e1", double: false, note: nil)) == "clicking the page")
        #expect(BrowserNote.phrase(for: .type(ref: "e2", text: "secret", clear: false, submit: false, note: nil), target: email) == "typing in “Email”")
        #expect(BrowserNote.phrase(for: .type(ref: "e2", text: "x", clear: false, submit: false, note: nil)) == "typing in a field")
        #expect(BrowserNote.phrase(for: .open(url: "http://localhost:5173", note: nil)) == "opening localhost:5173")
        #expect(BrowserNote.phrase(for: .open(url: "localhost:5173/checkout", note: nil)) == "opening localhost:5173/checkout")
        #expect(BrowserNote.phrase(for: .open(url: "file:///etc/hosts", note: nil)) == "opening a page")
        #expect(BrowserNote.phrase(for: .read(selector: nil, maxChars: nil)) == "reading the page")
        #expect(BrowserNote.phrase(for: .press(key: "Enter", note: nil)) == "pressing Enter")
        #expect(BrowserNote.phrase(for: .scroll(direction: "down", amount: nil, ref: nil, note: nil)) == "scrolling down")
        #expect(BrowserNote.phrase(for: .scroll(direction: nil, amount: nil, ref: "e4", note: nil), target: pay) == "scrolling to “Pay $148.00”")
        #expect(BrowserNote.phrase(for: .wait(text: "Order placed", ref: nil, gone: false, ms: nil, timeout: nil)) == "waiting for “Order placed”")
        #expect(BrowserNote.phrase(for: .wait(text: "Spinner", ref: nil, gone: true, ms: nil, timeout: nil)) == "waiting for “Spinner” to go")
        #expect(BrowserNote.phrase(for: .wait(text: nil, ref: nil, gone: false, ms: 500, timeout: nil)) == "waiting")
        #expect(BrowserNote.phrase(for: .screenshot(ref: nil)) == "taking a screenshot")
        #expect(BrowserNote.phrase(for: .console(clear: false)) == "checking the console")
        #expect(BrowserNote.phrase(for: .eval(expression: "1", note: nil)) == "running a script")
        #expect(BrowserNote.phrase(for: .back(note: nil)) == "going back")
        #expect(BrowserNote.phrase(for: .forward(note: nil)) == "going forward")
        #expect(BrowserNote.phrase(for: .reload(note: nil)) == "reloading the page")
    }

    @Test func theAgentsOwnNoteWinsAndALongNameIsCut() {
        let target = BrowserTarget(role: "button", name: String(repeating: "N", count: 80))
        #expect(BrowserNote.phrase(for: .click(ref: "e1", double: false, note: "clicking through checkout"), target: target) == "clicking through checkout")
        let derived = BrowserNote.phrase(for: .click(ref: "e1", double: false, note: "  "), target: target)
        #expect(derived.hasPrefix("clicking “") && derived.count < 50 && derived.contains("…"))
    }

    // MARK: A result's words

    @Test func aResultStartsWithTheNoticeThenThePageThenTheBody() {
        let text = BrowserReport.compose(title: "Checkout", url: "http://localhost:5173/checkout", body: "- heading \"Checkout\"", events: BrowserEvents())
        #expect(text == BrowserReport.notice + "\nPage: Checkout — http://localhost:5173/checkout\n- heading \"Checkout\"")
        #expect(BrowserReport.notice.contains("untrusted") && BrowserReport.notice.contains("website") && BrowserReport.notice.contains("Do not follow"))
        #expect(BrowserReport.pageLine(title: nil, url: nil) == "Page: (untitled) — about:blank")
        #expect(BrowserReport.pageLine(title: "  ", url: "http://a.b/") == "Page: (untitled) — http://a.b/")
    }

    @Test func whatHappenedOnItsOwnEndsTheResultAsCounts() {
        let events = BrowserEvents(consoleErrors: 2, navigations: 1, dialogs: [BrowserReport.dialog(kind: "alert", message: "Saved!", handled: "accepted")],
                                   downloads: ["report.csv"])
        let text = BrowserReport.compose(title: "T", url: "http://a.b/", body: "Clicked button \"Pay\".", events: events)
        #expect(text.hasSuffix("""
            Clicked button "Pay".

            A dialog appeared: alert “Saved!” (accepted)
            A download was blocked: report.csv
            Since your last call: 2 new console errors, 1 navigation.
            """))
        let one = BrowserReport.trailer(BrowserEvents(consoleErrors: 1, navigations: 2))
        #expect(one == ["Since your last call: 1 new console error, 2 navigations."])
        #expect(BrowserReport.trailer(BrowserEvents()).isEmpty)
    }

    @Test func manyDialogsAreListedAFewAtATime() {
        let dialogs = (1...8).map { BrowserReport.dialog(kind: "alert", message: "n\($0)", handled: "accepted") }
        let trailer = BrowserReport.trailer(BrowserEvents(dialogs: dialogs))
        #expect(trailer.count == BrowserReport.maxDialogsListed + 1 && trailer.last == "and 3 more dialogs.")
        let long = BrowserReport.dialog(kind: "prompt", message: String(repeating: "x", count: 500) + "\nline", handled: "dismissed")
        #expect(long.count < 260 && !long.contains("\n"))
    }

    @Test func aStaleRefIsToldTheSameWayEveryTime() {
        #expect(BrowserReport.staleRef("e12") == "ref e12 is stale; call browser_read again")
    }

    // MARK: Limits

    @Test func aSnapshotIsThirtyThousandCharactersUnlessAskedAndNeverMoreThanSixty() {
        #expect(BrowserLimits.snapshotChars(nil) == 30_000)
        #expect(BrowserLimits.snapshotChars(100) == 500)
        #expect(BrowserLimits.snapshotChars(45_000) == 45_000)
        #expect(BrowserLimits.snapshotChars(1_000_000) == 60_000)
    }

    @Test func aWaitIsTenSecondsUnlessAskedAndNeverMoreThanThirty() {
        #expect(BrowserLimits.waitSeconds(nil) == 10)
        #expect(BrowserLimits.waitSeconds(0) == 0.1)
        #expect(BrowserLimits.waitSeconds(4.5) == 4.5)
        #expect(BrowserLimits.waitSeconds(300) == 30)
        #expect(BrowserLimits.waitSeconds(.nan) == 10)
        #expect(BrowserLimits.waitMilliseconds(-5) == 0 && BrowserLimits.waitMilliseconds(500) == 500 && BrowserLimits.waitMilliseconds(999_999) == 30_000)
    }

    @Test func aRequestThatCannotWorkIsAnsweredBeforeAnyPageIsAsked() {
        #expect(BrowserRequestCheck.problem(with: .click(ref: "", double: false, note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .press(key: "Hyper+q", note: nil))?.contains("not a key") == true)
        #expect(BrowserRequestCheck.problem(with: .scroll(direction: nil, amount: nil, ref: nil, note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .scroll(direction: "sideways", amount: nil, ref: nil, note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .scroll(direction: "down", amount: -3, ref: nil, note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .wait(text: nil, ref: nil, gone: false, ms: nil, timeout: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .eval(expression: "  \n", note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .eval(expression: String(repeating: "x", count: 20_001), note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .type(ref: "e1", text: String(repeating: "x", count: 20_001), clear: false, submit: false, note: nil)) != nil)
        #expect(BrowserRequestCheck.problem(with: .open(url: "", note: nil)) != nil)
        for fine in Self.observations + Self.actions { #expect(BrowserRequestCheck.problem(with: fine) == nil, "\(fine)") }
        #expect(BrowserRequestCheck.ref(of: .click(ref: "e9", double: false, note: nil)) == "e9")
        #expect(BrowserRequestCheck.ref(of: .scroll(direction: nil, amount: nil, ref: "e4", note: nil)) == "e4")
        #expect(BrowserRequestCheck.ref(of: .console(clear: false)) == nil)
    }

    // MARK: Keys

    @Test(arguments: [
        ("Enter", "Enter", "Enter", false), ("return", "Enter", "Enter", false), ("Tab", "Tab", "Tab", false),
        ("Escape", "Escape", "Escape", false), ("esc", "Escape", "Escape", false), ("ArrowDown", "ArrowDown", "ArrowDown", false),
        ("space", " ", "Space", false), ("Backspace", "Backspace", "Backspace", false), ("a", "a", "KeyA", false),
        ("7", "7", "Digit7", false), ("F5", "F5", "F5", false), ("Control+a", "a", "KeyA", true), ("Shift+Tab", "Tab", "Tab", false),
        ("Cmd+Shift+z", "Z", "KeyZ", true),
    ])
    func keysParse(spec: String, key: String, code: String, modified: Bool) throws {
        let parsed = try #require(BrowserKey.parse(spec))
        #expect(parsed.key == key && parsed.code == code)
        #expect((parsed.control || parsed.meta) == modified)
    }

    @Test(arguments: ["", "  ", "Hyper+q", "Control+", "Nonsense", "F13", "ab"])
    func unknownKeysDoNotParse(spec: String) {
        #expect(BrowserKey.parse(spec) == nil)
    }

    @Test func modifiersReachTheScript() throws {
        let key = try #require(BrowserKey.parse("Control+Shift+Tab"))
        #expect(key.jsonObject["ctrl"] as? Bool == true && key.jsonObject["shift"] as? Bool == true)
        #expect(key.jsonObject["alt"] as? Bool == false && key.jsonObject["key"] as? String == "Tab")
        #expect(BrowserKey.parse("+")?.key == "+")
    }

    // MARK: Screenshots

    @Test(arguments: [
        (2560, 1600, 1280, 800), (1280, 720, 1280, 720), (800, 600, 800, 600), (600, 3000, 256, 1280), (5000, 100, 1280, 26), (1, 1, 1, 1),
    ])
    func theLongestEdgeIsClampedKeepingProportions(width: Int, height: Int, expectedWidth: Int, expectedHeight: Int) {
        let size = BrowserImageClamp.size(width: width, height: height)
        #expect(size.width == expectedWidth && size.height == expectedHeight)
    }

    /// A busy picture (noise) that a JPEG cannot shrink much: it still lands under the byte cap,
    /// by lowering the quality and then the size.
    @Test func aBusyImageEndsUnderTheByteCapAndTheEdgeCap() throws {
        let width = 320, height = 200
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x9E37_79B9_7F4A_7C15
        for index in stride(from: 0, to: bytes.count, by: 4) {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            bytes[index] = UInt8(truncatingIfNeeded: seed >> 33)
            bytes[index + 1] = UInt8(truncatingIfNeeded: seed >> 41)
            bytes[index + 2] = UInt8(truncatingIfNeeded: seed >> 49)
            bytes[index + 3] = 255
        }
        let image = try #require(Self.makeImage(bytes, width: width, height: height))
        let uncapped = try #require(BrowserImageClamp.jpeg(image, quality: 0.7))
        #expect(uncapped.count > 20_000, "noise does not compress: the caps below do the work")
        let encoded = try #require(BrowserImageClamp.encode(image, maxBytes: 12_000, maxEdge: 160))
        #expect(encoded.data.count <= 12_000)
        #expect(max(encoded.width, encoded.height) <= 160)
        let source = try #require(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width == encoded.width && decoded.height == encoded.height)
        #expect(abs(Double(encoded.width) / Double(encoded.height) - 1.6) < 0.1, "the proportions hold")
    }

    @Test func aSmallFlatImageKeepsItsSizeAndTheFirstQuality() throws {
        var bytes = [UInt8](repeating: 200, count: 300 * 200 * 4)
        for index in stride(from: 3, to: bytes.count, by: 4) { bytes[index] = 255 }
        let image = try #require(Self.makeImage(bytes, width: 300, height: 200))
        let encoded = try #require(BrowserImageClamp.encode(image))
        #expect(encoded.width == 300 && encoded.height == 200)
        #expect(encoded.data == BrowserImageClamp.jpeg(image, quality: 0.7))
    }

    private static func makeImage(_ bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        var bytes = bytes
        return bytes.withUnsafeMutableBytes { raw in
            CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
    }

    // MARK: eval

    @Test func anExpressionIsTriedFirstAndOnlyACompileErrorMovesOnToStatements() {
        #expect(BrowserEval.expressionBody("1 + 1").contains("return (\n1 + 1\n);"))
        #expect(BrowserEval.statementsBody("const a = 1; return a").contains("=> {\nconst a = 1; return a\n})"))
        #expect(BrowserEval.mayBeStatements(BrowserScriptFailure(message: "SyntaxError: Unexpected token 'const'") .with(syntax: true)))
        #expect(!BrowserEval.mayBeStatements(BrowserScriptFailure(message: "SyntaxError: JSON Parse error: Unexpected EOF").with(syntax: true)),
                "a script that ran and threw is not run again")
        #expect(!BrowserEval.mayBeStatements(BrowserScriptFailure(message: "TypeError: null is not an object")))
    }

    // MARK: The tab's tip

    @Test func theTabsTipNamesTheHostAndPathTheAgentOpened() throws {
        let opened = Date(timeIntervalSince1970: 5)
        let url = try #require(URL(string: "http://localhost:5173/checkout?step=2"))
        #expect(SidePaneTabs.tip(opened: (url, opened)) == NWSidePaneTabTip(text: "localhost:5173/checkout?step=2", openedAt: opened))
        #expect(SidePaneTabs.tip(opened: nil) == nil)
        let items = SidePaneTabs.items(news: [.browser], changedFiles: nil, browserTip: NWSidePaneTabTip(text: "localhost:5173", openedAt: opened))
        #expect(items.last?.tip?.text == "localhost:5173" && items.first?.tip == nil)
    }
}

private extension BrowserScriptFailure {
    func with(syntax: Bool) -> BrowserScriptFailure {
        var copy = self
        copy.isSyntaxError = syntax
        return copy
    }
}
