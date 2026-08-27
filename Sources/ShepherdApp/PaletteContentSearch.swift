import Foundation
import ShepherdCore

/// Searches agents' pi session transcripts for palette queries, so a thread
/// is findable by remembered conversation text, not just its title.
///
/// Fast because it is bounded: only each agent's *current* session file, only
/// the trailing `tailBudget` bytes of it (recent conversation is what people
/// remember), and only for queries of 3+ characters, debounced by the caller.
/// Runs off the main actor; results carry a short match snippet for display.
enum PaletteContentSearch {
    static let minQueryLength = 3
    /// Bytes read from the end of each session file. 512KB covers days of
    /// conversation; a full-history index is deliberately out of scope.
    static let tailBudget = 512 * 1024

    struct Match: Sendable {
        let agentID: AgentID
        let snippet: String
    }

    /// The session file pi is writing for `piSessionID` in `cwd`, resolved
    /// the same way PiSessionFile names them (any timestamp prefix).
    static func sessionFile(piSessionID: String, cwd: String) -> URL? {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".pi/agent/sessions", isDirectory: true)
            .appendingPathComponent("--\(PiSessionFile.mangled(cwd))--", isDirectory: true)
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
        let needle = query.lowercased()
        guard needle.count >= minQueryLength else { return [] }
        var matches: [Match] = []
        for agent in agents {
            guard let url = sessionFile(piSessionID: agent.piSessionID, cwd: agent.cwd),
                  let handle = try? FileHandle(forReadingFrom: url) else { continue }
            defer { try? handle.close() }
            let size = (try? handle.seekToEnd()) ?? 0
            let offset = size > UInt64(tailBudget) ? size - UInt64(tailBudget) : 0
            try? handle.seek(toOffset: offset)
            guard let data = try? handle.readToEnd(), !data.isEmpty else { continue }
            let text = String(decoding: data, as: UTF8.self).lowercased()
            guard let range = text.range(of: needle) else { continue }
            matches.append(Match(agentID: agent.id, snippet: snippet(around: range, in: text)))
        }
        return matches
    }

    /// A short, cleaned excerpt around the match for the row's subtitle.
    private static func snippet(around range: Range<String.Index>, in text: String) -> String {
        let start = text.index(range.lowerBound, offsetBy: -30, limitedBy: text.startIndex) ?? text.startIndex
        let end = text.index(range.upperBound, offsetBy: 40, limitedBy: text.endIndex) ?? text.endIndex
        let raw = String(text[start..<end])
        // Session lines are JSON; strip the escapes and syntax that would
        // read as noise in a one-line snippet.
        let cleaned = raw
            .replacingOccurrences(of: "\\n", with: " ")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "  ", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return "…\(cleaned)…"
    }
}
