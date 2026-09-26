import Foundation

/// A design's `project/canvas.json` (version 3): the boards laid out on the canvas, their order,
/// pages, notes and design systems (docs/designs.md › The index).
///
/// Every key this build doesn't name is kept verbatim, at every level (`attachments`,
/// `createdOnFiles`, `frameless`, `guides`, drawing notes), so a canvas from claude.ai
/// round-trips; a known key whose value has another shape than expected is kept as it came.
public struct DesignIndex: Hashable, Sendable {
    public var v: Int
    public var title: String?
    public var launch: Launch?
    public var pages: [Page]?
    /// One entry per listed board, keyed by its path under `project/`.
    public var boards: [DesignPath: Board]
    /// The listed boards back to front: the same paths as `boards`.
    public var order: [DesignPath]
    public var notes: [String: Note]?
    public var designSystems: [SystemRecord]?
    /// Keys this build doesn't name.
    public var extra: [String: JSONValue]

    public static let version = 3
    /// The canvas limits a write must keep (the Design format's).
    public static let boardSizeRange: ClosedRange<Double> = 40...8000
    public static let maxPages = 40
    public static let maxNotes = 200
    public static let maxSystems = 4

    public init(title: String?, boards: [DesignPath: Board] = [:], order: [DesignPath] = [],
                launch: Launch? = Launch(view: "canvas"), pages: [Page]? = [], notes: [String: Note]? = [:],
                designSystems: [SystemRecord]? = [], extra: [String: JSONValue] = [:]) {
        v = Self.version
        self.title = title
        self.boards = boards
        self.order = order
        self.launch = launch
        self.pages = pages
        self.notes = notes
        self.designSystems = designSystems
        self.extra = extra
    }

    /// A new design's index: what a canvas made on claude.ai starts with, `createdOnFiles` stamped
    /// `at` now.
    public static func new(title: String, at date: Date) -> DesignIndex {
        let stamp = ISO8601DateFormatter().string(from: date)
        return DesignIndex(title: title, extra: ["createdOnFiles": .object(["v": .number(1), "at": .string(stamp)])])
    }

    // MARK: Nested records

    /// Where a board sits on the canvas and how it shows.
    public struct Board: Hashable, Sendable {
        public var x: Double
        public var y: Double
        public var w: Double
        public var h: Double
        public var title: String?
        public var page: String?
        public var isInteractive: Bool?
        public var expand: String?
        public var extra: [String: JSONValue]

        public init(x: Double, y: Double, w: Double, h: Double, title: String? = nil, page: String? = nil,
                    isInteractive: Bool? = nil, expand: String? = nil, extra: [String: JSONValue] = [:]) {
            self.x = x
            self.y = y
            self.w = w
            self.h = h
            self.title = title
            self.page = page
            self.isInteractive = isInteractive
            self.expand = expand
            self.extra = extra
        }
    }

    /// `{"view": "canvas"}`, optionally on a page, or `{"view": "focused", "file": …}`.
    public struct Launch: Hashable, Sendable {
        public var view: String?
        public var file: String?
        public var page: String?
        public var extra: [String: JSONValue]

        public init(view: String?, file: String? = nil, page: String? = nil, extra: [String: JSONValue] = [:]) {
            self.view = view
            self.file = file
            self.page = page
            self.extra = extra
        }
    }

    public struct Page: Hashable, Sendable {
        public var id: String
        public var name: String?
        public var extra: [String: JSONValue]

        public init(id: String, name: String?, extra: [String: JSONValue] = [:]) {
            self.id = id
            self.name = name
            self.extra = extra
        }
    }

    /// A title, a sticky, or a drawing the user made (`kind` rect, oval, pen, line, arrow, image),
    /// which keeps whatever else it carries in `extra`.
    public struct Note: Hashable, Sendable {
        public var x: Double?
        public var y: Double?
        public var text: String?
        public var kind: String?
        public var page: String?
        public var extra: [String: JSONValue]

