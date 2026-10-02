import Foundation
import ShepherdProtocol
import ShepherdRemote

/// What fills the agent's context window (`NativeThreadContext`) and pi's compactions: the total
/// is pi's (`get_session_stats`), refreshed once per reply and after each compaction; the split
/// and the largest items are the host's estimate from the messages pi holds, taken with history.
/// The estimate sizes each part itself (four characters a token; a screenshot and a reasoning
/// payload at their measured cost) and anchors the fixed part, the system prompt, the tools and
/// the instruction files, to the provider's own count for the first call after a start or a
/// compaction. What the total holds beyond the parts is `Other`, never folded into another part:
/// scaling every part to the total used to make a thread's reasoning payloads and screenshots
/// read as "System prompt and tools". A compaction runs as a live row and lands in history as
/// pi's `compactionSummary`, where it happened. Nothing here writes pi's settings: the
/// auto-compaction switch (`set_auto_compaction`) would write the user's settings.json, so it is only read.
extension RPCThreadState {
    /// The host's sizing of pi's context from its messages, in tokens, before it is held against pi's total.
    struct ContextEstimate: Equatable {
        var system = 0
        var instructions = 0
        var messages = 0
        var toolResults = 0
        /// The arguments of tool calls: the files a `write` or an `edit` carried.
        var toolCalls = 0
        /// Reasoning the provider has sent back with every call.
        var reasoning = 0
        var images = 0
        var instructionFiles: [String] = []
        /// What the system prompt and the tools are made of, and each instruction file, largest first.
        var systemParts: [NativeContextPart] = []
        var instructionParts: [NativeContextPart] = []
        /// The largest tool results, largest first.
        var largest: [NativeContextItem] = []
        /// The compaction pi's context starts from, if any: its entry, summary, and size before.
        var summaryEntryID: String?
        var summary: String?
        var before: Int?
        /// The provider's count of the first call since the start or the latest compaction, and what this
        /// host sizes of all that call carried but the fixed part (the first message, a summary, what was kept).
        var baseline: Baseline?

        struct Baseline: Equatable {
            var prompt: Int
            var visible: Int
        }

        var total: Int { system + instructions + messages + toolResults + toolCalls + reasoning + images }
    }

    /// A screenshot's cost in tokens, measured on real threads (the Read tool on a PNG), and what a
    /// reasoning payload costs per character of its encrypted form is carried by the provider's own
    /// `usage.reasoning`, so no density is assumed here.
    static let imageTokens = 2_100

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
            compactionNotes.append(CompactionNote(summary: summary, reason: reason, result: result))
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
        // Settled-turn filesystem capture gates prompts, not an idle pi's context operation.
        guard !running, dispatches.isEmpty else {
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
        let scaled = estimate.flatMap { Self.scaled($0, to: total) }
        let split = scaled?.split
        let largest = scaled?.largest ?? []
        let auto = autoCompaction ?? settings.enabled
        let next = NativeThreadContext(
            tokens: tokens, window: window,
            autoCompactAt: auto ? window.map { max(0, $0 - settings.reserveTokens) } : nil,
            autoCompact: auto, keepRecent: settings.keepRecentTokens, estimate: estimateAfter,
            before: estimate?.before, split: split, largest: largest, compacting: compactingRun,
            summaryEntryID: estimate?.summaryEntryID)
        if next != context { context = next }
    }

