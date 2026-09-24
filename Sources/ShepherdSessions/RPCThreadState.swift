import Dispatch
import Foundation
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

/// The native-thread view of one `RPCSession`, fed by pi's event stream: projection rules,
/// limits, error codes, and operation idempotency behind `SessionServer.nativeThread`, served
/// alike to the desktop, remote, and iOS clients. Confined to the session queue (which targets
/// the server queue).
final class RPCThreadState {
    static let textLimit = 16 * 1024
    static let snapshotLimit = 240 * 1024
    static let activeLimit = 120 * 1024
    static let pageSize = 50
    static let dialogLimit = 8
    static let dialogBytes = 48 * 1024
    /// UI_LIMITS in the extension.
    static let widgetItems = 16
    static let widgetTextBytes = 4096
    static let widgetTitleBytes = 256
    static let widgetAggregateBytes = 32 * 1024
    static let operationTableSize = 256
    static let supportedActions = ["send", "abort", "answer", "setModel", "setThinking", "sendImages", "subagents"]
    /// Bytes of a child session file the transcript reader will scan (tail); older is unreachable.
    static let transcriptReadLimit = 8 * 1024 * 1024

    private struct Provisional {
        let key: Int
        var raw: RPCMessage
        var value: NativeThreadMessage
        var ended: Bool
    }

    private struct Operation {
        let fingerprint: NativeThreadRequest
        var result: NativeThreadResult?
        var waiters: [(NativeThreadResult) -> Void] = []
    }

    private let session: RPCSession
    private let queue: DispatchQueue
    private(set) var piSessionID: String?
    /// How many times the bootstrap has asked pi for its state (more than once: a slow start).
    private(set) var bootstrapAttempts = 0
    /// The bootstrap's `get_messages` has not answered. pi answers it after `get_state`, and a
    /// long history takes a moment to arrive: served meanwhile, a resumed thread would show
    /// as a new, empty one.
    private var historyPending = true
    private(set) var generation = UUID().uuidString
    private(set) var revision: UInt64 = 0
    private var signature = 0
    private(set) var running = false
    private(set) var model: String?
    private(set) var thinking: String?
    private(set) var stats: NativeThreadStats?
    private(set) var commands: [NativeCommand]?
    /// Native child runs as last published by the children extension over the socket.
    private(set) var subagents: [NativeSubagent] = []
    /// Installed by SessionServer: writes a childCommand to the children extension and answers
    /// with its error text (nil on success). Runs on the server queue.
    var dispatchSubagentCommand: ((String, NativeSubagentAction, String?, NativeThreadDelivery?, @escaping (String?) -> Void) -> Void)?
    private var history: [NativeThreadMessage] = []
    private var provisional: [Provisional] = []
    private var sequence = 0
    private var currentAssistant: Int?
    private var tools: [(id: String, value: NativeThreadMessage)] = []
    /// When each tool execution was first seen (ms), for durations of live calls.
    private var toolStarts: [String: Double] = [:]
    /// Live thinking spans per provisional assistant message (ms), and the finished ones keyed
    /// by the message's pi timestamp so history projected later keeps "Thought for Ns".
    private var thinkingSpans: [Int: (start: Double, end: Double?)] = [:]
    private var thinkingByTimestamp: [Double: Double] = [:]
    private var dialogs: [NativeThreadDialog] = []
    private var widgets: [(id: String, value: NativeThreadWidget)] = []
    private var operations: [(id: String, operation: Operation)] = []
    private var projectionClipped = false
    private static let encoder = JSONEncoder()
    private static let ansi = try! NSRegularExpression(
        pattern: "\u{1B}(?:\\[[0-?]*[ -/]*[@-~]|\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)|[@-Z\\\\-_])"
    )

    init(session: RPCSession, queue: DispatchQueue) {
        self.session = session
        self.queue = queue
    }