        public init(x: Double?, y: Double?, text: String?, kind: String? = nil, page: String? = nil,
                    extra: [String: JSONValue] = [:]) {
            self.x = x
            self.y = y
            self.text = text
            self.kind = kind
            self.page = page
            self.extra = extra
        }
    }

    /// An installed design system: its folder under `project/ds/` and where it came from.
    public struct SystemRecord: Hashable, Sendable {
        public var title: String?
        public var namespace: String?
        public var extra: [String: JSONValue]

        public init(title: String?, namespace: String?, extra: [String: JSONValue] = [:]) {
            self.title = title
            self.namespace = namespace
            self.extra = extra
        }
    }
}

// MARK: - JSON

/// The `[String: JSONValue]` form of an index record: known keys read typed, the rest kept.
private struct JSONFields {
    var fields: [String: JSONValue]

    init(_ fields: [String: JSONValue]) { self.fields = fields }

    /// Takes `key` when it has the wanted shape; otherwise leaves it with the unknown keys.
    mutating func take<T>(_ key: String, _ read: (JSONValue) -> T?) -> T? {
        guard let value = fields[key], let typed = read(value) else { return nil }
        fields[key] = nil
        return typed
    }

    static func string(_ v: JSONValue) -> String? { v.stringValue }
    static func number(_ v: JSONValue) -> Double? { v.doubleValue.flatMap { $0.isFinite ? $0 : nil } }
    static func bool(_ v: JSONValue) -> Bool? { v.boolValue }
    static func object(_ v: JSONValue) -> [String: JSONValue]? {
        if case .object(let o) = v { return o }
        return nil
    }
}

extension DesignIndex.Board {
    init?(json: [String: JSONValue]) {
        var f = JSONFields(json)
        guard let x = f.take("x", JSONFields.number), let y = f.take("y", JSONFields.number),
              let w = f.take("w", JSONFields.number), let h = f.take("h", JSONFields.number) else { return nil }
        self.init(x: x, y: y, w: w, h: h,
                  title: f.take("title", JSONFields.string), page: f.take("page", JSONFields.string),
                  isInteractive: f.take("is_interactive", JSONFields.bool), expand: f.take("expand", JSONFields.string),
                  extra: f.fields)
    }

    var json: [String: JSONValue] {
        var o = extra
        o["x"] = .number(x)
        o["y"] = .number(y)
        o["w"] = .number(w)
        o["h"] = .number(h)
        if let title { o["title"] = .string(title) }
        if let page { o["page"] = .string(page) }
        if let isInteractive { o["is_interactive"] = .bool(isInteractive) }
        if let expand { o["expand"] = .string(expand) }
        return o
    }
}

extension DesignIndex.Launch {
    init(json: [String: JSONValue]) {
        var f = JSONFields(json)
        self.init(view: f.take("view", JSONFields.string), file: f.take("file", JSONFields.string),
                  page: f.take("page", JSONFields.string), extra: f.fields)
    }

    var json: [String: JSONValue] {
        var o = extra
        if let view { o["view"] = .string(view) }
        if let file { o["file"] = .string(file) }
        if let page { o["page"] = .string(page) }
        return o
    }
}

extension DesignIndex.Page {
    init?(json: [String: JSONValue]) {
        var f = JSONFields(json)
        guard let id = f.take("id", JSONFields.string) else { return nil }
        self.init(id: id, name: f.take("name", JSONFields.string), extra: f.fields)
    }

    var json: [String: JSONValue] {
        var o = extra
        o["id"] = .string(id)
        if let name { o["name"] = .string(name) }
        return o
    }
}

extension DesignIndex.Note {
    init(json: [String: JSONValue]) {
        var f = JSONFields(json)
        self.init(x: f.take("x", JSONFields.number), y: f.take("y", JSONFields.number),
                  text: f.take("text", JSONFields.string), kind: f.take("kind", JSONFields.string),
                  page: f.take("page", JSONFields.string), extra: f.fields)
    }

    var json: [String: JSONValue] {
        var o = extra
        if let x { o["x"] = .number(x) }
        if let y { o["y"] = .number(y) }
        if let text { o["text"] = .string(text) }
        if let kind { o["kind"] = .string(kind) }
        if let page { o["page"] = .string(page) }
        return o
    }
}

