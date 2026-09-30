import CoreGraphics
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

// The agent's browser tools against the thread's own page (docs/browser.md). Every tool is one
// `BrowserRequest`; `perform` runs them one at a time per page, refuses the ones that act while the
// user has taken over, shows the agent's use of the page (the ring, pointer and card), and answers
// text that starts with the untrusted-content notice and the page line. The web view itself is
// `BrowserHost.swift`'s: this file has no WebKit in it.

/// One tool call's result before it is worded: a body, and for a screenshot an image, or a failure.
private enum BrowserStep {
    case ok(String, image: BrowserImage? = nil)
    /// `fromPage`: the message quotes the page's own words (an element's name, what a script threw),
    /// so it carries the untrusted-content notice like a result does.
    case fail(code: String, message: String, fromPage: Bool = false)
}

extension BrowserSession {
    /// Serves `request`, after the requests before it. Never throws: a failure is an outcome. A
    /// request still waiting its turn when the agent gives up (`abandonQueued`) is not run.
    func perform(_ request: BrowserRequest, origin: BrowserOrigin = .local) async -> BrowserOutcome {
        let previous = operationTail
        let epoch = operationEpoch
        let work = Task { @MainActor () -> BrowserOutcome in
            await previous?.value
            guard epoch == self.operationEpoch else {
                return .failure(code: "cancelled", message: "The request was cancelled before it started.")
            }
            return await self.run(request, origin: origin)
        }
        operationTail = Task { _ = await work.value }
        return await work.value
    }

    /// The agent's connection went away with requests in flight (Stop): the ones not yet started
    /// never run, so a click queued behind a long wait does not fire after the user stopped the agent.
    func abandonQueued() {
        operationEpoch &+= 1
    }

    /// The user has taken over since this request began (it waited for a page, or for the request
    /// before it): an acting request that is about to act is refused.
    private func refusedByTakeOver() -> BrowserStep? {
        presence.userHasControl ? .fail(code: "taken_over", message: BrowserAgentPresence.takenOverMessage) : nil
    }

    // MARK: One request

    private func run(_ request: BrowserRequest, origin: BrowserOrigin) async -> BrowserOutcome {
        guard presence.permits(request) else {
            return .failure(code: "taken_over", message: BrowserAgentPresence.takenOverMessage)
        }
        if let problem = BrowserRequestCheck.problem(with: request) {
            return .failure(code: "invalid", message: problem)
        }
        if case .open = request {} else if webView == nil || url == nil {
            return .failure(code: "no_page", message: "No page is open in this thread's browser. Call browser_open with a URL first.")
        }
        // An agent on the thread's host drives a page on this Mac: what it may read, act on or open
        // stays off this Mac's own network (BrowserHostDrive.swift).
        if case .host(let guardian) = origin {
            let target = BrowserHostGuard.historyStep(of: request).flatMap { historyTarget($0) }
            if let refusal = await guardian.refusal(for: request, page: currentURL, historyTarget: target) { return refusal }
            hostGuard = guardian
            blockedNavigation = nil
            blockedFrames = []
            hostRequestsInFlight += 1
        }
        defer {
            if case .host = origin {
                hostRequestsInFlight -= 1
                hostGuardUntil = Date().addingTimeInterval(Self.hostGuardLinger)
            }
        }
        var target: BrowserTarget?
        if let ref = BrowserRequestCheck.ref(of: request), webView != nil {
            target = await peek(ref)
        }
        agentBegan(note: BrowserNote.phrase(for: request, target: target))
        defer { agentEnded() }
        let idleNavigations = events.navigations
        let step = await dispatch(request)
        let outcome = finish(step, idleNavigations: idleNavigations)
        // The page is where it is now: nothing of it (its title, its address, its text) goes to a
        // host's agent unless it is an address the agent may be shown.
        if case .host(let guardian) = origin, case .result = outcome, let refusal = await guardian.pageRefusal(currentURL) { return refusal }
        return outcome
    }

