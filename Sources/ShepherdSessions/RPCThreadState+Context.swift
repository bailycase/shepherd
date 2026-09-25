import Foundation
import ShepherdProtocol
import ShepherdRemote

/// What fills the agent's context window (`NativeThreadContext`) and pi's compactions: the total
/// is pi's (`get_session_stats`), refreshed once per reply and after each compaction; the split
/// and the largest items are the host's estimate from the messages pi holds, taken with history
/// and scaled to pi's total. A compaction runs as a live row and lands in history as pi's
/// `compactionSummary`, where it happened. Nothing here writes pi's settings: the auto-compaction
/// switch (`set_auto_compaction`) would write the user's settings.json, so it is only read.
extension RPCThreadState {
    /// The host's sizing of pi's context from its messages, in tokens at four characters a
    /// token (pi's own estimate), before scaling to pi's total.
    struct ContextEstimate: Equatable {
        var system = 0
        var instructions = 0
        var messages = 0
        var toolResults = 0
        var instructionFiles: [String] = []
        /// The largest tool results, largest first.
        var largest: [NativeContextItem] = []
        /// The compaction pi's context starts from, if any: its entry, summary, and size before.
        var summaryEntryID: String?
        var summary: String?
        var before: Int?

        var total: Int { system + instructions + messages + toolResults }
    }

    /// A compaction this host saw finish.
    struct CompactionNote: Equatable {
        var summary: String
        var reason: NativeCompactionReason
        var before: Int?
        var after: Int?
    }

    static let compactionNoteLimit = 16

    // MARK: - Events

    func compactionStarted(reason: NativeCompactionReason) {
        let now = Date().timeIntervalSince1970 * 1000
        let tokens = stats?.contextTokens
        compactingRun = NativeCompactionRun(reason: reason, startedAt: now, tokens: tokens)
        live.removeAll { if case .compaction = $0.kind { true } else { false } }
        let id = "compaction:\(Int64(now))"
        var value = NativeThreadMessage(entryID: id, role: "compaction", blocks: [], timestamp: now)
        value.compaction = NativeCompaction(phase: .running, reason: reason, tokensBefore: tokens)
        live.append(LiveItem(kind: .compaction(id), value: value, raw: nil, ended: false))
        updateContext()
    }

    func compactionEnded(reason: NativeCompactionReason, result: RPCCompactionResult?, aborted: Bool, willRetry: Bool, error: String?) {
        compactingRun = nil
        let index = live.lastIndex { if case .compaction = $0.kind { true } else { false } }
        if let result, let summary = result.summary {
            compactionNotes.append(CompactionNote(summary: summary, reason: reason, before: result.tokensBefore.map { Int($0) },
                                                  after: result.estimatedTokensAfter.map { Int($0) }))
            if compactionNotes.count > Self.compactionNoteLimit { compactionNotes.removeFirst() }
            // History brings the summary where it happened; the live row goes with that refresh.
            if let index {
                live[index].value.compaction?.phase = .done
                live[index].value.compaction?.willRetry = willRetry
                live[index].ended = true
            }
        } else if let index {
            live[index].value.compaction?.phase = aborted ? .stopped : .failed
            live[index].value.compaction?.error = aborted ? nil : error
        }
        updateContext()
        refreshMessages()
        refreshState()
        refreshStats()
    }

    // MARK: - Compact now

    /// pi's `compact`, with what to keep. pi stops a run to compact, so the host takes it only
    /// while pi is idle; the answer is the dispatch (pi reports the compaction as events).
    func compact(instructions: String?, operationID: UUID, completion: @escaping (NativeThreadResult) -> Void) {
        let text = instructions?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (text?.utf8.count ?? 0) <= Self.textLimit else {
            completion(.failure(code: "invalid", message: "What to keep is limited to 16 KiB."))
            return
        }
        guard compactingRun == nil else {
            completion(.failure(code: "busy", message: "The agent is already compacting."))
            return
        }
        guard !piBusy else {
            completion(.failure(code: "busy", message: "Compact once the agent has stopped: compacting ends its turn."))
            return
        }
        guard session.isAlive else {
            completion(.failure(code: "dispatch_failed", message: "pi is not running."))
            return
        }
        session.request(.compact(customInstructions: text?.isEmpty == false ? text : nil), timeout: Self.compactTimeout) { [weak self] result in
            guard let self else { return }
            if case .success(let response) = result, !response.success {
                ShepherdLog.info("rpc session \(self.session.id) compact: \(response.error ?? "refused")")
            }
            self.refreshMessages()
            self.refreshStats()
        }
        completion(.accepted(operationID: operationID))
    }

