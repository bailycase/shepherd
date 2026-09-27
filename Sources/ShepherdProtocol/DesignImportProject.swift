import Foundation
import ShepherdCore

// Importing a Claude Design project (File ▸ Import Claude Design Project…, New design's Import a
// project, a drop on Designs): a ZIP or a folder exported from Claude Design becomes a new
// design. Everything is checked before a design exists (canvas.json, sizes, paths, links), and
// only a complete design moves into Designs. docs/designs.md › Import.

extension DesignImport {
    /// A project is at most this many bytes, unpacked (ImportFailed: "up to 1 GB").
    public static let maxProjectBytes: Int64 = 1_000_000_000
}

/// A board, or a file of the project, that points outside it (ImportFailed › links outside):
/// where it is, and what it points to.
public struct DesignImportLink: Hashable, Sendable {
    public var board: String
    public var target: String

    public init(board: String, target: String) {
        self.board = board
        self.target = target
    }
}

/// A board canvas.json lists that can't be read (ImportFailed › unreadable board).
public struct DesignImportUnreadable: Hashable, Sendable {
    public var path: String
    /// Its title on the canvas, else its path.
    public var title: String
    /// "is empty", "is missing", "isn't text".
    public var reason: String

    public init(path: String, title: String, reason: String) {
        self.path = path
        self.title = title
        self.reason = reason
    }
}

/// Why a project didn't become a design. Nothing is ever half imported: every failure leaves
/// nothing behind. The words are ImportFailed's.
public enum DesignImportFailure: Error, Hashable, Sendable, CustomStringConvertible {
    /// No canvas.json at the top of the ZIP or folder.
    case notAProject
    /// The project unpacked is over `DesignImport.maxProjectBytes`: checked before a ZIP is
    /// unpacked.
    case tooLarge(bytes: Int64, limit: Int64)
    /// One file is over `DesignImport.maxFileBytes`.
    case fileTooLarge(path: String, bytes: Int64, limit: Int64)
    /// Boards (or files) that point outside the project: Shepherd never follows one.
    case linksOutside([DesignImportLink])
    /// Boards canvas.json lists that can't be read, and how many can: the one failure with a
    /// choice (import the rest on purpose).
    case unreadableBoards([DesignImportUnreadable], readable: Int)
    /// Anything else, in words: a name a design can't hold, too many files, a canvas this build
    /// can't read, a file that couldn't be read.
    case refused(String)

    /// "Couldn’t import “checkout-funnel.zip”".
    public static func title(file: String) -> String { "Couldn’t import “\(file)”" }

    /// What went wrong and what to do.
    public var message: String {
        switch self {
        case .notAProject:
            return "There’s no canvas.json inside, so it isn’t a Claude Design project. Export the project from Claude Design as a ZIP or folder, then try again."
        case .tooLarge(let bytes, let limit):
            return "It’s \(Self.size(bytes)). Shepherd imports projects up to \(Self.size(limit)). Remove large videos or images from the project in Claude Design, export it again, and try that."
        case .fileTooLarge(let path, let bytes, let limit):
            return "\(path) is \(Self.size(bytes)). Shepherd imports files up to \(Self.size(limit)). Remove large videos or images from the project in Claude Design, export it again, and try that."
        case .linksOutside(let links):
            let boards = links.allSatisfy { $0.board.hasSuffix(".html") }
            let noun = links.count == 1 ? (boards ? "1 board points" : "1 file points")
                : "\(links.count) \(boards ? "boards" : "files") point"
            return "\(noun) to files outside the project folder. Shepherd only reads what’s inside the project, so it stopped."
        case .unreadableBoards(let boards, let readable):
            let rest = readable == 1 ? "The other board is fine." : "The other \(readable) boards are fine."
            if boards.count == 1, let board = boards.first {
                return "The board \(board.title) couldn’t be read: \(board.path) \(board.reason). \(rest)"
            }
            return "\(boards.count) boards couldn’t be read: \(boards.prefix(3).map { "\($0.path) \($0.reason)" }.joined(separator: "; ")). \(rest)"
        case .refused(let why):
            return why
        }
    }

    /// The links a dialog lists: up to three.
    public var listedLinks: [DesignImportLink] {
        if case .linksOutside(let links) = self { return Array(links.prefix(3)) }
        return []
    }

    /// The line under the message: "Nothing was imported.", or, while the choice is open,
    /// "Nothing’s imported until you choose."
    public var footer: String {
        if case .unreadableBoards = self { return "Nothing’s imported until you choose." }
        return "Nothing was imported."
    }

    /// Whether the dialog offers another file (only when it wasn't a project at all).
    public var offersAnother: Bool { self == .notAProject }

