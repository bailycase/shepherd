import Foundation

// A canvas's pages, notes and a duplicated board's place (docs/designs.md › The index): what a
// canvas shows on each page, and where a copy of a board goes.

extension DesignIndex {
    /// The page a board is on: the page it names when the index has that page, else the first
    /// page, so nothing listed goes missing. Nil on a canvas without pages.
    public func page(of path: DesignPath) -> String? {
        guard let pages, let first = pages.first else { return nil }
        guard let named = boards[path]?.page, pages.contains(where: { $0.id == named }) else { return first.id }
        return named
    }

    /// A note's page, by the same rule as a board's.
    public func page(of note: Note) -> String? {
        guard let pages, let first = pages.first else { return nil }
        guard let named = note.page, pages.contains(where: { $0.id == named }) else { return first.id }
        return named
    }

    /// Whether `path` is shown on `page` (nil: a canvas without pages shows every board).
    public func isOnPage(_ path: DesignPath, _ page: String?) -> Bool {
        guard let page else { return true }
        return self.page(of: path) == page
    }

    /// The page a canvas opens on: `launch.page` when the index has it, else the first page.
    public var openingPage: String? {
        guard let pages, let first = pages.first else { return nil }
        if let wanted = launch?.page, pages.contains(where: { $0.id == wanted }) { return wanted }
        return first.id
    }

    // MARK: Duplicating a board

    /// A title a duplicate takes: the board's own, else its stem, then " copy".
    public func duplicateTitle(of path: DesignPath) -> String {
        let title = boards[path]?.title?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (title?.isEmpty == false ? title! : path.stem) + " copy"
    }

    /// A path for a copy of `path` beside it: `<stem>-copy`, then `<stem>-copy-2` and on, the first
    /// whose stem no board and no file in `taken` has (regardless of case). Nil when none fits the
    /// grammar.
    public static func duplicatePath(for path: DesignPath, taken: Set<DesignPath>) -> DesignPath? {
        let stems = Set(taken.map { $0.stem.lowercased() })
        let folder = path.rawValue.split(separator: "/").dropLast().joined(separator: "/")
        for number in 1...500 {
            let stem = path.stem + (number == 1 ? "-copy" : "-copy-\(number)")
            guard !stems.contains(stem.lowercased()) else { continue }
            let raw = (folder.isEmpty ? "" : folder + "/") + stem + DesignPath.fileExtension
            return DesignPath(raw)
        }
        return nil
    }

    /// Where a copy of `path` goes: to its right, `gap` apart, on its row; past any board of its
    /// page it would overlap (or come within `gap` of), further right.
    public func duplicatePlacement(of path: DesignPath, gap: Double = 80) -> (x: Double, y: Double)? {
        guard let board = boards[path] else { return nil }
        let page = self.page(of: path)
        typealias Span = (minX: Double, minY: Double, maxX: Double, maxY: Double)
        let others: [Span] = boards.compactMap { entry -> Span? in
            guard entry.key != path, self.page(of: entry.key) == page else { return nil }
            let b = entry.value
            return (b.x, b.y, b.x + b.w, b.y + b.h)
        }
        var x = board.x + board.w + gap
        for _ in 0...others.count {
            // The copy's frame with `gap` around it; touching edges don't overlap.
            let room: Span = (x - gap, board.y - gap, x + board.w + gap, board.y + board.h + gap)
            var furthest: Double?
            for other in others where other.minX < room.maxX && other.maxX > room.minX && other.minY < room.maxY && other.maxY > room.minY {
                furthest = Swift.max(furthest ?? -.infinity, other.maxX)
            }
            guard let furthest else { return (x, board.y) }
            x = furthest + gap
        }
        return (x, board.y)
    }

    /// The index with a copy of `path`'s entry at `copy`: placed beside it, titled as a copy,
    /// right after it in `order`, with its Tweak values; nil when `path` isn't a board or `copy`
    /// already is.
    public func duplicating(_ path: DesignPath, as copy: DesignPath, gap: Double = 80) -> DesignIndex? {
        guard var entry = boards[path], boards[copy] == nil, let place = duplicatePlacement(of: path, gap: gap) else { return nil }
        var next = self
        entry.x = place.x
        entry.y = place.y
        entry.title = duplicateTitle(of: path)
        next.boards[copy] = entry
        var order = next.order.filter { $0 != copy }
        if let index = order.firstIndex(of: path) { order.insert(copy, at: index + 1) } else { order.append(copy) }
        next.order = order
        let tweaks = self.tweaks(for: path)
        if !tweaks.isEmpty, case .object(var all)? = next.extra[Self.tweaksKey] {
            all[copy.rawValue] = .object(tweaks)
            next.extra[Self.tweaksKey] = .object(all)
        }
        return next
    }
}

// MARK: - Notes

extension DesignIndex.Note {
    /// How the canvas draws a note: a title (`title1`, `title2`, …) and a sticky read-only, and a
    /// drawing (`rect`, `oval`, `pen`, `line`, `arrow`, `image`, anything else) not yet. Every kind
    /// round-trips whatever it is.
    public enum Shown: Hashable, Sendable {
        case title
        case sticky
        case drawing
    }

    public var shown: Shown {
        guard let kind else { return .drawing }
        if kind.hasPrefix("title") { return .title }
        return kind == "sticky" ? .sticky : .drawing
    }

    /// How wide the note may run, in canvas points: its `maxW`, else its `w`; nil when it names
    /// neither.
    public var width: Double? {
        for key in ["maxW", "w"] {
            if let value = extra[key]?.doubleValue, value.isFinite, value > 0 { return value }
        }
        return nil
    }
}