    /// Populate from a freshly spawned (or resumed) pi. Until `get_state` and `get_messages`
    /// answer, requests are answered `native_starting`. pi reads its stdin only once it has
    /// started, so a pi slower than `timeout` answers requests that already timed out (and are
    /// dropped): ask again.
    func bootstrap(timeout: TimeInterval = 10) {
        bootstrapAttempts += 1
        let attempt = bootstrapAttempts
        refreshState(timeout: timeout) { [weak self] result in
            guard let self, self.piSessionID == nil, case .failure(.timeout) = result, self.session.isAlive else { return }
            ShepherdLog.info("rpc session \(self.session.id) has not started within \(timeout)s; asking again")
            self.bootstrap(timeout: timeout)
        }
        refreshMessages(timeout: timeout) { [weak self] _ in
            // Loaded or not (a history over the record cap never arrives), the thread serves now;
            // an attempt the bootstrap has since repeated waits for the repeat.
            guard let self, attempt == self.bootstrapAttempts else { return }
            self.historyPending = false
        }
        refreshStats(timeout: timeout)
        session.request(.getCommands, timeout: timeout) { [weak self] result in
            guard let self, case .success(let response) = result, response.success else { return }
            self.commands = Self.projectCommands(response.data?["commands"])
            self.commit()
        }
    }

    // MARK: - Events (session queue)

    func handle(_ event: RPCEvent) {
        switch event {
        case .agentStart:
            running = true
        case .agentEnd:
            running = false
            refreshMessages()
            refreshState()
            refreshStats()
        case .agentSettled:
            running = false
        case .messageStart(let message):
            guard message.role == "assistant" else { break }
            sequence += 1
            currentAssistant = sequence
            upsertAssistant(message, ended: false)
        case .messageUpdate(let delta, _):
            guard let key = currentAssistant, let index = provisional.firstIndex(where: { $0.key == key }) else {
                // message_start was missed (spawned mid-turn); start accumulating now.
                sequence += 1
                currentAssistant = sequence
                var raw = RPCMessage(role: "assistant", content: [])
                Self.apply(delta, to: &raw)
                upsertAssistant(raw, ended: false)
                break
            }
            var raw = provisional[index].raw
            Self.apply(delta, to: &raw)
            upsertAssistant(raw, ended: false)
        case .messageEnd(let message):
            guard message.role == "assistant" else { break }
            if currentAssistant == nil {
                sequence += 1
                currentAssistant = sequence
            }
            upsertAssistant(message, ended: true)
            currentAssistant = nil
        case .toolExecutionStart(let id, let name, let args):
            upsertTool(id: id, name: name, args: args, content: [], isError: nil, status: "running")
        case .toolExecutionUpdate(let id, let name, let args, let partial):
            upsertTool(id: id, name: name, args: args, content: partial?.content ?? [], isError: nil, status: "running")
        case .toolExecutionEnd(let id, let name, let result, let isError):
            upsertTool(id: id, name: name, args: nil, content: result?.content ?? [], isError: isError, status: "complete")
        case .extensionUIRequest(let request):
            handleUIRequest(request)
        case .extensionError(let path, let event, let error):
            ShepherdLog.warning("rpc session \(session.id) extension error in \(path ?? "?") (\(event ?? "?")): \(error)")
        case .turnStart, .turnEnd, .queueUpdate, .unknown:
            break
        }
        commit()
    }

    /// Server queue: full replacement from a setAgentChildren publish.
    func setSubagents(_ rows: [ChildRun]) {
        subagents = rows
        commit()
    }

    // MARK: - Requests (server queue)