    /// The estimate held against pi's `total`: the fixed part (prompt, tools, instruction files)
    /// anchored to the provider's count of the first call when that is in the history, every other
    /// part as sized, and what is left of `total` as `other`. When the parts add up to more than the
    /// total (a result clipped or cleared before it was sent, which the messages still hold whole),
    /// the difference comes off the parts that can shrink, tool results first, never the fixed ones.
    /// Without a total (no reply yet) the parts stand as sized. nil for an empty estimate.
    static func scaled(_ estimate: ContextEstimate, to total: Int?) -> (split: NativeContextSplit, largest: [NativeContextItem])? {
        guard estimate.total > 0 else { return nil }
        func share(_ value: Int, _ numerator: Int, _ denominator: Int) -> Int {
            denominator > 0 ? Int(reportedCount: (Double(value) * Double(numerator) / Double(denominator)).rounded()) ?? 0 : value
        }
        var system = estimate.system, instructions = estimate.instructions
        var systemParts = estimate.systemParts, instructionParts = estimate.instructionParts
        let fixed = system + instructions
        // The first call of the session (or since a compaction) says what the fixed part cost, once what else
        // it carried is taken off; an answer far from the sizing is a call that carried something unsized.
        if let baseline = estimate.baseline, fixed > 0 {
            let measured = baseline.prompt - baseline.visible
            if measured >= fixed / 2, measured <= fixed * 2, measured != fixed {
                system = share(system, measured, fixed)
                instructions = measured - system
                systemParts = systemParts.map { NativeContextPart(label: $0.label, tokens: share($0.tokens, measured, fixed)) }
                instructionParts = instructionParts.map { NativeContextPart(label: $0.label, tokens: share($0.tokens, measured, fixed)) }
            }
        }
        var messages = estimate.messages, toolResults = estimate.toolResults, toolCalls = estimate.toolCalls
        var reasoning = estimate.reasoning, images = estimate.images
        var other = 0
        var shrink = 1.0
        if let total {
            var excess = system + instructions + messages + toolResults + toolCalls + reasoning + images - total
            if excess <= 0 {
                other = -excess
            } else {
                // Shrinks the first value that can; true when the excess is gone.
                func take(_ value: inout Int) -> Bool {
                    let cut = min(excess, value)
                    value -= cut
                    excess -= cut
                    return excess == 0
                }
                let before = toolResults
                _ = take(&toolResults) || take(&toolCalls) || take(&reasoning) || take(&images) || take(&messages)
                if before > 0 { shrink = Double(toolResults) / Double(before) }
                if excess > 0 {
                    // Even the fixed part is over the total: hold every part to it in proportion.
                    let sum = system + instructions + messages + toolResults + toolCalls + reasoning + images
                    system = share(system, total, sum); instructions = share(instructions, total, sum)
                    messages = share(messages, total, sum); toolResults = share(toolResults, total, sum)
                    toolCalls = share(toolCalls, total, sum); reasoning = share(reasoning, total, sum); images = share(images, total, sum)
                }
            }
        }
        let split = NativeContextSplit(system: system, instructions: instructions, messages: messages, toolResults: toolResults,
                                       instructionFiles: estimate.instructionFiles, toolCalls: toolCalls, reasoning: reasoning,
                                       images: images, other: other, systemParts: systemParts, instructionParts: instructionParts)
        let largest = estimate.largest.map {
            NativeContextItem(entryID: $0.entryID, kind: $0.kind, label: $0.label, tokens: Int(reportedCount: (Double($0.tokens) * shrink).rounded()) ?? 0)
        }
        return (split, largest)
    }

    /// What one message contributes to the context, by part, in tokens.
    struct MessageSize {
        var messages = 0
        var toolResults = 0
        var toolCalls = 0
        var reasoning = 0
        var images = 0

        var total: Int { messages + toolResults + toolCalls + reasoning + images }
    }

    static func tokens(_ chars: Int) -> Int { (chars + 3) / 4 }

    /// A message sized by part: text at four characters a token (pi's own estimate), a screenshot at its
    /// measured cost, a tool call's arguments as JSON, and an assistant message's reasoning as the provider
    /// counted it (`usage.reasoning`; else the thinking text it kept).
    static func size(_ message: RPCMessage) -> MessageSize {
        var size = MessageSize()
        var thinkingChars = 0
        var thought = false
        for block in message.content {
            switch block {
            case .text(let text):
                if message.role == "toolResult" { size.toolResults += tokens(text.utf8.count) } else { size.messages += tokens(text.utf8.count) }
            case .thinking(let text):
                thought = true
                thinkingChars += text.utf8.count
            case .toolCall(_, let name, let args):
                size.toolCalls += tokens(name.utf8.count + (args.map(jsonLength) ?? 2))
            case .image:
                size.images += imageTokens
            case .unknown:
                break
            }
        }
        if thought { size.reasoning = message.usage?.reasoningTokens ?? tokens(thinkingChars) }
        return size
    }

