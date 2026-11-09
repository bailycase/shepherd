import Foundation
import ShepherdProtocol

/// Calls whose result has not come yet, by id. A result takes and removes its own; calls never answered are capped at `limit`,
/// the oldest dropped, so a long thread holds no more than that.
struct OpenCalls<Value> {
    static var limit: Int { 512 }
    private var calls: [String: (value: Value, serial: Int)] = [:]
    /// Calls in the order they were opened, from `head`. One taken by its result stays until the next compaction.
    private var order: [(id: String, serial: Int)] = []
    private var head = 0
    private var serial = 0

    var count: Int { calls.count }

    func value(for id: String) -> Value? { calls[id]?.value }

    mutating func open(_ id: String, _ value: Value) {
        serial += 1
        calls[id] = (value, serial)
        order.append((id, serial))
        if calls.count > Self.limit { dropOldest() }
        if order.count > 3 * Self.limit {
            order.removeSubrange(..<head)
            head = 0
            order.removeAll { calls[$0.id]?.serial != $0.serial }
        }
    }

    mutating func take(_ id: String) -> Value? { calls.removeValue(forKey: id)?.value }

    private mutating func dropOldest() {
        while head < order.count {
            let oldest = order[head]
            head += 1
            if calls[oldest.id]?.serial == oldest.serial {
                calls[oldest.id] = nil
                return
            }
        }
    }
}

extension RPCThreadState {
    /// pi's transcript as thread rows, in slices: appending a slice gives exactly the rows those messages take after everything
    /// appended before, as one `projectHistory` over the whole list would, and sizes pi's context alongside. A value whose tables
    /// grow with the history: its owner moves it and never copies it while appending.
    struct HistoryProjector {
        /// Messages appended so far, hidden ones included: the next one's position (`m:<index>`).
        private(set) var count = 0
        /// How often each entry key was given out (the `#n` of a repeat).
        private var seen: [String: Int] = [:]
        /// A call's arguments and the time of the message that made it, until its result is appended.
        private var openCalls = OpenCalls<(arguments: JSONValue?, time: Double?)>()
        private(set) var estimator = ContextEstimator()

        static var openCallLimit: Int { OpenCalls<Void>.limit }
        var openCallCount: Int { openCalls.count }

        /// Whether the thread never shows `message`: pi's structured system prompt, a custom message its extension did not mark
        /// for display, and a child's report (the card and ledger own that).
        static func isHidden(_ message: RPCMessage) -> Bool {
            switch message.role {
            case "system": true
            case "custom": message.display != true || message.customType == "shepherd-child"
            default: false
            }
        }

        /// The messages of `messages` that history shows, in order, each with the entry id `append` would give it. `seen` is read
        /// through a local overlay: the projector is not copied and not changed.
        func shown(_ messages: [RPCMessage]) -> [(entryID: String, message: RPCMessage)] {
            var added: [String: Int] = [:]
            return messages.enumerated().compactMap { offset, message in
                guard !Self.isHidden(message) else { return nil }
                guard let key = RPCThreadState.historyEntryKey(message) else { return ("m:\(count + offset)", message) }
                let repeats = seen[key, default: 0] + added[key, default: 0]
                added[key, default: 0] += 1
                return (RPCThreadState.historyEntryID(key: key, repeats: repeats), message)
            }
        }

        /// Appends `messages` (pi's order, after what was appended) and returns their rows, nested rows included.
        mutating func append(_ messages: [RPCMessage], sentReferences: [String: [String]] = [:],
                             images: [String: ThreadImages.Meta] = [:],
                             adjust: (inout NativeThreadMessage, RPCMessage) -> Void = { _, _ in }) -> [NativeThreadMessage] {
            var rows: [NativeThreadMessage] = []
            rows.reserveCapacity(messages.count)
            for message in messages {
                let index = count
                count += 1
                // The estimator reads an id only for a tool result and a compaction, which are never hidden.
                guard !Self.isHidden(message) else {
                    estimator.add(message, entryID: "m:\(index)")
                    continue
                }
                let entryID = RPCThreadState.historyEntryID(message, index: index, seen: &seen)
                if message.role == "assistant" {
                    for case .toolCall(let id, _, let arguments) in message.content {
                        let earlier = openCalls.value(for: id)
                        openCalls.open(id, (arguments ?? earlier?.arguments, message.timestamp ?? earlier?.time))
                    }
                }
                let call = message.role == "toolResult" ? message.toolCallId.flatMap { openCalls.take($0) } : nil
                var row = RPCThreadState.project(entryID: entryID, message: message, args: call?.arguments,
                                                 sentReferences: sentReferences[entryID], images: images)
                if message.role == "toolResult", message.toolCallId != nil { row.startedAt = call?.time }
                adjust(&row, message)
                rows.append(row)
                rows.append(contentsOf: RPCThreadState.nestedRows(message, parentEntryID: entryID, adjust: adjust))
                estimator.add(message, entryID: entryID)
            }
            return rows
        }
    }