    private func finish(_ step: BrowserStep, idleNavigations: Int) -> BrowserOutcome {
        switch step {
        case .fail(let code, let message, let fromPage):
            return .failure(code: code, message: fromPage ? BrowserReport.notice + "\n" + message : message)
        case .ok(let body, let image):
            let seen = BrowserEvents(consoleErrors: console.errorTotal - reportedErrors, navigations: idleNavigations,
                                     dialogs: events.dialogs, downloads: events.downloads,
                                     blocked: (blockedNavigation.map { [$0.message] } ?? []) + blockedFrames)
            events = BrowserEvents()
            reportedErrors = console.errorTotal
            return .result(text: BrowserReport.compose(title: pageTitle, url: pageURLString, body: body, events: seen), image: image)
        }
    }

    private func dispatch(_ request: BrowserRequest) async -> BrowserStep {
        switch request {
        case .open(let text, _): return await open(text)
        case .read(let selector, let maxChars): return await read(selector: selector, maxChars: maxChars)
        case .click(let ref, let double, _): return await click(ref, double: double)
        case .type(let ref, let text, let clear, let submit, _): return await type(ref, text: text, clear: clear, submit: submit)
        case .press(let key, _): return await press(key)
        case .scroll(let direction, let amount, let ref, _): return await scroll(direction: direction, amount: amount, ref: ref)
        case .wait(let text, let ref, let gone, let ms, let timeout): return await waitFor(text: text, ref: ref, gone: gone, ms: ms, timeout: timeout)
        case .screenshot(let ref): return await screenshot(ref)
        case .console(let clear): return consoleReport(clear: clear)
        case .eval(let expression, _): return await eval(expression)
        case .back: return await step(.back)
        case .forward: return await step(.forward)
        case .reload: return await step(.reload)
        }
    }

    // MARK: Tools

    private func open(_ text: String) async -> BrowserStep {
        let url: URL
        switch BrowserURLPolicy.agentURL(text) {
        case .failure(let refusal): return .fail(code: "refused_url", message: refusal.message)
        case .success(let resolved): url = resolved
        }
        if let refusal = refusedByTakeOver() { return refusal }
        prepareWebView()
        let serial = navigationSerial
        guard loadForAgent(url) else {
            // The page's own host port could not be forwarded here: nothing loaded.
            return .fail(code: "navigation_failed", message: forwardRefusal?.agentMessage ?? "\(url.absoluteString) could not be opened.")
        }
        switch await waitForLoad(after: serial, timeout: BrowserLimits.loadSeconds, target: url) {
        case .blocked(let code, let message):
            return .fail(code: code, message: message)
        case .timedOut:
            // A page can be usable and still hold a request that never ends: it has a document.
            if let answer = try? await callAgent("info"), let ready = answer["ready"] as? String, ready != "loading" {
                agentPointed(at: nil)
                return .ok("Opened \(pageURLString ?? url.absoluteString). It is still loading some resources.")
            }
            return .fail(code: "timeout", message: "\(url.absoluteString) did not finish loading in \(Int(BrowserLimits.loadSeconds)) seconds.")
        case .failed(let message):
            if !events.downloads.isEmpty {
                return .fail(code: "navigation_failed", message: "\(url.absoluteString) is a file download, which the browser doesn't take.")
            }
            return .fail(code: "navigation_failed", message: "Could not load \(url.absoluteString): \(message)")
        case .finished:
            await pause(150)
            agentPointed(at: nil)
            let status = mainStatus.map { $0 >= 400 ? " It answered HTTP \($0)." : "" } ?? ""
            return .ok("Opened \(pageURLString ?? url.absoluteString).\(status)")
        }
    }

    private func read(selector: String?, maxChars: Int?) async -> BrowserStep {
        await waitUntilSettled()
        do {
            var options: [String: Any] = ["maxChars": BrowserLimits.snapshotChars(maxChars)]
            if let selector, !selector.trimmingCharacters(in: .whitespaces).isEmpty { options["selector"] = selector }
            let answer = try await callAgent("read", options)
            if let failure = failure(in: answer) { return failure }
            return .ok((answer["text"] as? String) ?? "")
        } catch {
            return scriptFailure(error, doing: "read the page")
        }
    }