    func handle(_ request: NativeThreadRequest, completion: @escaping (NativeThreadResult) -> Void) {
        guard let piSessionID, !historyPending else {
            completion(.failure(code: NativeThreadCode.starting, message: "pi is starting."))
            return
        }
        commit()
        switch request {
        case .snapshot(let expectedSessionID, let beforeEntryID, let afterRevision):
            if let expectedSessionID, expectedSessionID != piSessionID {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            if beforeEntryID == nil, afterRevision == revision {
                completion(.unchanged(piSessionID: piSessionID, generation: generation, revision: revision))
                return
            }
            completion(snapshot(beforeEntryID: beforeEntryID))
        case .subagentTranscript(let expectedSessionID, let runID, let beforeEntryID):
            guard expectedSessionID == piSessionID else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            guard let run = subagents.first(where: { $0.runID == runID }), let file = run.sessionFile else {
                completion(.failure(code: "unknown_run", message: "That subagent is no longer listed."))
                return
            }
            completion(Self.transcript(runID: runID, file: file, beforeEntryID: beforeEntryID))
        case .send(let expectedSessionID, let generation, let operationID, _, _, _),
             .abort(let expectedSessionID, let generation, let operationID),
             .answer(let expectedSessionID, let generation, let operationID, _, _),
             .setModel(let expectedSessionID, let generation, let operationID, _),
             .setThinking(let expectedSessionID, let generation, let operationID, _),
             .subagentCommand(let expectedSessionID, let generation, let operationID, _, _, _, _):
            guard expectedSessionID == piSessionID, generation == self.generation else {
                completion(.failure(code: "stale_session", message: "Refresh the thread before acting."))
                return
            }
            let key = operationID.uuidString.uppercased()
            if let index = operations.firstIndex(where: { $0.id == key }) {
                guard operations[index].operation.fingerprint == request else {
                    completion(.failure(code: "operation_conflict", message: "Operation ID was reused with a different payload."))
                    return
                }
                if let result = operations[index].operation.result {
                    completion(result)
                } else {
                    operations[index].operation.waiters.append(completion)
                }
                return
            }
            operations.append((key, Operation(fingerprint: request)))
            if operations.count > Self.operationTableSize { operations.removeFirst() }
            perform(request, operationID: operationID) { [weak self] result in
                guard let self else { completion(result); return }
                guard let index = self.operations.firstIndex(where: { $0.id == key }) else {
                    // Evicted while in flight; still answer this caller.
                    completion(result)
                    return
                }
                self.operations[index].operation.result = result
                let waiters = self.operations[index].operation.waiters
                self.operations[index].operation.waiters = []
                self.revision += 1
                completion(result)
                waiters.forEach { $0(result) }
            }
        }
    }

    private func perform(_ request: NativeThreadRequest, operationID: UUID, completion: @escaping (NativeThreadResult) -> Void) {
        let accepted = NativeThreadResult.accepted(operationID: operationID)
        let dispatchFailed = NativeThreadResult.failure(code: "dispatch_failed", message: "Pi rejected native dispatch. Refresh before acting.")
        let settle: (Result<RPCResponse, RPCError>) -> Void = { result in
            if case .success(let response) = result, response.success {
                completion(accepted)
            } else {
                completion(dispatchFailed)
            }
        }
        switch request {
        case .send(_, _, _, let text, let delivery, let images):
            let images = images ?? []
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.textLimit else {
                completion(.failure(code: "invalid", message: "Send requires text up to 16 KiB and a valid delivery mode."))
                return
            }
            // Per-image cap from the contract; the aggregate keeps one prompt line
            // under RPCSession's 8 MiB stdin queue once base64-expanded.
            guard images.count <= NativeImage.maxPerSend,
                  images.allSatisfy({ $0.data.count <= NativeImage.maxBytes && $0.mimeType.hasPrefix("image/") }),
                  images.reduce(0, { $0 + $1.data.count }) <= 5 * 1024 * 1024 else {
                completion(.failure(code: "invalid", message: "Send accepts up to \(NativeImage.maxPerSend) images of \(NativeImage.maxBytes / 1024 / 1024) MiB each."))
                return
            }
            let behavior: RPCStreamingBehavior? = running ? (delivery == .steer ? .steer : .followUp) : nil
            let rpcImages = images.map { RPCImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType) }
            session.request(.prompt(message: text, images: rpcImages, streamingBehavior: behavior), completion: settle)
        case .abort:
            session.request(.abort, completion: settle)
        case .setModel(_, _, _, let model):
            // "provider/id"; ids may themselves contain "/" so split on the first one only.
            guard let slash = model.firstIndex(of: "/"), slash > model.startIndex, model.index(after: slash) < model.endIndex else {
                completion(.failure(code: "invalid", message: "Model must be provider/id."))
                return
            }
            let provider = String(model[..<slash])
            let id = String(model[model.index(after: slash)...])
            session.request(.setModel(provider: provider, modelId: id)) { [weak self] result in
                settle(result)
                self?.refreshState()
            }
        case .setThinking(_, _, _, let level):
            guard ["off", "low", "medium", "high"].contains(level) else {
                completion(.failure(code: "invalid", message: "Thinking level must be off, low, medium, or high."))
                return
            }
            session.request(.setThinkingLevel(level: level)) { [weak self] result in
                settle(result)
                self?.refreshState()
            }
        case .answer(_, _, _, let dialogID, let answer):
            guard let index = dialogs.firstIndex(where: { $0.id == dialogID }), dialogs[index].unavailable == nil else {
                completion(.failure(code: "dialog_unavailable", message: "Dialog answer not accepted. Refresh the thread."))
                return
            }
            let command: RPCCommand
            switch answer {
            case .select(let value), .input(let value), .editor(let value):
                command = .extensionUIResponse(id: dialogID, value: value)
            case .confirm(let value):
                command = .extensionUIResponse(id: dialogID, confirmed: value)
            case .cancel:
                command = .extensionUIResponse(id: dialogID, cancelled: true)
            }
            // pi never answers extension_ui_response; the write is the dispatch.
            session.send(command)
            dialogs.remove(at: index)
            completion(session.isAlive ? accepted : dispatchFailed)
        case .subagentCommand(_, _, _, let runID, let action, let text, let mode):
            // Unknown runs and empty replies never reach the socket; the dispatch itself is the
            // server's (it owns the children extension's connection).
            guard subagents.contains(where: { $0.runID == runID }) else {
                completion(.failure(code: "unknown_run", message: "That subagent is no longer listed."))
                return
            }
            if action == .message, (text ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (text ?? "").utf8.count > Self.textLimit {
                completion(.failure(code: "invalid", message: "A subagent message needs text up to 16 KiB."))
                return
            }
            guard let dispatchSubagentCommand else { completion(dispatchFailed); return }
            dispatchSubagentCommand(runID, action, text, mode) { error in
                completion(error.map { .failure(code: "child_command_failed", message: $0) } ?? accepted)
            }
        case .snapshot, .subagentTranscript:
            completion(dispatchFailed)
        }
    }

    // MARK: - Subagent transcript

    /// One page of a child's pi session JSONL, projected with the same rules as history.
    /// Entry ids are the session entry ids ("c:<id>"); a stale cursor fails like history paging.
    static func transcript(runID: String, file: String, beforeEntryID: String?) -> NativeThreadResult {
        guard let handle = FileHandle(forReadingAtPath: file) else {
            return .failure(code: "transcript_unavailable", message: "The subagent's session file is not readable.")
        }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()).map(Int.init) ?? 0
        let start = max(0, size - transcriptReadLimit)
        try? handle.seek(toOffset: UInt64(start))
        var data = (try? handle.readToEnd()) ?? Data()
        if start > 0, let newline = data.firstIndex(of: UInt8(ascii: "\n")) { data = data[data.index(after: newline)...] }
        struct Entry: Decodable { let type: String; let id: String?; let message: RPCMessage? }
        let decoder = JSONDecoder()
        var entries: [(id: String, message: RPCMessage)] = []
        for line in data.split(separator: UInt8(ascii: "\n")) {
            guard let entry = try? decoder.decode(Entry.self, from: line), entry.type == "message", let id = entry.id, let message = entry.message else { continue }
            if message.role == "custom" && message.display != true { continue }
            entries.append((id, message))
        }
        var arguments: [String: JSONValue] = [:]
        var callTimes: [String: Double] = [:]
        for entry in entries where entry.message.role == "assistant" {
            for case .toolCall(let id, _, let args) in entry.message.content {
                if let args { arguments[id] = args }
                if let time = entry.message.timestamp { callTimes[id] = time }
            }
        }
        var end = entries.count
        if let beforeEntryID {
            guard let index = entries.firstIndex(where: { "c:\($0.id)" == beforeEntryID }) else {
                return .failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
            }
            end = index
        }
        let pageStart = max(0, end - pageSize)
        let page = entries[pageStart..<end].map { entry in
            let args = entry.message.role == "toolResult" ? entry.message.toolCallId.flatMap { arguments[$0] } : nil
            var value = project(entryID: "c:\(entry.id)", message: entry.message, args: args)
            if entry.message.role == "toolResult" { value.startedAt = entry.message.toolCallId.flatMap { callTimes[$0] } }
            return value
        }
        return .transcript(value: NativeSubagentTranscript(
            runID: runID, messages: page, olderCursor: pageStart > 0 ? page.first?.entryID : nil, earlierCount: pageStart))
    }

