import Foundation
import ShepherdProtocol

/// Thread rows with the longest words real agents leave in them, one kind of row per case, in the
/// wire form the host serves (`NativeThreadMessage`): a prose paragraph with a path and a link that
/// cannot break, a table, a code line, activity lines whose label names boards, pages or systems, calls
/// whose arguments are one long JSON string, failures that name long paths, a compaction, a question,
/// a steer, a user message with an unbroken word. Layout tests and the previews draw them through
/// the same store and formatters as a live thread, at every width a thread meets, so a row that
/// cannot shrink to its column shows in all of them (docs/design/thread.md › Activity lines).
public enum LongThreads {
    public static let longPath = "Sources/ShepherdApp/Designs/withdrawals/mobile/approve/withdrawals-mobile-approve-with-a-long-name.dc.html"
    public static let childID = "native-48c1466f-3255-4d0a-9c1e-5b7f1e2a6b10"
    public static let boards = ["withdrawals-mobile-approve", "withdrawals-desktop-approve", "withdrawals-claims-details"]
    public static let longURL = "http://localhost:5173/checkout/withdrawals/mobile/approve/review/summary/details/claims/overview?step=3&tab=claims"
    public static let longWord = "Supercalifragilisticexpialidocious_withdrawals_mobile_approve_review_summary_details_claims_overview_0123456789"

    /// One kind of row: the messages of a conversation that holds it.
    public struct Row: Sendable, CustomStringConvertible {
        public var name: String
        /// The user's message and the reply (or messages) holding the row.
        public var messages: [NativeThreadMessage]
        /// The compactions whose summary is open (by entry id).
        public var opensSummaries: [String] = []
        public var description: String { name }
    }

    /// A moment well in the past, so a turn's footer reads a time and nothing is live.
    public static let start: Double = 1_790_000_000_000

