import Foundation

// What a Browser's address field takes and shows (docs/design/side-pane-browser.md › Address field),
// pure so it is tested without WebKit. Shared by the Mac's pane and the iOS client's page.

public enum BrowserAddress {
    /// Where a search goes.
    public static let searchBase = "https://www.google.com/search?q="

    /// What the address field takes: a URL with a scheme, a host (with a port or a path), a bare
    /// port (":5173" is this Mac), or else words to search for. Local hosts go over http, the
    /// rest over https. Nil for nothing.
    public static func resolve(_ input: String) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if text.hasPrefix(":"), let port = Int(text.dropFirst().prefix { $0.isNumber }), port > 0 {
            return URL(string: "http://localhost" + text)
        }
        let lower = text.lowercased()
        for scheme in ["http://", "https://", "file://", "about:"] where lower.hasPrefix(scheme) {
            return URL(string: text)
        }
        if !text.contains(where: \.isWhitespace), looksLikeHost(text) {
            return URL(string: (isLocal(text) ? "http://" : "https://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: searchAllowed) ?? text
        return URL(string: searchBase + query)
    }

    private static let searchAllowed: CharacterSet = {
        var set = CharacterSet.urlQueryAllowed
        set.remove(charactersIn: "&+=?#")
        return set
    }()

    /// "localhost:5173/checkout", "acme.dev", "127.0.0.1:8080", "app.test/x".
    public static func looksLikeHost(_ text: String) -> Bool {
        let host = hostPart(text)
        guard !host.isEmpty, host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == ":" || $0 == "[" || $0 == "]" }) else {
            return false
        }
        let name = host.split(separator: ":").first.map(String.init) ?? host
        if name == "localhost" || host.hasPrefix("[") { return true }
        let labels = name.split(separator: ".", omittingEmptySubsequences: false)
        return labels.count >= 2 && labels.allSatisfy { !$0.isEmpty } && (labels.last?.contains { $0.isLetter } == true || isIPv4(name))
    }

    /// Loopback, a `.local` or `.test` name, a private IPv4 address: served over http.
    public static func isLocal(_ text: String) -> Bool {
        let host = hostPart(text)
        let name = (host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : host.split(separator: ":").first.map(String.init) ?? host).lowercased()
        if name == "localhost" || name.hasSuffix(".localhost") || name.hasSuffix(".local") || name.hasSuffix(".test") || name == "[::1]" { return true }
        guard isIPv4(name) else { return false }
        let octets = name.split(separator: ".").compactMap { Int($0) }
        return octets[0] == 127 || octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) || (octets[0] == 172 && (16...31).contains(octets[1]))
            || octets == [0, 0, 0, 0]
    }

    private static func hostPart(_ text: String) -> String {
        String(text.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    private static func isIPv4(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        return parts.count == 4 && parts.allSatisfy { Int($0).map { (0...255).contains($0) } == true }
    }

    /// What the capsule shows for `url`: the host (with its port; the scheme left out for http
    /// and https) and the rest (path, query, fragment; a lone "/" left out). Nil for no page.
    public static func display(_ url: URL?) -> (host: String, path: String)? {
        guard let url, url.absoluteString != "about:blank" else { return nil }
        guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host else {
            return (url.absoluteString, "")
        }
        let shownHost = (host.contains(":") && !host.hasPrefix("[") ? "[\(host)]" : host) + (components.port.map { ":\($0)" } ?? "")
        var rest = components.percentEncodedPath
        if rest == "/" { rest = "" }
        if let query = components.percentEncodedQuery { rest += "?" + query }
        if let fragment = components.percentEncodedFragment { rest += "#" + fragment }
        return (shownHost, rest)
    }

    /// What the field holds while it is being edited: the whole URL.
    public static func editingText(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }
}