    // MARK: - Refresh

    private func refreshState(timeout: TimeInterval = 10, done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        session.request(.getState, timeout: timeout) { [weak self] result in
            defer { done?(result) }
            guard let self, case .success(let response) = result, response.success, let data = response.data else { return }
            if let id = data["sessionId"]?.stringValue, id != self.piSessionID {
                if self.piSessionID != nil { self.resetForNewSession() }
                self.piSessionID = id
            }
            if let m = data["model"], let provider = m["provider"]?.stringValue, let id = m["id"]?.stringValue {
                self.model = "\(provider)/\(id)"
            } else {
                self.model = nil
            }
            self.thinking = data["thinkingLevel"]?.stringValue
            if let streaming = data["isStreaming"]?.boolValue { self.running = streaming }
            self.commit()
        }
    }

    private func refreshMessages(timeout: TimeInterval = 10, done: ((Result<RPCResponse, RPCError>) -> Void)? = nil) {
        session.request(.getMessages, timeout: timeout) { [weak self] result in
            defer { done?(result) }
            guard let self, case .success(let response) = result, response.success,
                  let messages = try? response.data?["messages"]?.decode([RPCMessage].self) else { return }
            // Same filter as the terminal extension: custom messages are model-only unless the
            // extension marked them display (pi-subagents' task-completed JSON is the usual case).
            // Indices stay positional so `m:<i>` cursors remain stable across refreshes.
            // pi keeps a call's arguments on the assistant's toolCall block; the toolResult row
            // is what we show, so hand the arguments across by call id.
            var arguments: [String: JSONValue] = [:]
            var callTimes: [String: Double] = [:]
            for message in messages where message.role == "assistant" {
                for case .toolCall(let id, _, let args) in message.content {
                    if let args { arguments[id] = args }
                    if let time = message.timestamp { callTimes[id] = time }
                }
            }
            self.history = messages.enumerated().compactMap { index, message in
                if message.role == "custom" && message.display != true { return nil }
                // Child reports ("Child native-… (worker): complete … Session: …") restate the card and
                // ledger, which own that information in the RPC thread; the TUI still shows them.
                if message.role == "custom" && message.customType == "shepherd-child" { return nil }
                let args = message.role == "toolResult" ? message.toolCallId.flatMap { arguments[$0] } : nil
                var value = Self.project(entryID: "m:\(index)", message: message, args: args)
                if let id = message.toolCallId, message.role == "toolResult" {
                    value.startedAt = self.toolStarts[id] ?? callTimes[id]
                }
                if message.role == "assistant", let time = message.timestamp { value.thinkingSeconds = self.thinkingByTimestamp[time] }
                return value
            }
            // message_end precedes persistence; a refresh means everything ended is now history.
            self.provisional.removeAll { $0.ended }
            self.tools.removeAll { $0.value.status == "complete" }
            self.commit()
        }
    }

