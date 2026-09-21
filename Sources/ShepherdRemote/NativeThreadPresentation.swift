import Foundation
import ShepherdProtocol

// Pure derivations shared by the desktop and iOS native views. Nothing here
// touches the store, the protocol, or the extension: it only reads a snapshot's
// messages and turns them into row/pill/duration text.

/// One tool call as a scannable row: glyph · name · preview · result · duration.
public struct NativeToolRow: Equatable, Sendable {
    public enum State: Equatable, Sendable { case running, done, failed }
    public enum Tone: Equatable, Sendable { case success, danger, muted }
    public struct Result: Equatable, Sendable {
        public var text: String
        public var tone: Tone
        public init(_ text: String, tone: Tone) { self.text = text; self.tone = tone }
    }

    public var name: String
    public var state: State
    /// Primary preview in the text color: a path, a command, a quoted pattern.
    public var preview: String
    /// Muted tail after the preview: `:237–396` for a read range, ` in Sources/` for grep.
    public var previewSuffix: String?
    public var diff: NativeDiffStat?
    public var results: [Result]
    /// Saved output (text blocks joined). Empty means the row cannot expand.
    public var output: String
    /// Raw JSON arguments for the ⌥-click "Show call" popover; never shown inline.
    public var arguments: String?
    public var truncated: Bool

    public var expandable: Bool { !output.isEmpty }

    /// "read, DesktopNativeThreadView.swift, 160 lines, done"
    public var accessibilityLabel: String {
        var parts = [name, preview + (previewSuffix ?? "")]
        if let diff { parts.append("+\(diff.added) −\(diff.removed)") }
        parts += results.map(\.text)
        switch state {
        case .running: parts.append("running")
        case .done: parts.append("done")
        case .failed: parts.append("failed")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ", ")
    }
}

public struct NativeDiffStat: Equatable, Sendable {
    public var added: Int
    public var removed: Int
    public var blocks: Int
    public init(added: Int, removed: Int, blocks: Int) {
        self.added = added; self.removed = removed; self.blocks = blocks
    }

    /// Line counts per edit as a multiset difference: lines that only disappear
    /// count as removed, lines that only appear count as added. Moved lines cancel.
    public init(edits: [(old: String, new: String)]) {
        var added = 0, removed = 0
        for edit in edits {
            var counts: [Substring: Int] = [:]
            func lines(_ text: String) -> [Substring] { text.isEmpty ? [] : text.split(separator: "\n", omittingEmptySubsequences: false) }
            for line in lines(edit.old) { counts[line, default: 0] += 1 }
            for line in lines(edit.new) { counts[line, default: 0] -= 1 }
            for value in counts.values { if value > 0 { removed += value } else { added -= value } }
        }
        self.init(added: added, removed: removed, blocks: edits.count)
    }
}

public extension NativeToolRow {
    init(_ message: NativeThreadMessage) {
        let name = message.toolName ?? "result"
        let args = message.argumentsText.flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        let output = message.blocks.filter { $0.kind == .text }.map(\.text).joined(separator: "\n")
        let failed = message.isError == true
        let state: State = failed ? .failed : message.status == "running" || message.status == "streaming" ? .running : .done
        func string(_ key: String) -> String? { (args?[key] as? String).flatMap { $0.isEmpty ? nil : $0 } }
        func int(_ key: String) -> Int? { (args?[key] as? NSNumber)?.intValue }
        let firstLine = output.split(whereSeparator: \.isNewline).first(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty })
            .map { String($0.prefix(120)) } ?? ""
        let lineCount = output.isEmpty ? 0 : output.split(separator: "\n", omittingEmptySubsequences: false).count