    public var description: String { message }

    /// Sizes as the boards write them: "2.3 GB", "14.2 MB", "900 KB", in decimal units.
    public static func size(_ bytes: Int64) -> String {
        func one(_ value: Double) -> String {
            let rounded = (value * 10).rounded() / 10
            return rounded == rounded.rounded() ? String(Int(rounded)) : String(format: "%.1f", rounded)
        }
        // Shepherd's own caps are whole mebibytes (16 MB a file): they read as written.
        if bytes > 0, bytes < 1_000_000_000, bytes % 1_048_576 == 0 { return "\(bytes / 1_048_576) MB" }
        let value = Double(bytes)
        if value >= 1_000_000_000 { return "\(one(value / 1_000_000_000)) GB" }
        if value >= 1_000_000 { return "\(one(value / 1_000_000)) MB" }
        if value >= 1_000 { return "\(one(value / 1_000)) KB" }
        return "\(bytes) bytes"
    }
}

extension DesignImport.Problem {
    /// The failure the import dialog shows for a folder's problem.
    public var failure: DesignImportFailure {
        switch self {
        case .noCanvas: return .notAProject
        case .link(let path): return .linksOutside([DesignImportLink(board: path, target: "a link")])
        case .tooLarge(let path): return .fileTooLarge(path: path, bytes: Int64(DesignImport.maxFileBytes) + 1,
                                                      limit: Int64(DesignImport.maxFileBytes))
        case .tooMuch: return .tooLarge(bytes: DesignImport.maxProjectBytes + 1, limit: DesignImport.maxProjectBytes)
        case .notAFile, .badName, .tooDeep, .tooManyFiles: return .refused(description)
        }
    }
}

// MARK: - Links in a board

extension DesignImport {
    /// Where a board's markup points outside the project (ImportFailed › links outside): every
    /// `src`, `href`, `poster` and `srcset` value and CSS `url()` that climbs out of the project
    /// from the board's folder, is a `file:` URL, or names a place on a disk ("/Users/…",
    /// "~/…"). Web URLs, data, fragments and in-project paths are fine. `board` is the board's
    /// path in the project.
    public static func outsideReferences(in source: String, board: String) -> [String] {
        var found: [String] = []
        let depth = board.split(separator: "/").count - 1
        for value in referenceValues(source) {
            for candidate in value.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) {
                let target = candidate.split(separator: " ").first.map(String.init) ?? candidate
                if isOutside(target, depth: depth), !found.contains(target) { found.append(target) }
            }
        }
        return found
    }

    static func isOutside(_ raw: String, depth: Int) -> Bool {
        let target = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !target.hasPrefix("#"), !target.hasPrefix("//") else { return false }
        let lower = target.lowercased()
        if lower.hasPrefix("file:") { return true }
        if let colon = target.firstIndex(of: ":"), target[..<colon].allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }),
           target.distance(from: target.startIndex, to: colon) > 1 {
            return false
        }
        if target.hasPrefix("~/") || target.contains("\\") { return true }
        let path = target.split(separator: "?").first.map(String.init) ?? target
        if path.hasPrefix("/") {
            return diskRoots.contains { path.hasPrefix($0) }
        }
        var level = depth
        for segment in path.split(separator: "/", omittingEmptySubsequences: true) {
            if segment == ".." {
                level -= 1
                if level < 0 { return true }
            } else if segment != "." {
                level += 1
            }
        }
        return false
    }

    /// Absolute paths that name a place on a disk rather than the canvas root.
    static let diskRoots = ["/Users/", "/Volumes/", "/private/", "/tmp/", "/var/", "/home/", "/System/", "/Library/",
                            "/Applications/", "/opt/", "/etc/"]

    private static let attribute = try! NSRegularExpression(
        pattern: #"(?i)\b(?:src|href|poster|srcset|xlink:href)\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let cssURL = try! NSRegularExpression(pattern: #"(?i)url\(\s*(?:"([^"]*)"|'([^']*)'|([^)'"\s]+))\s*\)"#)

    private static func referenceValues(_ source: String) -> [String] {
        let range = NSRange(source.startIndex..., in: source)
        var values: [String] = []
        for pattern in [attribute, cssURL] {
            for match in pattern.matches(in: source, range: range) {
                for group in 1..<match.numberOfRanges {
                    if let found = Range(match.range(at: group), in: source) { values.append(String(source[found])) }
                }
            }
        }
        return values
    }
}

// MARK: - ZIP

