import Foundation

/// Importing a Claude Design folder from disk (decision 4): which of the folder's files a new
/// design takes, and the rules they pass. The folder is someone else's data: nothing in it may
/// lead outside it, links are refused, and sizes are capped.
///
/// The folder is either a canvas's `project/` itself (it holds `canvas.json`), or a folder
/// holding `project/` (and, from a Shepherd export, `assets/` beside it). Everything else in it
/// (an export's pages, `tokens.css`) is left behind.
public enum DesignImport {
    public enum Kind: Hashable, Sendable {
        case file, directory, symlink, other
    }

    /// One thing in the folder, as a walk that never follows links saw it.
    public struct Entry: Hashable, Sendable {
        /// Relative to the chosen folder, `/`-separated.
        public var path: String
        public var kind: Kind
        public var size: Int

        public init(_ path: String, _ kind: Kind = .file, size: Int = 0) {
            self.path = path
            self.kind = kind
            self.size = size
        }
    }

    /// What the new design takes: each file by its place in the chosen folder and in the design's.
    public struct Plan: Hashable, Sendable {
        /// Source path (relative to the chosen folder) → destination (relative to the design's
        /// folder: `project/…` or `assets/…`).
        public var files: [String: String]
        public var totalBytes: Int
        /// The canvas index's source path.
        public var index: String
    }

    public enum Problem: Error, Hashable, Sendable, CustomStringConvertible {
        case noCanvas
        case link(String)
        case notAFile(String)
        case badName(String)
        case tooLarge(String)
        case tooDeep(String)
        case tooManyFiles
        case tooMuch

        public var description: String {
            switch self {
            case .noCanvas: return "The folder holds no canvas.json, in it or in its project folder."
            case .link(let path): return "\(path) is a link; a design folder can't hold links."
            case .notAFile(let path): return "\(path) is neither a file nor a folder."
            case .badName(let path): return "\(path) isn't a name a design's file can have."
            case .tooLarge(let path): return "\(path) is over \(DesignImport.maxFileBytes / 1024 / 1024) MB."
            case .tooDeep(let path): return "\(path) is nested too deep."
            case .tooManyFiles: return "A design holds at most \(DesignImport.maxFiles) files."
            case .tooMuch: return "The folder is over \(DesignImport.maxTotalBytes / 1024 / 1024) MB."
            }
        }
    }

    public static let maxFiles = 512
    public static let maxFileBytes = 16 * 1024 * 1024
    public static let maxTotalBytes = 256 * 1024 * 1024
    public static let maxDepth = 16

    /// The files a new design takes from a folder with `entries`, or why it takes none. Hidden
    /// files and any `support.js` (Shepherd serves its own runtime there) are left behind.
    public static func plan(_ entries: [Entry]) throws(Problem) -> Plan {
        let byPath = Dictionary(entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let project: String
        if byPath["canvas.json"]?.kind == .file {
            project = ""
        } else if byPath["project/canvas.json"]?.kind == .file {
            project = "project"
        } else {
            if let link = ["canvas.json", "project", "project/canvas.json"].first(where: { byPath[$0]?.kind == .symlink }) {
                throw .link(link)
            }
            throw .noCanvas
        }
        var files: [String: String] = [:]
        var total = 0
        for entry in entries.sorted(by: { $0.path < $1.path }) {
            let segments = entry.path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard !segments.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { throw .badName(entry.path) }
            let destination: String
            if project.isEmpty {
                destination = "project/" + entry.path
            } else if segments.first == "project", segments.count > 1 {
                destination = entry.path
            } else if segments.first == "assets" {
                guard segments.count > 1 else {
                    if entry.kind == .symlink { throw .link(entry.path) }
                    continue
                }
                if segments.contains(where: { $0.hasPrefix(".") }) { continue }
                guard entry.kind == .file else { throw entry.kind == .symlink ? .link(entry.path) : .notAFile(entry.path) }
                guard segments.count == 2, DesignBundle.isAssetName(segments[1]) else { throw .badName(entry.path) }
                destination = entry.path
                try take(entry, destination, &files, &total)
                continue
            } else {
                if segments.first == "project", entry.kind == .symlink { throw .link(entry.path) }
                continue
            }
            if segments.contains(where: { $0.hasPrefix(".") }) { continue }
            switch entry.kind {
            case .directory:
                guard segments.count <= maxDepth else { throw .tooDeep(entry.path) }
                guard segments.allSatisfy(isSegment) else { throw .badName(entry.path) }
                continue
            case .symlink: throw .link(entry.path)
            case .other: throw .notAFile(entry.path)
            case .file: break
            }
            if segments.last == "support.js" { continue }
            guard segments.count <= maxDepth else { throw .tooDeep(entry.path) }
            guard segments.allSatisfy(isSegment) else { throw .badName(entry.path) }
            try take(entry, destination, &files, &total)
        }
        return Plan(files: files, totalBytes: total, index: project.isEmpty ? "canvas.json" : "project/canvas.json")
    }

    private static func take(_ entry: Entry, _ destination: String, _ files: inout [String: String], _ total: inout Int) throws(Problem) {
        guard entry.size <= maxFileBytes else { throw .tooLarge(entry.path) }
        guard files.count < maxFiles else { throw .tooManyFiles }
        total += entry.size
        guard total <= maxTotalBytes else { throw .tooMuch }
        files[entry.path] = destination
    }

    /// A file or folder name a design keeps: `[A-Za-z0-9_][A-Za-z0-9_.-]*`, never `..`.
    public static func isSegment(_ segment: String) -> Bool {
        guard let first = segment.utf8.first, isWordByte(first), !segment.contains("..") else { return false }
        return segment.utf8.allSatisfy { isWordByte($0) || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "-") }
    }

    private static func isWordByte(_ b: UInt8) -> Bool {
        (0x30...0x39).contains(b) || (0x41...0x5A).contains(b) || (0x61...0x7A).contains(b) || b == UInt8(ascii: "_")
    }

    /// The canvas the new design keeps, from the folder's `canvas.json`: its bytes as they came
    /// (every key kept), or, when it has no title, the same canvas titled `fallbackTitle`, which
    /// still keeps every key. Throws when it isn't a canvas this build reads.
    public static func index(_ data: Data, fallbackTitle: String) throws -> (data: Data, index: DesignIndex) {
        let index = try DesignIndex.decode(data)
        if let title = index.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return (data, index)
        }
        let titled = try index.merging(.object(["title": .string(DesignExportNames.fileName(fallbackTitle))]))
        return (try titled.encoded(), titled)
    }
}
