import Foundation
import ShepherdProtocol

/// A thread read from pi's session file on disk, shown while the agent's pi starts: the newest
/// page of history, the model, and the thinking level, as pi's first snapshot will have them.
/// History entries carry the ids pi's answer will (`RPCThreadState.historyEntryID`), so when that
/// answer replaces this one the rows stay where they are.
///
/// Only the end of the file is read: a session runs to tens of megabytes, and the newest page
/// sits in its last megabyte. From the newest entry (pi's leaf on resume) the reader follows
/// `parentId` back, as pi does, until it has a page or reaches the start of what pi keeps (the
/// session's first entry, or a compaction and the entries it kept), reading further back when
/// the page is not in the window. Lines it cannot parse are skipped. The page is approximate by
/// design: anything pi projects differently (a branch, an edit to an older entry) is corrected
/// when pi answers.
public enum PiSessionPreview {
    /// `generation` of every preview snapshot. pi's own snapshots carry a UUID.
    public static let generation = "preview"
    /// The window the reader starts from, at the end of the file. It grows fourfold while the
    /// page reaches back past it, up to `maxWindow`.
    static let initialWindow = 1 << 20
    static let maxWindow = 64 << 20
    /// Entries beyond the page it keeps walking for: a tool result's call (its arguments and
    /// start) comes before it.
    static let contextMargin = 8
    /// How much of the head it reads for a model or thinking level the tail does not have (pi
    /// writes them as a session's first entries).
    static let headBytes = 64 * 1024

    /// The newest page of the thread in pi's session `file`; nil when the file is missing or is
    /// not a pi session.
    public static func snapshot(file: URL, sessionID: String) -> NativeThreadSnapshot? {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd(), size > 0 else { return nil }
        try? handle.seek(toOffset: 0)
        let head = (try? handle.read(upToCount: headBytes)) ?? Data()
        let headLines = head.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true)
        guard let first = headLines.first,
              let header = try? decoder.decode(Entry.self, from: first), header.type == "session" else { return nil }

