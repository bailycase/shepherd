import Foundation

/// What Export writes a design's boards as (DZExport's format cards).
public enum DesignExportFormat: String, CaseIterable, Hashable, Sendable {
    case html, zip, pdf, png

    public var title: String { rawValue.uppercased() }

    /// The card's line under the format.
    public var line: String {
        switch self {
        case .html: return "One standalone file per board. Opens anywhere."
        case .zip: return "HTML, tokens.css and assets."
        case .pdf: return "One page per board."
        case .png: return "@2x, one image per board."
        }
    }
}

/// The Export sheet's boards: every board the canvas lists, in canvas order, with the ticked
/// ones. It opens ticked from the canvas's selection, or every board when nothing is selected.
public struct DesignExportSelection: Hashable, Sendable {
    public struct Row: Hashable, Sendable, Identifiable {
        public let path: DesignPath
        /// The board's title, else its file's stem.
        public let title: String
        public let width: Double
        public let height: Double

        public var id: String { path.rawValue }

        /// "1280 × 800", as the row's trailing size reads.
        public var size: String { "\(Self.number(width)) × \(Self.number(height))" }

        static func number(_ value: Double) -> String {
            value.rounded() == value ? String(Int(value)) : String(format: "%g", value)
        }
    }

    public let rows: [Row]
    public private(set) var ticked: Set<DesignPath>

    public init(index: DesignIndex, selected: some Sequence<DesignPath>) {
        let synced = index.inSync()
        rows = synced.order.compactMap { path in
            guard let board = synced.boards[path] else { return nil }
            let title = board.title?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Row(path: path, title: title?.isEmpty == false ? title! : path.stem, width: board.w, height: board.h)
        }
        let listed = Set(rows.map(\.path))
        let picked = Set(selected).intersection(listed)
        ticked = picked.isEmpty ? listed : picked
    }

    /// The ticked boards in canvas order: what an export writes, in the order it writes them.
    public var boards: [DesignPath] { rows.map(\.path).filter(ticked.contains) }

    public var count: Int { boards.count }

    /// The primary button's title, whose count follows the ticks.
    public var exportTitle: String { "Export \(count) board\(count == 1 ? "" : "s")" }

    public func isTicked(_ path: DesignPath) -> Bool { ticked.contains(path) }

    public mutating func setTicked(_ path: DesignPath, _ on: Bool) {
        guard rows.contains(where: { $0.path == path }) else { return }
        if on { ticked.insert(path) } else { ticked.remove(path) }
    }

    public mutating func toggle(_ path: DesignPath) {
        setTicked(path, !ticked.contains(path))
    }
}

/// Where each export lands, by name.
public enum DesignExportNames {
    /// A board's standalone page: `flows/Cart.dc.html` → `flows/Cart.html`.
    public static func html(_ path: DesignPath) -> String {
        String(path.rawValue.dropLast(DesignPath.fileExtension.count)) + ".html"
    }

    /// A board's image: `flows/Cart.dc.html` → `flows/Cart@2x.png`.
    public static func png(_ path: DesignPath) -> String {
        String(path.rawValue.dropLast(DesignPath.fileExtension.count)) + "@2x.png"
    }

    /// A design's name as a file name: no `/` or `:`, no leading dot, never empty.
    public static func fileName(_ name: String) -> String {
        var text = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasPrefix(".") { text.removeFirst() }
        text = String(text.prefix(120)).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? "Design" : text
    }

    /// What the save panel suggests, and whether it names a folder: one file for a ZIP or a PDF
    /// (named for the design) and for a single board's page or image; a folder holding one per
    /// board otherwise.
    public static func destination(_ format: DesignExportFormat, boards: [DesignPath], design: String) -> (name: String, isFolder: Bool) {
        switch format {
        case .zip: return (fileName(design) + ".zip", false)
        case .pdf: return (fileName(design) + ".pdf", false)
        case .html, .png:
            guard boards.count == 1, let board = boards.first else { return (fileName(design), true) }
            let name = format == .html ? html(board) : png(board)
            return (name.split(separator: "/").last.map(String.init) ?? name, false)
        }
    }

    /// From the page at `from` (a path in the export's folder), the relative way to `to`.
    public static func relative(_ to: String, from: String) -> String {
        let depth = from.split(separator: "/").count - 1
        return String(repeating: "../", count: max(0, depth)) + to
    }
}