        var preview = ""
        var suffix: String?
        var diff: NativeDiffStat?
        var results: [Result] = []
        switch name {
        case "read", "write":
            preview = string("path") ?? firstLine
            if name == "read", let offset = int("offset") {
                suffix = int("limit").map { ":\(offset)–\(offset + $0 - 1)" } ?? ":\(offset)–"
            }
            if name == "read", !failed, lineCount > 0 { results.append(Result("\(lineCount) line\(lineCount == 1 ? "" : "s")", tone: .muted)) }
        case "edit":
            preview = string("path") ?? firstLine
            var edits: [(old: String, new: String)] = []
            if let list = args?["edits"] as? [[String: Any]] {
                edits = list.compactMap { edit in
                    guard let old = edit["oldText"] as? String, let new = edit["newText"] as? String else { return nil }
                    return (old, new)
                }
            } else if let old = string("oldText"), let new = args?["newText"] as? String {
                edits = [(old, new)]
            }
            if !edits.isEmpty, !failed {
                let stat = NativeDiffStat(edits: edits)
                diff = stat
                results.append(Result("\(stat.blocks) block\(stat.blocks == 1 ? "" : "s")", tone: .muted))
            }
        case "bash", "powershell":
            preview = string("command").flatMap { $0.split(whereSeparator: \.isNewline).first.map(String.init) } ?? firstLine
            if failed {
                if let code = capture(#"Command exited with code (\d+)"#, in: output) {
                    results.append(Result("exit \(code)", tone: .danger))
                } else {
                    results.append(Result("failed", tone: .danger))
                }
            } else if output.contains("BUILD SUCCEEDED") {
                results.append(Result("BUILD SUCCEEDED", tone: .success))
            } else if let count = capture(#"(\d+) (?:tests? |checks? )?passed"#, in: output) {
                results.append(Result("\(count) passed", tone: .success))
            } else if let count = capture(#"(\d+) files? changed"#, in: output) {
                results.append(Result("\(count) file\(count == "1" ? "" : "s") changed", tone: .success))
            }
        case "grep":
            preview = string("pattern").map { "\"\($0)\"" } ?? firstLine
            suffix = " in " + (string("path") ?? ".")
            if !failed {
                let count = output.hasPrefix("No matches") ? 0 : lineCount
                results.append(Result("\(count) match\(count == 1 ? "" : "es")", tone: .muted))
            }
        case "find", "glob":
            preview = string("pattern") ?? firstLine
            suffix = " in " + (string("path") ?? ".")
            if !failed, lineCount > 0 { results.append(Result("\(lineCount) file\(lineCount == 1 ? "" : "s")", tone: .muted)) }
        case "ls":
            preview = string("path") ?? "."
        default:
            // Spec §5 says unknown tools show the first output line; we prefer an obvious action
            // field first (a URL beats "<html>") and fall back to output. The 120-char cap is the spec's.
            preview = ["command", "path", "query", "url", "pattern"].compactMap(string).first ?? firstLine
        }
        if failed, results.isEmpty { results.append(Result("failed", tone: .danger)) }
        self.init(name: name, state: state, preview: String(preview.prefix(120)), previewSuffix: suffix, diff: diff,
                  results: results, output: output, arguments: message.argumentsText, truncated: message.truncated)
    }
}

/// First capture group of `pattern` in `text`, or nil.
private func capture(_ pattern: String, in text: String) -> String? {
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
          let range = Range(match.range(at: 1), in: text) else { return nil }
    return String(text[range])
}

/// "10.2s" under a minute (integers while live), then "1m 04s", then "1h 02m".
public func nativeDurationText(_ seconds: Double, live: Bool = false) -> String {
    let seconds = max(0, seconds)
    if seconds < 60 {
        if live { return "\(Int(seconds))s" }
        let text = String(format: "%.1f", seconds)
        return (text.hasSuffix(".0") ? String(text.dropLast(2)) : text) + "s"
    }
    let whole = Int(seconds)
    if whole < 3600 { return String(format: "%dm %02ds", whole / 60, whole % 60) }
    return String(format: "%dh %02dm", whole / 3600, (whole % 3600) / 60)
}

