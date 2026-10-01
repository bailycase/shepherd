import Foundation

// Shared pieces (docs/designs.md › Shared pieces): `<dc-import name="Card">` mounts the board
// `Card.dc.html` in place, so a piece drawn once serves every board that imports it. These are
// the static reads of that: which boards a board imports, which boards import a piece, and which
// imports name a board that isn't there.

public enum DesignImports {
    /// One `<dc-import>` of a board.
    public struct Reference: Hashable, Sendable {
        /// The element's tid in its board's template.
        public var tid: Int
        /// The `name` as written.
        public var name: String
        /// The board it names, resolved the way the runtime resolves it; nil for a name with a
        /// hole in it, or one outside the grammar.
        public var target: DesignPath?
        /// The line of the element in its board.
        public var line: Int
        /// The name has a hole in it, so only the board's own data says what it imports.
        public var isDynamic: Bool
    }

    /// The board a `<dc-import name>` in `board` names: `name` + `.dc.html` beside `board` (or
    /// below its folder, `parts/Card`), never above it. Nil when the name has a hole in it or
    /// breaks the runtime's grammar (`[A-Za-z0-9_][A-Za-z0-9_.-]*` segments, no `..`).
    public static func resolve(name: String, from board: DesignPath) -> DesignPath? {
        guard !name.isEmpty, !name.contains("{{"), !name.contains("..") else { return nil }
        let segments = name.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.allSatisfy(DesignPath.isSegment) else { return nil }
        let folder = board.rawValue.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
        let raw = (folder.isEmpty ? "" : folder + "/") + name + DesignPath.fileExtension
        return DesignPath(raw)
    }

    /// A `<dc-import>` as the board's text says it, before its name is resolved against a board.
    public struct Raw: Hashable, Sendable {
        public var tid: Int
        public var name: String
        public var line: Int
    }

    /// The `<dc-import>`s of a board, in template order, as written.
    public static func raw(in tree: DesignBoardTree) -> [Raw] {
        var out: [Raw] = []
        for element in tree.elements where element.name == "dc-import" {
            guard let name = tree.attribute("name", of: element.tid) else { continue }
            out.append(Raw(tid: element.tid, name: name, line: element.tagRange.map { tree.line(at: $0.lowerBound) } ?? 1))
        }
        return out
    }

    /// `raw`'s imports resolved against `board`.
    public static func references(_ raw: [Raw], of board: DesignPath) -> [Reference] {
        raw.map { Reference(tid: $0.tid, name: $0.name, target: resolve(name: $0.name, from: board), line: $0.line,
                            isDynamic: $0.name.contains("{{")) }
    }

    /// The `<dc-import>`s of a board, in template order.
    public static func references(in tree: DesignBoardTree, of board: DesignPath) -> [Reference] {
        references(raw(in: tree), of: board)
    }
}

/// Which boards import which, across a design: what the canvas's "Used in 3 boards" and
/// `board_search`'s usages read. Built from the boards' sources (the store keeps each board's
/// imports by hash, so a revision re-reads only boards that changed).
public struct DesignUsageIndex: Hashable, Sendable {
    /// A piece → the boards that import it, sorted, never itself.
    public var importers: [DesignPath: [DesignPath]]
    /// A board → the `<dc-import>` names no board of the design answers to, sorted.
    public var missing: [DesignPath: [String]]

    public init(importers: [DesignPath: [DesignPath]] = [:], missing: [DesignPath: [String]] = [:]) {
        self.importers = importers
        self.missing = missing
    }

    /// How many boards import `piece`.
    public func usedIn(_ piece: DesignPath) -> Int { importers[piece]?.count ?? 0 }

    /// The index from each board's imports (`DesignImports.references`) and the boards that exist.
    public static func build(imports: [DesignPath: [DesignImports.Reference]], boards: Set<DesignPath>) -> DesignUsageIndex {
        var importers: [DesignPath: Set<DesignPath>] = [:]
        var missing: [DesignPath: Set<String>] = [:]
        for (board, references) in imports {
            for reference in references {
                guard let target = reference.target else {
                    if !reference.isDynamic { missing[board, default: []].insert(reference.name) }
                    continue
                }
                if boards.contains(target) {
                    if target != board { importers[target, default: []].insert(board) }
                } else {
                    missing[board, default: []].insert(reference.name)
                }
            }
        }
        return DesignUsageIndex(importers: importers.mapValues { $0.sorted() }, missing: missing.mapValues { $0.sorted() })
    }

    /// The label the canvas puts beside a piece's title: "used in 3 boards"; nil when no board does.
    public func label(for piece: DesignPath) -> String? {
        let count = usedIn(piece)
        guard count > 0 else { return nil }
        return "used in \(count) \(count == 1 ? "board" : "boards")"
    }
}
