import AppKit
import Foundation
import ImageIO
import ShepherdCore
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
import WebKit
@testable import ShepherdApp

/// An agent's browser tools against real pages (docs/browser.md): a real web view, hosted off
/// screen with no pane showing it, on fixture pages a local server serves. Nothing here touches
/// the user's focus, mouse or keyboard: the tools dispatch DOM events, and the window sits far off
/// every screen.
@MainActor
@Suite("Browser agent tools", .mainActorExclusive)
struct BrowserAgentTests {
    static let checkout = """
        <!doctype html><html><head><title>Checkout</title>
        <style>body { font: 14px sans-serif; margin: 0; padding: 16px } .tall { height: 3000px; background: linear-gradient(#c33, #33c) }
        #cover { position: fixed; left: 0; top: 0; width: 100%; height: 100%; background: rgba(0,0,0,.4); display: none }</style></head>
        <body>
        <h1>Checkout</h1>
        <form id="form" action="/done" method="get">
          <label for="email">Email</label>
          <input id="email" name="email" type="email" placeholder="you@example.com">
          <p id="echo">nothing typed</p>
          <label><input type="checkbox" id="terms"> I accept the terms</label>
          <select id="country" aria-label="Country"><option value="us">United States</option><option value="ca">Canada</option></select>
          <button type="button" id="apply" class="apply">Apply promo</button>
          <button type="submit" id="pay" class="pay">Pay $148.00</button>
        </form>
        <button id="off" disabled>Unavailable</button>
        <p id="count">0</p>
        <a id="terms-link" href="/terms">Terms of sale</a>
        <div id="hidden" style="display:none"><button>Secret</button></div>
        <script>
          window.__inputs = 0;
          const state = { email: '' };
          // A controlled input in the style of React: it keeps its own record of the value and only
          // an input event tells it the value changed.
          const email = document.getElementById('email');
          const tracker = { value: '' };
          Object.defineProperty(email, 'value', {
            configurable: true,
            get() { return Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').get.call(this); },
            set(v) { tracker.value = String(v); Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(this, v); },
          });
          email.addEventListener('input', (e) => {
            window.__inputs += 1;
            state.email = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').get.call(email);
            document.getElementById('echo').textContent = 'typed: ' + state.email;
          });
          document.getElementById('apply').addEventListener('click', () => {
            document.getElementById('count').textContent = String(Number(document.getElementById('count').textContent) + 1);
            console.log('promo applied');
          });
          document.getElementById('country').addEventListener('change', (e) => { document.getElementById('echo').textContent = 'country: ' + e.target.value; });
        </script>
        </body></html>
        """

    static let pages: [String: String] = [
        "/checkout": checkout,
        "/done": "<html><head><title>Done</title></head><body><h1>Thank you</h1><p id=\"q\">received</p><a href=\"/checkout\">Back</a></body></html>",
        "/terms": "<html><head><title>Terms</title></head><body><h1>Terms of sale</h1></body></html>",
        "/tall": "<html><head><title>Tall</title></head><body style=\"margin:0\"><div style=\"height:3000px;background:linear-gradient(#c33,#33c)\"><h1>Top</h1></div><p>bottom</p></body></html>",
        "/secrets": """
            <html><head><title>Secrets</title></head><body>
            <input type="password" aria-label="Password" value="s3cret-pass">
            <input aria-label="Card number" autocomplete="cc-number" value="4242424242424242">
            <input aria-label="Name" value="Baily">
            <button id="apply" onclick="document.title = 'applied'">Apply</button>
            </body></html>
            """,
    ]

    /// A session on its own scratch server.
    private func start(_ pages: [String: String] = pages) async throws -> (BrowserSession, TinyWebServer) {
        let server = try TinyWebServer(pages: pages)
        try await server.start()
        return (BrowserSession(agentID: AgentID(), dataStores: .ephemeral), server)
    }

    private func text(_ outcome: BrowserOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        guard case .result(let text, _) = outcome else {
            Issue.record("expected a result, got \(outcome)", sourceLocation: sourceLocation)
            return ""
        }
        return text
    }