/// The header pill and sidebar dot share this state; see spec §6.
public enum NativeAgentPill: Equatable, Sendable {
    case idle, running, needsApproval, error, stopped

    public var label: String {
        switch self {
        case .idle: return "Idle"
        case .running: return "Running"
        case .needsApproval: return "Needs approval"
        case .error: return "Error"
        case .stopped: return "Stopped"
        }
    }
}

public func nativeAgentPill(running: Bool, awaitingAnswer: Bool, error: Bool, stopped: Bool = false) -> NativeAgentPill {
    if error { return .error }
    if awaitingAnswer { return .needsApproval }
    if running { return .running }
    if stopped { return .stopped }
    return .idle
}

/// Consecutive non-user messages form one agent turn.
public struct NativeTurn: Identifiable, Equatable, Sendable {
    public var id: String
    public var isUser: Bool
    public var messages: [NativeThreadMessage]
}

public func nativeTurns(_ messages: [NativeThreadMessage]) -> [NativeTurn] {
    var turns: [NativeTurn] = []
    for message in messages {
        let isUser = message.role == "user"
        if let last = turns.last, last.isUser == isUser {
            turns[turns.count - 1].messages.append(message)
        } else {
            turns.append(NativeTurn(id: message.entryID, isUser: isUser, messages: [message]))
        }
    }
    return turns
}

/// An agent turn flattened into renderable items. Consecutive tool calls collapse
/// into one group; a prose block between them splits the group.
public enum NativeTurnItem: Equatable, Sendable {
    case thinking(String)
    case prose(String)
    case tools([NativeThreadMessage])
    /// Compaction and branch summaries, or an image that cannot render natively.
    case note(String)
}

public func nativeTurnItems(_ messages: [NativeThreadMessage]) -> [NativeTurnItem] {
    var items: [NativeTurnItem] = []
    for message in messages {
        if message.toolName != nil || message.role == "toolResult" {
            if case .tools(let group) = items.last {
                items[items.count - 1] = .tools(group + [message])
            } else {
                items.append(.tools([message]))
            }
            continue
        }
        for block in message.blocks {
            switch block.kind {
            case .thinking: items.append(.thinking(block.text))
            case .unsupportedImage: items.append(.note("Image · open Terminal to view"))
            case .text:
                if message.role == "assistant" || message.role == "user" {
                    items.append(.prose(block.text))
                } else {
                    items.append(.note(message.role.replacingOccurrences(of: "_", with: " ") + " · " + block.text))
                }
            }
        }
        if message.truncated { items.append(.note("Output truncated · full text in Terminal")) }
    }
    return items
}

/// "6 tool calls · read 1 · edit 3 · bash 2" for the phone's collapsed group.
public func nativeToolGroupSummary(_ messages: [NativeThreadMessage]) -> String {
    var order: [String] = []
    var counts: [String: Int] = [:]
    for message in messages {
        let name = message.toolName ?? "result"
        if counts[name] == nil { order.append(name) }
        counts[name, default: 0] += 1
    }
    let total = messages.count
    let head = "\(total) tool call\(total == 1 ? "" : "s")"
    return ([head] + order.map { "\($0) \(counts[$0]!)" }).joined(separator: " · ")
}

/// Head-truncate a path so the filename survives: "…pp/DesktopNativeThreadView.swift".
public func nativeHeadTruncated(_ path: String, max: Int) -> String {
    guard path.count > max, max > 1 else { return path }
    return "…" + path.suffix(max - 1)
}

/// Label for the persistent tail indicator while the agent runs: the running tool wins,
/// then a thinking block that is still streaming, otherwise plain work.
public func nativeWorkingLabel(_ provisional: [NativeThreadMessage]) -> String {
    if let tool = provisional.last(where: { $0.toolName != nil && $0.status == "running" })?.toolName {
        return "Running \(tool)…"
    }
    if let last = provisional.last(where: { $0.role == "assistant" })?.blocks.last, last.kind == .thinking {
        return "Thinking…"
    }
    return "Working…"
}

