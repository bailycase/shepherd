import Foundation

/// How an agent's `browser_*` tool calls read as activity lines (docs/design/side-pane-browser.md › Side pane: Browser ›
/// In the thread): "Opened localhost:5173/checkout in Browser", "Read the page", "Clicked “Pay
/// $148.00”", "Typed in “Email”", "Took a screenshot", "Ran a script in the page". A line names
/// what was acted on when the tool's result says it (`Clicked button "Pay $148.00".`); what was
/// typed is never in a line. Shared with the iOS client, which draws the same lines.
public enum NativeBrowserActivity {
    public static let prefix = "browser_"

    public static func isBrowserTool(_ name: String) -> Bool {
        tools.contains(name)
    }

    public static let tools: Set<String> = [
        "browser_open", "browser_read", "browser_click", "browser_type", "browser_press", "browser_scroll", "browser_wait",
        "browser_screenshot", "browser_console", "browser_eval", "browser_back", "browser_forward", "browser_reload",
    ]

    /// "click", "open": the calls list's kind column.
    public static func action(_ tool: String) -> String {
        tool.hasPrefix(prefix) ? String(tool.dropFirst(prefix.count)) : tool
    }

    /// "localhost:5173/checkout" for `http://localhost:5173/checkout`: the host and port, then the
    /// path and query, the scheme left out for http and https and a lone "/" too.
    public static func address(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let components = URLComponents(string: trimmed), let scheme = components.scheme?.lowercased() else { return trimmed }
        if scheme == "about" { return trimmed }
        guard scheme == "http" || scheme == "https", let host = components.host else { return trimmed }
        var shown = (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host) + (components.port.map { ":\($0)" } ?? "")
        let path = components.percentEncodedPath
        if path != "/" { shown += path }
        if let query = components.percentEncodedQuery { shown += "?" + query }
        return shown
    }

    /// What a click or a type acted on, from the result's line `Clicked button "Pay $148.00".`
    /// or `Typed 14 characters into textbox "Email".`: the quoted name. Nil when the result names none.
    public static func subject(fromResult output: String) -> String? {
        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("Clicked ") || line.hasPrefix("Double-clicked ") || line.hasPrefix("Typed ") || line.hasPrefix("Scrolled ") else { continue }
            guard let open = line.firstIndex(of: "\""), let close = line.lastIndex(of: "\""), open < close else { return nil }
            let name = line[line.index(after: open)..<close]
            return name.isEmpty ? nil : String(name)
        }
        return nil
    }

    /// The line while the call runs: "Opening localhost:5173/checkout in Browser".
    public static func running(tool: String, subject: String?) -> String {
        switch tool {
        case "browser_open": return "Opening \(subject ?? "a page") in Browser"
        case "browser_read": return "Reading the page"
        case "browser_click": return "Clicking" + (subject.map { " “\($0)”" } ?? "")
        case "browser_type": return "Typing" + (subject.map { " in “\($0)”" } ?? "")
        case "browser_press": return "Pressing" + (subject.map { " \($0)" } ?? " a key")
        case "browser_scroll": return "Scrolling"
        case "browser_wait": return "Waiting" + (subject.map { " for “\($0)”" } ?? "")
        case "browser_screenshot": return "Taking a screenshot"
        case "browser_console": return "Reading the console"
        case "browser_eval": return "Running a script in the page"
        case "browser_back": return "Going back"
        case "browser_forward": return "Going forward"
        case "browser_reload": return "Reloading the page"
        default: return "Using Browser"
        }
    }

    /// One finished call: "Opened localhost:5173/checkout in Browser", "Clicked “Pay $148.00”".
    public static func done(tool: String, subject: String?) -> String {
        switch tool {
        case "browser_open": return "Opened \(subject ?? "a page") in Browser"
        case "browser_read": return "Read the page"
        case "browser_click": return "Clicked" + (subject.map { " “\($0)”" } ?? " an element")
        case "browser_type": return "Typed in" + (subject.map { " “\($0)”" } ?? " a field")
        case "browser_press": return "Pressed" + (subject.map { " \($0)" } ?? " a key")
        case "browser_scroll": return "Scrolled" + (subject.map { " \($0)" } ?? " the page")
        case "browser_wait": return "Waited" + (subject.map { " for “\($0)”" } ?? "")
        case "browser_screenshot": return "Took a screenshot"
        case "browser_console": return "Read the console"
        case "browser_eval": return "Ran a script in the page"
        case "browser_back": return "Went back"
        case "browser_forward": return "Went forward"
        case "browser_reload": return "Reloaded the page"
        default: return "Used Browser"
        }
    }

    /// Consecutive calls of one tool as one line: "Clicked 3 elements", "Read the page 4 times".
    public static func merged(tool: String, count: Int) -> String {
        switch tool {
        case "browser_open": return "Opened \(count) pages in Browser"
        case "browser_read": return "Read the page \(count) times"
        case "browser_click": return "Clicked \(count) elements"
        case "browser_type": return "Typed in \(count) fields"
        case "browser_press": return "Pressed \(count) keys"
        case "browser_scroll": return "Scrolled \(count) times"
        case "browser_wait": return "Waited \(count) times"
        case "browser_screenshot": return "Took \(count) screenshots"
        case "browser_console": return "Read the console \(count) times"
        case "browser_eval": return "Ran \(count) scripts in the page"
        case "browser_back": return "Went back \(count) times"
        case "browser_forward": return "Went forward \(count) times"
        case "browser_reload": return "Reloaded the page \(count) times"
        default: return "Used Browser \(count) times"
        }
    }

    /// A call that failed: "Click failed in Browser".
    public static func failed(tool: String) -> String {
        "Browser \(action(tool)) failed"
    }

    /// A call the user's Stop interrupted.
    public static func stopped(tool: String) -> String {
        "Browser \(action(tool)) stopped"
    }
}