    /// The ref of the first snapshot line containing `needle`.
    private func ref(in snapshot: String, _ needle: String, sourceLocation: SourceLocation = #_sourceLocation) throws -> String {
        let line = try #require(snapshot.split(separator: "\n").first { $0.contains(needle) && $0.contains("[e") },
                                "no ref line for \(needle) in\n\(snapshot)", sourceLocation: sourceLocation)
        let start = try #require(line.range(of: "[e"), sourceLocation: sourceLocation)
        let end = try #require(line[start.upperBound...].firstIndex(of: "]"), sourceLocation: sourceLocation)
        return String(line[line.index(after: start.lowerBound)..<end])
    }

    private func failure(_ outcome: BrowserOutcome) -> (code: String, message: String)? {
        if case .failure(let code, let message) = outcome { return (code, message) }
        return nil
    }

    private func opened(_ session: BrowserSession, _ server: TinyWebServer, _ path: String) async throws {
        let outcome = await session.perform(.open(url: server.url(path).absoluteString, note: nil))
        _ = try text(outcome)
    }

    // MARK: Open and read

    @Test func openingAPageWaitsForItAndReadingItGivesRefs() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        let opened = try text(await session.perform(.open(url: server.url("/checkout").absoluteString, note: nil)))
        #expect(opened.hasPrefix(BrowserReport.notice + "\n" + "Page: Checkout — \(server.origin)/checkout"))
        #expect(opened.contains("Opened \(server.origin)/checkout."))

        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(snapshot.hasPrefix(BrowserReport.notice))
        #expect(snapshot.contains("- heading \"Checkout\" [level=1]"))
        #expect(snapshot.contains("textbox \"Email\" [e1] empty placeholder=\"you@example.com\""))
        #expect(snapshot.contains("checkbox \"I accept the terms\""))
        #expect(snapshot.contains("unchecked"))
        #expect(snapshot.contains("combobox \"Country\""))
        #expect(snapshot.contains("options=[\"United States\", \"Canada\"]"))
        #expect(snapshot.contains("button \"Pay $148.00\""))
        #expect(snapshot.contains("button \"Unavailable\"") && snapshot.contains("disabled"))
        #expect(snapshot.contains("link \"Terms of sale\"") && snapshot.contains("href=\"/terms\""))
        #expect(!snapshot.contains("Secret"), "hidden elements are left out")
        #expect(snapshot.contains("text \"nothing typed\""))
    }

    @Test func aReadCanBeScopedAndIsCapped() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let scoped = try text(await session.perform(.read(selector: "#form", maxChars: nil)))
        #expect(scoped.contains("Pay $148.00") && !scoped.contains("Terms of sale"))
        #expect(scoped.contains("[e1]"), "refs start over with every read")
        let missing = await session.perform(.read(selector: "#nope", maxChars: nil))
        #expect(failure(missing)?.code == "not_found")
        let capped = try text(await session.perform(.read(selector: nil, maxChars: 500)))
        #expect(capped.contains("Snapshot truncated"))
    }

    // MARK: Acting

    @Test func aClickChangesThePageAndNamesWhatItClicked() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        let clicked = try text(await session.perform(.click(ref: apply, double: false, note: nil)))
        #expect(clicked.contains("Clicked button \"Apply promo\"."))
        let after = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(after.contains("text \"1\""), "the page's own click handler ran:\n\(after)")
        let logged = try text(await session.perform(.console(clear: false)))
        #expect(logged.contains("promo applied"))
        // The card pointed at the button.
        #expect(session.presence.pointer != nil)
    }

    @Test func typingFiresInputAndChangeLikeAControlledField() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let email = try ref(in: snapshot, "textbox \"Email\"")
        let typed = try text(await session.perform(.type(ref: email, text: "baily@acme.dev", clear: false, submit: false, note: nil)))
        #expect(typed.contains("Typed 14 characters into textbox \"Email\"."))
        let after = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(after.contains("value=\"baily@acme.dev\""))
        #expect(after.contains("text \"typed: baily@acme.dev\""), "the page heard the input event:\n\(after)")
        // Clearing replaces what is there; without it the text is added.
        _ = try text(await session.perform(.type(ref: email, text: "!", clear: false, submit: false, note: nil)))
        _ = try text(await session.perform(.type(ref: email, text: "x@y.z", clear: true, submit: false, note: nil)))
        let end = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(end.contains("value=\"x@y.z\""))
        let events = try text(await session.perform(.eval(expression: "window.__inputs", note: nil)))
        #expect(events.contains("Result: 3"))
    }

    @Test func enterSubmitsTheForm() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let email = try ref(in: snapshot, "textbox \"Email\"")
        let typed = try text(await session.perform(.type(ref: email, text: "a@b.co", clear: true, submit: true, note: nil)))
        #expect(typed.contains("Pressed Enter. The page navigated."))
        #expect(typed.contains("Page: Done — \(server.origin)/done?email=a%40b.co"))
    }

    @Test func aSelectTakesAnOptionByItsText() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let country = try ref(in: snapshot, "combobox \"Country\"")
        _ = try text(await session.perform(.type(ref: country, text: "Canada", clear: false, submit: false, note: nil)))
        let after = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(after.contains("text \"country: ca\""))
        let bad = await session.perform(.type(ref: country, text: "Narnia", clear: false, submit: false, note: nil))
        #expect(failure(bad)?.code == "invalid")
    }

    @Test func aCheckboxToggles() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let terms = try ref(in: snapshot, "checkbox")
        _ = try text(await session.perform(.click(ref: terms, double: false, note: nil)))
        let after = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(after.contains("checkbox \"I accept the terms\" [\(terms)] checked"))
        let wrong = await session.perform(.type(ref: terms, text: "x", clear: false, submit: false, note: nil))
        #expect(failure(wrong)?.code == "invalid")
    }

    @Test func aDisabledOrCoveredElementIsRefusedWithWhy() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let off = try ref(in: snapshot, "Unavailable")
        #expect(failure(await session.perform(.click(ref: off, double: false, note: nil)))?.code == "disabled")
        _ = try text(await session.perform(.eval(expression: "document.body.insertAdjacentHTML('beforeend', '<div id=\"modal\" class=\"modal-backdrop\" style=\"position:fixed;inset:0;background:#0003\"></div>'), 1", note: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        let covered = try #require(failure(await session.perform(.click(ref: apply, double: false, note: nil))))
        #expect(covered.code == "covered")
        #expect(covered.message.contains("is covered by div#modal"), "\(covered.message)")
        #expect(covered.message.hasPrefix(BrowserReport.notice), "words that quote the page carry the untrusted-content notice")
    }

    @Test func aStaleRefSaysSoAfterANavigation() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let link = try ref(in: snapshot, "Terms of sale")
        let apply = try ref(in: snapshot, "Apply promo")
        let clicked = try text(await session.perform(.click(ref: link, double: false, note: nil)))
        #expect(clicked.contains("The page navigated."))
        #expect(clicked.contains("Page: Terms — \(server.origin)/terms"))
        let stale = try #require(failure(await session.perform(.click(ref: apply, double: false, note: nil))))
        #expect(stale.code == "stale_ref")
        #expect(stale.message == "ref \(apply) is stale; call browser_read again")
        let invalid = try #require(failure(await session.perform(.click(ref: "nonsense", double: false, note: nil))))
        #expect(invalid.code == "no_such_ref")
    }

    @Test func scrollingMovesThePageAndWaitingSeesTextAppear() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/tall")
        let scrolled = try text(await session.perform(.scroll(direction: "down", amount: nil, ref: nil, note: nil)))
        #expect(scrolled.contains("Scrolled down. Now at "))
        let y = try text(await session.perform(.eval(expression: "window.scrollY", note: nil)))
        #expect(y.contains("Result: ") && !y.contains("Result: 0"))
        let bottom = try text(await session.perform(.scroll(direction: "bottom", amount: nil, ref: nil, note: nil)))
        #expect(bottom.contains("(the bottom)"))
        _ = try text(await session.perform(.scroll(direction: "top", amount: nil, ref: nil, note: nil)))

        _ = try text(await session.perform(.eval(expression: "setTimeout(() => { const p = document.createElement('p'); p.textContent = 'All loaded'; document.body.append(p); }, 300); 1", note: nil)))
        let started = ContinuousClock.now
        let waited = try text(await session.perform(.wait(text: "All loaded", ref: nil, gone: false, ms: nil, timeout: 5)))
        #expect(waited.contains("“All loaded” is there."))
        #expect(ContinuousClock.now - started < .seconds(4))
        let timedOut = await session.perform(.wait(text: "never appears", ref: nil, gone: false, ms: nil, timeout: 0.4))
        #expect(failure(timedOut)?.code == "timeout")
        let gone = try text(await session.perform(.wait(text: "never appears", ref: nil, gone: true, ms: nil, timeout: 1)))
        #expect(gone.contains("is gone."))
    }

    // MARK: Shadow roots, frames, editors, keys and history

    /// A page with an open shadow root, a same-origin frame, another origin's frame (localhost
    /// against 127.0.0.1), and a contenteditable.
    private func richServer() async throws -> TinyWebServer {
        let server = try TinyWebServer()
        try await server.start()
        let port = server.port
        server.setHandler { request in
            switch request.path {
            case "/frame":
                return .html("<html><body><button id=\"fb\">Frame button</button><script>document.getElementById('fb').onclick = () => { try { parent.document.title = 'frame clicked' } catch (e) {} }</script></body></html>")
            default:
                return .html("""
                    <html><head><title>Rich</title></head><body>
                    <div id="host"></div>
                    <iframe id="same" title="Same origin" src="/frame" width="300" height="80"></iframe>
                    <iframe id="other" title="Other origin" src="http://localhost:\(port)/frame" width="300" height="80"></iframe>
                    <div id="editor" contenteditable="true" role="textbox" aria-label="Notes" style="border:1px solid #999;min-height:24px"></div>
                    <button id="dbl">Double</button><p id="dcount">0</p>
                    <input id="a" aria-label="First"><input id="b" aria-label="Second"><button id="go">Go</button>
                    <script>
                      const root = document.getElementById('host').attachShadow({ mode: 'open' });
                      root.innerHTML = '<button id="inner">Shadow button</button><p>shadow text</p>';
                      root.getElementById('inner').addEventListener('click', () => { document.title = 'shadow clicked'; });
                      document.getElementById('dbl').addEventListener('dblclick', () => { const p = document.getElementById('dcount'); p.textContent = String(Number(p.textContent) + 1); });
                      window.keys = [];
                      document.addEventListener('keydown', (e) => window.keys.push(e.key));
                      document.getElementById('go').addEventListener('click', () => { window.keys.push('go-clicked'); });
                    </script></body></html>
                    """)
            }
        }
        return server
    }

    @Test func readingFollowsShadowRootsAndSameOriginFramesButNotAnotherOrigins() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        let server = try await richServer()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/rich")
        // The frames load after the page does: read until the same-origin one has its button.
        var snapshot = ""
        try await eventuallyAsync("the frame's button in a read") {
            snapshot = try self.text(await session.perform(.read(selector: nil, maxChars: nil)))
            return snapshot.contains("Frame button")
        }
        #expect(snapshot.contains("button \"Shadow button\"") && snapshot.contains("text \"shadow text\""), "\(snapshot)")
        #expect(snapshot.contains("iframe \"Same origin\"") && snapshot.contains("button \"Frame button\""), "\(snapshot)")
        #expect(snapshot.contains("iframe \"Other origin\" (another origin: its content is not shown)"), "\(snapshot)")
        #expect(snapshot.contains("textbox \"Notes\""))

        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "Shadow button"), double: false, note: nil)))
        #expect(session.pageTitle == "shadow clicked")
        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "Frame button"), double: false, note: nil)))
        #expect(session.pageTitle == "frame clicked")
    }

    @Test func aContenteditableTakesTextAndADoubleClickIsTwo() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        let server = try await richServer()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/rich")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let editor = try ref(in: snapshot, "textbox \"Notes\"")
        _ = try text(await session.perform(.type(ref: editor, text: "hello", clear: false, submit: false, note: nil)))
        _ = try text(await session.perform(.type(ref: editor, text: " world", clear: false, submit: false, note: nil)))
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('editor').textContent", note: nil))).contains("Result: \"hello world\""))
        _ = try text(await session.perform(.type(ref: editor, text: "fresh", clear: true, submit: false, note: nil)))
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('editor').textContent", note: nil))).contains("Result: \"fresh\""))

        let clicked = try text(await session.perform(.click(ref: try ref(in: snapshot, "Double"), double: true, note: nil)))
        #expect(clicked.contains("Double-clicked button \"Double\"."))
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('dcount').textContent", note: nil))).contains("Result: \"1\""))
    }

    @Test func keysMoveFocusTypeAndActivate() async throws {
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        let server = try await richServer()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/rich")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "textbox \"First\""), double: false, note: nil)))
        let tab = try text(await session.perform(.press(key: "Tab", note: nil)))
        #expect(tab.contains("Pressed Tab.") && tab.contains("Focus is on textbox \"Second\"."), "\(tab)")
        _ = try text(await session.perform(.press(key: "h", note: nil)))
        _ = try text(await session.perform(.press(key: "i", note: nil)))
        _ = try text(await session.perform(.press(key: "!", note: nil)))
        _ = try text(await session.perform(.press(key: "Backspace", note: nil)))
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('b').value", note: nil))).contains("Result: \"hi\""))
        _ = try text(await session.perform(.press(key: "Escape", note: nil)))
        _ = try text(await session.perform(.press(key: "Control+a", note: nil)))
        _ = try text(await session.perform(.press(key: "Tab", note: nil)))
        _ = try text(await session.perform(.press(key: "Enter", note: nil)))
        let keys = try text(await session.perform(.eval(expression: "window.keys.join(',')", note: nil)))
        #expect(keys.contains("Tab,h,i,!,Backspace,Escape,a,Tab,Enter,go-clicked"), "\(keys)")
        let bad = await session.perform(.press(key: "Hyper+q", note: nil))
        #expect(failure(bad)?.code == "invalid")
    }

    @Test func backForwardAndReloadWalkTheHistory() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let none = await session.perform(.back(note: nil))
        #expect(failure(none)?.code == "invalid" && failure(none)?.message.contains("no earlier page") == true)
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "Terms of sale"), double: false, note: nil)))
        let back = try text(await session.perform(.back(note: nil)))
        #expect(back.contains("Went back to \(server.origin)/checkout.") && back.contains("Page: Checkout"))
        let forward = try text(await session.perform(.forward(note: nil)))
        #expect(forward.contains("Went forward to \(server.origin)/terms.") && forward.contains("Page: Terms"))
        let before = server.requested.current.count
        let reload = try text(await session.perform(.reload(note: nil)))
        #expect(reload.contains("Reloaded \(server.origin)/terms."))
        #expect(server.requested.current.count > before, "a reload asks the server again")
    }

    @Test func historyNeverLandsOnAPageTheUserOpenedByHand() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        // The app's own load (the address field's) may open a page the agent's open never could.
        session.load(try #require(URL(string: "data:text/html,<title>byhand</title>hi")))
        try await eventuallyOnMain("the hand-opened page") { session.pageTitle == "byhand" && !session.isLoading }
        try await opened(session, server, "/terms")
        let back = try #require(failure(await session.perform(.back(note: nil))))
        #expect(back.code == "refused_url", "\(back.message)")
        #expect(session.pageURLString == server.origin + "/terms")
    }

    // MARK: When the page or the user gets in the way

    @Test func aPageStuckInAScriptFailsTheToolCallsInsteadOfHoldingThemForGood() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        session.scriptDeadline = 1
        session.evalDeadline = 1
        let stuck = try #require(failure(await session.perform(.eval(
            expression: "(() => { const end = Date.now() + 4000; while (Date.now() < end) {} return 1 })()", note: nil))))
        #expect(stuck.code == "timeout" && stuck.message.contains("stuck"), "\(stuck.message)")
        let busy = try #require(failure(await session.perform(.read(selector: nil, maxChars: nil))), "the page is still busy")
        #expect(busy.code == "timeout")
        // The page frees itself, and the same session works again: the queue was never held.
        session.scriptDeadline = 15
        try await eventuallyAsync("a read to work again", timeout: .seconds(30)) {
            if case .result = await session.perform(.read(selector: nil, maxChars: nil)) { return true }
            return false
        }
    }

    @Test func openingTheSamePageAtAnotherFragmentIsQuickNotATimeout() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let started = ContinuousClock.now
        let moved = try text(await session.perform(.open(url: server.url("/checkout").absoluteString + "#step2", note: nil)))
        #expect(moved.contains("Opened \(server.origin)/checkout#step2."), "\(moved)")
        #expect(ContinuousClock.now - started < .seconds(10))
        #expect(server.requested.current.filter { $0 == "/checkout" }.count == 1, "the document was not fetched again")
    }

    @Test func aSecretFieldIsNeverReadBackAndAScopedReadOfAButtonGivesItsRef() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/secrets")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(snapshot.contains("textbox \"Password\" [e1] value=[hidden]"), "\(snapshot)")
        #expect(snapshot.contains("textbox \"Card number\" [e2] value=[hidden]"), "\(snapshot)")
        #expect(snapshot.contains("value=\"Baily\""))
        #expect(!snapshot.contains("s3cret-pass") && !snapshot.contains("4242424242424242"))
        let scoped = try text(await session.perform(.read(selector: "#apply", maxChars: nil)))
        #expect(scoped.contains("button \"Apply\" [e1]"), "\(scoped)")
        _ = try text(await session.perform(.click(ref: "e1", double: false, note: nil)))
        #expect(session.pageTitle == "applied")
    }

    @Test func backspaceEditsAnEmailFieldThatHasNoCaret() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "textbox \"Email\""), double: false, note: nil)))
        for key in ["x", "y", "Backspace"] { _ = try text(await session.perform(.press(key: key, note: nil))) }
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('email').value", note: nil))).contains("Result: \"x\""))
    }

    /// A click that waits for the page to load must not act if the user takes over while it waits.
    @Test func takingOverWhileARequestWaitsForTheLoadStopsItActing() async throws {
        let checkoutPage = Self.checkout
        let server = try TinyWebServer { request in
            if request.path == "/slow" {
                Thread.sleep(forTimeInterval: 1.5)
                return .html("<html><head><title>Slow</title></head><body><button>Late</button></body></html>")
            }
            return .html(checkoutPage)
        }
        try await server.start()
        let session = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        _ = try text(await session.perform(.eval(expression: "setTimeout(() => { location.href = '/slow' }, 0); 1", note: nil)))
        try await eventuallyOnMain("the slow page to start loading") { session.loadState == .loading }
        let acting = Task { await session.perform(.click(ref: apply, double: false, note: nil)) }
        try await eventuallyOnMain("the click to wait on the load") { session.agentOverlay?.note.hasPrefix("clicking") == true }
        session.takeOver()
        let refused = try #require(failure(await acting.value))
        #expect(refused.code == "taken_over")
    }

    /// Stop closes the agent's connection: what it had queued behind a long request never runs.
    @Test func whenTheAgentIsStoppedWhatItQueuedNeverRuns() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        let waiting = Task { await session.perform(.wait(text: "never appears", ref: nil, gone: false, ms: nil, timeout: 20)) }
        try await eventuallyOnMain("the wait to run") { session.agentOverlay?.note == "waiting for “never appears”" }
        let before = session.operationTail
        let queued = Task { await session.perform(.click(ref: apply, double: false, note: nil)) }
        try await eventuallyOnMain("the click to queue behind it") { session.operationTail != before }
        session.abandonQueued()
        let started = ContinuousClock.now
        let (first, second) = (await waiting.value, await queued.value)
        #expect(failure(first)?.code == "cancelled" && failure(second)?.code == "cancelled")
        #expect(ContinuousClock.now - started < .seconds(3), "the wait gave up at once")
        #expect(try text(await session.perform(.eval(expression: "document.getElementById('count').textContent", note: nil))).contains("Result: \"0\""),
                "the queued click never ran")
    }

    // MARK: A page nobody is looking at

    /// With no pane the page sits in a borderless, nearly transparent window, ordered back and never
    /// key; the pane takes the page and gives it back without a reload. The app's window hangs off a
    /// screen's corner by one pixel (`BrowserParkPlacement`, tested on its own): a test's stays far
    /// off every screen, as every test window does, and a test process is no GUI app anyway (every
    /// window counts as occluded in it), so whether frames run parked was measured in a real app
    /// (docs/browser.md).
    @Test func aPageWithNoPaneSitsInAnUnfocusedWindowAndMovesToThePaneAndBackWithoutReloading() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let parked = try #require(session.webView?.window)
        #expect(parked.styleMask == .borderless && !parked.isKeyWindow && !parked.canBecomeKey)
        #expect(parked.isVisible && parked.alphaValue < 0.1 && parked.ignoresMouseEvents, "ordered back, deaf to the mouse")
        #expect(parked.frame.origin == BrowserParkPlacement.farAway, "a test's window touches no screen")

        _ = try text(await session.perform(.eval(expression: "window.__marker = 'same document'; 1", note: nil)))
        let timers = try text(await session.perform(.eval(expression: "new Promise((resolve) => setTimeout(() => resolve(window.innerWidth > 0), 20))", note: nil)))
        #expect(timers.contains("Result: true"), "the page is laid out and its timers run parked")

        // The pane takes the page.
        let pane = OffscreenWindow(size: CGSize(width: 700, height: 500), BrowserPageView(session: session).frame(width: 700, height: 500))
        try await eventuallyOnMain("the pane to hold the page") { session.webView?.window === pane.window }
        let inPane = try text(await session.perform(.eval(expression: "[window.__marker, innerWidth]", note: nil)))
        #expect(inPane.contains("\"same document\"") && inPane.contains("700"), "\(inPane)")

        // And gives it back when the pane goes.
        pane.show(EmptyView())
        try await eventuallyOnMain("the page to go back to its window") { session.webView?.window === parked }
        pane.close()
        let back = try text(await session.perform(.eval(expression: "window.__marker", note: nil)))
        #expect(back.contains("Result: \"same document\""), "the page never reloaded")
        #expect(server.requested.current.filter { $0 == "/checkout" }.count == 1)
    }

    // MARK: Screenshots

    @Test func aScreenshotIsAClampedNotBlankJPEG() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/tall")
        let outcome = await session.perform(.screenshot(ref: nil))
        guard case .result(let body, let image?) = outcome else {
            Issue.record("expected a screenshot, got \(outcome)")
            return
        }
        #expect(body.contains("Screenshot of the visible page"))
        #expect(image.mimeType == "image/jpeg")
        let data = try #require(Data(base64Encoded: image.data))
        #expect(data.count <= BrowserImageClamp.maxBytes)
        #expect(image.data.utf8.count <= BrowserOutcome.maxImageBase64Bytes)
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(max(decoded.width, decoded.height) <= BrowserImageClamp.maxEdge)
        #expect(decoded.width > 100 && decoded.height > 100)
        #expect(Self.distinctColors(decoded) > 8, "the page drew something")
        // Nothing of the agent's ring or card is in the picture: they live outside the page.
        #expect(session.agentOverlay != nil, "the overlay is up while it lingers")
    }

    @Test func anElementScreenshotIsCroppedToIt() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let pay = try ref(in: snapshot, "Pay $148.00")
        guard case .result(let body, let image?) = await session.perform(.screenshot(ref: pay)) else {
            Issue.record("expected an element screenshot")
            return
        }
        #expect(body.contains("button \"Pay $148.00\""))
        let data = try #require(Data(base64Encoded: image.data))
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(decoded.width < 400 && decoded.height < 100, "\(decoded.width)×\(decoded.height)")
    }

    private static func distinctColors(_ image: CGImage) -> Int {
        guard let data = image.dataProvider?.data, let bytes = CFDataGetBytePtr(data) else { return 0 }
        var seen = Set<UInt32>()
        let step = max(1, image.bytesPerRow / 8)
        let total = CFDataGetLength(data)
        var offset = 0
        while offset + 3 < total {
            seen.insert(UInt32(bytes[offset]) << 16 | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]))
            offset += step * 4 + 4
            if seen.count > 64 { break }
        }
        return seen.count
    }

    // MARK: Console and eval

    @Test func theConsoleAndScriptsAnswer() async throws {
        let (session, server) = try await start([
            "/log": "<html><head><title>Log</title></head><body><script>console.log('hello', {a:1}); console.warn('careful'); console.error('bad thing'); setTimeout(() => { throw new Error('later'); }, 0);</script></body></html>",
        ])
        defer { server.stop(); session.close() }
        let opened = try text(await session.perform(.open(url: server.url("/log").absoluteString, note: nil)))
        _ = opened
        try await eventuallyOnMain("the errors") { session.console.errorTotal >= 2 }
        let logged = try text(await session.perform(.console(clear: false)))
        #expect(logged.contains("log hello {\"a\":1}"))
        #expect(logged.contains("warn careful"))
        #expect(logged.contains("error bad thing"))
        #expect(logged.contains("Network: "))
        // The two errors were counted in the last result, not this one's trailer again.
        let after = try text(await session.perform(.console(clear: true)))
        #expect(!after.contains("Since your last call"), "\(after)")
        let cleared = try text(await session.perform(.console(clear: false)))
        #expect(cleared.contains("The console is empty."))

        #expect(try text(await session.perform(.eval(expression: "1 + 1", note: nil))).hasSuffix("Result: 2"))
        #expect(try text(await session.perform(.eval(expression: "document.title", note: nil))).contains("Result: \"Log\""))
        #expect(try text(await session.perform(.eval(expression: "({a: [1, 2], b: undefined, c: () => 1})", note: nil))).contains("Result: {\"a\":[1,2],\"c\":\"[function c]\"}"))
        #expect(try text(await session.perform(.eval(expression: "Promise.resolve('later')", note: nil))).contains("Result: \"later\""))
        #expect(try text(await session.perform(.eval(expression: "const x = 4; return x * 3", note: nil))).contains("Result: 12"), "statements that return a value")
        let threw = try #require(failure(await session.perform(.eval(expression: "null.boom", note: nil))))
        #expect(threw.code == "script_error")
        #expect(threw.message.hasPrefix(BrowserReport.notice + "\nThe script threw: "), "what the page threw is the page's words: \(threw.message)")
        let big = try text(await session.perform(.eval(expression: "'x'.repeat(50000)", note: nil)))
        #expect(big.contains("…[truncated]") && big.utf8.count < 20_000)
    }

    // MARK: Dialogs, downloads and refused navigations

    @Test func dialogsAreHandledAndToldInTheNextResult() async throws {
        let (session, server) = try await start([
            "/dialogs": "<html><head><title>Dialogs</title></head><body><button id=\"a\" onclick=\"alert('Saved!'); document.title = 'after alert'\">Save</button><button id=\"c\" onclick=\"document.title = confirm('Delete everything?') ? 'yes' : 'no'\">Delete</button><button id=\"p\" onclick=\"document.title = String(prompt('Name?', 'x'))\">Name</button></body></html>",
        ])
        defer { server.stop(); session.close() }
        try await opened(session, server, "/dialogs")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let alert = try text(await session.perform(.click(ref: try ref(in: snapshot, "Save"), double: false, note: nil)))
        #expect(alert.contains("A dialog appeared: alert “Saved!” (accepted)"), "\(alert)")
        #expect(alert.contains("Page: after alert"))
        let confirm = try text(await session.perform(.click(ref: try ref(in: snapshot, "Delete"), double: false, note: nil)))
        #expect(confirm.contains("A dialog appeared: confirm “Delete everything?” (dismissed)"))
        #expect(confirm.contains("Page: no"))
        let prompt = try text(await session.perform(.click(ref: try ref(in: snapshot, "Name"), double: false, note: nil)))
        #expect(prompt.contains("prompt “Name?” (dismissed)"))
        let quiet = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        #expect(!quiet.contains("A dialog appeared"), "each dialog is told once")
    }

    @Test func aDownloadIsCancelledAndReported() async throws {
        let (session, server) = try await start()
        server.setHandler { request in
            switch request.path {
            case "/file.bin":
                return TinyWebServer.Response(contentType: "application/octet-stream", headers: ["Content-Disposition": "attachment; filename=\"report.csv\""],
                                              body: Data("a,b\n1,2\n".utf8))
            default:
                return .html("<html><head><title>Files</title></head><body><a href=\"/file.bin\">Download the report</a></body></html>")
            }
        }
        defer { server.stop(); session.close() }
        try await opened(session, server, "/files")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let clicked = try text(await session.perform(.click(ref: try ref(in: snapshot, "Download the report"), double: false, note: nil)))
        #expect(clicked.contains("A download was blocked: report.csv"), "\(clicked)")
        #expect(clicked.contains("Page: Files"), "the page stays")
        let direct = await session.perform(.open(url: server.url("/file.bin").absoluteString, note: nil))
        #expect(failure(direct)?.code == "navigation_failed")
        #expect(failure(direct)?.message.contains("file download") == true)
    }

    @Test func onlyWebPagesOpenAndAPageCannotGoToAFile() async throws {
        let (session, server) = try await start([
            "/links": "<html><head><title>Links</title></head><body><a id=\"f\" href=\"file:///etc/hosts\">Local file</a><button onclick=\"location.href = 'file:///etc/hosts'\">Go</button><a href=\"x-shepherd-test://go\">Custom scheme</a></body></html>",
        ])
        defer { server.stop(); session.close() }
        for refused in ["file:///etc/hosts", "javascript:alert(1)", "data:text/html,hi", "blob:http://127.0.0.1/abc", "ftp://example.com/x", "about:config", "mailto:a@b.co"] {
            let outcome = try #require(failure(await session.perform(.open(url: refused, note: nil))), "\(refused) should be refused")
            #expect(outcome.code == "refused_url", "\(refused)")
        }
        #expect(session.webView == nil, "nothing was loaded")
        try await opened(session, server, "/links")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        _ = try text(await session.perform(.click(ref: try ref(in: snapshot, "Local file"), double: false, note: nil)))
        let go = try text(await session.perform(.click(ref: try ref(in: snapshot, "Go"), double: false, note: nil)))
        #expect(go.contains("Page: Links — \(server.origin)/links"), "the page stays: \(go)")
        #expect(session.pageURLString == server.origin + "/links")
        // A scheme WebKit would hand to the system is cancelled by the session's own policy.
        let custom = try text(await session.perform(.click(ref: try ref(in: snapshot, "Custom scheme"), double: false, note: nil)))
        #expect(custom.contains("Page: Links — \(server.origin)/links"), "\(custom)")
        let logged = try text(await session.perform(.console(clear: false)))
        #expect(logged.contains("Blocked a navigation to x-shepherd-test: URL."), "\(logged)")
        #expect(try text(await session.perform(.open(url: "about:blank", note: nil))).contains("Page: (untitled) — about:blank"))
    }

    @Test func anOpenThatFailsToConnectSaysWhy() async throws {
        let (session, server) = try await start()
        server.stop()
        defer { session.close() }
        let failed = try #require(failure(await session.perform(.open(url: "http://127.0.0.1:\(server.port)/x", note: nil))))
        #expect(failed.code == "navigation_failed")
        #expect(failed.message.hasPrefix("Could not load http://127.0.0.1:\(server.port)/x: "))
    }

    // MARK: Isolation

    @Test func twoThreadsPagesShareNoCookieOrStorage() async throws {
        let (a, server) = try await start()
        let b = BrowserSession(agentID: AgentID(), dataStores: .ephemeral)
        defer { server.stop(); a.close(); b.close() }
        try await opened(a, server, "/terms")
        try await opened(b, server, "/terms")
        _ = try text(await a.perform(.eval(expression: "document.cookie = 'session=a; path=/'; localStorage.setItem('cart', 'one item'); sessionStorage.setItem('s', '1'); 1", note: nil)))
        let inA = try text(await a.perform(.eval(expression: "[document.cookie, localStorage.getItem('cart')]", note: nil)))
        #expect(inA.contains("Result: [\"session=a\",\"one item\"]"))
        let inB = try text(await b.perform(.eval(expression: "[document.cookie, localStorage.getItem('cart'), sessionStorage.getItem('s')]", note: nil)))
        #expect(inB.contains("Result: [\"\",null,null]"), "\(inB)")
        #expect(a.webView?.configuration.websiteDataStore !== b.webView?.configuration.websiteDataStore)
    }

    // MARK: Taking over

    @Test func takingOverRefusesActionsButNotReading() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        session.takeOver()
        #expect(session.userHasControl)
        #expect(session.agentOverlay == nil, "the ring and card go")
        let refusals: [BrowserRequest] = [
            .open(url: server.url("/terms").absoluteString, note: nil), .click(ref: apply, double: false, note: nil),
            .type(ref: apply, text: "x", clear: false, submit: false, note: nil), .press(key: "Enter", note: nil),
            .scroll(direction: "down", amount: nil, ref: nil, note: nil), .eval(expression: "1", note: nil),
            .back(note: nil), .forward(note: nil), .reload(note: nil),
        ]
        for request in refusals {
            let refused = try #require(failure(await session.perform(request)), "\(request) should be refused")
            #expect(refused.code == "taken_over")
            #expect(refused.message == BrowserAgentPresence.takenOverMessage)
        }
        #expect(session.pageURLString == server.origin + "/checkout", "nothing was done")
        // Reading, waiting, screenshots and the console still work, and do not show the card.
        _ = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        _ = try text(await session.perform(.console(clear: false)))
        _ = try text(await session.perform(.wait(text: "Checkout", ref: nil, gone: false, ms: nil, timeout: 2)))
        guard case .result(_, let image?) = await session.perform(.screenshot(ref: nil)) else {
            Issue.record("a screenshot still works")
            return
        }
        #expect(!image.data.isEmpty)
        #expect(session.agentOverlay == nil)
        session.handBack()
        #expect(!session.userHasControl)
        _ = try text(await session.perform(.click(ref: apply, double: false, note: nil)))
    }

    @Test func theUsersOwnInputInThePageTakesItOverButTheAgentsDoesNot() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        try await opened(session, server, "/checkout")
        let snapshot = try text(await session.perform(.read(selector: nil, maxChars: nil)))
        let apply = try ref(in: snapshot, "Apply promo")
        // While an action's card is up, the agent's own dispatched click is untrusted and changes nothing.
        session.agentBegan(note: "clicking through checkout")
        #expect(session.agentOverlay?.note == "clicking through checkout")
        _ = try text(await session.perform(.click(ref: apply, double: false, note: nil)))
        #expect(!session.userHasControl, "the agent's events are not the user's")
        // A trusted event reaches the same handler: the page told the app the user's input arrived.
        session.handle(.userInput)
        #expect(session.userHasControl)
        #expect(session.agentOverlay == nil)
    }

    // MARK: The card

    @Test func theCardShowsWhileAnActionRunsAndLingersThenGoes() async throws {
        let (session, server) = try await start()
        defer { server.stop(); session.close() }
        let opening = Task { await session.perform(.open(url: server.url("/checkout").absoluteString, note: "opening the checkout")) }
        try await eventuallyOnMain("the card") { session.agentOverlay?.note == "opening the checkout" }
        _ = await opening.value
        #expect(session.agentOverlay != nil, "it stays for a few seconds after")
        try await eventuallyOnMain("the card to go", timeout: .seconds(10)) { session.agentOverlay == nil }
    }
}