extension DesignIndex.SystemRecord {
    init(json: [String: JSONValue]) {
        var f = JSONFields(json)
        self.init(title: f.take("title", JSONFields.string), namespace: f.take("namespace", JSONFields.string),
                  extra: f.fields)
    }

    var json: [String: JSONValue] {
        var o = extra
        if let title { o["title"] = .string(title) }
        if let namespace { o["namespace"] = .string(namespace) }
        return o
    }
}

/// Why a canvas.json can't be read.
public struct DesignIndexDecodingError: Error, Hashable, Sendable, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

extension DesignIndex {
    /// Reads an index from its JSON object. Boards keyed by a path outside the grammar, or
    /// missing a number for `x`, `y`, `w` or `h`, make it unreadable: nothing may name a file
    /// the grammar refuses. `order` is read as written; `inSync()` repairs it.
    public init(json: JSONValue) throws {
        guard case .object(let object) = json else { throw DesignIndexDecodingError("canvas.json is not an object") }
        var f = JSONFields(object)
        guard let v = f.take("v", JSONFields.number), v == Double(Self.version) else {
            throw DesignIndexDecodingError("canvas.json is not version \(Self.version)")
        }
        var boards: [DesignPath: Board] = [:]
        if let raw = f.take("boards", JSONFields.object) {
            for (key, value) in raw {
                let path: DesignPath
                do { path = try DesignPath.validate(key) } catch {
                    throw DesignIndexDecodingError("board \"\(key)\": \(error.description)")
                }
                guard let entry = JSONFields.object(value).flatMap(Board.init(json:)) else {
                    throw DesignIndexDecodingError("board \"\(key)\" needs numbers for x, y, w and h")
                }
                boards[path] = entry
            }
        }
        var order: [DesignPath] = []
        if let raw = f.take("order", { $0.arrayValue }) {
            for item in raw {
                guard let key = item.stringValue, let path = DesignPath(key) else {
                    throw DesignIndexDecodingError("order holds something that is not a board path")
                }
                order.append(path)
            }
        }
        self.init(title: nil, boards: boards, order: order, launch: nil, pages: nil, notes: nil, designSystems: nil)
        title = f.take("title", JSONFields.string)
        launch = f.take("launch", JSONFields.object).map(Launch.init(json:))
        pages = f.take("pages") { value -> [Page]? in
            guard let items = value.arrayValue else { return nil }
            let pages = items.compactMap { JSONFields.object($0).flatMap(Page.init(json:)) }
            return pages.count == items.count ? pages : nil
        }
        notes = f.take("notes") { value -> [String: Note]? in
            JSONFields.object(value).flatMap { raw in
                var notes: [String: Note] = [:]
                for (id, note) in raw {
                    guard let fields = JSONFields.object(note) else { return nil }
                    notes[id] = Note(json: fields)
                }
                return notes
            }
        }
        designSystems = f.take("designSystems") { value -> [SystemRecord]? in
            guard let items = value.arrayValue else { return nil }
            let records = items.compactMap { JSONFields.object($0).map(SystemRecord.init(json:)) }
            return records.count == items.count ? records : nil
        }
        extra = f.fields
    }

    public var json: JSONValue {
        var o = extra
        o["v"] = .number(Double(v))
        if let title { o["title"] = .string(title) }
        if let launch { o["launch"] = .object(launch.json) }
        if let pages { o["pages"] = .array(pages.map { .object($0.json) }) }
        o["boards"] = .object(Dictionary(uniqueKeysWithValues: boards.map { ($0.key.rawValue, .object($0.value.json)) }))
        o["order"] = .array(order.map { .string($0.rawValue) })
        if let notes { o["notes"] = .object(notes.mapValues { .object($0.json) }) }
        if let designSystems { o["designSystems"] = .array(designSystems.map { .object($0.json) }) }
        return .object(o)
    }