// MARK: Sticky scroll

/// bb's sticky-bottom rule as a value: follow the tail until the user scrolls away, re-stick
/// once they return to within `threshold` of the bottom. Programmatic growth never detaches.
public struct NativeScrollFollower: Equatable, Sendable {
    public static let threshold: Double = 4
    public var sticky = true
    /// Set for the duration of a wheel/drag gesture (or shortly after a wheel tick).
    public var userScrolling = false
    /// Content grew while detached; cleared on re-stick.
    public var unseen = false

    public init(sticky: Bool = true, userScrolling: Bool = false, unseen: Bool = false) {
        self.sticky = sticky
        self.userScrolling = userScrolling
        self.unseen = unseen
    }

    /// One scroll-geometry observation. `userIntent` ORs the stored gesture flag with any
    /// caller-side intent (a recent wheel event); `contentGrew` is the content height rising.
    public mutating func observe(distanceFromBottom: Double, userIntent: Bool = false, contentGrew: Bool = false) {
        if distanceFromBottom <= Self.threshold {
            sticky = true
            unseen = false
            return
        }
        if userIntent || userScrolling { sticky = false }
        if !sticky, contentGrew { unseen = true }
    }

    /// The user asked for the tail (jump pill, send): stick and forget what was missed.
    public mutating func jumpToLatest() {
        sticky = true
        unseen = false
    }

    /// The pill shows while detached and something is happening or already happened below.
    public func showsJump(running: Bool) -> Bool { !sticky && (running || unseen) }
}

// MARK: Markdown blocks

public enum NativeMarkdownBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case list(ordered: Bool, start: Int, items: [NativeMarkdownListItem])
    case quote(String)
    case code(String)
    case rule
}

public struct NativeMarkdownListItem: Equatable, Sendable {
    public var text: String
    /// One level of nesting: a sub-list, or a fenced block indented under the item.
    public var children: [NativeMarkdownBlock]
    public init(text: String, children: [NativeMarkdownBlock] = []) {
        self.text = text
        self.children = children
    }
}