    public static func user(_ id: String, _ text: String, at: Double = start, origin: NativeMessageOrigin? = nil) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "user", blocks: [NativeThreadBlock(kind: .text, text: text)], timestamp: at, origin: origin)
    }

    public static func assistant(_ id: String, _ text: String, thinking: String? = nil, at: Double = start + 1_000) -> NativeThreadMessage {
        var blocks: [NativeThreadBlock] = []
        if let thinking { blocks.append(NativeThreadBlock(kind: .thinking, text: thinking)) }
        if !text.isEmpty { blocks.append(NativeThreadBlock(kind: .text, text: text)) }
        return NativeThreadMessage(entryID: id, role: "assistant", blocks: blocks, timestamp: at, thinkingSeconds: thinking == nil ? nil : 4)
    }

    public static func failure(_ id: String, _ text: String, at: Double = start + 1_000) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "assistant", blocks: [NativeThreadBlock(kind: .text, text: text)], status: "error", timestamp: at)
    }

    /// A finished call, as the host serves it: the tool's result with its arguments.
    public static func tool(_ id: String, _ name: String, _ args: [String: Any], output: String = "", error: Bool = false,
                            at: Double = start + 2_000) -> NativeThreadMessage {
        let data = try! JSONSerialization.data(withJSONObject: args, options: [.sortedKeys])
        return NativeThreadMessage(entryID: "t-\(id)", role: "toolResult", blocks: output.isEmpty ? [] : [NativeThreadBlock(kind: .text, text: output)],
                                   toolName: name, toolCallID: id, argumentsText: String(data: data, encoding: .utf8), status: "complete",
                                   isError: error, timestamp: at + 400, startedAt: at)
    }

    public static func compaction(_ id: String, reason: NativeCompactionReason, at: Double = start + 3_000) -> NativeThreadMessage {
        NativeThreadMessage(entryID: id, role: "compactionSummary", blocks: [], timestamp: at,
                            compaction: NativeCompaction(phase: .done, reason: reason, tokensBefore: 263_000, tokensAfter: 50_000, summary: """
                            ## Goal
                            Make Details and Claims plain tabs under the header on \(boards.joined(separator: ", ")).

                            ## Done
                            \(longPath) is drawn; \(longWord) is next.

                            <modified-files>
                            \(longPath)
                            </modified-files>
                            """))
    }

    public static let prompt = "Make Details and Claims plain tabs under the header, like the desktop board."

    /// The rows one after another as one conversation (each its own turn, its ids and times made
    /// distinct), for a thread that draws them all.
    public static func conversation(_ rows: [Row], designChat: Bool = false) -> [NativeThreadMessage] {
        var messages = rows.enumerated().flatMap { index, row in
            row.messages.map { message in
                var message = message
                message.entryID = "\(index):\(message.entryID)"
                message.toolCallID = message.toolCallID.map { "\(index):\($0)" }
                message.timestamp = message.timestamp.map { $0 + Double(index) * 10_000 }
                message.startedAt = message.startedAt.map { $0 + Double(index) * 10_000 }
                return message
            }
        }
        if designChat, let first = messages.indices.first { messages[first].origin = .designComment(id: commentID) }
        return messages
    }

    /// The comment a design chat's first message carries.
    public static let commentID = UUID(uuidString: "6B1B2E0A-6C7E-4A5B-9B53-0D7A7F7E3C11")!

    /// A reply's prose: paragraphs that run long, a path in code and a link that cannot break, a list.
    public static var paragraph: String {
        """
        Details and Claims are now plain tabs below the header, with the status, amount and counterparty moved into one summary row above them. The approve and reject actions stay in the sticky footer so they remain reachable on the phone board, and the mobile board follows the same structure at 390px.

        I kept `\(longPath)` as the source of truth and changed only the markup under `<header>`; \(longURL) is the reference I matched, and \(longWord) is the token it names.

        - Tabs sit 8px under the header and use the system's underline indicator, as in `\(longPath)`.
        - The summary row wraps its three values under 360px instead of truncating them.
        """
    }

    /// Every row kind, each in a conversation of its own.
    public static var rows: [Row] {
        func row(_ name: String, _ messages: [NativeThreadMessage]) -> Row {
            Row(name: name, messages: [user("u", prompt)] + messages)
        }
        let paragraph = Self.paragraph
        let table = """
            | Board | Change | Where |
            | --- | --- | --- |
            | \(boards[0]) | Details and Claims are plain tabs under the header | \(longPath) |
            | \(boards[1]) | The summary row moved above the tabs | \(longURL) |
            """
        let code = "```html\n<nav class=\"tabs\" data-board=\"\(longPath)\" data-reference=\"\(longURL)\" aria-label=\"Details and Claims\">\n</nav>\n```"
        var all: [Row] = [
            row("prose with a path, a link and a long word", [assistant("a", paragraph)]),
            row("a table with long cells", [assistant("a", table)]),
            row("a code line that does not fit", [assistant("a", code)]),
            row("a heading and a quote that do not break", [assistant("a", "## \(longWord)\n\n> \(longURL)\n\nDone.")]),
            row("thinking with a long word", [assistant("a", "Done.", thinking: "**\(longWord)** — checking \(longPath) against \(longURL) before I change anything.")]),
            row("a note", [NativeThreadMessage(entryID: "n", role: "custom", blocks: [NativeThreadBlock(kind: .text, text: "\(longPath) \(longURL)")],
                                               timestamp: start + 1_000)]),
        ]
        // Activity lines: the label's words come from the work (board names, a system, a page), so
        // they are as long as those are.
        all += [
            row("boards updated by name", boards.enumerated().map { index, board in
                tool("e\(index)", "board_edit", ["path": "\(board).dc.html", "edits": [["find": "<div class=\"tabs\">", "replace": "<nav class=\"tabs\">"]]],
                     output: "Edited \(board).dc.html · 1 edit, 1 match\nTags balance, one root.", at: start + 2_000 + Double(index) * 500)
            }),
            row("boards drawn and updated by name", [
                tool("w0", "board_write", ["path": "\(boards[0]).dc.html", "source": "<helmet></helmet>"], output: "Drew \(boards[0]).dc.html\nTags balance, one root."),
                tool("w1", "board_edit", ["path": "\(boards[1]).dc.html", "edits": []], output: "Edited \(boards[1]).dc.html · 1 edit, 1 match", at: start + 3_000),
                tool("w2", "board_write", ["path": "\(boards[2]).dc.html", "source": "<helmet></helmet>"], output: "Drew \(boards[2]).dc.html\nTags balance, one root.", at: start + 4_000),
            ]),
            row("a check against a long system", [
                tool("c", "design_check", [:], output: "Checked against withdrawals-design-system-v2-enterprise-dashboard-tokens · 0 off-system values")]),
            row("a page opened in the Browser", [
                tool("b", "browser_open", ["url": longURL], output: "Opened \(longURL)")]),
            row("an element clicked in the Browser", [
                tool("b", "browser_click", ["selector": "button"], output: "Clicked “Approve every pending withdrawal for the selected claims and notify their owners”")]),
            row("a tool the thread has no verb for", [
                tool("m", "shepherd_child_message", ["id": childID, "message": "Update \(boards[0]).dc.html"],
                     output: #"{"id":"\#(childID)","delivered":true,"queued":false,"state":"running"}"#)]),
            row("a tool with a long name", [
                tool("m", "shepherd_native_children_wait_for_every_helper_to_finish", ["id": childID], output: "done")]),
            row("a render that failed on a long path", [
                tool("r", "board_render", ["path": "\(boards[0]).dc.html", "width": 390],
                     output: "no board at \(boards[0]).dc.html: the canvas holds A.dc.html, B.dc.html and C.dc.html", error: true)]),
            row("a search that failed on a long pattern", [
                tool("s", "board_search", ["text": "menuOpen|has-next-page|width:390px|<table|summary-row|claims-tab|details-tab", "regex": true],
                     output: "invalid regular expression: nothing to repeat at offset 61 in menuOpen|has-next-page", error: true)]),
            row("a read that failed on a long path", [
                tool("x", "read", ["path": longPath], output: "ENOENT: no such file or directory, open '\(longPath)'", error: true)]),
            row("a command that failed", [
                tool("b", "bash", ["command": "swift test --filter \(longWord) --filter \(longWord)"], output: "error: no tests\n\nCommand exited with code 1", error: true)]),
            row("subagents started by name", [
                tool("s0", "shepherd_child_start", ["agent": "withdrawals-mobile-approve-helper", "task": "Draw \(boards[0])"], output: "started"),
                tool("s1", "shepherd_child_start", ["agent": "withdrawals-desktop-approve-helper", "task": "Draw \(boards[1])"], output: "started", at: start + 3_000),
            ]),
        ]
        all += [
            row("a failed request", [failure("e", #"429 {"type":"error","error":{"type":"rate_limit_error","message":"This request would exceed the rate limit for your organization (\#(childID))"},"request_id":"req_011CTwJkXq9P2cE8yM4s7nHdVb3Zs"}"#)]),
            row("a compaction", [assistant("a", "Working."), compaction("c", reason: .threshold), assistant("b", "Picking up from the summary.", at: start + 4_000)]),
            row("a compaction after an overflow", [assistant("a", "Working."), compaction("c", reason: .overflow), assistant("b", "Retrying.", at: start + 4_000)]),
            Row(name: "a compaction with its summary open", messages: [user("u", prompt), assistant("a", "Working."), compaction("c", reason: .threshold)],
                opensSummaries: ["c"]),
            row("a question answered", [
                NativeThreadMessage(entryID: "q:1", role: "question", blocks: [], timestamp: start + 2_000,
                                    question: NativeQuestionRecord(kind: .select, question: "How should I handle \(longPath) and \(longURL)?",
                                                                   answer: "Compare \(longWord), keep what's unique, then go through GitHub", outcome: .answered, askedAt: start + 1_500)),
                assistant("a", "Done.", at: start + 3_000)]),
            row("a message steered in", [
                assistant("a", "Working."),
                NativeThreadMessage(entryID: "s", role: "user", blocks: [NativeThreadBlock(kind: .text, text: "Also \(longWord) \(longURL)")],
                                    timestamp: start + 2_000, origin: .steered),
                assistant("b", "Understood.", at: start + 3_000)]),
        ]
        all.append(Row(name: "a message with a word that does not break", messages: [user("u", "Check \(longWord) and \(longURL) before you start"), assistant("a", "Checking.")]))
        return all
    }
}