    private func refreshStats(timeout: TimeInterval = 10) {
        session.request(.getSessionStats, timeout: timeout) { [weak self] result in
            guard let self, case .success(let response) = result, response.success, let data = response.data else { return }
            let usage = data["contextUsage"]
            self.stats = NativeThreadStats(
                contextTokens: usage?["tokens"]?.doubleValue.map { Int($0) },
                contextWindow: usage?["contextWindow"]?.doubleValue.map { Int($0) },
                contextPercent: usage?["percent"]?.doubleValue,
                totalTokens: data["tokens"]?["total"]?.doubleValue.map { Int($0) },
                cost: data["cost"]?.doubleValue
            )
            self.commit()
        }
    }

    /// get_commands → capped, byte-limited list. Over-long names are dropped, descriptions clipped.
    static func projectCommands(_ value: JSONValue?) -> [NativeCommand] {
        guard let items = value?.arrayValue else { return [] }
        var result: [NativeCommand] = []
        for item in items {
            guard let name = item["name"]?.stringValue, !name.isEmpty, name.utf8.count <= NativeCommand.maxNameBytes else { continue }
            var description = item["description"]?.stringValue
            if let text = description, text.utf8.count > NativeCommand.maxDescriptionBytes {
                description = String(decoding: Array(text.utf8.prefix(NativeCommand.maxDescriptionBytes)), as: UTF8.self)
            }
            result.append(NativeCommand(name: name, description: description, source: item["source"]?.stringValue))
            if result.count == NativeCommand.maxCount { break }
        }
        return result
    }