        var window = min(Int(size), initialWindow)
        while true {
            let start = Int(size) - window
            try? handle.seek(toOffset: UInt64(start))
            guard var data = try? handle.readToEnd() else { return nil }
            // A window that starts mid-line drops the partial line.
            if start > 0 {
                guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return nil }
                data = data[data.index(after: newline)...]
            }
            let walk = walk(data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true))
            if !walk.complete, start > 0, window < maxWindow {
                window = min(Int(size), window * 4, maxWindow)
                continue
            }
            return snapshot(walk, head: headLines, sessionID: sessionID, moreBefore: !walk.reachedStart)
        }
    }

    /// A thread known to have nothing in it yet (a new agent), with the model and thinking level
    /// its pi is launched with, when known.
    public static func empty(sessionID: String, model: String?, thinking: String?) -> NativeThreadSnapshot {
        base(sessionID: sessionID, model: model, thinking: thinking)
    }

    // MARK: - Reading

    private static let decoder = JSONDecoder()

    /// One session entry: only what the thread needs.
    struct Entry: Decodable {
        let type: String
        let id: String?
        let parentId: String?
        let timestamp: String?
        let message: RPCMessage?
        /// An assistant message's provider and model.
        let author: Author?
        // custom_message
        let customType: String?
        let content: CustomContent?
        let display: Bool?
        // compaction and branch_summary
        let summary: String?
        let firstKeptEntryId: String?
        let systemMessage: RPCMessage?
        // model_change and thinking_level_change
        let provider: String?
        let modelId: String?
        let thinkingLevel: String?
        // context_edit
        let targetId: String?
        let replacement: Replacement??

        struct Author: Decodable {
            let provider: String?
            let model: String?
        }

        struct Replacement: Decodable {
            let content: CustomContent?
        }

        /// A string or content blocks.
        struct CustomContent: Decodable {
            let blocks: [RPCContentBlock]
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let text = try? container.decode(String.self) {
                    blocks = [.text(text)]
                } else {
                    blocks = (try? container.decode([RPCContentBlock].self)) ?? []
                }
            }
        }

        enum CodingKeys: String, CodingKey {
            case type, id, parentId, timestamp, message, customType, content, display, summary, firstKeptEntryId,
                 systemMessage, provider, modelId, thinkingLevel, targetId, replacement
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try c.decodeIfPresent(String.self, forKey: .type) ?? ""
            id = try? c.decodeIfPresent(String.self, forKey: .id)
            parentId = try? c.decodeIfPresent(String.self, forKey: .parentId)
            timestamp = try? c.decodeIfPresent(String.self, forKey: .timestamp)
            message = try? c.decodeIfPresent(RPCMessage.self, forKey: .message)
            author = message?.role == "assistant" ? try? c.decodeIfPresent(Author.self, forKey: .message) : nil
            customType = try? c.decodeIfPresent(String.self, forKey: .customType)
            content = try? c.decodeIfPresent(CustomContent.self, forKey: .content)
            display = try? c.decodeIfPresent(Bool.self, forKey: .display)
            summary = try? c.decodeIfPresent(String.self, forKey: .summary)
            firstKeptEntryId = try? c.decodeIfPresent(String.self, forKey: .firstKeptEntryId)
            systemMessage = try? c.decodeIfPresent(RPCMessage.self, forKey: .systemMessage)
            provider = try? c.decodeIfPresent(String.self, forKey: .provider)
            modelId = try? c.decodeIfPresent(String.self, forKey: .modelId)
            thinkingLevel = try? c.decodeIfPresent(String.self, forKey: .thinkingLevel)
            targetId = try? c.decodeIfPresent(String.self, forKey: .targetId)
            if c.contains(.replacement) {
                replacement = .some(try? c.decodeIfPresent(Replacement.self, forKey: .replacement))
            } else {
                replacement = .none
            }
        }
    }

    /// The entries of pi's current path found in a window, oldest first.
    struct Walk {
        var path: [Entry] = []
        /// The path reached the session's first entry, or the start of what a compaction kept.
        var reachedStart = false
        /// The path has a page (or reached its start): no need to read further back.
        var complete = false
    }

    /// Follows the path from the newest entry back through `lines` (oldest first), as pi does
    /// from its leaf, and stops once it holds a page or reaches the start of pi's context.
    static func walk(_ lines: [Data.SubSequence]) -> Walk {
        var result = Walk()
        var wanted: String?
        var started = false
        var visible = 0
        /// Set at the newest compaction on the path: its kept entries follow it back to here.
        var keptFrom: String?
        var reversed: [Entry] = []
        for line in lines.reversed() {
            guard let entry = try? decoder.decode(Entry.self, from: line), let id = entry.id, entry.type != "session" else { continue }
            if !started {
                started = true
            } else if id != wanted {
                continue
            }
            reversed.append(entry)
            wanted = entry.parentId
            if entry.type == "compaction", keptFrom == nil {
                keptFrom = entry.firstKeptEntryId
            }
            if entry.type == "message" || entry.type == "custom_message" { visible += 1 }
            if let keptFrom, id == keptFrom {
                result.reachedStart = true
                break
            }
            if wanted == nil {
                result.reachedStart = true
                break
            }
            if visible >= RPCThreadState.pageSize + contextMargin { break }
        }
        result.complete = result.reachedStart || visible >= RPCThreadState.pageSize + contextMargin
        result.path = reversed.reversed()
        return result
    }

    /// pi's context messages for a path: messages, custom messages, summaries, with context
    /// edits applied (as pi's `buildSessionProjection` does).
    static func messages(_ path: [Entry]) -> [RPCMessage] {
        var edits: [String: Entry.Replacement?] = [:]
        for entry in path where entry.type == "context_edit" {
            if let target = entry.targetId, let replacement = entry.replacement { edits[target] = replacement }
        }
        let newestCompaction = path.lastIndex { $0.type == "compaction" }
        // The newest compaction comes first in pi's context, then what it kept, then what followed.
        var ordered = path
        if let newestCompaction {
            let compaction = path[newestCompaction]
            // The walk stops at the first kept entry, or earlier with a page in hand: then all it
            // found before the compaction was kept.
            var kept = path[..<newestCompaction]
            if let from = compaction.firstKeptEntryId, let index = kept.firstIndex(where: { $0.id == from }) {
                kept = kept[index...]
            } else if path.first?.parentId == nil {
                kept = []
            }
            ordered = [compaction] + kept.filter { !($0.type == "message" && $0.message?.role == "system") }
                + path[(newestCompaction + 1)...]
        }
        var result: [RPCMessage] = []
        for (index, entry) in ordered.enumerated() {
            var messages: [RPCMessage]
            switch entry.type {
            case "message":
                messages = entry.message.map { [$0] } ?? []
            case "custom_message":
                messages = [RPCMessage(role: "custom", content: entry.content?.blocks ?? [], timestamp: milliseconds(entry.timestamp),
                                       customType: entry.customType, display: entry.display)]
            case "branch_summary" where entry.summary?.isEmpty == false:
                messages = [RPCMessage(role: "branchSummary", content: [], timestamp: milliseconds(entry.timestamp))]
            case "compaction" where index == 0 && newestCompaction != nil:
                messages = (entry.systemMessage.map { [$0] } ?? [])
                    + [RPCMessage(role: "compactionSummary", content: [], timestamp: milliseconds(entry.timestamp))]
            default:
                messages = []
            }
            if let id = entry.id, let edit = edits[id] {
                guard let replacement = edit else { continue }
                messages = messages.map { message in
                    guard ["user", "assistant", "toolResult", "custom"].contains(message.role) else { return message }
                    var edited = message
                    edited.content = replacement.content?.blocks ?? []
                    return edited
                }
            }
            result += messages
        }
        return result
    }

    /// The model and thinking level pi resumes with: the newest on the path, else the newest in
    /// the head of the file (where pi writes a session's first ones).
    static func settings(_ path: [Entry], head: [Data.SubSequence]) -> (model: String?, thinking: String?) {
        var model: String?
        var thinking: String?
        func take(_ entry: Entry) {
            if model == nil {
                if entry.type == "model_change", let provider = entry.provider, let id = entry.modelId {
                    model = "\(provider)/\(id)"
                } else if entry.type == "message", let author = entry.author, let provider = author.provider, let id = author.model {
                    model = "\(provider)/\(id)"
                }
            }
            if thinking == nil, entry.type == "thinking_level_change" { thinking = entry.thinkingLevel }
        }
        for entry in path.reversed() { take(entry) }
        if model == nil || thinking == nil {
            for line in head.dropFirst().reversed() {
                guard let entry = try? decoder.decode(Entry.self, from: line) else { continue }
                take(entry)
            }
        }
        return (model, thinking)
    }

    private static func snapshot(_ walk: Walk, head: [Data.SubSequence], sessionID: String, moreBefore: Bool) -> NativeThreadSnapshot {
        let settings = settings(walk.path, head: head)
        var value = base(sessionID: sessionID, model: settings.model, thinking: settings.thinking)
        let history = RPCThreadState.projectHistory(messages(walk.path))
        RPCThreadState.fillPage(&value, from: history, end: history.count, moreBefore: moreBefore)
        return value
    }

    private static func base(sessionID: String, model: String?, thinking: String?) -> NativeThreadSnapshot {
        NativeThreadSnapshot(
            piSessionID: sessionID, generation: generation, revision: 0, running: false, model: model, thinking: thinking,
            supportedActions: RPCThreadState.supportedActions, dialogsSupported: true, dialogs: [], widgets: [],
            messages: [], provisional: [], clipped: false, runtime: "rpc"
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    /// pi's ISO timestamp in milliseconds, as `new Date(timestamp).getTime()` gives it.
    static func milliseconds(_ iso: String?) -> Double? {
        guard let iso, let date = isoFormatter.date(from: iso) else { return nil }
        return (date.timeIntervalSince1970 * 1000).rounded()
    }
}