    /// `estimate(_:)`'s pass over pi's messages, kept between slices: adding the messages of a list one after another gives the
    /// estimate of the whole list.
    struct ContextEstimator {
        private var result = ContextEstimate()
        private var sections: [String: String] = [:]
        private var tools: [String: Int] = [:]
        private var systemText = 0
        private var calls = OpenCalls<(name: String, args: JSONValue?)>()
        /// The tool results by what they read or ran, in the order first seen, with the size of the largest of each.
        private var items: [(item: NativeContextItem, best: Int)] = []
        private var itemIndex: [String: Int] = [:]
        private var visible = 0
        private var baselineTaken = false

        var openCallCount: Int { calls.count }

        /// `entryID` is the message's id in history; it is read for a tool result and a compaction summary only.
        mutating func add(_ message: RPCMessage, entryID: String) {
            switch message.role {
            case "system":
                for (name, value) in message.sections ?? [:] {
                    if let value { sections[name] = value } else { sections[name] = nil }
                }
                for tool in message.toolsRemoved ?? [] { if let name = tool["name"]?.stringValue { tools[name] = nil } }
                for tool in message.toolsAdded ?? [] { if let name = tool["name"]?.stringValue { tools[name] = RPCThreadState.jsonLength(tool) } }
                systemText += message.content.reduce(0) { sum, block in if case .text(let text) = block { sum + text.utf8.count } else { sum } }
                sizeThePrompt()
            case "toolResult":
                let sized = RPCThreadState.size(message)
                result.toolResults += sized.toolResults
                result.images += sized.images
                visible += sized.total
                let call = message.toolCallId.flatMap { calls.take($0) }
                let item = RPCThreadState.contextItem(entryID: entryID, toolName: message.toolName ?? call?.name, args: call?.args,
                                                      tokens: sized.toolResults)
                let key = "\(item.kind.rawValue):\(item.label)"
                if let index = itemIndex[key] {
                    items[index].item.tokens += sized.toolResults
                    if sized.toolResults > items[index].best { items[index].item.entryID = entryID; items[index].best = sized.toolResults }
                } else {
                    itemIndex[key] = items.count
                    items.append((item, sized.toolResults))
                }
            case "compactionSummary", "branchSummary":
                let sized = RPCThreadState.tokens(message.summary?.utf8.count ?? 0)
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
                for case .toolCall(let id, let name, let args) in message.content { calls.open(id, (name, args)) }
                let sized = RPCThreadState.size(message)
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

        /// The estimate of what was added. The largest tool results come from one pass, largest first, ties in the order first seen.
        func estimate() -> ContextEstimate {
            var estimate = result
            var largest: [NativeContextItem] = []
            for entry in items {
                let place = largest.firstIndex { $0.tokens < entry.item.tokens } ?? largest.endIndex
                guard place < NativeContextItem.limit else { continue }
                largest.insert(entry.item, at: place)
                if largest.count > NativeContextItem.limit { largest.removeLast() }
            }
            estimate.largest = largest
            return estimate
        }

        /// What the system prompt, the tools and the instruction files add up to, which only a system message changes.
        private mutating func sizeThePrompt() {
            var rest = sections
            let project = rest.removeValue(forKey: "project_context") ?? ""
            let addendum = rest.removeValue(forKey: "addendum") ?? ""
            result.instructions = RPCThreadState.tokens(project.utf8.count + addendum.utf8.count)
            result.instructionFiles = RPCThreadState.instructionFiles(project)
            var instructionParts = RPCThreadState.instructionFileSizes(project)
            if !addendum.isEmpty {
                instructionParts.append(NativeContextPart(label: "APPEND_SYSTEM.md", tokens: RPCThreadState.tokens(addendum.utf8.count)))
            }
            result.instructionParts = instructionParts.sorted { $0.tokens > $1.tokens }
            // What the prompt and the tools are made of: the prompt's sections (the skills list apart), and the tools by group.
            var parts: [String: Int] = [:]
            for (name, text) in rest { parts[name == "skills" ? "skills" : "pi · system prompt", default: 0] += text.utf8.count }
            if systemText > 0 { parts["pi · system prompt", default: 0] += systemText }
            for (name, length) in tools { parts[ContextToolGroups.label(forTool: name), default: 0] += length }
            let partTokens = parts.mapValues { RPCThreadState.tokens($0) }
            result.system = partTokens.values.reduce(0, +)
            result.systemParts = partTokens.filter { $0.value > 0 }.map { NativeContextPart(label: $0.key, tokens: $0.value) }
                .sorted { $0.tokens != $1.tokens ? $0.tokens > $1.tokens : $0.label < $1.label }
        }
    }
}