    /// pi switched sessions (new_session / switch): nothing from the previous
    /// session may be acted on with the old generation.
    private func resetForNewSession() {
        generation = UUID().uuidString
        operations.removeAll()
        provisional.removeAll()
        tools.removeAll()
        toolStarts.removeAll()
        thinkingSpans.removeAll()
        thinkingByTimestamp.removeAll()
        widgets.removeAll()
        history.removeAll()
        currentAssistant = nil
        projectionClipped = false
        signature = 0
        revision += 1
    }

    // MARK: - Provisional items

    private func upsertAssistant(_ raw: RPCMessage, ended: Bool) {
        guard let key = currentAssistant else { return }
        var value = Self.project(entryID: "provisional:assistant:\(key)", message: raw)
        value.status = ended ? (raw.stopReason ?? "complete") : "streaming"
        let now = Date().timeIntervalSince1970 * 1000
        var hasThinking = false, answered = false
        for block in raw.content {
            switch block {
            case .thinking: hasThinking = true
            case .text(let text) where !text.isEmpty: answered = true
            case .toolCall: answered = true
            default: break
            }
        }
        if hasThinking, thinkingSpans[key] == nil { thinkingSpans[key] = (now, nil) }
        if var span = thinkingSpans[key], span.end == nil, answered || ended {
            span.end = now
            thinkingSpans[key] = span
        }
        if let span = thinkingSpans[key] {
            let seconds = ((span.end ?? now) - span.start) / 1000
            value.thinkingSeconds = seconds
            if ended, let time = raw.timestamp { thinkingByTimestamp[time] = seconds }
        }
        if let index = provisional.firstIndex(where: { $0.key == key }) {
            provisional[index] = Provisional(key: key, raw: raw, value: value, ended: ended)
        } else {
            provisional.append(Provisional(key: key, raw: raw, value: value, ended: ended))
        }
        if provisional.count > Self.pageSize {
            provisional.removeFirst()
            projectionClipped = true
        }
    }

    private func upsertTool(id: String, name: String, args: JSONValue?, content: [RPCContentBlock], isError: Bool?, status: String) {
        let previous = tools.first { $0.id == id }?.value
        var value = Self.project(
            entryID: "provisional:tool:\(id)",
            message: RPCMessage(role: "toolResult", content: content, toolName: name, toolCallId: id, isError: isError),
            args: args
        )
        if value.argumentsText == nil { value.argumentsText = previous?.argumentsText }
        value.status = status
        if toolStarts[id] == nil { toolStarts[id] = Date().timeIntervalSince1970 * 1000 }
        value.startedAt = toolStarts[id]
        if status == "complete", value.timestamp == nil { value.timestamp = Date().timeIntervalSince1970 * 1000 }
        if let index = tools.firstIndex(where: { $0.id == id }) {
            tools[index].value = value
        } else {
            tools.append((id, value))
        }
        if tools.count > Self.pageSize {
            tools.removeFirst()
            projectionClipped = true
        }
    }

    static func apply(_ delta: RPCAssistantDelta, to message: inout RPCMessage) {
        guard let index = delta.contentIndex, index >= 0 else { return }
        while message.content.count <= index { message.content.append(.text("")) }
        switch delta.type {
        case "text_start":
            message.content[index] = .text("")
        case "text_delta":
            if case .text(let text) = message.content[index] {
                message.content[index] = .text(text + (delta.delta ?? ""))
            } else {
                message.content[index] = .text(delta.delta ?? "")
            }
        case "text_end":
            if let content = delta.content { message.content[index] = .text(content) }
        case "thinking_start":
            message.content[index] = .thinking("")
        case "thinking_delta":
            if case .thinking(let text) = message.content[index] {
                message.content[index] = .thinking(text + (delta.delta ?? ""))
            } else {
                message.content[index] = .thinking(delta.delta ?? "")
            }
        case "thinking_end":
            if let content = delta.content { message.content[index] = .thinking(content) }
        case "toolcall_start":
            message.content[index] = .toolCall(id: delta.id ?? "", name: delta.toolName ?? "", arguments: nil)
        case "toolcall_end":
            if let call = delta.toolCall { message.content[index] = call }
        default:
            break
        }
    }

    // MARK: - Dialogs and widgets