/// The table of contents of a ZIP (its central directory), read without unpacking anything, so
/// a project's sizes, names and links are checked before a byte of it lands on disk.
public enum DesignArchive {
    public struct Entry: Hashable, Sendable {
        /// As the archive names it, `/`-separated.
        public var path: String
        public var size: Int64
        public var kind: DesignImport.Kind

        public init(_ path: String, size: Int64 = 0, kind: DesignImport.Kind = .file) {
            self.path = path
            self.size = size
            self.kind = kind
        }
    }

    /// The last bytes of a file hold the end record; read at least this many (or the whole file).
    public static let tailBytes = 128 * 1024
    /// A central directory bigger than this is refused rather than read.
    public static let maxDirectoryBytes = 32 * 1024 * 1024

    public enum ReadError: Error, Hashable, Sendable {
        case notAZip
        case unsupported(String)
    }

    /// Where the central directory is, from the file's last bytes (`tail`) and its size.
    public static func directory(tail: Data, fileSize: Int64) throws(ReadError) -> (offset: Int64, size: Int64, count: Int) {
        let bytes = [UInt8](tail)
        let tailStart = fileSize - Int64(bytes.count)
        guard bytes.count >= 22 else { throw .notAZip }
        var end = -1
        var at = bytes.count - 22
        while at >= 0 {
            if read32(bytes, at) == 0x0605_4b50 { end = at; break }
            at -= 1
        }
        guard end >= 0 else { throw .notAZip }
        var count = Int64(read16(bytes, end + 10))
        var size = Int64(read32(bytes, end + 12))
        var offset = Int64(read32(bytes, end + 16))
        if count == 0xFFFF || size == 0xFFFF_FFFF || offset == 0xFFFF_FFFF {
            let locator = end - 20
            guard locator >= 0, read32(bytes, locator) == 0x0706_4b50 else { throw .unsupported("a ZIP64 archive without its locator") }
            let record = Int64(bitPattern: read64(bytes, locator + 8)) - tailStart
            guard record >= 0, record + 56 <= Int64(bytes.count), read32(bytes, Int(record)) == 0x0606_4b50 else {
                throw .unsupported("a ZIP64 archive whose end record isn't at its end")
            }
            count = Int64(bitPattern: read64(bytes, Int(record) + 32))
            size = Int64(bitPattern: read64(bytes, Int(record) + 40))
            offset = Int64(bitPattern: read64(bytes, Int(record) + 48))
        }
        guard count >= 0, size >= 0, offset >= 0, offset + size <= fileSize else { throw .notAZip }
        guard size <= maxDirectoryBytes else { throw .unsupported("a table of contents over \(maxDirectoryBytes) bytes") }
        return (offset, size, Int(count))
    }

    /// Every entry of a central directory.
    public static func entries(_ directory: Data, count: Int) throws(ReadError) -> [Entry] {
        let bytes = [UInt8](directory)
        var entries: [Entry] = []
        var at = 0
        while at + 46 <= bytes.count, read32(bytes, at) == 0x0201_4b50 {
            let madeBy = read16(bytes, at + 4) >> 8
            var compressed = Int64(read32(bytes, at + 20))
            var size = Int64(read32(bytes, at + 24))
            let nameLength = Int(read16(bytes, at + 28))
            let extraLength = Int(read16(bytes, at + 30))
            let commentLength = Int(read16(bytes, at + 32))
            let external = read32(bytes, at + 38)
            let nameStart = at + 46
            guard nameStart + nameLength + extraLength + commentLength <= bytes.count else { throw .notAZip }
            let name = String(decoding: bytes[nameStart..<nameStart + nameLength], as: UTF8.self)
            // ZIP64 sizes live in the extra field, in order, for the fields that overflowed.
            var extra = nameStart + nameLength
            let extraEnd = extra + extraLength
            while extra + 4 <= extraEnd {
                let id = read16(bytes, extra)
                let length = Int(read16(bytes, extra + 2))
                if id == 0x0001 {
                    var field = extra + 4
                    if size == 0xFFFF_FFFF, field + 8 <= extra + 4 + length { size = Int64(bitPattern: read64(bytes, field)); field += 8 }
                    if compressed == 0xFFFF_FFFF, field + 8 <= extra + 4 + length { compressed = Int64(bitPattern: read64(bytes, field)) }
                }
                extra += 4 + length
            }
            let mode = (external >> 16) & 0o170000
            let kind: DesignImport.Kind
            if madeBy == 3, mode == 0o120000 {
                kind = .symlink
            } else if name.hasSuffix("/") || (madeBy == 3 && mode == 0o040000) {
                kind = .directory
            } else if madeBy == 3, mode != 0, mode != 0o100000 {
                kind = .other
            } else {
                kind = .file
            }
            _ = compressed
            entries.append(Entry(name, size: size, kind: kind))
            at = extraEnd + commentLength
        }
        guard entries.count == count || count == 0xFFFF else { throw .notAZip }
        return entries
    }