    // MARK: - The context

    /// Rebuilds `context` from pi's stats and state, the estimate, and a running compaction.
    func updateContext() {
        let model = self.model
        if settingsFor == nil || settingsFor?.model != model {
            settingsFor = (model, compactionSettings(model))
        }
        let settings = settingsFor?.value ?? PiCompactionSettings()
        let window = stats?.contextWindow
        let tokens = stats?.contextTokens
        var estimateAfter: Int?
        if tokens == nil, let estimate, estimate.summaryEntryID != nil {
            // Until pi's next reply: pi's own estimate after the compaction, else ours.
            estimateAfter = compactionNotes.last(where: { $0.summary == estimate.summary })?.after
                ?? (estimate.total > 0 ? estimate.total : nil)
        }
        let total = tokens ?? estimateAfter
        var split: NativeContextSplit?
        var largest: [NativeContextItem] = []
        if let estimate, estimate.total > 0 {
            let scale = total.map { Double($0) / Double(estimate.total) } ?? 1
            func scaled(_ value: Int) -> Int { Int((Double(value) * scale).rounded()) }
            split = NativeContextSplit(system: scaled(estimate.system), instructions: scaled(estimate.instructions),
                                       messages: scaled(estimate.messages), toolResults: scaled(estimate.toolResults),
                                       instructionFiles: estimate.instructionFiles)
            largest = estimate.largest.map { NativeContextItem(entryID: $0.entryID, kind: $0.kind, label: $0.label, tokens: scaled($0.tokens)) }
        }
        let auto = autoCompaction ?? settings.enabled
        let next = NativeThreadContext(
            tokens: tokens, window: window,
            autoCompactAt: auto ? window.map { max(0, $0 - settings.reserveTokens) } : nil,
            autoCompact: auto, keepRecent: settings.keepRecentTokens, estimate: estimateAfter,
            before: estimate?.before, split: split, largest: largest, compacting: compactingRun,
            summaryEntryID: estimate?.summaryEntryID)
        if next != context { context = next }
    }

    /// pi's messages as the host sizes them (four characters a token, as pi estimates): its
    /// structured system prompt (sections and tools) split from the instruction files it
    /// loaded, the conversation, and tool results, with the largest results by what they read
    /// or ran.
    static func estimate(_ messages: [RPCMessage]) -> ContextEstimate {
        var result = ContextEstimate()
        var sections: [String: String] = [:]
        var tools: [String: Int] = [:]
        var systemText = 0
        var calls: [String: (name: String, args: JSONValue?)] = [:]
        var items: [String: (item: NativeContextItem, best: Int)] = [:]
        var order: [String] = []
        var seen: [String: Int] = [:]
        func tokens(_ chars: Int) -> Int { (chars + 3) / 4 }
        func contentChars(_ blocks: [RPCContentBlock]) -> Int {
            blocks.reduce(0) { sum, block in
                switch block {
                case .text(let text): sum + text.utf8.count
                case .thinking(let text): sum + text.utf8.count
                case .toolCall(_, let name, let args): sum + name.utf8.count + (args.map(jsonLength) ?? 2)
                case .image: sum + 4800
                case .unknown: sum
                }
            }
        }
        for (index, message) in chronological(messages).enumerated() {
            let entryID = historyEntryID(message, index: index, seen: &seen)
            switch message.role {
            case "system":
                for (name, value) in message.sections ?? [:] {
                    if let value { sections[name] = value } else { sections[name] = nil }
                }
                for tool in message.toolsRemoved ?? [] { if let name = tool["name"]?.stringValue { tools[name] = nil } }
                for tool in message.toolsAdded ?? [] { if let name = tool["name"]?.stringValue { tools[name] = jsonLength(tool) } }
                systemText += contentChars(message.content)
            case "toolResult":
                let size = tokens(contentChars(message.content))
                result.toolResults += size
                let call = message.toolCallId.flatMap { calls[$0] }
                let item = contextItem(entryID: entryID, toolName: message.toolName ?? call?.name, args: call?.args, tokens: size)
                let key = "\(item.kind.rawValue):\(item.label)"
                if var existing = items[key] {
                    existing.item.tokens += size
                    if size > existing.best { existing.item.entryID = entryID; existing.best = size }
                    items[key] = existing
                } else {
                    items[key] = (item, size)
                    order.append(key)
                }
            case "compactionSummary", "branchSummary":
                result.messages += tokens(message.summary?.utf8.count ?? 0)
                if message.role == "compactionSummary" {
                    result.summaryEntryID = entryID
                    result.summary = message.summary
                    result.before = message.tokensBefore.map { Int($0) }
                }
            default:
                for case .toolCall(let id, let name, let args) in message.content { calls[id] = (name, args) }
                result.messages += tokens(contentChars(message.content))
            }
        }
        let project = sections.removeValue(forKey: "project_context") ?? ""
        result.instructions = tokens(project.utf8.count)
        result.instructionFiles = instructionFiles(project)
        result.system = tokens(sections.values.reduce(systemText) { $0 + $1.utf8.count } + tools.values.reduce(0, +))
        // Largest first; ties keep the thread's order.
        result.largest = order.enumerated()
            .sorted { a, b in
                let (x, y) = (items[a.element]!.item.tokens, items[b.element]!.item.tokens)
                return x != y ? x > y : a.offset < b.offset
            }
            .prefix(NativeContextItem.limit)
            .map { items[$0.element]!.item }
        return result
    }