    private func handleUIRequest(_ request: RPCExtensionUIRequest) {
        switch request.method {
        case "select", "confirm", "input", "editor":
            guard let kind = NativeThreadDialog.Kind(rawValue: request.method) else { return }
            var dialog = NativeThreadDialog(
                id: request.id, kind: kind, title: request.title ?? "", options: request.options,
                message: request.message, placeholder: request.placeholder, prefill: request.prefill, timeout: request.timeout
            )
            if Self.bytes(dialog) > Self.dialogBytes {
                dialog = NativeThreadDialog(id: request.id, kind: kind, title: "Dialog too large for native thread", unavailable: "payload-limit")
            }
            dialogs.removeAll { $0.id == request.id }
            dialogs.append(dialog)
            if let timeout = request.timeout, timeout > 0 {
                // pi auto-resolves on its side; we only stop showing it.
                queue.asyncAfter(deadline: .now() + .milliseconds(Int(timeout))) { [weak self] in
                    guard let self else { return }
                    self.dialogs.removeAll { $0.id == request.id }
                    self.commit()
                }
            }
        case "setWidget":
            guard let key = request.widgetKey else { return }
            let text = request.widgetLines.map { $0.map(Self.stripANSI).joined(separator: "\n") }
            // Some extensions publish machine payloads for their own TUI component
            // (pi-subagents: "PI_SUBAGENT_ASYNC_JSON:{…}"). Those are not for people.
            if let text, Self.isMachineWidget(text) { setWidget(nil, key: key); return }
            setWidget(text.map { NativeThreadWidget(namespace: "pi", key: key, kind: .text, text: $0) }, key: key)
        case "notify":
            // A TUI toast ("Ponytail loaded: full", "Task queued"). The native thread has no
            // toast surface and the message rarely matters after the moment; dropping it beats
            // parking it above the composer.
            break
        default:
            // setStatus is the TUI footer slot (ponytail, goal, codex-fast park persistent
            // chrome there), not conversation content; setTitle / set_editor_text likewise.
            break
        }
    }

    /// nil clears. Over-limit items are dropped with a log line, never fatal.
    /// `UPPER_SNAKE:` marker prefixes and bare JSON objects/arrays are machine widgets.
    static func isMachineWidget(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("{") || trimmed.hasPrefix("[") { return true }
        guard let colon = trimmed.firstIndex(of: ":") else { return false }
        let marker = trimmed[..<colon]
        return marker.count >= 4 && marker.allSatisfy { $0.isUppercase || $0 == "_" || $0.isNumber }
    }