    private func click(_ ref: String, double: Bool) async -> BrowserStep {
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        let serial = navigationSerial
        do {
            let answer = try await callAgent("click", ["ref": ref, "double": double])
            if let failure = failure(in: answer) { return failure }
            point(at: answer["rect"])
            let navigated = await settleAfterAction(serial: serial)
            let label = Self.label(of: answer["target"])
            return .ok("\(double ? "Double-clicked" : "Clicked") \(label).\(navigated ? " The page navigated." : "")")
        } catch {
            return scriptFailure(error, doing: "click")
        }
    }

    private func type(_ ref: String, text: String, clear: Bool, submit: Bool) async -> BrowserStep {
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        let serial = navigationSerial
        do {
            let answer = try await callAgent("type", ["ref": ref, "text": text, "clear": clear, "submit": submit])
            if let failure = failure(in: answer) { return failure }
            point(at: answer["rect"])
            let navigated = await settleAfterAction(serial: serial)
            let label = Self.label(of: answer["target"])
            var body = "Typed \(text.count) character\(text.count == 1 ? "" : "s") into \(label)"
            body += clear ? ", replacing what was there." : "."
            if submit { body += " Pressed Enter." + (navigated ? " The page navigated." : "") }
            return .ok(body)
        } catch {
            return scriptFailure(error, doing: "type")
        }
    }

    private func press(_ spec: String) async -> BrowserStep {
        guard let key = BrowserKey.parse(spec) else {
            return .fail(code: "invalid", message: "\"\(spec)\" is not a key browser_press knows. Try Enter, Tab, Escape, ArrowDown, Backspace, a single character, or Control+a.")
        }
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        let serial = navigationSerial
        do {
            let answer = try await callAgent("pressKey", key.jsonObject)
            if let failure = failure(in: answer) { return failure }
            point(at: answer["rect"])
            let navigated = await settleAfterAction(serial: serial)
            var body = "Pressed \(spec)."
            if let focus = answer["focus"] as? String { body += " Focus is on \(focus)." }
            if navigated { body += " The page navigated." }
            return .ok(body)
        } catch {
            return scriptFailure(error, doing: "press")
        }
    }

    private func scroll(direction: String?, amount: Int?, ref: String?) async -> BrowserStep {
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        do {
            var options: [String: Any] = [:]
            if let direction { options["direction"] = direction.lowercased() }
            if let amount { options["amount"] = amount }
            if let ref { options["ref"] = ref }
            let answer = try await callAgent("scroll", options)
            if let failure = failure(in: answer) { return failure }
            point(at: answer["rect"])
            await pause(120)
            let y = (answer["y"] as? NSNumber)?.intValue ?? 0
            let maxY = (answer["maxY"] as? NSNumber)?.intValue ?? 0
            var body: String
            if ref != nil, direction == nil {
                body = "Scrolled \(Self.label(of: answer["target"])) into view."
            } else {
                body = "Scrolled \(direction?.lowercased() ?? "the page")."
            }
            if let container = answer["container"] as? String { body += " In \(container)." }
            body += " Now at \(y) of \(maxY) px" + (y <= 0 ? " (the top)." : y >= maxY ? " (the bottom)." : ".")
            return .ok(body)
        } catch {
            return scriptFailure(error, doing: "scroll")
        }
    }

