import CoreGraphics
import Foundation
import ShepherdProtocol

// Reading Pencil markup on the device that drew it (iPadDesign): which strokes are marks (a loop
// around something, a line under it, an arrow at it) and which are handwriting, which note goes
// with which mark, and which element of which board each mark is on. Pure geometry, so it is
// tested on fixed strokes; the iPad adds the handwriting (Vision, on the device) and the boards'
// hit tests. docs/designs.md › Pencil markup.

/// One stroke of ink, in canvas points (the boards' own CSS pixels, where the canvas lays them
/// out), in the order it was drawn.
public struct DesignMarkupInk: Equatable, Sendable {
    public var points: [CGPoint]

    public init(points: [CGPoint]) {
        self.points = points
    }

    public var bounds: CGRect {
        guard let first = points.first else { return .null }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for p in points.dropFirst() {
            minX = min(minX, p.x); maxX = max(maxX, p.x)
            minY = min(minY, p.y); maxY = max(maxY, p.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

/// Where the canvas looks, as the markup layer maps the screen: the screen position of the
/// canvas's origin and the zoom (`NWCanvasViewport`'s numbers).
public struct DesignMarkupViewport: Equatable, Sendable {
    public var offset: CGPoint
    public var zoom: CGFloat

    public init(offset: CGPoint, zoom: CGFloat) {
        self.offset = offset
        self.zoom = zoom
    }

    /// The canvas point under a screen point.
    public func canvas(_ point: CGPoint) -> CGPoint {
        CGPoint(x: (point.x - offset.x) / zoom, y: (point.y - offset.y) / zoom)
    }

    /// Canvas points to screen points: what ink kept on the canvas is drawn through.
    public var toScreen: CGAffineTransform {
        CGAffineTransform(a: zoom, b: 0, c: 0, d: zoom, tx: offset.x, ty: offset.y)
    }
}

public enum DesignMarkupReading {
    // MARK: One stroke

    /// What one stroke looks like on its own.
    public enum Shape: Equatable, Sendable {
        /// Goes around and comes back near where it began.
        case loop
        /// Nearly straight, from `start` to `end`.
        case line(start: CGPoint, end: CGPoint)
        /// Two short straight legs meeting at `apex`: an arrowhead drawn on its own.
        case hook(apex: CGPoint)
        /// A straight shaft that ends in a head drawn without lifting the Pencil: from `tail` to
        /// the head at `head`.
        case arrow(tail: CGPoint, head: CGPoint)
        /// Anything else: handwriting, or a mark with no shape of its own.
        case scribble
    }

    /// Steps along a stroke when it is measured, relative to its size: the Pencil's speed doesn't
    /// change what a stroke is.
    static let samples = 64

    /// Reads one stroke's shape.
    public static func shape(_ ink: DesignMarkupInk) -> Shape {
        let points = resampled(ink.points, count: samples)
        guard points.count >= 3 else { return .scribble }
        let bounds = ink.bounds
        let diagonal = hypot(bounds.width, bounds.height)
        guard diagonal > 0 else { return .scribble }
        let length = pathLength(points)
        let chord = distance(points[0], points[points.count - 1])
        if chord / length >= 0.9 {
            return .line(start: points[0], end: points[points.count - 1])
        }
        // Around and back: closed, and its path about a loop's length.
        if chord <= 0.3 * diagonal, length >= 1.7 * diagonal, turning(points) >= 1.4 * .pi, reversals(points) <= 6 {
            return .loop
        }
        if let apex = hookApex(points, length: length) { return .hook(apex: apex) }
        if let arrow = oneStrokeArrow(points, length: length) { return arrow }
        return .scribble
    }

    /// Two nearly straight legs of similar length meeting at one sharp corner: the corner.
    static func hookApex(_ points: [CGPoint], length: CGFloat) -> CGPoint? {
        let corner = sharpestCorner(points)
        guard corner > 2, corner < points.count - 3 else { return nil }
        let first = Array(points[...corner]), second = Array(points[corner...])
        let a = pathLength(first), b = pathLength(second)
        guard min(a, b) >= 0.25 * max(a, b), straightness(first) >= 0.85, straightness(second) >= 0.85 else { return nil }
        let angle = angleBetween(first[0], points[corner], second[second.count - 1])
        guard angle >= .pi / 9, angle <= .pi * 0.8 else { return nil }
        return points[corner]
    }

    /// A long straight shaft then a short leg back at a sharp angle: an arrow drawn in one
    /// stroke, its head where the shaft turns.
    static func oneStrokeArrow(_ points: [CGPoint], length: CGFloat) -> Shape? {
        let corner = sharpestCorner(points)
        guard corner > 2, corner < points.count - 2 else { return nil }
        let shaft = Array(points[...corner]), barb = Array(points[corner...])
        let shaftLength = pathLength(shaft), barbLength = pathLength(barb)
        guard shaftLength >= 0.7 * length, barbLength >= 0.05 * length, straightness(shaft) >= 0.9, straightness(barb) >= 0.8 else { return nil }
        let angle = angleBetween(shaft[0], points[corner], barb[barb.count - 1])
        guard angle <= .pi * 0.35 else { return nil }
        return .arrow(tail: shaft[0], head: points[corner])
    }

    // MARK: The markup

    /// A mark as the reading makes it: its kind, the strokes it is drawn with (by index), and
    /// where it points: the loop's bounds, the underline's two ends, or the arrow's head and tail.
    public struct Mark: Equatable, Sendable {
        public var kind: DesignMarkupKind
        public var strokes: [Int]
        public var bounds: CGRect
        /// An underline's two ends, left to right.
        public var line: (start: CGPoint, end: CGPoint)?
        /// An arrow's head and tail.
        public var head: CGPoint?
        public var tail: CGPoint?

        public static func == (a: Mark, b: Mark) -> Bool {
            a.kind == b.kind && a.strokes == b.strokes && a.bounds == b.bounds && a.line?.start == b.line?.start
                && a.line?.end == b.line?.end && a.head == b.head && a.tail == b.tail
        }
    }

    /// The strokes read so far: the marks, and the handwriting as groups of strokes (each a note
    /// once it is read, or a mark when it holds no words).
    public struct Reading: Equatable, Sendable {
        public var marks: [Mark]
        /// Groups of stroke indices that may be words, in the order they were begun.
        public var writing: [[Int]]
    }

    /// Sorts strokes into marks and handwriting:
    /// 1. an arrowhead joins the line whose end it sits on, when that line is longer than writing;
    /// 2. a small loop, line or hook among writing is writing too (an "o", a "t"'s bar);
    /// 3. any other loop is a circle; a line is an underline when it runs nearly level, else a
    ///    mark; a stroke with no shape of its own is writing.
    public static func read(_ inks: [DesignMarkupInk]) -> Reading {
        let shapes = inks.map(shape)
        let bounds = inks.map(\.bounds)
        var used = Set<Int>()
        var marks: [Mark] = []

        // Writing's size, from the strokes with no shape.
        let scribbles = shapes.indices.filter { shapes[$0] == .scribble }
        let letter = median(scribbles.map { bounds[$0].height })

        // Arrowheads onto their shafts first, so a head that lands beside a note stays a head.
        for index in shapes.indices {
            guard case .hook(let apex) = shapes[index] else { continue }
            let reach = max(0.6 * hypot(bounds[index].width, bounds[index].height), 1)
            var best: (shaft: Int, head: CGPoint, tail: CGPoint, distance: CGFloat)?
            for other in shapes.indices where other != index && !used.contains(other) {
                guard case .line(let start, let end) = shapes[other] else { continue }
                if let letter, distance(start, end) < 2.5 * letter { continue }
                for (head, tail) in [(start, end), (end, start)] {
                    let d = distance(head, apex)
                    if d <= reach, d < (best?.distance ?? .infinity) { best = (other, head, tail, d) }
                }
            }
            guard let best else { continue }
            used.insert(index)
            used.insert(best.shaft)
            marks.append(Mark(kind: .arrow, strokes: [best.shaft, index].sorted(), bounds: bounds[best.shaft].union(bounds[index]),
                              head: best.head, tail: best.tail))
        }

        // Small shapes among writing are letters.
        var writing = Set(scribbles)
        if let letter {
            // Letter by letter: one taken in brings the next within reach.
            var grew = true
            while grew {
                grew = false
                for index in shapes.indices where !writing.contains(index) && !used.contains(index) {
                    let box = bounds[index]
                    let small = box.height <= 1.6 * letter && box.width <= 3 * letter
                    if small && writing.contains(where: { gap(bounds[$0], box) <= 0.8 * letter }) {
                        writing.insert(index)
                        grew = true
                    }
                }
            }
        }

        for index in shapes.indices where !used.contains(index) && !writing.contains(index) {
            switch shapes[index] {
            case .loop:
                marks.append(Mark(kind: .circle, strokes: [index], bounds: bounds[index]))
            case .line(let start, let end):
                let level = abs(end.y - start.y) <= tan(.pi / 9) * abs(end.x - start.x)
                if level {
                    let ends = start.x <= end.x ? (start, end) : (end, start)
                    marks.append(Mark(kind: .underline, strokes: [index], bounds: bounds[index], line: ends))
                } else {
                    marks.append(Mark(kind: .mark, strokes: [index], bounds: bounds[index]))
                }
            case .arrow(let tail, let head):
                marks.append(Mark(kind: .arrow, strokes: [index], bounds: bounds[index], head: head, tail: tail))
            case .hook:
                marks.append(Mark(kind: .mark, strokes: [index], bounds: bounds[index]))
            case .scribble:
                break
            }
            used.insert(index)
        }
        marks.sort { ($0.strokes.first ?? 0) < ($1.strokes.first ?? 0) }
        return Reading(marks: marks, writing: groups(writing.sorted(), bounds: bounds))
    }

    /// Writing strokes grouped by what touches what: strokes join when the gap between them is
    /// under most of a letter's height.
    static func groups(_ indices: [Int], bounds: [CGRect]) -> [[Int]] {
        var parent = Dictionary(uniqueKeysWithValues: indices.map { ($0, $0) })
        func root(_ i: Int) -> Int {
            var i = i
            while let p = parent[i], p != i { i = p }
            return i
        }
        for (n, a) in indices.enumerated() {
            for b in indices[(n + 1)...] {
                let size = max(bounds[a].height, bounds[b].height, 1)
                if gap(bounds[a], bounds[b]) <= 0.9 * size {
                    let ra = root(a), rb = root(b)
                    if ra != rb { parent[max(ra, rb)] = min(ra, rb) }
                }
            }
        }
        var byRoot: [Int: [Int]] = [:]
        for i in indices { byRoot[root(i), default: []].append(i) }
        return byRoot.values.map { $0.sorted() }.sorted { $0[0] < $1[0] }
    }

    // MARK: Notes

    /// A note as the device read it: the words, and where they are written.
    public struct Note: Equatable, Sendable {
        public var text: String
        public var bounds: CGRect

        public init(text: String, bounds: CGRect) {
            self.text = text
            self.bounds = bounds
        }
    }

    /// A mark with the note that goes with it.
    public struct Placed: Equatable, Sendable {
        public var mark: Mark
        public var note: String?
    }

    /// Which note goes with which mark:
    /// 1. an arrow from a note to a loop or line (or from one to a note) ties them, and draws
    ///    nothing of its own;
    /// 2. an arrow with a note at one end and nothing marked at the other is the mark, pointing
    ///    from the note;
    /// 3. any other note goes with the nearest mark that has none yet (else the nearest mark);
    /// 4. a note with no mark anywhere is a mark of its own, where it is written.
    /// Marks keep the order they were drawn in; two notes on one mark join with "; ".
    public static func attach(_ notes: [Note], to marks: [Mark]) -> [Placed] {
        var placed = marks.map { Placed(mark: $0, note: nil) }
        var taken = Set<Int>()
        var connectors = Set<Int>()
        func add(_ note: String, to index: Int) {
            placed[index].note = placed[index].note.map { "\($0); \(note)" } ?? note
        }
        func noteAt(_ point: CGPoint) -> Int? {
            notes.indices.filter { !taken.contains($0) }.min { a, b in
                gap(notes[a].bounds, point) < gap(notes[b].bounds, point)
            }.flatMap { gap(notes[$0].bounds, point) <= max(0.6 * notes[$0].bounds.height, 12) ? $0 : nil }
        }
        func markAt(_ point: CGPoint, besides arrow: Int) -> Int? {
            placed.indices.filter { $0 != arrow && placed[$0].mark.kind != .arrow }.min { a, b in
                gap(placed[a].mark.bounds, point) < gap(placed[b].mark.bounds, point)
            }.flatMap { index in
                let box = placed[index].mark.bounds
                return gap(box, point) <= max(0.15 * max(box.width, box.height), 16) ? index : nil
            }
        }
        for index in placed.indices where placed[index].mark.kind == .arrow {
            guard let head = placed[index].mark.head, let tail = placed[index].mark.tail else { continue }
            for (noteEnd, otherEnd) in [(tail, head), (head, tail)] {
                guard let note = noteAt(noteEnd) else { continue }
                taken.insert(note)
                if let target = markAt(otherEnd, besides: index) {
                    add(notes[note].text, to: target)
                    connectors.insert(index)
                } else {
                    add(notes[note].text, to: index)
                    // The arrow points away from its note.
                    placed[index].mark.head = otherEnd
                    placed[index].mark.tail = noteEnd
                }
                break
            }
        }
        for note in notes.indices where !taken.contains(note) {
            let candidates = placed.indices.filter { !connectors.contains($0) }
            let open = candidates.filter { placed[$0].note == nil }
            let pool = open.isEmpty ? candidates : open
            if let nearest = pool.min(by: { gap(placed[$0].mark.bounds, notes[note].bounds) < gap(placed[$1].mark.bounds, notes[note].bounds) }) {
                add(notes[note].text, to: nearest)
            } else {
                placed.append(Placed(mark: Mark(kind: .mark, strokes: [], bounds: notes[note].bounds), note: notes[note].text))
            }
            taken.insert(note)
        }
        return placed.indices.filter { !connectors.contains($0) }.map { placed[$0] }
    }

    // MARK: Boards and elements

    /// The board a mark is on: the one its bounds overlap most, else (a mark beside the boards)
    /// the nearest. `boards` in canvas order, back to front; a later one wins a tie.
    public static func board(for bounds: CGRect, in boards: [(path: DesignPath, frame: CGRect)]) -> DesignPath? {
        // A level line has no height: measure the overlap of its box a point out on every side.
        let box = bounds.insetBy(dx: -1, dy: -1)
        var best: (path: DesignPath, overlap: CGFloat)?
        for board in boards {
            let overlap = board.frame.intersection(box)
            let area = overlap.isNull ? 0 : overlap.width * overlap.height
            if area > 0, area >= (best?.overlap ?? 0) { best = (board.path, area) }
        }
        if let best { return best.path }
        return boards.min { gap($0.frame, bounds) < gap($1.frame, bounds) }?.path
    }

    /// Canvas points to a board's own points: the board's frame on the canvas is its size in
    /// its own points, wherever the canvas puts it.
    public static func boardPoint(_ point: CGPoint, frame: CGRect) -> CGPoint {
        CGPoint(x: point.x - frame.minX, y: point.y - frame.minY)
    }

    public static func boardRect(_ rect: CGRect, frame: CGRect) -> CGRect {
        rect.offsetBy(dx: -frame.minX, dy: -frame.minY)
    }

    /// Where to ask a board what is under a mark, in the board's points: the loop's middle; a
    /// little above an underline at a quarter, half and three quarters along; an arrow's head.
    public static func probes(for mark: Mark, frame: CGRect) -> [CGPoint] {
        let middle = [boardPoint(CGPoint(x: mark.bounds.midX, y: mark.bounds.midY), frame: frame)]
        switch mark.kind {
        case .underline:
            guard let line = mark.line else { return middle }
            let lift = max(mark.bounds.height, 6)
            return [0.25, 0.5, 0.75].map { t in
                boardPoint(CGPoint(x: line.start.x + (line.end.x - line.start.x) * t,
                                   y: line.start.y + (line.end.y - line.start.y) * t - lift), frame: frame)
            }
        case .arrow:
            guard let head = mark.head else { return middle }
            return [boardPoint(head, frame: frame)]
        case .circle, .mark:
            return middle
        }
    }

    /// An element a board reported, with where it draws it (the board's points).
    public struct Candidate: Equatable, Sendable {
        public var tid: Int
        public var rect: CGRect
        /// How many elements are above it: the board's root is 0.
        public var depth: Int

        public init(tid: Int, rect: CGRect, depth: Int) {
            self.tid = tid
            self.rect = rect
            self.depth = depth
        }
    }

    /// The element a mark is on, among the elements under its probes and their ancestors (the
    /// board's points):
    /// - a loop or a mark: the element whose box matches the mark's best (intersection over union);
    /// - an underline: the element whose bottom edge the line runs along, over most of the line's
    ///   width, the best match in width first;
    /// - an arrow: the deepest element under its head.
    /// Ties go to the deeper element. Nil when none qualifies.
    public static func element(for mark: Mark, frame: CGRect, among candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        // Best score first, then the deeper element.
        func ranked(_ scored: [(Candidate, CGFloat)]) -> Candidate? {
            scored.max { ($0.1, $0.0.depth) < ($1.1, $1.0.depth) }?.0
        }
        let deepest = candidates.max { $0.depth < $1.depth }
        switch mark.kind {
        case .circle, .mark:
            let box = boardRect(mark.bounds, frame: frame)
            return ranked(candidates.map { ($0, iou($0.rect, box)) }.filter { $0.1 > 0 })
        case .underline:
            let box = boardRect(mark.bounds, frame: frame)
            let lineY = box.midY, span = box.minX...box.maxX
            let scored = candidates.compactMap { candidate -> (Candidate, CGFloat)? in
                let rect = candidate.rect
                guard rect.width > 0, abs(rect.maxY - lineY) <= max(24, 0.35 * rect.height) else { return nil }
                let overlap = max(0, min(rect.maxX, span.upperBound) - max(rect.minX, span.lowerBound))
                let union = max(rect.maxX, span.upperBound) - min(rect.minX, span.lowerBound)
                guard union > 0, overlap >= 0.6 * (span.upperBound - span.lowerBound) else { return nil }
                return (candidate, overlap / union)
            }
            return ranked(scored) ?? deepest
        case .arrow:
            guard let head = mark.head else { return deepest }
            let tip = boardPoint(head, frame: frame)
            let under = candidates.filter { $0.rect.insetBy(dx: -4, dy: -4).contains(tip) }
            return (under.isEmpty ? candidates : under).max { $0.depth < $1.depth }
        }
    }

    // MARK: Geometry

    static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let i = a.intersection(b)
        guard !i.isNull, !i.isEmpty else { return 0 }
        let inter = i.width * i.height
        let union = a.width * a.height + b.width * b.height - inter
        return union > 0 ? inter / union : 0
    }

    /// The distance between two boxes; 0 when they touch or overlap.
    static func gap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let dx = max(0, max(a.minX - b.maxX, b.minX - a.maxX))
        let dy = max(0, max(a.minY - b.maxY, b.minY - a.maxY))
        return hypot(dx, dy)
    }

    static func gap(_ a: CGRect, _ p: CGPoint) -> CGFloat {
        gap(a, CGRect(origin: p, size: .zero))
    }

    static func distance(_ a: CGPoint, _ b: CGPoint) -> CGFloat {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func pathLength(_ points: [CGPoint]) -> CGFloat {
        zip(points, points.dropFirst()).reduce(0) { $0 + distance($1.0, $1.1) }
    }

    static func straightness(_ points: [CGPoint]) -> CGFloat {
        let length = pathLength(points)
        guard length > 0, let first = points.first, let last = points.last else { return 0 }
        return distance(first, last) / length
    }

    /// `count` points evenly spaced along the stroke.
    static func resampled(_ points: [CGPoint], count: Int) -> [CGPoint] {
        guard points.count >= 2 else { return points }
        let length = pathLength(points)
        guard length > 0 else { return [points[0]] }
        let step = length / CGFloat(count - 1)
        var out = [points[0]]
        var carried: CGFloat = 0
        var previous = points[0]
        for next in points.dropFirst() {
            var segment = distance(previous, next)
            var from = previous
            while carried + segment >= step, out.count < count {
                let t = (step - carried) / segment
                let point = CGPoint(x: from.x + (next.x - from.x) * t, y: from.y + (next.y - from.y) * t)
                out.append(point)
                segment -= step - carried
                from = point
                carried = 0
            }
            carried += segment
            previous = next
        }
        if out.count < count { out.append(points[points.count - 1]) }
        return out
    }

    /// The summed size of every turn along the stroke.
    static func turning(_ points: [CGPoint]) -> CGFloat {
        headings(points).adjacentPairs().reduce(0) { $0 + abs(wrapped($1.1 - $1.0)) }
    }

    /// How often the stroke turns back on itself sideways: handwriting does, a loop doesn't.
    static func reversals(_ points: [CGPoint]) -> Int {
        let turns = headings(points).adjacentPairs().map { wrapped($0.1 - $0.0) }.filter { abs($0) > 0.05 }
        return zip(turns, turns.dropFirst()).count { ($0 > 0) != ($1 > 0) }
    }

    static func headings(_ points: [CGPoint]) -> [CGFloat] {
        zip(points, points.dropFirst()).compactMap { a, b in
            a == b ? nil : atan2(b.y - a.y, b.x - a.x)
        }
    }

    /// The index where the stroke turns most sharply (over a few points either side).
    static func sharpestCorner(_ points: [CGPoint]) -> Int {
        let reach = 3
        var best = (index: 0, angle: CGFloat.pi)
        for i in reach..<(points.count - reach) {
            let angle = angleBetween(points[i - reach], points[i], points[i + reach])
            if angle < best.angle { best = (i, angle) }
        }
        return best.index
    }

    /// The angle at `b` between the legs to `a` and to `c` (π: straight on).
    static func angleBetween(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
        let u = CGVector(dx: a.x - b.x, dy: a.y - b.y), v = CGVector(dx: c.x - b.x, dy: c.y - b.y)
        let lu = hypot(u.dx, u.dy), lv = hypot(v.dx, v.dy)
        guard lu > 0, lv > 0 else { return .pi }
        return acos(max(-1, min(1, (u.dx * v.dx + u.dy * v.dy) / (lu * lv))))
    }

    static func wrapped(_ angle: CGFloat) -> CGFloat {
        var a = angle
        while a > .pi { a -= 2 * .pi }
        while a < -.pi { a += 2 * .pi }
        return a
    }

    static func median(_ values: [CGFloat]) -> CGFloat? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        return sorted[sorted.count / 2]
    }
}

private extension Array {
    func adjacentPairs() -> [(Element, Element)] {
        Array<(Element, Element)>(zip(self, dropFirst()))
    }
}
