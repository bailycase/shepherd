import Foundation
import CryptoKit
import SQLite3
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote

struct ProjectArchivedChatAnswer: Codable, Sendable {
    var humanReplyID: UUID
    var receipt: ProjectChatAnswerReceipt
}

/// Indexed durable history, not an in-memory mirror. Each use is confined to its caller's file worker.
/// Committed workspace records are archived BEFORE eviction. New native events are a durable outbox:
/// a failed workspace rename leaves them pending, rather than dropping a completion.
final class ProjectHistoryStore {
    static let chunkBytes = 8 * 1024
    private var db: OpaquePointer?
    private let encoder: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return e }()
    private let decoder = JSONDecoder()
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(beside stateURL: URL) throws {
        // Foundation may shorten /private/var back to /var. SQLite NOFOLLOW needs the
        // filesystem's canonical parent, while the database leaf must never be resolved.
        let parent = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        guard let resolved = realpath(parent.path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        let path = String(cString: resolved) + "/project-history.sqlite"
        let fd = open(path, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        var info = stat(); let regular = fstat(fd, &info) == 0 && (info.st_mode & S_IFMT) == S_IFREG
        close(fd)
        guard regular, info.st_uid == geteuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0 else {
            throw LogicalProjectsError("history_unavailable", "Project history must be an owner-private regular file.")
        }
        let status = sqlite3_open_v2(path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX | SQLITE_OPEN_NOFOLLOW, nil)
        guard status == SQLITE_OK else {
            let code = sqlite3_extended_errcode(db)
            sqlite3_close(db); db = nil
            throw LogicalProjectsError("history_unavailable", "Project history could not be opened (SQLite \(status)/\(code)); no records were retired.")
        }
        sqlite3_busy_timeout(db, 500)
        try sql("PRAGMA synchronous=FULL; PRAGMA journal_mode=DELETE; PRAGMA cache_size=-512; PRAGMA temp_store=MEMORY;")
        try sql("""
            CREATE TABLE IF NOT EXISTS records (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                scope TEXT NOT NULL, kind TEXT NOT NULL, identity TEXT NOT NULL,
                revision INTEGER NOT NULL, payload BLOB NOT NULL,
                UNIQUE(scope,kind,identity));
            CREATE TABLE IF NOT EXISTS events (
                sequence INTEGER PRIMARY KEY AUTOINCREMENT,
                scope TEXT NOT NULL, source TEXT NOT NULL, messageID TEXT NOT NULL,
                task TEXT NOT NULL, operation TEXT NOT NULL, phase TEXT NOT NULL,
                revision INTEGER NOT NULL, payload BLOB NOT NULL,
                UNIQUE(scope,source), UNIQUE(scope,messageID));
            CREATE INDEX IF NOT EXISTS history_sequence ON records(scope,kind,sequence);
            CREATE INDEX IF NOT EXISTS history_task ON records(scope,json_extract(CAST(payload AS TEXT),'$.source.taskID'),sequence) WHERE kind='message';
            CREATE INDEX IF NOT EXISTS event_delivery ON events(scope,phase,sequence);
            CREATE INDEX IF NOT EXISTS event_task ON events(scope,task,sequence);
            CREATE INDEX IF NOT EXISTS execution_worker ON records(json_extract(CAST(payload AS TEXT),'$.assignment.reservedWorkerID'),sequence) WHERE kind='execution';
            """)
    }
    deinit { sqlite3_close(db) }

    private func sql(_ text: String) throws {
        guard sqlite3_exec(db, text, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }
    private func failure() -> LogicalProjectsError {
        // Database errors can contain private paths/content. Keep the public failure deliberately literal.
        LogicalProjectsError("history_storage", "Project history storage failed. No proof may be discarded; resolve storage availability before retrying.")
    }
    private func statement(_ text: String, _ values: [Data], binary: Set<Int> = [], body: (OpaquePointer) throws -> Void) throws {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, text, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw failure() }
        defer { sqlite3_finalize(stmt) }
        for (i, value) in values.enumerated() {
            // Parameters are UTF-8 strings/JSON/final text. Text binding preserves INTEGER affinity for revisions.
            let status = value.isEmpty ? sqlite3_bind_zeroblob(stmt, Int32(i + 1), 0) : value.withUnsafeBytes { bytes in
                if binary.contains(i) {
                    if bytes.isEmpty { return sqlite3_bind_zeroblob(stmt, Int32(i + 1), 0) }
                    return sqlite3_bind_blob(stmt, Int32(i + 1), bytes.baseAddress, Int32(bytes.count), Self.transient)
                }
                return sqlite3_bind_text(stmt, Int32(i + 1), bytes.bindMemory(to: CChar.self).baseAddress, Int32(bytes.count), Self.transient)
            }
            guard status == SQLITE_OK else { throw failure() }
        }
        try body(stmt)
    }
    private func bytes(_ value: String) -> Data { Data(value.utf8) }
    private func payload(_ stmt: OpaquePointer, _ column: Int32 = 0) -> Data {
        guard let pointer = sqlite3_column_blob(stmt, column) else { return Data() }
        return Data(bytes: pointer, count: Int(sqlite3_column_bytes(stmt, column)))
    }
    private func rows<T: Decodable>(_ query: String, _ values: [String], as: T.Type) throws -> [T] {
        var output: [T] = []
        try statement(query, values.map(bytes)) { stmt in
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                output.append(try decoder.decode(T.self, from: payload(stmt)))
            }
        }
        return output
    }
    private func scope(_ project: Project) -> String { "\(project.ownerID.uuidString)/\(project.id)" }
    private func sourceKey(_ source: ProjectEventSource) throws -> String {
        // Older settled events omitted generation. One operation cannot acquire a second final reply
        // merely by adding that metadata on replay; the original source remains stored verbatim.
        var identity = source
        if identity.kind == .settled { identity.generation = nil }
        return SHA256.hash(data: try encoder.encode(identity)).map { String(format: "%02x", $0) }.joined()
    }
    private func put<T: Encodable>(_ project: Project, kind: String, id: String, value: T) throws {
        try statement("""
            INSERT INTO records(scope,kind,identity,revision,payload) VALUES(?,?,?,?,?)
            ON CONFLICT(scope,kind,identity) DO UPDATE SET revision=excluded.revision,payload=excluded.payload
            WHERE excluded.revision >= records.revision
            """, [bytes(scope(project)), bytes(kind), bytes(id), bytes(String(project.revision)), try encoder.encode(value)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }
    func record<T: Decodable>(_ project: Project, kind: String, id: String, as: T.Type) throws -> T? {
        try rows("SELECT payload FROM records WHERE scope=? AND kind=? AND identity=? LIMIT 1", [scope(project),kind,id], as: T.self).first
    }

    /// Copies only the bounded committed working set. Never archive an uncommitted caller mutation as replay proof.
    /// Index only an already committed owner snapshot, never a proposed mutation. The revision checkpoint
    /// makes explicit history reads include the latest accepted messages without loading older history.
    func captureCommitted(_ project: Project) throws {
        try sql("BEGIN IMMEDIATE")
        do { try capture(project); try sql("COMMIT") }
        catch { try? sql("ROLLBACK"); throw error }
    }

    private func capture(_ project: Project) throws {
        if let captured = try record(project, kind: "checkpoint", id: "revision", as: UInt64.self), captured >= project.revision { return }
        if let command = project.commandReceipt { try put(project, kind: "command", id: command.operationID.uuidString, value: command) }
        for message in project.messages {
            try put(project, kind: "message", id: message.id.uuidString, value: message)
            for receipt in message.answerReceipts ?? [] {
                try put(project, kind: "answer", id: receipt.nativeAnswer.operationID.uuidString,
                        value: ProjectArchivedChatAnswer(humanReplyID: message.id, receipt: receipt))
            }
            if let source = message.source {
                try event(project, message: message, source: source, committed: true)
                if source.kind == .settled { try retainResult(project, message: message, result: nil) }
            }
        }
        for id in project.retiredWakeups { try put(project, kind: "retired", id: id.uuidString, value: id) }
        for task in project.tasks {
            try put(project, kind: "task-index", id: task.id.rawValue, value: task)
            // The current activation is archived with its immutable destination; older legacy IDs retain only their original proof.
            try put(project, kind: "activation", id: task.operationID.uuidString, value: task)
            for id in task.previousOperations ?? [] {
                if try record(project, kind: "activation", id: id.uuidString, as: ProjectTask.self) == nil {
                    try put(project, kind: "legacy_activation", id: id.uuidString, value: task.id)
                }
            }
            for id in task.resolutionOperations ?? [] { try put(project, kind: "resolution", id: id.uuidString, value: task.id) }
        }
        for id in project.memoryOperations { try put(project, kind: "memory", id: id.uuidString, value: id) }
        for proposal in project.spaceProposals { try put(project, kind: "proposal", id: proposal.operationID.uuidString, value: proposal) }
        try put(project, kind: "checkpoint", id: "revision", value: project.revision)
    }

    private func event(_ project: Project, message: ProjectMessage, source: ProjectEventSource, committed: Bool) throws {
        let update = committed ? " ON CONFLICT(scope,source) DO UPDATE SET phase=excluded.phase,revision=excluded.revision,payload=excluded.payload WHERE excluded.revision >= events.revision ON CONFLICT(scope,messageID) DO NOTHING" : " ON CONFLICT DO NOTHING"
        try statement("INSERT INTO events(scope,source,messageID,task,operation,phase,revision,payload) VALUES(?,?,?,?,?,?,?,?)" + update,
                      [bytes(scope(project)),bytes(try sourceKey(source)),bytes(message.id.uuidString),bytes(source.taskID.rawValue),bytes(source.operationID.uuidString),bytes(message.phase.rawValue),bytes(String(project.revision)),try encoder.encode(message)]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    func messages(_ project: Project, task: ProjectTaskID, operation: UUID? = nil) throws -> [ProjectMessage] {
        if let operation {
            return try rows("SELECT payload FROM events WHERE scope=? AND task=? AND operation=? ORDER BY sequence DESC LIMIT 3", [scope(project), task.rawValue, operation.uuidString], as: ProjectMessage.self).reversed()
        }
        return try rows("SELECT payload FROM events WHERE scope=? AND task=? ORDER BY sequence DESC LIMIT 3", [scope(project), task.rawValue], as: ProjectMessage.self).reversed()
    }

    func history(_ project: Project, task: ProjectTaskID?, before: Int64?, includeBodies: Bool = false) throws -> [ProjectHistoryEntry] {
        var result: [ProjectHistoryEntry] = [], bodyBytes = 0
        let filter = task == nil ? "" : " AND json_extract(CAST(payload AS TEXT),\'$.source.taskID\')=?"
        let parameters = [bytes(scope(project)), bytes(String(before ?? Int64.max))] + (task.map { [bytes($0.rawValue)] } ?? [])
        try statement("SELECT sequence,payload FROM records WHERE scope=? AND kind=\'message\' AND sequence < CAST(? AS INTEGER)\(filter) ORDER BY sequence DESC LIMIT 5", parameters) { stmt in
            while true {
                let status = sqlite3_step(stmt)
                if status == SQLITE_DONE { break }
                guard status == SQLITE_ROW else { throw failure() }
                let message = try decoder.decode(ProjectMessage.self, from: payload(stmt, 1))
                let count = try encoder.encode(message).count
                let fits = includeBodies && bodyBytes + count <= 256 * 1024
                if fits { bodyBytes += count }
                var entry = ProjectHistoryEntry(sequence: sqlite3_column_int64(stmt, 0), messageID: message.id, source: message.source, phase: message.phase, humanSubmitted: message.humanSubmitted, message: fits ? message : nil)
                if includeBodies && !fits { entry.bodyOmittedReason = "Receipt body exceeds the history page budget. Use exact result paging for final assistant content; this index is not inspected content." }
                result.append(entry)
            }
        }
        return result
    }

    /// A pending event survives a full live queue and a failed workspace commit. Dispatch still uses the ordinary native delivery ID.
    func prepare(before: ShepherdState, candidate: ShepherdState) throws -> ShepherdState {
        try sql("BEGIN IMMEDIATE")
        do {
            for project in before.projects { try capture(project) }
            for receipt in before.projectExecutions {
                var scope = executionProject(receipt.key)
                scope.revision = receipt.revision
                try put(scope, kind: "execution", id: receipt.key.operationID.uuidString, value: receipt)
            }
            var next = candidate
            for project in before.projects + candidate.projects {
                for worker in project.tasks.map(\.workerAgentID) {
                    if let i = next.agents.firstIndex(where: { $0.id == worker }) { next.agents[i].projectWorkerFor = project.id }
                }
            }
            for receipt in before.projectExecutions {
                if let worker = receipt.assignment?.reservedWorkerID, let i = next.agents.firstIndex(where: { $0.id == worker }), next.agents[i].executionFor == nil {
                    next.agents[i].executionFor = receipt.key
                }
            }
            for i in next.projectExecutions.indices {
                let running = next.projectExecutions[i]
                if [.sent, .waiting, .sendReserved, .unknown].contains(running.phase),
                   let terminal = try record(executionProject(running.key), kind: "terminal-execution", id: running.key.operationID.uuidString, as: ProjectExecutionReceipt.self),
                   terminal.assignment == running.assignment, terminal.sessionID == running.sessionID, terminal.generation == running.generation,
                   terminal.matchedUserEntryID == running.matchedUserEntryID, terminal.pendingAnswer == running.pendingAnswer {
                    next.projectExecutions[i] = terminal; next.projectExecutions[i].revision = max(terminal.revision, running.revision + 1)
                }
                let receipt = next.projectExecutions[i]
                if let previous = receipt.previousOperationID,
                   let prior = (before.projectExecutions + candidate.projectExecutions).first(where: { $0.key.ownerID == receipt.key.ownerID && $0.key.projectID == receipt.key.projectID && $0.key.operationID == previous }),
                   let proof = ProjectExecutionPredecessor(prior) { next.projectExecutions[i].predecessorProof = proof }
            }
            let recentTerminal = Set(next.projectExecutions.filter { !$0.phase.active && $0.phase != .unknown }.suffix(16).map(\.key))
            next.projectExecutions.removeAll { receipt in
                guard !recentTerminal.contains(receipt.key), !receipt.phase.active, receipt.phase != .unknown, before.projectExecutions.contains(receipt) else { return false }
                return true
            }
            for i in next.projects.indices {
                var project = next.projects[i]
                let old = before.projects.first { $0.id == project.id && $0.ownerID == project.ownerID }
                let archived = Set((old?.messages ?? []).filter { project.messages.contains($0) }.map(\.id))
                project.retireFinishedMessages(archived: archived)
                for staged in project.stagedEvents {
                    guard let source = staged.message.source else { continue }
                    try event(project, message: staged.message, source: source, committed: false)
                    // The database's first immutable source identity wins even after archival/reload.
                    let stored = try rows("SELECT payload FROM events WHERE scope=? AND source=? LIMIT 1", [scope(project), try sourceKey(source)], as: ProjectMessage.self).first
                    if stored?.id != staged.message.id { project.messages.removeAll { $0.id == staged.message.id }; continue }
                    try put(project, kind: "message", id: staged.message.id.uuidString, value: staged.message)
                    if source.kind == .settled {
                        try retainResult(project, message: staged.message, result: staged.result, observedRevision: old?.revision)
                        if let task = staged.settledTask { try put(project, kind: "terminal-task", id: source.operationID.uuidString, value: task) }
                    }
                }
                project.stagedEvents = []
                for j in project.tasks.indices where [.running, .waiting, .unknown].contains(project.tasks[j].phase) || (project.tasks[j].phase == .settled && project.tasks[j].error != nil) {
                    let task = project.tasks[j]
                    if let settled = try record(project, kind: "terminal-task", id: task.operationID.uuidString, as: ProjectTask.self),
                       settled.id == task.id, settled.workerAgentID == task.workerAgentID, settled.workerSessionID == task.workerSessionID,
                       settled.nativeDeliveryID == task.nativeDeliveryID, settled.childScopeEpoch == task.childScopeEpoch,
                       settled.executionAssignment == task.executionAssignment {
                        project.tasks[j].phase = .settled; project.tasks[j].revision += 1
                        project.tasks[j].settledAt = settled.settledAt; project.tasks[j].error = settled.error
                        project.tasks[j].question = nil
                    }
                }
                let excluded = project.messages.map { $0.id.uuidString }
                let slots = excluded.map { _ in "?" }.joined(separator: ",")
                let clause = excluded.isEmpty ? "" : " AND messageID NOT IN (\(slots))"
                let pending = try rows("SELECT payload FROM events WHERE scope=? AND phase=?\(clause) ORDER BY sequence LIMIT 65", [scope(project),ProjectMessage.Phase.queued.rawValue] + excluded, as: ProjectMessage.self)
                for message in pending where project.coordinatorAgentID != nil && project.messages.count < 64 && !project.messages.contains(where: { $0.id == message.id }) {
                    var trial = project
                    let committed = Set((old?.messages ?? []).map(\.id))
                    let insertion = trial.messages.firstIndex { !committed.contains($0.id) && $0.source == nil } ?? trial.messages.endIndex
                    trial.messages.insert(message, at: insertion)
                    var frame = next; frame.projects[i] = trial
                    guard (try? trial.validate()) != nil,
                          let encoded = try? NDJSON.encode(RemoteReply.stateChanged(state: frame)), encoded.count <= NDJSON.maxPayloadBytes else { break }
                    project = trial
                }
                project.historyPending = pending.contains { event in !project.messages.contains(where: { $0.id == event.id }) }
                if project.coordinatorAgentID != nil, project.historyPending == true, project.messages.contains(where: { message in message.source == nil && !(old?.messages.contains(where: { $0.id == message.id }) ?? false) }) {
                    throw LogicalProjectsError("project_busy", "Older worker receipts await live capacity. No new message was accepted; retry the same message identity after delivery progresses.")
                }
                if let old {
                    let oldIDs = Set(old.tasks.map(\.id))
                    var restored = 0
                    for task in project.tasks where !oldIDs.contains(task.id) {
                        if try taskByID(old, id: task.id) != nil { restored += 1 }
                    }
                    project.retireResolvedTasks(eligible: Set(old.tasks.filter { $0.phase == .resolved && project.tasks.contains($0) }.map(\.id)))
                    let retainedIDs = Set(project.tasks.map(\.id))
                    let archivedTasks = old.tasks.filter { $0.phase == .resolved && !retainedIDs.contains($0.id) }.count
                    project.archivedResolvedTaskCount = max(0, (old.archivedResolvedTaskCount ?? 0) + archivedTasks - restored)
                    for j in project.tasks.indices {
                        let task = project.tasks[j]
                        let pinned = Set(project.artifacts.filter { $0.taskID == task.id }.map { $0.key.operationID })
                        project.tasks[j].previousOperations = task.previousOperations?.filter { $0 == task.previousOperations?.last || pinned.contains($0) }
                        project.tasks[j].resolutionOperations = task.resolutionOperations.map { Array($0.suffix(1)) }
                    }
                    project.memoryOperations = Array(project.memoryOperations.suffix(1))
                    let recentProposals = Set(project.spaceProposals.filter { $0.phase != .pending }.suffix(16).map(\.id))
                    project.spaceProposals.removeAll { proposal in
                        proposal.phase != .pending && !recentProposals.contains(proposal.id) && old.spaceProposals.contains(proposal)
                    }
                }
                if project != candidate.projects[i], project.revision == old?.revision { project.revision += 1 }
                for task in (old?.tasks ?? []) + project.tasks where task.destination == .local {
                    if let index = next.agents.firstIndex(where: { $0.id == task.workerAgentID && $0.coordinatorFor == nil }) { next.agents[index].projectWorkerFor = project.id }
                }
                next.projects[i] = project
            }
            try sql("COMMIT")
            return next
        } catch { try? sql("ROLLBACK"); throw error }
    }

    private func executionProject(_ key: ProjectExecutionKey) -> Project {
        var project = Project(id: key.projectID, name: "Executor history")
        project.ownerID = key.ownerID
        return project
    }

    struct ExecutionHistory: Sendable {
        var existing: ProjectExecutionReceipt?
        var workerProof: [ProjectExecutionReceipt] = []
    }

    func executionHistory(_ request: ProjectExecutionRequest) throws -> ExecutionHistory {
        let project = executionProject(request.key)
        let existing = try record(project, kind: "execution", id: request.key.operationID.uuidString, as: ProjectExecutionReceipt.self)
        var proof: [ProjectExecutionReceipt] = []
        if case .execute(let assignment) = request {
            let worker = assignment.reservedWorkerID.rawValue
            proof += try rows("SELECT payload FROM records WHERE kind='execution' AND json_extract(CAST(payload AS TEXT),'$.assignment.reservedWorkerID')=? ORDER BY sequence LIMIT 1", [worker], as: ProjectExecutionReceipt.self)
            proof += try rows("SELECT payload FROM records WHERE kind='execution' AND json_extract(CAST(payload AS TEXT),'$.assignment.reservedWorkerID')=? AND json_extract(CAST(payload AS TEXT),'$.phase') IN ('settled','cancelled') AND json_extract(CAST(payload AS TEXT),'$.matchedUserEntryID') IS NOT NULL ORDER BY sequence DESC LIMIT 1", [worker], as: ProjectExecutionReceipt.self)
        }
        return .init(existing: existing, workerProof: proof)
    }

    func retainExecutionResult(_ receipt: ProjectExecutionReceipt, result: ProjectVisibleResult) throws {
        guard let assignment = receipt.assignment else { throw LogicalProjectsError("invalid_execution", "A result needs its original assignment.") }
        var project = executionProject(receipt.key)
        var task = ProjectTask(id: assignment.taskID, operationID: receipt.key.operationID, workerAgentID: assignment.reservedWorkerID,
                               spaceID: assignment.executorSpaceID, title: "Result", prompt: "Result", phase: .settled)
        task.nativeDeliveryID = receipt.key.operationID
        project.tasks = [task]
        let source = ProjectEventSource(kind: .settled, taskID: assignment.taskID, operationID: receipt.key.operationID,
                                       workerAgentID: assignment.reservedWorkerID, sessionID: receipt.sessionID, generation: receipt.generation)
        try sql("BEGIN IMMEDIATE")
        do {
            if receipt.phase == .settled { try put(project, kind: "terminal-execution", id: receipt.key.operationID.uuidString, value: receipt) }
            try retainResult(project, message: .init(id: UUID(), text: "", source: source), result: result, executionRevision: receipt.revision)
            try sql("COMMIT")
        } catch { try? sql("ROLLBACK"); throw error }
    }

    func command(_ project: Project, operation: UUID) throws -> ProjectCommandReceipt? {
        if project.commandReceipt?.operationID == operation { return project.commandReceipt }
        return try record(project, kind: "command", id: operation.uuidString, as: ProjectCommandReceipt.self)
    }

    func legacyOperation(_ project: Project, operation: UUID) throws -> Bool {
        var count = false
        try statement("SELECT 1 FROM records WHERE scope=? AND identity=? AND kind IN ('activation','legacy_activation','resolution','memory','proposal','message','retired') LIMIT 1", [bytes(scope(project)),bytes(operation.uuidString)]) { stmt in
            count = sqlite3_step(stmt) == SQLITE_ROW
        }
        return count
    }

    func chatAnswer(_ project: Project, operation: UUID) throws -> ProjectArchivedChatAnswer? {
        try record(project, kind: "answer", id: operation.uuidString, as: ProjectArchivedChatAnswer.self)
    }

    func taskByID(_ project: Project, id: ProjectTaskID) throws -> ProjectTask? {
        if let task = project.tasks.first(where: { $0.id == id }) { return task }
        return try record(project, kind: "task-index", id: id.rawValue, as: ProjectTask.self)
    }

    func task(_ project: Project, operation: UUID) throws -> ProjectTask? {
        if let task = project.tasks.first(where: { $0.operationID == operation }) { return task }
        return try record(project, kind: "activation", id: operation.uuidString, as: ProjectTask.self)
    }

    func adoptRemoteDescriptor(_ project: Project, task: ProjectTask, page: ProjectResultPage) throws {
        guard let upstream = page.identity else { throw LogicalProjectsError("unavailable_result", "No exact executor capture is retained.") }
        let old = try record(project, kind: "result-meta", id: task.operationID.uuidString, as: ProjectResultPage.self)
        if let old, old.sha256 != nil {
            guard old.sha256 == page.sha256, old.originIdentity == upstream, old.totalBytes == page.totalBytes,
                  old.availability == page.availability, old.stopReason == page.stopReason else { throw LogicalProjectsError("stale_result", "Remote retained result changed.") }
            return
        }
        var descriptor = page
        var ownerIdentity = old?.identity ?? upstream
        ownerIdentity.host = task.destination
        descriptor.identity = ownerIdentity
        descriptor.originEventID = upstream.eventID
        descriptor.originIdentity = upstream
        descriptor.data = Data(); descriptor.offset = 0; descriptor.nextOffset = nil
        try put(project, kind: "result-meta", id: task.operationID.uuidString, value: descriptor)
    }

    func executionResult(_ receipt: ProjectExecutionReceipt, offset: Int64, hash: String?) throws -> ProjectResultPage {
        guard let task = receipt.assignment?.taskID else { return .init(availability: .unavailable, reason: "No original task assignment is retained.") }
        return try result(executionProject(receipt.key), task: task, operation: receipt.key.operationID, offset: offset, hash: hash)
    }

    private func retainResult(_ project: Project, message: ProjectMessage, result: ProjectVisibleResult?, observedRevision: UInt64? = nil, executionRevision: UInt64? = nil) throws {
        guard let source = message.source, let task = project.tasks.first(where: { $0.id == source.taskID }) else { return }
        if try record(project, kind: "result-meta", id: source.operationID.uuidString, as: ProjectResultPage.self) != nil { return }
        let text = result.map { NativeRedaction.projectData($0.text) }
        let data = text.map { Data($0.utf8) } ?? Data()
        let hash = result.map { _ in SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        var identity = ProjectResultIdentity(ownerID: project.ownerID, projectID: project.id, eventID: message.id, source: source,
                                             host: task.destination, deliveryID: task.nativeDeliveryID ?? source.operationID, observedProjectRevision: executionRevision == nil ? observedRevision ?? project.revision : nil)
        identity.executionReceiptRevision = executionRevision
        let page = ProjectResultPage(identity: identity, availability: result.map { $0.complete ? .complete : .incomplete } ?? .unavailable,
                                     reason: result == nil ? "Only legacy/clipped receipt content is retained; a complete result was not captured." : (result?.complete == false ? "Final content exceeded the 16 MiB capture budget, includes unsupported visible blocks, or did not end with a normal stop. See stopReason; no success is inferred." : nil),
                                     totalBytes: Int64(data.count), sha256: hash, stopReason: result?.stopReason)
        try put(project, kind: "result-meta", id: source.operationID.uuidString, value: page)
        // Store bytes, not a JSON string: substr reads a bounded page without materializing the result in hot state.
        try statement("INSERT INTO records(scope,kind,identity,revision,payload) VALUES(?,?,?,?,?) ON CONFLICT DO NOTHING",
                      [bytes(scope(project)),bytes("result-data"),bytes(source.operationID.uuidString),bytes(String(project.revision)),data], binary: [4]) { stmt in
            guard sqlite3_step(stmt) == SQLITE_DONE else { throw failure() }
        }
    }

    func resultDescriptor(_ project: Project, task: ProjectTaskID, operation: UUID) throws -> ProjectResultPage {
        guard let page = try record(project, kind: "result-meta", id: operation.uuidString, as: ProjectResultPage.self) else {
            return .init(availability: .unavailable, reason: "No exact complete result was captured for this operation.")
        }
        guard page.identity?.source.taskID == task else { throw LogicalProjectsError("project_scope", "Result belongs to another task.") }
        return page
    }

    func result(_ project: Project, task: ProjectTaskID, operation: UUID, offset: Int64, hash: String?) throws -> ProjectResultPage {
        guard offset >= 0, offset == 0 || hash != nil else { throw LogicalProjectsError("invalid_result_page", "Continuation requires its immutable digest and a nonnegative byte offset.") }
        var page = try resultDescriptor(project, task: task, operation: operation)
        if page.identity == nil { return page }
        guard hash == nil || hash == page.sha256 else { throw LogicalProjectsError("stale_result", "The requested result digest does not match.") }
        guard offset <= page.totalBytes else { throw LogicalProjectsError("invalid_result_page", "Offset exceeds the result length.") }
        page.offset = offset
        if page.originEventID != nil { return page }
        var rowID: Int64?
        try statement("SELECT sequence FROM records WHERE scope=? AND kind='result-data' AND identity=? LIMIT 1", [bytes(scope(project)),bytes(operation.uuidString)]) { stmt in
            if sqlite3_step(stmt) == SQLITE_ROW { rowID = sqlite3_column_int64(stmt, 0) }
        }
        guard let rowID else { throw LogicalProjectsError("unavailable_result", "Result bytes are missing; metadata is not proof of content.") }
        var blob: OpaquePointer?
        guard sqlite3_blob_open(db, "main", "records", "payload", rowID, 0, &blob) == SQLITE_OK, let blob else { throw failure() }
        defer { sqlite3_blob_close(blob) }
        guard Int64(sqlite3_blob_bytes(blob)) == page.totalBytes else { throw LogicalProjectsError("incomplete_result", "Retained bytes do not match immutable result metadata.") }
        page.data = Data(count: Int(min(Int64(Self.chunkBytes), page.totalBytes - offset)))
        if !page.data.isEmpty {
            let status = page.data.withUnsafeMutableBytes { sqlite3_blob_read(blob, $0.baseAddress, Int32($0.count), Int32(offset)) }
            guard status == SQLITE_OK else { throw failure() }
        }
        // Align UTF-8 pages without re-reading or redacting separate chunks (secrets can span a page boundary).
        for _ in 0..<3 where String(data: page.data, encoding: .utf8) == nil && !page.data.isEmpty { page.data.removeLast() }
        guard String(data: page.data, encoding: .utf8) != nil else { throw LogicalProjectsError("invalid_result_page", "Offset is not a UTF-8 boundary.") }
        if String(data: page.data, encoding: .utf8) == nil {
            var boundary: Data?
            for trim in 1..<min(4, page.data.count) {
                let prefix = Data(page.data.dropLast(trim))
                if String(data: prefix, encoding: .utf8) != nil { boundary = prefix; break }
            }
            guard let boundary else { throw LogicalProjectsError("invalid_result_offset", "Offset is not an immutable UTF-8 page boundary.") }
            page.data = boundary
        }
        let end = offset + Int64(page.data.count)
        page.nextOffset = end < page.totalBytes ? end : nil
        return page
    }
}