    private func waitFor(text: String?, ref: String?, gone: Bool, ms: Int?, timeout: Double?) async -> BrowserStep {
        let text = text.flatMap { $0.isEmpty ? nil : $0 }
        guard text != nil || ref != nil else {
            let wait = BrowserLimits.waitMilliseconds(ms ?? 1000)
            await pause(wait)
            return .ok("Waited \(wait) ms.")
        }
        let seconds = BrowserLimits.waitSeconds(timeout)
        let deadline = ContinuousClock.now + .milliseconds(Int(seconds * 1000))
        let what = text.map { "“\(BrowserNote.clip($0, to: 60))”" } ?? "ref \(ref ?? "")"
        let epoch = operationEpoch
        while ContinuousClock.now < deadline {
            guard epoch == operationEpoch else { return .fail(code: "cancelled", message: "The wait was cancelled.") }
            do {
                var options: [String: Any] = ["gone": gone]
                if let text { options["text"] = text }
                if let ref { options["ref"] = ref }
                let answer = try await callAgent("check", options)
                if let failure = failure(in: answer) { return failure }
                if answer["met"] as? Bool == true {
                    return .ok(gone ? "\(what) is gone." : "\(what) is there.")
                }
            } catch {
                // The page is between documents, or busy; ask again.
            }
            await pause(150)
        }
        return .fail(code: "timeout", message: "Timed out after \(Int(seconds)) seconds waiting for \(what)\(gone ? " to go" : "").")
    }

    private func screenshot(_ ref: String?) async -> BrowserStep {
        await waitUntilSettled()
        var rect: CGRect?
        var subject = "the visible page"
        if let ref {
            do {
                let answer = try await callAgent("rectOf", ["ref": ref])
                if let failure = failure(in: answer) { return failure }
                rect = Self.rect(answer["rect"]).map { css in
                    let viewport = Self.viewportSize(answer["viewport"]) ?? CGSize(width: 10_000, height: 10_000)
                    let visible = css.intersection(CGRect(origin: .zero, size: viewport))
                    return CGRect(x: visible.minX * zoom, y: visible.minY * zoom, width: visible.width * zoom, height: visible.height * zoom)
                }
                if let rect, rect.width < 1 || rect.height < 1 {
                    return .fail(code: "hidden", message: "ref \(ref) is not in the visible page; scroll to it first.")
                }
                subject = Self.label(of: answer["target"])
            } catch {
                return scriptFailure(error, doing: "screenshot")
            }
        }
        await pause(100)
        guard let image = await snapshotImage(rect: rect), let encoded = BrowserImageClamp.encode(image) else {
            return .fail(code: "unavailable", message: "The page could not be captured.")
        }
        let picture = BrowserImage(data: encoded.data.base64EncodedString(), mimeType: "image/jpeg")
        return .ok("Screenshot of \(subject), \(encoded.width)×\(encoded.height).", image: picture)
    }

    private func consoleReport(clear: Bool) -> BrowserStep {
        let entries = console.entries
        var lines = entries.suffix(BrowserLimits.consoleLines).map { entry in
            let level = entry.level == .error ? "error" : entry.level == .warning ? "warn" : "log"
            return "[\(entry.time)] \(level) \(entry.text)"
        }
        if entries.count > lines.count { lines.insert("(\(entries.count - lines.count) earlier lines not shown)", at: 0) }
        var body = lines.isEmpty ? "The console is empty." : "Console:\n" + lines.joined(separator: "\n")
        body += "\nNetwork: \(console.network) request\(console.network == 1 ? "" : "s") since the page loaded."
        if clear {
            console.clear()
            body += "\nThe console was cleared."
        }
        return .ok(body)
    }

    private func eval(_ expression: String) async -> BrowserStep {
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        let attempts = [BrowserEval.expressionBody(expression), BrowserEval.statementsBody(expression)]
        var last: BrowserScriptFailure?
        for (index, body) in attempts.enumerated() {
            do {
                let value = try await callPage(body, deadline: evalDeadline)
                let text = (value as? String) ?? "undefined"
                return .ok("Result: " + BrowserNote.clip(text, to: BrowserLimits.evalResultChars, mark: "…[truncated]"))
            } catch {
                let failure = error as? BrowserScriptFailure ?? BrowserScriptFailure(error)
                last = failure
                if failure.isTimeout { return scriptFailure(failure, doing: "run the script", seconds: evalDeadline) }
                // Only a script that never compiled as an expression is tried as statements.
                guard index == 0, BrowserEval.mayBeStatements(failure) else {
                    return .fail(code: "script_error", message: "The script threw: \(failure.message)", fromPage: true)
                }
            }
        }
        return .fail(code: "script_error", message: "The script threw: \(last?.message ?? "an error")", fromPage: true)
    }