/// What a ZIP carries of the canvas itself, so it opens on claude.ai as a project folder:
/// `project/canvas.json` narrowed to the exported boards, their files, and every board they
/// import (format.md: every `.dc.html` under `project/` shows).
public enum DesignBundle {
    /// The boards `source` (the board at `path`) imports: each `<dc-import name="Card">` names
    /// the sibling `Card.dc.html`.
    public static func imports(in source: String, of path: DesignPath) -> [DesignPath] {
        let text = source as NSString
        let folder = path.rawValue.split(separator: "/").dropLast().joined(separator: "/")
        var found: [DesignPath] = []
        for match in importPattern.matches(in: source, range: NSRange(location: 0, length: text.length)) {
            let name = text.substring(with: match.range(at: 2))
            let raw = (folder.isEmpty ? "" : folder + "/") + name + DesignPath.fileExtension
            if let imported = DesignPath(raw), imported != path, !found.contains(imported) { found.append(imported) }
        }
        return found
    }

    /// `boards` and everything they import, however deep, in the order first reached.
    public static func members(_ boards: [DesignPath], source: (DesignPath) -> String?) -> [DesignPath] {
        var members: [DesignPath] = []
        var queue = boards
        while !queue.isEmpty {
            let path = queue.removeFirst()
            guard !members.contains(path) else { continue }
            members.append(path)
            if let text = source(path) { queue += imports(in: text, of: path).filter { !members.contains($0) } }
        }
        return members
    }

    /// The canvas narrowed to `keeping`: the other boards leave `boards` and `order`, a launch
    /// naming one goes back to the canvas, and every other key stays as it was.
    public static func index(_ index: DesignIndex, keeping: Set<DesignPath>) -> DesignIndex {
        var copy = index
        copy.boards = index.boards.filter { keeping.contains($0.key) }
        copy.order = index.order.filter { keeping.contains($0) }
        if let file = copy.launch?.file, let path = DesignPath(file), !keeping.contains(path) {
            copy.launch?.file = nil
            copy.launch?.view = "canvas"
        }
        return copy.inSync()
    }

    /// A standalone page's links to other boards (`href="Cart.dc.html"`, relative to `page`, or
    /// from the canvas root with a leading `/`) pointed at their exported pages when the export
    /// holds them; every other link as it was.
    public static func rewritingBoardLinks(_ html: String, page: DesignPath, exported: Set<DesignPath>) -> String {
        let ns = html as NSString
        let folder = page.rawValue.split(separator: "/").dropLast().map(String.init)
        let from = DesignExportNames.html(page)
        var out = ""
        var last = 0
        for match in linkPattern.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: match.range(at: 2))
            var parts = target.hasPrefix("/") ? [] : folder
            var valid = true
            for segment in target.split(separator: "/", omittingEmptySubsequences: true).map(String.init) where segment != "." {
                if segment == ".." {
                    if parts.isEmpty { valid = false; break }
                    parts.removeLast()
                } else {
                    parts.append(segment)
                }
            }
            guard valid, let path = DesignPath(parts.joined(separator: "/")), exported.contains(path) else { continue }
            let rewritten = DesignExportNames.relative(DesignExportNames.html(path), from: from)
            out += ns.substring(with: NSRange(location: last, length: match.range(at: 2).location - last)) + rewritten
            last = match.range(at: 2).location + match.range(at: 2).length
        }
        return out + ns.substring(from: last)
    }

    /// Every upload `text` names by its `/_blob/<id>` url, once each, in order.
    public static func blobIDs(in text: String) -> [String] {
        let ns = text as NSString
        var ids: [String] = []
        for match in blobPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let id = ns.substring(with: match.range(at: 1))
            if !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// `text` with each `/_blob/<id>` url `replacement` answers for swapped in; the rest as it was.
    public static func rewritingBlobs(_ text: String, _ replacement: (String) -> String?) -> String {
        let ns = text as NSString
        var out = ""
        var last = 0
        for match in blobPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            guard let swapped = replacement(ns.substring(with: match.range(at: 1))) else { continue }
            out += ns.substring(with: NSRange(location: last, length: match.range.location - last)) + swapped
            last = match.range.location + match.range.length
        }
        return out + ns.substring(from: last)
    }

    /// An upload inlined into a standalone page.
    public static func dataURI(_ data: Data, type: String) -> String {
        "data:\(type);base64,\(data.base64EncodedString())"
    }

    /// An upload's file name in `assets/` for its id: `<id>` or `<id>.<ext>`.
    public static func isAssetName(_ name: String) -> Bool {
        let parts = name.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let id = parts.first, (1...128).contains(id.utf8.count),
              id.utf8.allSatisfy({ isWordByte($0) || $0 == UInt8(ascii: "-") }) else { return false }
        guard parts.count == 2 else { return true }
        let ext = parts[1]
        return (1...10).contains(ext.utf8.count) && ext.utf8.allSatisfy { isWordByte($0) && $0 != UInt8(ascii: "_") }
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == UInt8(ascii: "_")
    }

    private static let importPattern = try! NSRegularExpression(
        pattern: "<dc-import\\b[^>]*?\\sname\\s*=\\s*([\"'])([A-Za-z0-9_][A-Za-z0-9_.-]*)\\1", options: [.caseInsensitive])
    private static let linkPattern = try! NSRegularExpression(
        pattern: "(\\shref\\s*=\\s*\")([^\"#?]+\\.dc\\.html)(?=[\"#?])", options: [.caseInsensitive])
    private static let blobPattern = try! NSRegularExpression(pattern: "/_blob/([A-Za-z0-9_-]{1,128})")
}