/// Small block parser for agent prose: headings, lists (one nested level), blockquotes,
/// fenced code, rules, paragraphs. Inline Markdown stays inside each block's text for the
/// renderer. Fences keep their contents literal and an unclosed fence runs to the end.
public func nativeMarkdownBlocks(_ text: String) -> [NativeMarkdownBlock] {
    var blocks: [NativeMarkdownBlock] = []
    var paragraph: [String] = []
    var quote: [String] = []
    var list: (ordered: Bool, start: Int, items: [NativeMarkdownListItem])?
    var child: (ordered: Bool, start: Int, items: [NativeMarkdownListItem])?
    var listBreak = false

    func flushParagraph() {
        if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
        paragraph = []
    }
    func flushQuote() {
        if !quote.isEmpty { blocks.append(.quote(quote.joined(separator: "\n"))) }
        quote = []
    }
    func flushChild() {
        guard let nested = child, list != nil, !list!.items.isEmpty else { child = nil; return }
        list!.items[list!.items.count - 1].children.append(.list(ordered: nested.ordered, start: nested.start, items: nested.items))
        child = nil
    }
    func flushList() {
        flushChild()
        if let list, !list.items.isEmpty { blocks.append(.list(ordered: list.ordered, start: list.start, items: list.items)) }
        list = nil
        listBreak = false
    }
    func flushAll() { flushParagraph(); flushQuote(); flushList() }
    func appendContinuation(_ text: String) {
        let separator = listBreak ? "\n\n" : "\n"
        if child != nil, !child!.items.isEmpty {
            child!.items[child!.items.count - 1].text += separator + text
        } else if list != nil, !list!.items.isEmpty {
            list!.items[list!.items.count - 1].text += separator + text
        }
        listBreak = false
    }

    let lines = text.components(separatedBy: "\n")
    var index = 0
    while index < lines.count {
        let line = lines[index]
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        let indent = line.prefix(while: { $0 == " " }).count
        let fence = String(trimmed.prefix(while: { $0 == "`" }))

        if fence.count >= 3 {
            var body: [String] = []
            var next = index + 1
            var closed = false
            while next < lines.count {
                let candidate = lines[next].trimmingCharacters(in: .whitespaces)
                let marker = String(candidate.prefix(while: { $0 == "`" }))
                if marker.count >= fence.count, candidate == marker { closed = true; break }
                let lead = lines[next].prefix(while: { $0 == " " }).count
                body.append(String(lines[next].dropFirst(min(indent, lead))))
                next += 1
            }
            let code = NativeMarkdownBlock.code(body.joined(separator: "\n"))
            if list != nil, !list!.items.isEmpty, indent >= 2 {
                // Indented under an item: the fence belongs to that item, contents stay literal.
                flushChild()
                list!.items[list!.items.count - 1].children.append(code)
                listBreak = false
            } else {
                flushAll()
                blocks.append(code)
            }
            index = closed ? next + 1 : next
            continue
        }
        index += 1

        if trimmed.isEmpty {
            flushParagraph()
            flushQuote()
            if list != nil { listBreak = true }
            continue
        }
        if trimmed.count >= 3, let first = trimmed.first, "-*_".contains(first),
           trimmed.allSatisfy({ $0 == first || $0 == " " }) {
            flushAll()
            blocks.append(.rule)
            continue
        }
        let hashes = trimmed.prefix(while: { $0 == "#" }).count
        if (1...6).contains(hashes), trimmed.dropFirst(hashes).first == " " {
            flushAll()
            blocks.append(.heading(level: hashes, text: trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)))
            continue
        }
        if trimmed.hasPrefix(">") {
            flushParagraph()
            flushList()
            quote.append(String(trimmed.dropFirst(trimmed.hasPrefix("> ") ? 2 : 1)))
            continue
        }
        if let item = nativeListItem(trimmed) {
            flushParagraph()
            flushQuote()
            if list == nil {
                list = (item.ordered, item.number, [])
            } else if indent < 2 {
                if list!.ordered != item.ordered || list!.items.isEmpty { flushList(); list = (item.ordered, item.number, []) }
            } else {
                if child == nil || child!.ordered != item.ordered { flushChild(); child = (item.ordered, item.number, []) }
                child!.items.append(NativeMarkdownListItem(text: item.text))
                listBreak = false
                continue
            }
            flushChild()
            list!.items.append(NativeMarkdownListItem(text: item.text))
            listBreak = false
            continue
        }
        if list != nil, !list!.items.isEmpty, !listBreak || indent >= 2 {
            appendContinuation(trimmed)
            continue
        }
        flushQuote()
        flushList()
        paragraph.append(line)
    }
    flushAll()
    return blocks
}

/// "- item", "* item", "+ item", "3. item", "3) item" → marker kind, number, and text.
private func nativeListItem(_ trimmed: String) -> (ordered: Bool, number: Int, text: String)? {
    if let first = trimmed.first, "-*+".contains(first) {
        let rest = trimmed.dropFirst()
        guard rest.first == " " else { return nil }
        return (false, 1, rest.trimmingCharacters(in: .whitespaces))
    }
    let digits = trimmed.prefix(while: \.isNumber)
    guard !digits.isEmpty, digits.count <= 9, let number = Int(digits) else { return nil }
    let rest = trimmed.dropFirst(digits.count)
    guard let punct = rest.first, punct == "." || punct == ")", rest.dropFirst().first == " " else { return nil }
    return (true, number, rest.dropFirst().trimmingCharacters(in: .whitespaces))
}