    private func step(_ direction: BrowserHistoryStep) async -> BrowserStep {
        let can = canStep
        switch direction {
        case .back where !can.back: return .fail(code: "invalid", message: "There is no earlier page in this thread's browser history.")
        case .forward where !can.forward: return .fail(code: "invalid", message: "There is no later page in this thread's browser history.")
        default: break
        }
        // History can hold a page the user opened by hand (a `file:` page): the agent's steps
        // never land on anything but a web page.
        if let target = historyTarget(direction), !BrowserURLPolicy.allowsPageNavigation(to: target) || target.scheme?.lowercased() == "blob" {
            return .fail(code: "refused_url", message: "That page isn't a web page (\(target.scheme ?? "no scheme"):); browser_\(direction == .back ? "back" : direction == .forward ? "forward" : "reload") only goes to http, https and about:blank pages.")
        }
        await waitUntilSettled()
        if let refusal = refusedByTakeOver() { return refusal }
        let serial = navigationSerial
        stepHistory(direction)
        _ = await settleAfterAction(serial: serial, patience: 1_000)
        await waitUntilSettled()
        if case .failed(let message) = loadState { return .fail(code: "navigation_failed", message: "Could not load the page: \(message)") }
        let page = pageURLString ?? "the page"
        switch direction {
        case .back: return .ok("Went back to \(page).")
        case .forward: return .ok("Went forward to \(page).")
        case .reload: return .ok("Reloaded \(page).")
        }
    }

    // MARK: Waiting

    private enum LoadResult {
        case finished, failed(String), timedOut
        /// The guard stopped the navigation (a redirect, or the address itself): it never started.
        case blocked(code: String, message: String)
    }

    /// Waits for the navigation that begins after `serial` to finish or fail. A `target` that only
    /// changes the address's fragment moves inside the document and starts no navigation: the page
    /// is taken as loaded once it stands at `target` and nothing loads.
    private func waitForLoad(after serial: Int, timeout: Double, target: URL? = nil) async -> LoadResult {
        let deadline = ContinuousClock.now + .milliseconds(Int(timeout * 1000))
        let begun = ContinuousClock.now
        while ContinuousClock.now < deadline {
            if let blocked = blockedNavigation { return .blocked(code: blocked.code, message: blocked.message) }
            if navigationSerial > serial {
                switch loadState {
                case .finished: return .finished
                case .failed(let message): return .failed(message)
                case .idle, .loading: break
                }
            } else if let target, ContinuousClock.now - begun > .milliseconds(400), !isLoading, pageURLString == target.absoluteString {
                return .finished
            }
            await pause(25)
        }
        return .timedOut
    }

    /// A page that is still loading is waited for (at most 10 seconds) before it is read or acted on.
    private func waitUntilSettled() async {
        let deadline = ContinuousClock.now + .seconds(10)
        while loadState == .loading, ContinuousClock.now < deadline { await pause(25) }
    }

