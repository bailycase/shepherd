import Foundation

/// A subagent file as the edit form sees it: the frontmatter's lines and the Markdown body.
/// The form rewrites only the keys it owns. A key it does not draw (one the runtime parser
/// rejects, an alias, a comment) stays in the file exactly as written, so editing a field never
/// repairs or loses another.
struct SubagentProfileText: Equatable {
    private var head: [String]
    /// Everything after the closing fence, starting at that line's newline.
    private var tail: String
    private var fenced: Bool

    init(_ text: String) {
        let lines = text.components(separatedBy: "\n")
        if lines.first == "---", let close = lines.indices.dropFirst().first(where: { Self.isFence(lines[$0]) }) {
            head = Array(lines[1..<close])
            tail = lines[(close + 1)...].map { "\n" + $0 }.joined()
            fenced = true
        } else {
            head = []
            tail = "\n\n" + text
            fenced = false
        }
    }

    var text: String {
        guard fenced else { return String(tail.dropFirst(2)) }
        return (head.isEmpty ? "---\n---" : "---\n" + head.joined(separator: "\n") + "\n---") + tail
    }

    /// The instructions: what follows the fence, less the one newline that ends it and the blank
    /// line after it. Anything beyond those is the author's and is kept.
    var body: String {
        get {
            var rest = Substring(tail)
            for _ in 0..<2 where rest.first == "\n" { rest = rest.dropFirst() }
            return String(rest)
        }
        set { tail = "\n\n" + newValue }
    }

    // MARK: Reading

    func scalar(_ key: String) -> String? {
        guard let (inline, rest) = value(of: key) else { return nil }
        if let marker = inline.first, marker == ">" || marker == "|" {
            return rest.joined(separator: marker == ">" ? " " : "\n")
        }
        return Self.decode(([inline] + rest).filter { !$0.isEmpty }.joined(separator: " "))
    }

    func bool(_ key: String) -> Bool? {
        switch scalar(key)?.lowercased() {
        case "true": true
        case "false": false
        default: nil
        }
    }

    /// A flow list (`[a, b]`), a block list, or the comma-separated string the parser also takes.
    func list(_ key: String) -> [String]? {
        guard let (inline, rest) = value(of: key) else { return nil }
        if inline.isEmpty { return rest.filter { $0.hasPrefix("-") }.map { Self.decode(String($0.dropFirst()).trimmingCharacters(in: .whitespaces)) } }
        var whole = ([inline] + rest).joined(separator: " ")
        if whole.hasPrefix("[") { whole.removeFirst(); if let close = whole.lastIndex(of: "]") { whole = String(whole[..<close]) } }
        return whole.split(separator: ",").map { Self.decode($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty }
    }

    // MARK: Writing (nil removes the key)

    mutating func set(_ key: String, scalar: String?) { set(key, lines: scalar.map { ["\(key): \(Self.encode($0))"] }) }
    mutating func set(_ key: String, bool: Bool?) { set(key, lines: bool.map { ["\(key): \($0)"] }) }
    mutating func set(_ key: String, list: [String]?) {
        set(key, lines: list.map { ["\(key): [\($0.map(Self.encode).joined(separator: ", "))]"] })
    }

    private mutating func set(_ key: String, lines: [String]?) {
        if lines != nil { fenced = true }
        if let range = region(of: key) { head.replaceSubrange(range, with: lines ?? []) }
        else if let lines { head.append(contentsOf: lines) }
    }

    // MARK: YAML

    private static func isFence(_ line: String) -> Bool {
        line.hasPrefix("---") && line.dropFirst(3).allSatisfy { $0 == " " || $0 == "\r" }
    }

    private static func isContinuation(_ line: String) -> Bool {
        line.first == " " || line.first == "\t" || line.hasPrefix("- ") || line == "-"
    }

    /// The key's line and the lines that belong to it: indented text, block-list items, and the
    /// blank lines between them.
    private func region(of key: String) -> Range<Int>? {
        guard let start = head.firstIndex(where: { $0.hasPrefix(key + ":") }) else { return nil }
        var end = start + 1
        while end < head.count {
            if head[end].allSatisfy(\.isWhitespace) {
                var next = end
                while next < head.count, head[next].allSatisfy(\.isWhitespace) { next += 1 }
                guard next < head.count, Self.isContinuation(head[next]) else { break }
                end = next
            } else if Self.isContinuation(head[end]) { end += 1 } else { break }
        }
        return start..<end
    }

    private func value(of key: String) -> (inline: String, rest: [String])? {
        guard let range = region(of: key) else { return nil }
        let inline = head[range.lowerBound].dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces)
        return (inline, head[(range.lowerBound + 1)..<range.upperBound].map { $0.trimmingCharacters(in: .whitespaces) })
    }

    private static func decode(_ raw: String) -> String {
        if raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\""),
           let value = try? JSONDecoder().decode(String.self, from: Data(raw.utf8)) { return value }
        if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if let comment = raw.range(of: " #") { return String(raw[..<comment.lowerBound]).trimmingCharacters(in: .whitespaces) }
        return raw
    }

    /// Plain when YAML would read it back as the same string, double-quoted otherwise.
    private static func encode(_ value: String) -> String {
        let reserved: Set<String> = ["true", "false", "null", "yes", "no", "on", "off", "y", "n", "~"]
        if value.range(of: #"^[A-Za-z_][A-Za-z0-9_./-]*$"#, options: .regularExpression) != nil, !reserved.contains(value.lowercased()) { return value }
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return (try? encoder.encode(value)).flatMap { String(data: $0, encoding: .utf8) } ?? "\"\""
    }
}