    /// A tool result named as the Largest list shows it: the file it read or wrote, the command
    /// it ran, or else the tool.
    static func contextItem(entryID: String, toolName: String?, args: JSONValue?, tokens: Int) -> NativeContextItem {
        let name = toolName ?? "tool"
        if let path = args?["path"]?.stringValue ?? args?["file_path"]?.stringValue, !path.isEmpty {
            return NativeContextItem(entryID: entryID, kind: .file, label: (path as NSString).lastPathComponent, tokens: tokens)
        }
        if let command = args?["command"]?.stringValue,
           let line = command.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty {
            return NativeContextItem(entryID: entryID, kind: .command, label: line, tokens: tokens)
        }
        return NativeContextItem(entryID: entryID, kind: .tool, label: name, tokens: tokens)
    }

    /// The files pi's project context holds (`<project_instructions path="…">`), by name.
    static func instructionFiles(_ section: String) -> [String] {
        var names: [String] = []
        var rest = section[...]
        let marker = "<project_instructions path=\""
        while let start = rest.range(of: marker) {
            rest = rest[start.upperBound...]
            guard let end = rest.firstIndex(of: "\"") else { break }
            let name = (String(rest[..<end]) as NSString).lastPathComponent
            if !name.isEmpty, !names.contains(name) { names.append(name) }
            rest = rest[end...]
        }
        return names
    }

    /// About how long `value` is as JSON, without encoding it.
    static func jsonLength(_ value: JSONValue) -> Int {
        switch value {
        case .null: 4
        case .bool(let flag): flag ? 4 : 5
        case .number: 8
        case .string(let text): text.utf8.count + 2
        case .array(let values): values.reduce(2) { $0 + jsonLength($1) + 1 }
        case .object(let fields): fields.reduce(2) { $0 + $1.key.utf8.count + 4 + jsonLength($1.value) }
        }
    }

    // MARK: - History across a compaction

    /// pi lists its latest compaction first, then the messages it kept, then the rest; the
    /// thread shows the compaction where it happened, after the kept messages written before it.
    static func chronological(_ messages: [RPCMessage]) -> [RPCMessage] {
        guard let index = messages.lastIndex(where: { $0.role == "compactionSummary" }),
              let time = messages[index].timestamp else { return messages }
        var end = index + 1
        while end < messages.count, let kept = messages[end].timestamp, kept <= time, messages[end].role != "compactionSummary" { end += 1 }
        guard end > index + 1 else { return messages }
        var ordered = messages
        let summary = ordered.remove(at: index)
        ordered.insert(summary, at: end - 1)
        return ordered
    }

    /// After a compaction pi lists only what it kept; the thread keeps what came before (what
    /// was summarized), readable above the compaction, for as long as this pi runs.
    static func keepingSummarized(previous: [NativeThreadMessage], next: [NativeThreadMessage]) -> [NativeThreadMessage] {
        guard !previous.isEmpty, next.contains(where: { $0.role == "compactionSummary" }) else { return next }
        let known = Dictionary(previous.enumerated().map { ($1.entryID, $0) }, uniquingKeysWith: { first, _ in first })
        if let shared = next.lazy.compactMap({ known[$0.entryID] }).first {
            return shared == 0 ? next : Array(previous[..<shared]) + next
        }
        // Nothing kept that this host had shown: everything it had was summarized.
        return previous + next
    }
}