    /// After a click, a key or a submit: a navigation it caused starts a moment later and is waited
    /// for; either way the page gets a moment to draw what the action changed. True if it navigated.
    private func settleAfterAction(serial: Int, patience: Int = 250) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(patience)
        while ContinuousClock.now < deadline, navigationSerial == serial { await pause(25) }
        if navigationSerial > serial {
            _ = await waitForLoad(after: serial, timeout: 15)
            await pause(150)
            return true
        }
        await pause(100)
        return false
    }

    private func pause(_ milliseconds: Int) async {
        try? await Task.sleep(for: .milliseconds(milliseconds))
    }

    // MARK: Answers from the page's script

    /// The failure a script answered (`{error, message}`), if it did.
    private func failure(in answer: [String: Any]) -> BrowserStep? {
        guard let code = answer["error"] as? String else { return nil }
        // A ref that is unknown or gone says only what the agent gave; the rest quote the page.
        return .fail(code: code, message: (answer["message"] as? String) ?? "The page refused.",
                     fromPage: code != "stale_ref" && code != "no_such_ref")
    }

    private func scriptFailure(_ error: Error, doing action: String, seconds: Double? = nil) -> BrowserStep {
        if let failure = error as? BrowserScriptFailure, failure.isTimeout {
            return .fail(code: "timeout", message: "The page didn't answer in \(Int(seconds ?? scriptDeadline)) seconds; a script in it may be stuck. The user can reload the page.")
        }
        let message = (error as? BrowserScriptFailure)?.message ?? error.localizedDescription
        return .fail(code: "script_error", message: "Could not \(action): \(message)", fromPage: true)
    }

    private func peek(_ ref: String) async -> BrowserTarget? {
        guard let answer = try? await callAgent("peek", ["ref": ref]), let target = answer["target"] as? [String: Any] else { return nil }
        return BrowserTarget(role: target["role"] as? String, name: (target["name"] as? String).flatMap { $0.isEmpty ? nil : $0 })
    }

    private func point(at rect: Any?) {
        guard let rect = Self.rect(rect) else { return }
        agentPointed(at: CGPoint(x: rect.midX, y: rect.midY))
    }

    /// `role "name"` from a script's `target`.
    private static func label(of target: Any?) -> String {
        guard let target = target as? [String: Any] else { return "the element" }
        let role = (target["role"] as? String) ?? "element"
        let name = (target["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return role + (name.map { " \"\(BrowserNote.clip($0, to: 80))\"" } ?? "")
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any], let x = (value["x"] as? NSNumber)?.doubleValue,
              let y = (value["y"] as? NSNumber)?.doubleValue, let width = (value["width"] as? NSNumber)?.doubleValue,
              let height = (value["height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func viewportSize(_ value: Any?) -> CGSize? {
        guard let value = value as? [String: Any], let width = (value["width"] as? NSNumber)?.doubleValue,
              let height = (value["height"] as? NSNumber)?.doubleValue else { return nil }
        return CGSize(width: width, height: height)
    }
}

// MARK: Checks that need no page

enum BrowserRequestCheck {
    /// What is wrong with `request` before any page is asked, in words for the agent; nil if nothing.
    static func problem(with request: BrowserRequest) -> String? {
        switch request {
        case .type(let ref, let text, _, _, _):
            if ref.isEmpty { return "browser_type needs a ref from browser_read." }
            if text.count > BrowserRequest.maxTextLength { return "text is longer than \(BrowserRequest.maxTextLength) characters." }
        case .click(let ref, _, _):
            if ref.isEmpty { return "browser_click needs a ref from browser_read." }
        case .press(let key, _):
            if BrowserKey.parse(key) == nil {
                return "\"\(key)\" is not a key browser_press knows. Try Enter, Tab, Escape, ArrowDown, Backspace, a single character, or Control+a."
            }
        case .scroll(let direction, let amount, let ref, _):
            if direction == nil, ref == nil { return "browser_scroll needs a direction (up, down, left, right, top, bottom) or a ref." }
            if let direction, !["up", "down", "left", "right", "top", "bottom"].contains(direction.lowercased()) {
                return "direction must be up, down, left, right, top or bottom."
            }
            if let amount, amount < 0 { return "amount must not be negative." }
        case .wait(let text, let ref, _, let ms, _):
            if (text ?? "").isEmpty, ref == nil, ms == nil { return "browser_wait needs text, a ref, or ms." }
        case .eval(let expression, _):
            if expression.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "browser_eval needs an expression." }
            if expression.count > BrowserRequest.maxExpressionLength { return "the expression is longer than \(BrowserRequest.maxExpressionLength) characters." }
        case .open(let url, _):
            if url.isEmpty { return BrowserURLPolicy.Refusal.empty.message }
        case .read, .screenshot, .console, .back, .forward, .reload:
            break
        }
        return nil
    }

    /// The ref a request acts on, if it names one.
    static func ref(of request: BrowserRequest) -> String? {
        switch request {
        case .click(let ref, _, _), .type(let ref, _, _, _, _): ref
        case .scroll(_, _, let ref, _), .wait(_, let ref, _, _, _), .screenshot(let ref): ref
        default: nil
        }
    }
}

