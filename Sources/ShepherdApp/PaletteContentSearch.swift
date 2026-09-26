import Foundation
import ShepherdCore
import ShepherdProtocol

/// Searches agents' pi session transcripts for palette queries, so a thread
/// is findable by remembered conversation text, not just its title.
///
/// Only what was said counts: the text of user and assistant messages. The session header,
/// pi's system prompt and tool definitions, thinking, tool calls and their results, and the
/// JSON around it all are never matched, or every agent would match "new" or "read".
///
/// Fast because it is bounded: only each agent's *current* session file, only
/// the trailing `tailBudget` bytes of it (recent conversation is what people
/// remember), and only for queries of 3+ characters, debounced by the caller.
/// A line is decoded only when its raw text contains the query. Runs off the
/// main actor; results carry a short match snippet for display.
///
/// Shared by the Mac palette and the host's answer to a remote `agentQuery(.search)`.
enum PaletteContentSearch {
    static let minQueryLength = 3
    /// Bytes read from the end of each session file. 512KB covers days of
    /// conversation; a full-history index is deliberately out of scope.
    static let tailBudget = 512 * 1024
    /// Characters of context a snippet keeps before and after the match.
    static let snippetLead = 30
    static let snippetTrail = 40

    struct Match: Sendable {
        let agentID: AgentID
        let snippet: String
    }

    /// The session file pi is writing for `piSessionID` in `cwd`, resolved
    /// the same way PiSessionFile names them (any timestamp prefix).
    static func sessionFile(piSessionID: String, cwd: String) -> URL? {
        let directory = PiSessionFile.projectDirectory(forCwd: cwd)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else {
            return nil
        }
        return names.first { $0.hasSuffix("_\(piSessionID).jsonl") }
            .map { directory.appendingPathComponent($0) }
    }

    /// Case-insensitive substring search across the given agents' sessions.
    static func search(
        query: String,
        agents: [(id: AgentID, piSessionID: String, cwd: String)]
    ) -> [Match] {
        guard query.count >= minQueryLength else { return [] }
        return agents.compactMap { agent in
            guard let url = sessionFile(piSessionID: agent.piSessionID, cwd: agent.cwd),
                  let snippet = snippet(for: query, inSessionAt: url) else { return nil }
            return Match(agentID: agent.id, snippet: snippet)
        }
    }

    /// A snippet of the newest conversation text in the tail of the session file at `url` that
    /// contains `query`, or nil when nothing said there does.
    static func snippet(for query: String, inSessionAt url: URL, tailBudget: Int = tailBudget) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(tailBudget) ? size - UInt64(tailBudget) : 0
        try? handle.seek(toOffset: offset)
        guard var data = try? handle.readToEnd(), !data.isEmpty else { return nil }
        // A tail that starts mid-line drops the partial line.
        if offset > 0 {
            guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
            data = data[data.index(after: newline)...]
        }
        return snippet(for: query, inSessionLines: data)
    }

    /// A snippet of the newest user or assistant text in `lines` (pi session JSONL) that
    /// contains `query`.
    static func snippet(for query: String, inSessionLines lines: Data) -> String? {
        guard !query.isEmpty else { return nil }
        // One scan over the whole tail finds the lines holding the query, newest first; only
        // those are decoded. pi writes JSON with only quotes, backslashes and control characters
        // escaped, so a query without them appears verbatim in any line whose text holds it. A
        // query with them decodes every line.
        let text = NSString(data: lines, encoding: NSUTF8StringEncoding) ?? String(decoding: lines, as: UTF8.self) as NSString
        let verbatim = !query.unicodeScalars.contains { $0 == "\"" || $0 == "\\" || $0.value < 0x20 }
        var upper = text.length
        while upper > 0 {
            var location = upper - 1
            if verbatim {
                let hit = text.range(of: query, options: [.caseInsensitive, .backwards], range: NSRange(location: 0, length: upper))
                guard hit.location != NSNotFound else { return nil }
                location = hit.location
            }
            let before = text.range(of: "\n", options: .backwards, range: NSRange(location: 0, length: location))
            let lineStart = before.location == NSNotFound ? 0 : before.location + 1
            let after = text.range(of: "\n", range: NSRange(location: location, length: text.length - location))
            let lineEnd = after.location == NSNotFound ? text.length : after.location
            let line = text.substring(with: NSRange(location: lineStart, length: lineEnd - lineStart))
            if let snippet = snippet(for: query, inSessionLine: line) { return snippet }
            upper = lineStart
        }
        return nil
    }

    /// A snippet of the match in one session line's user or assistant text.
    private static func snippet(for query: String, inSessionLine line: String) -> String? {
        guard let entry = try? decoder.decode(Entry.self, from: Data(line.utf8)), entry.type == "message",
              let message = entry.message, message.role == "user" || message.role == "assistant" else { return nil }
        for (index, raw) in (message.content?.texts ?? []).enumerated() {
            // A design view record fenced ahead of a user's message is pi's to read, not theirs.
            let text = index == 0 && message.role == "user" ? DesignViewRecord.strippingFence(from: raw) : raw
            if let range = text.range(of: query, options: .caseInsensitive) {
                return snippet(around: range, in: text)
            }
        }
        return nil
    }

    /// A one-line excerpt around the match, cut at word boundaries, with `…` where it was cut.
    static func snippet(around range: Range<String.Index>, in text: String) -> String {
        var start = text.index(range.lowerBound, offsetBy: -snippetLead, limitedBy: text.startIndex) ?? text.startIndex
        var end = text.index(range.upperBound, offsetBy: snippetTrail, limitedBy: text.endIndex) ?? text.endIndex
        if start > text.startIndex, !text[text.index(before: start)].isWhitespace, let space = text[start..<range.lowerBound].firstIndex(where: \.isWhitespace) {
            start = text.index(after: space)
        }
        if end < text.endIndex, !text[end].isWhitespace, let space = text[range.upperBound..<end].lastIndex(where: \.isWhitespace) {
            end = space
        }
        let excerpt = text[start..<end].split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return (start > text.startIndex ? "…" : "") + excerpt + (end < text.endIndex ? "…" : "")
    }

    // MARK: - Reading

    private static let decoder = JSONDecoder()

    /// One session entry: only a message's role and its text.
    private struct Entry: Decodable {
        let type: String?
        let message: Message?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            message = try? c.decodeIfPresent(Message.self, forKey: .message)
        }

        enum CodingKeys: String, CodingKey { case type, message }
    }

    private struct Message: Decodable {
        let role: String?
        let content: Content?

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            role = try? c.decodeIfPresent(String.self, forKey: .role)
            content = try? c.decodeIfPresent(Content.self, forKey: .content)
        }

        enum CodingKeys: String, CodingKey { case role, content }
    }

    /// A message's text: a plain string, or its `text` blocks (never thinking, tool calls or
    /// images).
    private struct Content: Decodable {
        let texts: [String]

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let text = try? container.decode(String.self) {
                texts = [text]
            } else {
                texts = ((try? container.decode([Block].self)) ?? []).compactMap { $0.type == "text" ? $0.text : nil }
            }
        }
    }

    private struct Block: Decodable {
        let type: String?
        let text: String?

        init(from decoder: Decoder) throws {
            let c = try? decoder.container(keyedBy: CodingKeys.self)
            type = try? c?.decodeIfPresent(String.self, forKey: .type)
            text = try? c?.decodeIfPresent(String.self, forKey: .text)
        }

        enum CodingKeys: String, CodingKey { case type, text }
    }
}
