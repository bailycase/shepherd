import CryptoKit
import Foundation
import ShepherdProtocol

/// What a board draws from beyond its own file, as a digest of those files' content: the boards it
/// imports (`<dc-import>`, a design system's `ds/<system>/…` components among them, and what they
/// import in turn) and the project files any of them name (a stylesheet such as `ds/acme/tokens.css`,
/// a script, a font, an image, and what those name in turn: `@import`, `import`).
///
/// It is the part of a finished picture's key (`BoardPictureKey.dependencies`) the board's own
/// hash can't give: when a design system's file or an imported piece changes, every board that
/// reads it gets a new digest and draws again, and no other board does.
///
/// A file is read as named if its file name appears in the text (`href="../ds/acme/tokens.css"`,
/// `url(fonts/x.woff2)`), so a board may be taken to read a file it only mentions (it draws
/// again for nothing) but never the other way round. An import whose name has a hole in it
/// (`name="{{kind}}"`) can name any piece, so the board depends on every piece of the design.
public final class BoardDependencies: @unchecked Sendable {
    private struct References {
        var imports: [String] = []
        var dynamic = false
        var names: Set<String> = []
    }

    private let lock = NSLock()
    private var memo: [String: References] = [:]

    public init() {}

    /// File types whose text is read for what it names, and the largest such file read.
    static let readable: Set<String> = ["css", "scss", "less", "js", "mjs", "html", "htm", "svg", "json"]
    static let maxReadBytes = 512 * 1024
    /// File types a name can have to count as a file the board reads.
    static let named: Set<String> = ["css", "scss", "less", "js", "mjs", "json", "svg", "png", "jpg", "jpeg", "gif", "webp", "avif",
                                     "ico", "woff", "woff2", "ttf", "otf", "mp4", "webm", "txt", "html", "htm"]

    /// The digest for each of `boards` (a board that depends on nothing has ""), from the design's
    /// files (`files`: every file under its project, as its index lists them) and a way to read a
    /// file's bytes by its hash.
    public func digests(for boards: [DesignPath], files: [RemoteDesignFileInfo], read: (String) -> Data?) -> [DesignPath: String] {
        var shaByPath: [String: RemoteDesignFileInfo] = [:]
        var pieces: [String] = []
        var byName: [String: [String]] = [:]
        for file in files {
            shaByPath[file.path] = file
            if file.path.hasSuffix(DesignPath.fileExtension) {
                pieces.append(file.path)
            } else {
                byName[String(file.path.split(separator: "/").last ?? ""), default: []].append(file.path)
            }
        }
        pieces.sort()
        var result: [DesignPath: String] = [:]
        for board in boards {
            result[board] = digest(of: board.rawValue, files: shaByPath, pieces: pieces, byName: byName, read: read)
        }
        lock.lock()
        if memo.count > 8_192 { memo.removeAll() }
        lock.unlock()
        return result
    }

    private func digest(of board: String, files: [String: RemoteDesignFileInfo], pieces: [String], byName: [String: [String]],
                        read: (String) -> Data?) -> String {
        var found: [String: String] = [:]
        var seen: Set<String> = [board]
        var queue = [board]
        var everyPiece = false
        while let path = queue.popLast() {
            guard let file = files[path] else { continue }
            let references = references(of: file, read: read)
            let from = DesignPath(path) ?? DesignPath.systemComponent(path)
            for name in references.imports {
                guard let from, let target = DesignImports.resolve(name: name, from: from)?.rawValue else {
                    if name.contains("{{") { everyPiece = true } else { found["import:" + name] = "-" }
                    continue
                }
                if let piece = files[target] {
                    found[target] = piece.sha256
                    if seen.insert(target).inserted { queue.append(target) }
                } else {
                    // Not there yet: the digest moves when it appears.
                    found[target] = "-"
                }
            }
            if references.dynamic { everyPiece = true }
            for name in references.names {
                for named in byName[name] ?? [] {
                    guard let file = files[named] else { continue }
                    found[named] = file.sha256
                    if seen.insert(named).inserted { queue.append(named) }
                }
            }
        }
        if everyPiece {
            for piece in pieces where piece != board { found[piece] = files[piece]?.sha256 ?? "-" }
        }
        guard !found.isEmpty else { return "" }
        let text = found.sorted { $0.key < $1.key }.map { "\($0.key)\t\($0.value)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func references(of file: RemoteDesignFileInfo, read: (String) -> Data?) -> References {
        lock.lock()
        let kept = memo[file.sha256]
        lock.unlock()
        if let kept { return kept }
        var found = References()
        let ext = file.path.split(separator: ".").last.map { $0.lowercased() } ?? ""
        let isBoard = file.path.hasSuffix(DesignPath.fileExtension)
        if isBoard || Self.readable.contains(ext) {
            if file.size > Self.maxReadBytes {
                // Too big to read: a board that big may import anything.
                found.dynamic = isBoard
            } else if let data = read(file.sha256) {
                found = Self.scan(String(decoding: data, as: UTF8.self), importsBoards: isBoard)
            } else {
                // Not kept (yet): assume the most, and look again next time.
                found.dynamic = isBoard
                return found
            }
        }
        lock.lock()
        memo[file.sha256] = found
        lock.unlock()
        return found
    }

    private static let importElement = try! NSRegularExpression(pattern: #"<dc-import\b"#)
    private static let importName = try! NSRegularExpression(pattern: #"<dc-import\b[^>]*?\bname\s*=\s*(?:"([^"]*)"|'([^']*)')"#)
    private static let fileName = try! NSRegularExpression(pattern: #"[A-Za-z0-9_][A-Za-z0-9_.\-]*\.([A-Za-z0-9]{2,5})\b"#)

    private static func scan(_ text: String, importsBoards: Bool) -> References {
        var found = References()
        let whole = NSRange(text.startIndex..., in: text)
        if importsBoards {
            var named = 0
            for match in importName.matches(in: text, range: whole) {
                for group in 1...2 {
                    if let range = Range(match.range(at: group), in: text) {
                        found.imports.append(String(text[range]))
                        named += 1
                    }
                }
            }
            // An import whose name isn't plain quoted text can name any piece.
            if importElement.numberOfMatches(in: text, range: whole) > named { found.dynamic = true }
        }
        for match in fileName.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text), let ext = Range(match.range(at: 1), in: text),
                  named.contains(text[ext].lowercased()) else { continue }
            found.names.insert(String(text[range]))
        }
        return found
    }
}