    /// pi's messages as the host sizes them: its structured system prompt (sections and tools) split from
    /// the instruction files it loaded, the conversation by part, tool results with the largest by what
    /// they read or ran, and the provider's count of the first call since the start or a compaction.
    static func estimate(_ messages: [RPCMessage]) -> ContextEstimate {
        var result = ContextEstimate()
        var sections: [String: String] = [:]
        var tools: [String: Int] = [:]
        var systemText = 0
        var calls: [String: (name: String, args: JSONValue?)] = [:]
        var items: [String: (item: NativeContextItem, best: Int)] = [:]
        var order: [String] = []
        var seen: [String: Int] = [:]
        var visible = 0
        var baselineTaken = false
        for (index, message) in chronological(messages).enumerated() {
            let entryID = historyEntryID(message, index: index, seen: &seen)
            switch message.role {
            case "system":
                for (name, value) in message.sections ?? [:] {
                    if let value { sections[name] = value } else { sections[name] = nil }
                }
                for tool in message.toolsRemoved ?? [] { if let name = tool["name"]?.stringValue { tools[name] = nil } }
                for tool in message.toolsAdded ?? [] { if let name = tool["name"]?.stringValue { tools[name] = jsonLength(tool) } }
                systemText += message.content.reduce(0) { sum, block in if case .text(let text) = block { sum + text.utf8.count } else { sum } }
            case "toolResult":
                let sized = size(message)
                result.toolResults += sized.toolResults
                result.images += sized.images
                visible += sized.total
                let call = message.toolCallId.flatMap { calls[$0] }
                let item = contextItem(entryID: entryID, toolName: message.toolName ?? call?.name, args: call?.args, tokens: sized.toolResults)
                let key = "\(item.kind.rawValue):\(item.label)"
                if var existing = items[key] {
                    existing.item.tokens += sized.toolResults
                    if sized.toolResults > existing.best { existing.item.entryID = entryID; existing.best = sized.toolResults }
                    items[key] = existing
                } else {
                    items[key] = (item, sized.toolResults)
                    order.append(key)
                }
            case "compactionSummary", "branchSummary":
                let sized = tokens(message.summary?.utf8.count ?? 0)
                result.messages += sized
                visible += sized
                if message.role == "compactionSummary" {
                    result.summaryEntryID = entryID
                    result.summary = message.summary
                    result.before = message.tokensBefore.flatMap(Int.init(reportedCount:))
                    // What the provider counted before was a bigger context: the next call is the baseline.
                    result.baseline = nil
                    baselineTaken = false
                }
            default:
                for case .toolCall(let id, let name, let args) in message.content { calls[id] = (name, args) }
                let sized = size(message)
                if message.role == "assistant", !baselineTaken, message.stopReason != "aborted", message.stopReason != "error",
                   let prompt = message.usage?.prompt {
                    result.baseline = ContextEstimate.Baseline(prompt: prompt, visible: visible)
                    baselineTaken = true
                }
                result.messages += sized.messages
                result.toolCalls += sized.toolCalls
                result.reasoning += sized.reasoning
                result.images += sized.images
                visible += sized.total
            }
        }
        let project = sections.removeValue(forKey: "project_context") ?? ""
        let addendum = sections.removeValue(forKey: "addendum") ?? ""
        result.instructions = tokens(project.utf8.count + addendum.utf8.count)
        result.instructionFiles = instructionFiles(project)
        var instructionParts = instructionFileSizes(project)
        if !addendum.isEmpty { instructionParts.append(NativeContextPart(label: "APPEND_SYSTEM.md", tokens: tokens(addendum.utf8.count))) }
        result.instructionParts = instructionParts.sorted { $0.tokens > $1.tokens }
        // What the prompt and the tools are made of: the prompt's sections (the skills list apart), and the tools by group.
        var parts: [String: Int] = [:]
        for (name, text) in sections { parts[name == "skills" ? "skills" : "pi · system prompt", default: 0] += text.utf8.count }
        if systemText > 0 { parts["pi · system prompt", default: 0] += systemText }
        for (name, length) in tools { parts[ContextToolGroups.label(forTool: name), default: 0] += length }
        let partTokens = parts.mapValues { tokens($0) }
        result.system = partTokens.values.reduce(0, +)
        result.systemParts = partTokens.filter { $0.value > 0 }.map { NativeContextPart(label: $0.key, tokens: $0.value) }
            .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }
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

    /// Each file `<project_instructions path="…">` holds, by where it is ("instructions/AGENTS.md", "pi/AGENTS.md",
    /// "Shepherd/AGENTS.md": the folder and the name, which tell two AGENTS.md apart), with its size in tokens, the
    /// tags and the section's lead-in counted with the first.
    static func instructionFileSizes(_ section: String) -> [NativeContextPart] {
        var parts: [NativeContextPart] = []
        var counted = 0
        var rest = section[...]
        let open = "<project_instructions path=\""
        let close = "</project_instructions>"
        while let start = rest.range(of: open) {
            let afterOpen = rest[start.upperBound...]
            guard let quote = afterOpen.firstIndex(of: "\"") else { break }
            let path = String(afterOpen[..<quote])
            let end = rest.range(of: close, range: start.lowerBound..<rest.endIndex)?.upperBound ?? rest.endIndex
            let chars = rest[start.lowerBound..<end].utf8.count
            var label = path.split(separator: "/").suffix(2).map(String.init).joined(separator: "/")
            if label.isEmpty { label = path }
            parts.append(NativeContextPart(label: label, tokens: tokens(chars)))
            counted += chars
            rest = rest[end...]
        }
        // The lead-in ("Project-specific instructions and guidelines:") and the section's own tags.
        let extra = section.utf8.count - counted
        if !parts.isEmpty, extra > 0 { parts[0].tokens += tokens(extra) }
        return parts
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

extension RPCThreadState.CompactionNote {
    /// The sizes pi reported with the compaction's result.
    init(summary: String, reason: NativeCompactionReason, result: RPCCompactionResult) {
        self.init(summary: summary, reason: reason, before: result.tokensBefore.flatMap(Int.init(reportedCount:)),
                  after: result.estimatedTokensAfter.flatMap(Int.init(reportedCount:)))
    }
}