    /// The import's rules for an archive, before anything is unpacked: every name inside the
    /// project (no absolute path, no `..`, no backslash), no links or devices, no file over
    /// `DesignImport.maxFileBytes`, and the whole under `DesignImport.maxProjectBytes`.
    public static func check(_ entries: [Entry]) throws(DesignImportFailure) {
        var outside: [DesignImportLink] = []
        var total: Int64 = 0
        for entry in entries {
            let path = entry.path
            let segments = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let escapes = path.hasPrefix("/") || path.contains("\\") || path.contains("\0") || segments.contains("..")
                || (segments.first?.contains(":") ?? false)
            if escapes {
                outside.append(DesignImportLink(board: path, target: "outside the project"))
                continue
            }
            switch entry.kind {
            case .symlink: outside.append(DesignImportLink(board: path.hasSuffix("/") ? String(path.dropLast()) : path, target: "a link"))
            case .other: throw .refused("\(path) is neither a file nor a folder.")
            case .directory: break
            case .file:
                total += max(0, entry.size)
                let hidden = segments.contains { $0.hasPrefix(".") } || segments.first == "__MACOSX"
                if !hidden, entry.size > Int64(DesignImport.maxFileBytes) {
                    throw .fileTooLarge(path: path, bytes: entry.size, limit: Int64(DesignImport.maxFileBytes))
                }
            }
        }
        if !outside.isEmpty { throw .linksOutside(outside) }
        guard entries.count <= DesignImport.maxFiles * 8 else {
            throw .refused("It holds \(entries.count) files; a design holds at most \(DesignImport.maxFiles).")
        }
        guard total <= DesignImport.maxProjectBytes else { throw .tooLarge(bytes: total, limit: DesignImport.maxProjectBytes) }
    }

    private static func read16(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at + 2 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ at: Int) -> UInt32 {
        guard at >= 0, at + 4 <= bytes.count else { return 0 }
        return UInt32(bytes[at]) | UInt32(bytes[at + 1]) << 8 | UInt32(bytes[at + 2]) << 16 | UInt32(bytes[at + 3]) << 24
    }

    private static func read64(_ bytes: [UInt8], _ at: Int) -> UInt64 {
        UInt64(read32(bytes, at)) | UInt64(read32(bytes, at + 4)) << 32
    }
}

// MARK: - A project read and waiting

/// A project read, checked and staged, waiting for the viewer's choice (ImportAgain, or
/// ImportFailed's unreadable board): what the dialogs name. Nothing is in Designs yet.
public struct DesignImportPreview: Hashable, Sendable, Identifiable {
    public var id: UUID
    /// The ZIP's or folder's name ("checkout-funnel.zip").
    public var file: String
    /// The canvas's title, else the file's name without `.zip`.
    public var title: String
    /// The boards it brings (the readable ones).
    public var boards: Int
    public var pages: Int
    /// Its own design systems, and the namespace of one this host already has unchanged.
    public var systems: [System]
    /// Boards canvas.json lists that can't be read: importing needs the viewer's say-so.
    public var unreadable: [DesignImportUnreadable]
    public var origin: DesignImportOrigin

    public struct System: Hashable, Sendable {
        public var namespace: String
        public var title: String
        /// A system this host already has with the same files: the import uses it.
        public var existing: String?

        public init(namespace: String, title: String, existing: String? = nil) {
            self.namespace = namespace
            self.title = title
            self.existing = existing
        }
    }

    public init(id: UUID = UUID(), file: String, title: String, boards: Int, pages: Int, systems: [System] = [],
                unreadable: [DesignImportUnreadable] = [], origin: DesignImportOrigin) {
        self.id = id
        self.file = file
        self.title = title
        self.boards = boards
        self.pages = pages
        self.systems = systems
        self.unreadable = unreadable
        self.origin = origin
    }

    /// The failure a preview with unreadable boards stands for, until the viewer chooses.
    public var unreadableFailure: DesignImportFailure? {
        unreadable.isEmpty ? nil : .unreadableBoards(unreadable, readable: boards)
    }
}

/// How an import is going (ImportProgress): its checks, then its boards as they land, then the
/// design opening.
public enum DesignImportProgress: Hashable, Sendable {
    case checking(file: String)
    /// Boards copied so far, of all; the project's title and its first system's.
    case boards(done: Int, of: Int, title: String, system: String?)
    case opening(title: String)
}