    /// canvas.json's bytes as Shepherd writes them: sorted keys, two-space indents.
    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(json)
    }

    public static func decode(_ data: Data) throws -> DesignIndex {
        try DesignIndex(json: JSONDecoder().decode(JSONValue.self, from: data))
    }
}

extension DesignIndex: Codable {
    public init(from decoder: Decoder) throws {
        try self.init(json: JSONValue(from: decoder))
    }

    public func encode(to encoder: Encoder) throws {
        try json.encode(to: encoder)
    }
}

// MARK: - Rules

extension DesignIndex {
    /// `order` and `boards` in step: order entries without a board go, and boards missing from
    /// order join its end (by path, so the result doesn't depend on dictionary order).
    public func inSync() -> DesignIndex {
        var copy = self
        var seen = Set<DesignPath>()
        copy.order = order.filter { boards[$0] != nil && seen.insert($0).inserted }
        copy.order += boards.keys.filter { !seen.contains($0) }.sorted()
        return copy
    }

    /// What a write must not break: board sizes, unique stems, `order` matching `boards`, page
    /// and note ids and counts, and design system folder names. Empty when the index is sound.
    public func problems() -> [String] {
        var problems: [String] = []
        if v != Self.version { problems.append("v is \(Self.version)") }
        for (path, board) in boards.sorted(by: { $0.key < $1.key }) {
            if !Self.boardSizeRange.contains(board.w) || !Self.boardSizeRange.contains(board.h) {
                problems.append("\(path): w and h are 40–8000")
            }
        }
        var stems: [String: DesignPath] = [:]
        for path in boards.keys.sorted() {
            let stem = path.stem.lowercased()
            if let other = stems[stem] {
                problems.append("\(path) and \(other) share the name \(path.stem)")
            } else {
                stems[stem] = path
            }
        }
        if order.count != boards.count || Set(order) != Set(boards.keys) {
            problems.append("order lists each board once")
        }
        if let pages {
            if pages.count > Self.maxPages { problems.append("at most \(Self.maxPages) pages") }
            for page in pages where !DesignPath.isIndexID(page.id) { problems.append("page id \"\(page.id)\" is [A-Za-z0-9_-]{1,40}") }
            if Set(pages.map(\.id)).count != pages.count { problems.append("page ids are unique") }
        }
        if let notes {
            if notes.count > Self.maxNotes { problems.append("at most \(Self.maxNotes) notes") }
            for id in notes.keys.sorted() where !DesignPath.isIndexID(id) { problems.append("note id \"\(id)\" is [A-Za-z0-9_-]{1,40}") }
        }
        if let designSystems {
            if designSystems.count > Self.maxSystems { problems.append("at most \(Self.maxSystems) design systems") }
            for record in designSystems {
                if let namespace = record.namespace, !DesignPath.isSystemNamespace(namespace) {
                    problems.append("design system folder \"\(namespace)\" is [a-z0-9][a-z0-9_-]{0,63}")
                }
            }
        }
        return problems
    }

    /// Applies a canvas_update: `patch` merges into the index as a JSON merge patch (RFC 7396),
    /// so objects merge key by key, `null` removes a key, and anything else replaces. Boards the
    /// patch adds join the end of `order` unless it sets `order`; boards it removes leave it.
    public func merging(_ patch: JSONValue) throws -> DesignIndex {
        guard case .object = patch else { throw DesignIndexDecodingError("a canvas update is an object") }
        var merged = try DesignIndex(json: Self.mergePatch(json, patch))
        let setsOrder = patch["order"] != nil
        if !setsOrder {
            let added = merged.boards.keys.filter { boards[$0] == nil }.sorted()
            merged.order = order.filter { merged.boards[$0] != nil } + added
        }
        return merged
    }

    static func mergePatch(_ target: JSONValue, _ patch: JSONValue) -> JSONValue {
        guard case .object(let changes) = patch else { return patch }
        var result: [String: JSONValue]
        if case .object(let existing) = target { result = existing } else { result = [:] }
        for (key, value) in changes {
            if value == .null {
                result[key] = nil
            } else {
                result[key] = mergePatch(result[key] ?? .null, value)
            }
        }
        return .object(result)
    }
}