/// A design's tokens as an export carries them: `tokens.css` (a `:root` block of custom
/// properties), and the note attached boards arrive with (the tokens they use).
public enum DesignExportTokens {
    /// The custom properties the boards reference with `var(--name)` that `tokens` declares,
    /// in `tokens`' order.
    public static func used(_ tokens: DesignTokens, in sources: [String]) -> DesignTokens {
        var names = Set<String>()
        for source in sources {
            let ns = source as NSString
            for match in variablePattern.matches(in: source, range: NSRange(location: 0, length: ns.length)) {
                names.insert(ns.substring(with: match.range(at: 1)))
            }
        }
        return DesignTokens(colors: tokens.colors.filter { names.contains($0.name) },
                            lengths: tokens.lengths.filter { names.contains($0.name) })
    }

    /// `tokens.css`: a comment naming where they come from, then every token in a `:root` block.
    public static func css(_ tokens: DesignTokens, heading: String) -> String {
        var lines = ["/* \(heading.replacingOccurrences(of: "*/", with: "* /")) */", ":root {"]
        for color in tokens.colors { lines.append("  \(color.name): \(color.hex);") }
        for length in tokens.lengths { lines.append("  \(length.name): \(DesignExportSelection.Row.number(length.px))px;") }
        lines.append("}")
        return lines.joined(separator: "\n") + "\n"
    }

    private static let variablePattern = try! NSRegularExpression(pattern: "var\\(\\s*(--[A-Za-z0-9_-]+)")
}

/// What an export of some boards reads from its design (`DesignStore.exportFiles`).
public struct DesignExportFiles: Sendable {
    public struct Asset: Hashable, Sendable {
        /// Its file name in `assets/`: `<id>.<ext>`.
        public var name: String
        public var data: Data

        public init(name: String, data: Data) {
            self.name = name
            self.data = data
        }

        /// The media type a page or an inlined url gives it, by its extension.
        public var type: String {
            switch (name.split(separator: ".").last.map(String.init) ?? "").lowercased() {
            case "png": return "image/png"
            case "jpg", "jpeg": return "image/jpeg"
            case "gif": return "image/gif"
            case "webp": return "image/webp"
            case "avif": return "image/avif"
            case "svg": return "image/svg+xml"
            case "woff2": return "font/woff2"
            case "woff": return "font/woff"
            case "ttf": return "font/ttf"
            case "otf": return "font/otf"
            case "css": return "text/css"
            case "js": return "text/javascript"
            case "json": return "application/json"
            default: return "application/octet-stream"
            }
        }
    }

    public var index: DesignIndex
    /// The boards the export writes, in canvas order.
    public var boards: [DesignPath]
    /// Those boards and every board they import.
    public var members: [DesignPath]
    /// Each member's source.
    public var sources: [DesignPath: String]
    /// The project's other files by their path under `project/` (design systems under `ds/`,
    /// support files the boards name), canvas.json and the boards aside.
    public var support: [String: Data]
    /// The uploads the members name, by id.
    public var assets: [String: Asset]

    public init(index: DesignIndex, boards: [DesignPath], members: [DesignPath], sources: [DesignPath: String],
                support: [String: Data] = [:], assets: [String: Asset] = [:]) {
        self.index = index
        self.boards = boards
        self.members = members
        self.sources = sources
        self.support = support
        self.assets = assets
    }
}
