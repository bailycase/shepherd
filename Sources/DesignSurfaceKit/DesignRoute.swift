import Foundation

/// What a `shepherd-design://<design>/…` request asks for. Only these three things are served;
/// anything else is refused before a file is touched.
enum DesignRoute: Equatable, Sendable {
    /// `project/…/support.js`: Shepherd's board runtime, whatever the design folder holds.
    case runtime
    /// A file under the design's `project/`, by its path segments.
    case project([String])
    /// `/_blob/<id>`: an upload in the design's `assets/`.
    case blob(String)
    case refused

    static let scheme = "shepherd-design"

    init(url: URL?, host: String) {
        guard let url, url.scheme?.lowercased() == Self.scheme,
              let urlHost = url.host(percentEncoded: false), urlHost.caseInsensitiveCompare(host) == .orderedSame,
              url.port == nil, url.user == nil, url.password == nil else {
            self = .refused
            return
        }
        let path = url.path(percentEncoded: false)
        guard path.hasPrefix("/") else {
            self = .refused
            return
        }
        let segments = path.dropFirst().split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        switch segments.first {
        case "project":
            let rest = Array(segments.dropFirst())
            guard !rest.isEmpty, rest.allSatisfy(Self.isSegment) else { self = .refused; return }
            self = rest.last == "support.js" ? .runtime : .project(rest)
        case "_blob":
            guard segments.count == 2, Self.isBlobID(segments[1]) else { self = .refused; return }
            self = .blob(segments[1])
        default:
            self = .refused
        }
    }

    /// A project path segment, by the canvas's file grammar: `[A-Za-z0-9_][A-Za-z0-9_.-]*`, and
    /// never `..`.
    static func isSegment(_ segment: String) -> Bool {
        guard let first = segment.utf8.first, isWordByte(first), !segment.contains("..") else { return false }
        return segment.utf8.allSatisfy { isWordByte($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    /// An upload's id: `[A-Za-z0-9_-]`, up to 128.
    static func isBlobID(_ id: String) -> Bool {
        (1...128).contains(id.utf8.count) && id.utf8.allSatisfy { isWordByte($0) || $0 == UInt8(ascii: "-") }
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == UInt8(ascii: "_")
    }
}

/// The rules every board runs under (docs/designs.md › Security): what it may load, from where.
public enum DesignSandbox {
    /// Where a board may reach beyond its own design.
    public enum Network: Sendable, Hashable {
        /// Google Fonts' stylesheets and font files, which boards link in their helmet.
        case googleFonts
        /// Nothing: a board renders from its design alone.
        case none
    }

    /// The Content-Security-Policy header on every response. Scripts come only from the design
    /// (the runtime compiles a board's logic, hence `'unsafe-eval'`; inline scripts never run),
    /// styles also inline, and nothing may frame, submit, or connect elsewhere.
    public static func contentSecurityPolicy(network: Network) -> String {
        let fonts = network == .googleFonts
        return [
            "default-src 'none'",
            "script-src 'self' 'unsafe-eval'",
            "style-src 'self' 'unsafe-inline'" + (fonts ? " https://fonts.googleapis.com" : ""),
            "font-src 'self'" + (fonts ? " https://fonts.gstatic.com" : ""),
            "img-src 'self'",
            "media-src 'self'",
            "connect-src 'self'",
            "frame-src 'none'",
            "child-src 'none'",
            "worker-src 'none'",
            "object-src 'none'",
            "manifest-src 'none'",
            "base-uri 'none'",
            "form-action 'none'",
        ].joined(separator: "; ")
    }

    /// The content rules WebKit enforces below the page: block every load, then allow the
    /// design's scheme and (when allowed) Google Fonts.
    public static func contentRules(network: Network) -> String {
        var rules: [[String: Any]] = [
            ["trigger": ["url-filter": ".*"], "action": ["type": "block"]],
            ["trigger": ["url-filter": "^shepherd-design://"], "action": ["type": "ignore-previous-rules"]],
        ]
        if network == .googleFonts {
            rules.append(["trigger": ["url-filter": "^https://fonts\\.googleapis\\.com/css2\\?"], "action": ["type": "ignore-previous-rules"]])
            rules.append(["trigger": ["url-filter": "^https://fonts\\.gstatic\\.com/"], "action": ["type": "ignore-previous-rules"]])
        }
        let data = try! JSONSerialization.data(withJSONObject: rules, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The media type a served file goes out as, by its extension. Unknown types are
    /// `application/octet-stream`, which a board can't navigate to or download.
    static func contentType(forExtension ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "text/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json"
        case "txt": return "text/plain; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "avif": return "image/avif"
        case "woff2": return "font/woff2"
        case "woff": return "font/woff"
        case "ttf": return "font/ttf"
        case "otf": return "font/otf"
        case "mp4": return "video/mp4"
        case "webm": return "video/webm"
        default: return "application/octet-stream"
        }
    }
}