    private func setWidget(_ item: NativeThreadWidget?, key: String) {
        let id = "pi\u{0}\(key)"
        guard let item else {
            widgets.removeAll { $0.id == id }
            return
        }
        guard !key.isEmpty, key.utf8.count <= 128 else {
            ShepherdLog.warning("rpc session \(session.id) widget key rejected (1–128 bytes)")
            return
        }
        guard item.text.utf8.count <= Self.widgetTextBytes, (item.title ?? "").utf8.count <= Self.widgetTitleBytes else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: text exceeds \(Self.widgetTextBytes) bytes or title exceeds \(Self.widgetTitleBytes)")
            return
        }
        let existing = widgets.firstIndex { $0.id == id }
        guard existing != nil || widgets.count < Self.widgetItems else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: at most \(Self.widgetItems) items")
            return
        }
        var next = widgets.filter { $0.id != id }
        next.append((id, item))
        guard Self.bytes(next.map(\.value)) <= Self.widgetAggregateBytes else {
            ShepherdLog.warning("rpc session \(session.id) widget '\(key)' dropped: items exceed the \(Self.widgetAggregateBytes)-byte budget")
            return
        }
        widgets = next
    }

    static func stripANSI(_ text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        return ansi.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    // MARK: - Snapshot

    private func commit() {
        var hasher = Hasher()
        hasher.combine(history.count)
        hasher.combine(provisional.map(\.value))
        hasher.combine(tools.map(\.value))
        hasher.combine(dialogs)
        hasher.combine(widgets.map(\.value))
        hasher.combine(running)
        hasher.combine(model)
        hasher.combine(thinking)
        hasher.combine(piSessionID)
        hasher.combine(stats)
        hasher.combine(commands)
        hasher.combine(subagents)
        let next = hasher.finalize()
        if next != signature {
            signature = next
            revision += 1
        }
    }

    private func snapshot(beforeEntryID: String?) -> NativeThreadResult {
        var end = history.count
        if let beforeEntryID {
            // Entry ids are positional in pi's message list, but history skips model-only
            // customs, so resolve the cursor by id rather than by array index.
            guard let index = history.firstIndex(where: { $0.entryID == beforeEntryID }) else {
                return .failure(code: "stale_cursor", message: "History changed. Refresh the recent page.")
            }
            end = index
        }
        let dialogs = Array(self.dialogs.prefix(Self.dialogLimit))
        var value = NativeThreadSnapshot(
            piSessionID: piSessionID ?? "", generation: generation, revision: revision, running: running,
            model: model, thinking: thinking, supportedActions: Self.supportedActions, dialogsSupported: true,
            dialogs: dialogs, widgets: widgets.map(\.value), messages: [],
            provisional: provisional.map(\.value) + tools.map(\.value),
            clipped: projectionClipped || dialogs.contains { $0.unavailable == "payload-limit" },
            runtime: "rpc", stats: stats, commands: commands, subagents: subagents
        )
        // Keep active output bounded before filling the remaining budget with history.
        while Self.bytes(value) > Self.activeLimit, !value.provisional.isEmpty {
            value.provisional.removeFirst()
            value.clipped = true
        }
        while Self.bytes(value) > Self.activeLimit, !value.dialogs.isEmpty {
            value.dialogs.removeLast()
            value.clipped = true
        }
        var size = Self.bytes(value)
        var index = end - 1
        while index >= 0 {
            let message = history[index]
            size += Self.bytes(message) + 1
            if size > Self.snapshotLimit {
                value.clipped = true
                break
            }
            value.messages.insert(message, at: 0)
            index -= 1
            if value.messages.count == Self.pageSize { break }
        }
        if index >= 0, let first = value.messages.first { value.olderCursor = first.entryID }
        return .snapshot(value: value)
    }

    private static func bytes<T: Encodable>(_ value: T) -> Int {
        (try? encoder.encode(value).count) ?? Int.max
    }

    // MARK: - Projection

    static func project(entryID: String, message: RPCMessage, args: JSONValue? = nil) -> NativeThreadMessage {
        var remaining = textLimit
        var truncated = false
        func clip(_ value: String) -> String {
            let raw = Array(value.utf8)
            if raw.count <= remaining {
                remaining -= raw.count
                return value
            }
            truncated = true
            var end = remaining
            while end > 0, raw[end] & 0xC0 == 0x80 { end -= 1 }
            remaining = 0
            return String(decoding: raw[0..<end], as: UTF8.self)
        }
        var result = NativeThreadMessage(entryID: entryID, role: message.role.isEmpty ? "custom" : message.role, blocks: [])
        if let toolName = message.toolName { result.toolName = clip(toolName) }
        if let toolCallID = message.toolCallId { result.toolCallID = clip(toolCallID) }
        if let args { result.argumentsText = clip(json(args)) }
        for block in message.content {
            if result.blocks.count >= 128 || remaining == 0 {
                truncated = true
                break
            }
            switch block {
            case .text(let text):
                result.blocks.append(NativeThreadBlock(kind: .text, text: clip(text)))
            case .thinking(let text):
                result.blocks.append(NativeThreadBlock(kind: .thinking, text: clip(text)))
            case .image:
                result.blocks.append(NativeThreadBlock(kind: .unsupportedImage, text: clip("[Image unavailable in native thread]")))
            case .toolCall:
                // The tool row (name, arguments, result) is the call's surface; dumping the
                // call JSON as prose duplicated it.
                break
            case .unknown:
                break
            }
        }
        if let error = message.errorMessage, !error.isEmpty {
            result.blocks.append(NativeThreadBlock(kind: .text, text: clip(error)))
        }
        if let isError = message.isError { result.isError = isError }
        if let stop = message.stopReason, !stop.isEmpty { result.status = clip(stop) }
        result.timestamp = message.timestamp
        result.truncated = truncated
        return result
    }

    private static let argumentEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return e
    }()

    private static func json(_ value: JSONValue) -> String {
        (try? argumentEncoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
