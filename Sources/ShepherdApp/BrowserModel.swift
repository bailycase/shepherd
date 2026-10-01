import Foundation
import CoreGraphics
import ShepherdProtocol
import ShepherdUI

// The Browser tab's rules (docs/design/side-pane-changes.md › Side pane › Browser), pure so they are tested without
// WebKit: what the address field takes and shows, the viewport widths, the dev servers a
// repository offers, and what the page's scripts report. `BrowserHost.swift` holds the web view.

// MARK: Address

enum BrowserAddress {
    /// Where a search goes.
    static let searchBase = "https://www.google.com/search?q="

    /// What the address field takes: a URL with a scheme, a host (with a port or a path), a bare
    /// port (":5173" is this Mac), or else words to search for. Local hosts go over http, the
    /// rest over https. Nil for nothing.
    static func resolve(_ input: String) -> URL? {
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
    static func looksLikeHost(_ text: String) -> Bool {
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
    static func isLocal(_ text: String) -> Bool {
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
    static func display(_ url: URL?) -> (host: String, path: String)? {
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
    static func editingText(_ url: URL?) -> String {
        guard let url, url.absoluteString != "about:blank" else { return "" }
        return url.absoluteString
    }
}

// MARK: Viewport

/// The widths the viewport menu offers (PaneStates › BrowserPane · viewport).
enum BrowserViewport: String, CaseIterable, Identifiable, Sendable {
    case fit, phone, tablet, laptop

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fit: "Fit the pane"
        case .phone: "iPhone 16"
        case .tablet: "iPad mini"
        case .laptop: "Laptop"
        }
    }

    /// The page's width in CSS pixels; nil fits the pane.
    var width: CGFloat? {
        switch self {
        case .fit: nil
        case .phone: 393
        case .tablet: 744
        case .laptop: 1280
        }
    }

    var option: NWViewportOption {
        NWViewportOption(id: rawValue, title: title, width: width.map { String(Int($0)) })
    }

    struct Layout: Equatable {
        /// The web view's width in points.
        var width: CGFloat
        /// Its page zoom: below 1 when the chosen width is wider than the pane, so the page still
        /// lays out at that width (media queries see it) and shrinks to fit.
        var zoom: CGFloat
        /// Drawn in a frame on `bgSunken`, centered.
        var framed: Bool
    }

    /// How the page sits in a pane `available` points wide (less the frame's margins when framed).
    func layout(available: CGFloat, margin: CGFloat) -> Layout {
        guard let width else { return Layout(width: max(0, available), zoom: 1, framed: false) }
        let room = max(1, available - 2 * margin)
        return width <= room ? Layout(width: width, zoom: 1, framed: true) : Layout(width: room, zoom: room / width, framed: true)
    }
}

// MARK: Dev servers

/// The dev servers a folder offers live in ShepherdProtocol (`DevServerDiscovery`), where a host's
/// server reads them too; this is how Nothing open draws one.
extension DevServer {
    /// "Start on This Mac", or "Start on build-01" for a remote thread's host.
    func item(startTitle: String) -> NWDevServerItem {
        NWDevServerItem(id: id, command: command, detail: detail, startTitle: startTitle)
    }
}

// MARK: What the page reports

/// A message from the page's scripts (`BrowserScripts`), parsed.
enum BrowserScriptMessage: Equatable {
    /// A console line, or an error the page threw.
    case console(level: NWConsoleLevel, text: String)
    /// Resources the page loaded so far, its document included.
    case network(count: Int)
    /// Select an element picked `element`, at `rect` (CSS pixels in the page's viewport).
    case pick(BrowserElement, rect: CGRect)
    /// The picked element moved (the page scrolled or resized).
    case moved(rect: CGRect)
    /// Esc in the page stopped selecting.
    case cancel
    /// The user's own click or key reached the page while the agent was using it.
    case userInput

    /// Nil for anything malformed; `page` is the page's URL for a pick.
    init?(console body: Any) {
        guard let body = body as? [String: Any], let text = body["text"] as? String else { return nil }
        let level: NWConsoleLevel = switch body["level"] as? String {
        case "warning": .warning
        case "error": .error
        default: .log
        }
        self = .console(level: level, text: String(text.prefix(BrowserConsoleLog.maxTextLength)))
    }

    init?(picker body: Any, page: String) {
        guard let body = body as? [String: Any], let kind = body["kind"] as? String else { return nil }
        switch kind {
        case "network":
            guard let count = (body["count"] as? NSNumber)?.intValue, count >= 0 else { return nil }
            self = .network(count: count)
        case "cancel":
            self = .cancel
        case "userInput":
            self = .userInput
        case "rect":
            guard let rect = Self.rect(body["rect"]) else { return nil }
            self = .moved(rect: rect)
        case "pick":
            guard let selector = body["selector"] as? String, !selector.isEmpty, let label = body["label"] as? String,
                  let rect = Self.rect(body["rect"]) else { return nil }
            let source = (body["source"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            let element = BrowserElement(page: page, selector: selector, label: label, source: source,
                                         width: Int(rect.width.rounded()), height: Int(rect.height.rounded()),
                                         html: body["html"] as? String).clamped
            self = .pick(element, rect: rect)
        default:
            return nil
        }
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let value = value as? [String: Any], let x = (value["x"] as? NSNumber)?.doubleValue, let y = (value["y"] as? NSNumber)?.doubleValue,
              let width = (value["width"] as? NSNumber)?.doubleValue, let height = (value["height"] as? NSNumber)?.doubleValue,
              width.isFinite, height.isFinite, x.isFinite, y.isFinite else { return nil }
        return CGRect(x: x, y: y, width: max(0, width), height: max(0, height))
    }
}

// MARK: Console

/// A page's console (the drawer): its lines, newest last, capped, and its counts. Observed on its
/// own, so a line arriving redraws the drawer and nothing else.
@MainActor @Observable
final class BrowserConsoleLog {
    nonisolated static let maxLines = 500
    nonisolated static let maxTextLength = 2000

    private(set) var lines: [NWConsoleLine] = []
    private(set) var warnings = 0
    private(set) var network = 0
    @ObservationIgnored private var nextID = 0

    /// What the agent reads (`browser_console`): the same lines with their true level, the drawer's
    /// errors and warnings not merged, and every error ever counted, across new documents.
    struct Entry: Equatable {
        var time: String
        var level: NWConsoleLevel
        var text: String
    }
    @ObservationIgnored private(set) var entries: [Entry] = []
    @ObservationIgnored private(set) var errorTotal = 0

    /// The page's own errors show as warning rows too: no board draws a separate error count or
    /// red rows (the user's decision, 2026-09-29).
    func append(_ level: NWConsoleLevel, _ text: String, at date: Date = Date()) {
        nextID += 1
        let shown: NWConsoleLevel = level == .error ? .warning : level
        lines.append(NWConsoleLine(id: nextID, time: Self.time(date), text: text, level: shown))
        if lines.count > Self.maxLines { lines.removeFirst(lines.count - Self.maxLines) }
        if shown == .warning { warnings += 1 }
        entries.append(Entry(time: Self.time(date), level: level, text: text))
        if entries.count > Self.maxLines { entries.removeFirst(entries.count - Self.maxLines) }
        if level == .error { errorTotal += 1 }
    }

    func setNetwork(_ count: Int) {
        if network != count { network = count }
    }

    /// A new page: the console starts over.
    func clear() {
        if !lines.isEmpty { lines = [] }
        if warnings != 0 { warnings = 0 }
        if network != 0 { network = 0 }
        entries.removeAll()
    }

    /// "14:02:11", on a 24-hour clock whatever the locale.
    nonisolated static func time(_ date: Date) -> String {
        let parts = Calendar.current.dateComponents([.hour, .minute, .second], from: date)
        return String(format: "%02d:%02d:%02d", parts.hour ?? 0, parts.minute ?? 0, parts.second ?? 0)
    }
}

// MARK: Picked element's popover

enum BrowserPopoverPlacement {
    /// Where a picked element's popover goes in the page area (points): beside the element's
    /// right edge, else its left, else under it, kept inside the area. `rect` is in CSS pixels,
    /// `origin` and `zoom` place the page in the area.
    static func origin(for rect: CGRect, pageOrigin: CGPoint, zoom: CGFloat, popover: CGSize, area: CGSize, gap: CGFloat) -> CGPoint {
        let element = CGRect(x: pageOrigin.x + rect.minX * zoom, y: pageOrigin.y + rect.minY * zoom,
                             width: rect.width * zoom, height: rect.height * zoom)
        var x = element.maxX + gap
        var y = element.minY
        if x + popover.width > area.width {
            x = element.minX - gap - popover.width
            if x < 0 {
                x = element.minX
                y = element.maxY + gap
            }
        }
        x = min(max(gap, x), max(gap, area.width - popover.width - gap))
        y = min(max(gap, y), max(gap, area.height - popover.height - gap))
        return CGPoint(x: x, y: y)
    }
}