// MARK: eval

enum BrowserEval {
    /// Serializes a value for the agent: JSON, with functions, DOM nodes, errors, maps, sets, cycles
    /// and non-finite numbers put in words.
    static let serializer = #"""
    const __serialize = (value) => {
      if (value === undefined) return 'undefined';
      const stack = [];
      const replacer = function (key, v) {
        if (typeof v === 'bigint') return v.toString() + 'n';
        if (typeof v === 'function') return '[function ' + (v.name || 'anonymous') + ']';
        if (typeof v === 'symbol') return v.toString();
        if (typeof v === 'number' && !Number.isFinite(v)) return String(v);
        if (v instanceof Error) return v.name + ': ' + v.message;
        if (typeof Node !== 'undefined' && v instanceof Node) return '[' + v.nodeName + (v.id ? '#' + v.id : '') + ']';
        if (v instanceof Map) return Object.fromEntries(Array.from(v.entries()).map(([k, x]) => [String(k), x]));
        if (v instanceof Set) return Array.from(v);
        if (v && typeof v === 'object') {
          while (stack.length && stack[stack.length - 1] !== this) stack.pop();
          if (stack.includes(v)) return '[Circular]';
          stack.push(v);
        }
        return v;
      };
      try {
        const text = JSON.stringify(value, replacer);
        return text === undefined ? String(value) : text;
      } catch (e) {
        return 'Could not serialize the result: ' + e.message;
      }
    };
    """#

    /// `expression` as a single expression whose value is the answer.
    static func expressionBody(_ expression: String) -> String {
        serializer + "\nconst __value = await (async () => { return (\n" + expression + "\n); })();\nreturn __serialize(__value);"
    }

    /// `expression` as statements that `return` the answer.
    static func statementsBody(_ expression: String) -> String {
        serializer + "\nconst __value = await (async () => {\n" + expression + "\n})();\nreturn __serialize(__value);"
    }

    /// Whether a failed expression attempt was a script that only parses as statements. A runtime
    /// `SyntaxError` (a bad `JSON.parse`) already ran, so it is not tried again.
    static func mayBeStatements(_ failure: BrowserScriptFailure) -> Bool {
        failure.isSyntaxError && !failure.message.contains("JSON")
    }
}

// MARK: A bounded wait on something that may not answer

enum BrowserDeadline<Value> {
    case value(Value)
    case thrown(Error)
    case timedOut
}

/// Runs `operation` and gives up on it after `seconds`. A page's script can hang; its call is then
/// abandoned, not cancelled.
@MainActor
func withDeadline<Value>(_ seconds: Double, _ operation: @escaping @MainActor () async throws -> Value) async -> BrowserDeadline<Value> {
    await withCheckedContinuation { continuation in
        var finished = false
        let finish: (BrowserDeadline<Value>) -> Void = { result in
            guard !finished else { return }
            finished = true
            continuation.resume(returning: result)
        }
        Task { @MainActor in
            do { finish(.value(try await operation())) } catch { finish(.thrown(error)) }
        }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            finish(.timedOut)
        }
    }
}

extension BrowserNote {
    /// `text` cut to `length` with `mark` at the cut.
    static func clip(_ text: String, to length: Int, mark: String) -> String {
        text.count > length ? String(text.prefix(length)) + mark : text
    }
}
