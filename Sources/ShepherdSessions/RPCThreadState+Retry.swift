import Foundation
import CryptoKit
import Darwin
import ShepherdCore
import ShepherdProtocol

extension SessionServer {
    /// A move and restore cannot revive a grant captured before that move. Unrelated agents
    /// and status/name updates do not revoke it. Entries disappear with their agents.
    func refreshNativeRecoveryAuthority(before: ShepherdState) {
        for id in Array(nativeRecoveryAuthority.keys) {
            let old = before.agents.first { $0.id == id }
            guard let current = store.state.agents.first(where: { $0.id == id }) else {
                nativeRecoveryAuthority.removeValue(forKey: id); continue
            }
            let oldSession = (old?.paneID).flatMap { pane in before.tabs.first { $0.id == old?.tabID }?.layout.leaf(withID: pane)?.sessionID }
            let currentSession = current.paneID.flatMap { pane in store.state.tabs.first { $0.id == current.tabID }?.layout.leaf(withID: pane)?.sessionID }
            if old?.spaceID != current.spaceID || old?.tabID != current.tabID || old?.paneID != current.paneID
                || old?.worktreePath != current.worktreePath || oldSession != currentSession
                || old?.executionFor != current.executionFor || old?.projectWorkerFor != current.projectWorkerFor
                || old?.coordinatorFor != current.coordinatorFor || before.isProjectWorker(id) != store.state.isProjectWorker(id)
                || old.map({ before.isOrdinaryThread($0) }) != store.state.isOrdinaryThread(current) {
                nativeRecoveryAuthority[id] = UUID()
            }
        }
    }
}

struct CheckpointRecoveryBinding: Codable, Equatable, Sendable {
    var agentID: AgentID
    var spaceID: SpaceID
    var tabID: TabID
    var paneID: PaneID
}

/// One durable intent precedes transport delivery. An unreadable or interrupted write blocks
/// redispatch too. This is not a tool-execution journal and makes no external exactly-once claim.
struct CheckpointRecoveryIntent: Codable, Equatable, Sendable {
    var sessionID: String
    var entryID: String
    var checkpoint: NativeRecoveryCheckpoint
    var operationID: UUID
    var binding: CheckpointRecoveryBinding
    var nativeGeneration: String

    func url(in directory: URL, slot: Int = 0) -> URL {
        let key = SHA256.hash(data: Data("\(sessionID)\u{0}\(checkpoint.failedEntryID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
        return directory.appendingPathComponent("checkpoint-recovery", isDirectory: true).appendingPathComponent(key + ".\(slot).json")
    }

    // ponytail: scan explicit busy refusals; index this journal only if their volume matters.
    private func location(in directory: URL) throws -> (URL, Self?) {
        var slot = 0
        while true {
            let url = url(in: directory, slot: slot)
            guard FileManager.default.fileExists(atPath: url.path) else { return (url, nil) }
            let prior = try JSONDecoder().decode(Self.self, from: Data(contentsOf: url))
            guard prior.operationID != operationID, prior.sessionID == sessionID, prior.entryID == entryID,
                  prior.checkpoint.failedEntryID == checkpoint.failedEntryID, prior.binding == binding,
                  prior.nativeGeneration == nativeGeneration,
                  FileManager.default.fileExists(atPath: url.appendingPathExtension("busy").path) else { return (url, prior) }
            guard try JSONDecoder().decode(Self.self, from: Data(contentsOf: url.appendingPathExtension("busy"))) == prior else {
                throw NSError(domain: "CheckpointRecovery", code: 1)
            }
            slot += 1
        }
    }

    /// Only an exact, durable busy refusal permits another explicit operation in the next slot.
    func existing(in directory: URL) throws -> Self? { try location(in: directory).1 }

    func reserve(in directory: URL) throws {
        let (url, prior) = try location(in: directory)
        guard prior == nil else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EEXIST)) }
        try write(to: url)
    }

    func recordBusy(in directory: URL) throws {
        let (url, prior) = try location(in: directory)
        guard prior == self else { throw NSError(domain: "CheckpointRecovery", code: 2) }
        let proof = url.appendingPathExtension("busy")
        if FileManager.default.fileExists(atPath: proof.path) {
            guard try JSONDecoder().decode(Self.self, from: Data(contentsOf: proof)) == self else {
                throw NSError(domain: "CheckpointRecovery", code: 3)
            }
        } else { try write(to: proof) }
    }

    private func write(to url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .withoutOverwriting)
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
        let fd = Darwin.open(parent.path, O_RDONLY)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        defer { Darwin.close(fd) }
        guard fsync(fd) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    }
}

extension RPCThreadState {
    static let retryCommand = "shepherd-retry"
    /// pi's error for an assistant reply with no text and no tool call (the engine's
    /// `normalizeEmptyCompletion`, mirrored by the status extension for older engines).
    static let emptyCompletionError = "The provider returned no answer or tool call. Retry to continue the interrupted turn."
    static let recoveryUnsupported = "Continue requires an updated host and Pi engine with message-free checkpoint recovery support. Nothing was resent."

    func cancelRecovery() {
        guard let pending = recoveryPending else { return }
        recoveryPending = nil
        retryDispatch = nil
        pending.completion(.failure(code: "recovery_cancelled", message: "Recovery was stopped. Delivery may be unknown; nothing will be resent."))
    }

    private func finishRecoveryRequest(_ id: UUID, result: NativeThreadResult) {
        guard let pending = recoveryPending, pending.id == id else { return }
        recoveryPending = nil
        retryDispatch = nil
        commit()
        pending.completion(result)
        drainIfReady()
    }

    func isGitMergeRetry(entryID: String) -> Bool {
        (history + live.map(\.value)).contains { message in
            message.entryID == entryID && message.role == "user" &&
                message.blocks.contains { $0.kind == .text && $0.text == DesignGitMergeBrief.request }
        }
    }

    func retryTurn(entryID: String, checkpoint: NativeRecoveryCheckpoint?, operationID: UUID, binding: CheckpointRecoveryBinding?,
                   authorized permission: @escaping () -> Bool, completion originalCompletion: @escaping (NativeThreadResult) -> Void) {
        guard !isGitMergeRetry(entryID: entryID) else {
            originalCompletion(.failure(code: "git_merge", message: "Use Try again with agent to retry the merge.")); return
        }
        guard !restoringRecovery || recoveryAtLaunch == nil else {
            originalCompletion(.failure(code: "native_starting", message: "Recovery is waiting for conversation history. Try again once it has loaded.")); return
        }
        guard recoveryPending == nil else {
            originalCompletion(.failure(code: "busy", message: "A recovery operation is already pending.")); return
        }
        recoveryPending = (operationID, originalCompletion)
        retryDispatch = operationID
        let completion: (NativeThreadResult) -> Void = { [weak self] result in self?.finishRecoveryRequest(operationID, result: result) }
        let authorized = { [weak self] in permission() && self?.recoveryPending?.id == operationID }
        guard let checkpoint, checkpointRecovery?.version == 1 else {
            completion(.failure(code: "recovery_unsupported", message: Self.recoveryUnsupported)); return
        }
        guard let piSessionID, let directory = originStore?.directory, let binding else {
            completion(.failure(code: "recovery_unavailable", message: "Recovery delivery cannot be recorded safely on this host.")); return
        }
        let generation = generation
        let intent = CheckpointRecoveryIntent(sessionID: piSessionID, entryID: entryID, checkpoint: checkpoint,
                                              operationID: operationID, binding: binding, nativeGeneration: generation)
        commit()
        let queue = queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let existing = Result { try intent.existing(in: directory) }
            queue.async { [weak self] in
                guard let self else { return }
                guard generation == self.generation, piSessionID == self.piSessionID, authorized() else {
                    completion(.failure(code: "stale_session", message: "The thread, binding or permission changed. Nothing was continued.")); return
                }
                switch existing {
                case .failure:
                    completion(.failure(code: "outcome_unknown", message: "Prior recovery delivery is unknown. Nothing will be resent."))
                case .success(let prior?):
                    guard prior.binding == intent.binding, prior.sessionID == intent.sessionID, prior.entryID == intent.entryID,
                          prior.operationID == intent.operationID, prior.checkpoint.failedEntryID == intent.checkpoint.failedEntryID,
                          prior.nativeGeneration == intent.nativeGeneration else {
                        completion(.failure(code: "recovery_reserved", message: "This failure already has a recovery operation. Its delivery must be reconciled, not sent again.")); return
                    }
                    self.reconcileRecovery(prior, generation: generation, authorized: authorized, completion: completion)
                case .success(nil):
                    self.reserveRecovery(intent, directory: directory, generation: generation, authorized: authorized, completion: completion)
                }
            }
        }
    }

    private func recoveryReady(_ intent: CheckpointRecoveryIntent, generation: String, authorized: () -> Bool) -> NativeThreadResult? {
        guard generation == self.generation, intent.sessionID == piSessionID, authorized() else {
            return .failure(code: "stale_session", message: "The thread, binding or permission changed. Nothing was continued.")
        }
        guard canRecoverCheckpoint(operationID: intent.operationID) else {
            return .failure(code: "busy", message: "Wait for the agent, queued work and questions before continuing.")
        }
        guard checkpointRecovery?.checkpoint == intent.checkpoint else {
            return .failure(code: "recovery_stale", message: checkpointRecovery?.refusalMessage ?? "The failure checkpoint changed. Refresh before continuing.")
        }
        let latestUser = (history + live.map(\.value)).last { $0.role == "user" }
        guard latestUser?.entryID == intent.entryID else {
            return .failure(code: "not_latest", message: "Only the displayed latest failed turn can continue.")
        }
        return nil
    }

    private func reserveRecovery(_ intent: CheckpointRecoveryIntent, directory: URL, generation: String,
                                 authorized: @escaping () -> Bool, completion: @escaping (NativeThreadResult) -> Void) {
        if let refusal = recoveryReady(intent, generation: generation, authorized: authorized) { completion(refusal); return }
        retryDispatch = intent.operationID
        commit()
        let queue = queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let reserved = Result { try intent.reserve(in: directory) }
            queue.async { [weak self] in
                guard let self else { return }
                guard generation == self.generation, intent.sessionID == self.piSessionID, authorized() else {
                    completion(.failure(code: "stale_session", message: "The thread, binding or permission changed. Recovery was not dispatched.")); return
                }
                self.retryDispatch = nil
                guard case .success = reserved else {
                    self.commit()
                    completion(.failure(code: "recovery_reserved", message: "Recovery delivery is already reserved or could not be recorded. Nothing was resent.")); return
                }
                if let refusal = self.recoveryReady(intent, generation: generation, authorized: authorized) {
                    self.finishUndeliveredRecovery(refusal, intent: intent, generation: generation, authorized: authorized, completion: completion); return
                }
                self.retryDispatch = intent.operationID
                self.commit()
                let send = { [weak self] in
                    guard let self else { completion(.failure(code: "stale_session", message: "The thread closed before recovery.")); return }
                    if let refusal = self.recoveryReady(intent, generation: generation, authorized: authorized) {
                        if generation == self.generation { self.retryDispatch = nil; self.commit() }
                        self.finishUndeliveredRecovery(refusal, intent: intent, generation: generation, authorized: authorized, completion: completion); return
                    }
                    self.dispatchRecovery(intent, generation: generation, authorized: authorized, completion: completion)
                }
                if let beforePrompt = self.beforePrompt { beforePrompt(send) } else { send() }
            }
        }
    }

    private func finishUndeliveredRecovery(_ result: NativeThreadResult, intent: CheckpointRecoveryIntent,
                                           generation: String, authorized: @escaping () -> Bool,
                                           completion: @escaping (NativeThreadResult) -> Void) {
        if case .failure("busy", _) = result {
            recordBusyRefusal(intent, generation: generation, authorized: authorized, completion: completion)
        } else { completion(result) }
    }

    private func recordBusyRefusal(_ intent: CheckpointRecoveryIntent, generation: String,
                                   authorized: @escaping () -> Bool, completion: @escaping (NativeThreadResult) -> Void) {
        guard let directory = originStore?.directory else {
            completion(.failure(code: "outcome_unknown", message: "Recovery's refusal could not be recorded. Nothing will be resent.")); return
        }
        let queue = queue
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let recorded = Result { try intent.recordBusy(in: directory) }
            queue.async { [weak self] in
                guard let self else { return }
                guard generation == self.generation, intent.sessionID == self.piSessionID, authorized() else {
                    completion(.failure(code: "stale_session", message: "The thread changed while recording recovery's refusal.")); return
                }
                self.refreshState()
                if case .success = recorded {
                    completion(.failure(code: "busy", message: "Recovery was not accepted because the agent was busy. You may explicitly try again when it is idle."))
                } else {
                    completion(.failure(code: "outcome_unknown", message: "Recovery's refusal could not be recorded. Nothing will be resent."))
                }
            }
        }
    }

    private func dispatchRecovery(_ intent: CheckpointRecoveryIntent, generation: String,
                                  authorized: @escaping () -> Bool, completion: @escaping (NativeThreadResult) -> Void) {
        // A new, fenced Continue is authorization; a late agent_start after Stop is not.
        stopRequested = false
        restartRequestID = nil
        recoveryDispatchID = nil
        recoveryToken = nil
        recoveryFence = nil
        recoveryResumePending = false
        recoveryAttempts = 0
        restoringRecovery = false
        recoveryAtLaunch = nil
        session.request(.recoverCheckpoint(token: intent.checkpoint.token, operationID: intent.operationID)) { [weak self] result in
                    guard let self else { return }
                    guard generation == self.generation, intent.sessionID == self.piSessionID, authorized() else {
                        completion(.failure(code: "stale_session", message: "The thread changed while recovery was pending. Check its recorded outcome.")); return
                    }
                    self.retryDispatch = nil
                    switch result {
                    case .success(let response) where response.success:
                        guard self.matchesRecoveryReceipt(response.data, intent: intent),
                              let state = response.data?["state"]?.stringValue, state == "accepted" || state == "settled" else {
                            self.reconcileRecovery(intent, generation: generation, authorized: authorized, completion: completion); return
                        }
                        self.refreshMessages()
                        self.refreshState()
                        self.refreshStats()
                        self.commit()
                        completion(.accepted(operationID: intent.operationID))
                    case .success:
                        self.reconcileRecovery(intent, generation: generation, authorized: authorized, completion: completion)
                    case .failure:
                        // Read the exact receipt once. Absence or a lost read is still unknown,
                        // never permission to send this or a fresh recovery operation.
                        self.reconcileRecovery(intent, generation: generation, authorized: authorized, completion: completion)
                    }
                }
    }

    private func matchesRecoveryReceipt(_ receipt: JSONValue?, intent: CheckpointRecoveryIntent, busy: Bool = false) -> Bool {
        receipt?["token"]?.stringValue == intent.checkpoint.token
            && (busy || receipt?["failedEntryID"]?.stringValue == intent.checkpoint.failedEntryID)
            && receipt?["sessionID"]?.stringValue == intent.sessionID
            && receipt?["operationID"]?.stringValue?.uppercased() == intent.operationID.uuidString
    }

    private func reconcileRecovery(_ intent: CheckpointRecoveryIntent, generation: String,
                                   authorized: @escaping () -> Bool, completion: @escaping (NativeThreadResult) -> Void) {
        session.request(.getRecoveryOperation(operationID: intent.operationID)) { [weak self] result in
            guard let self else { return }
            guard generation == self.generation, intent.sessionID == self.piSessionID, authorized() else {
                completion(.failure(code: "stale_session", message: "The thread or permission changed while reading recovery's outcome.")); return
            }
            if case .success(let response) = result, response.success, let receipt = response.data?["receipt"],
               receipt["state"]?.stringValue == "refused", receipt["error"]?.stringValue == "recovery_busy",
               self.matchesRecoveryReceipt(receipt, intent: intent, busy: true) {
                self.recordBusyRefusal(intent, generation: generation, authorized: authorized, completion: completion)
                return
            }
            if case .success(let response) = result, response.success, let receipt = response.data?["receipt"],
               receipt["state"]?.stringValue == "refused", self.matchesRecoveryReceipt(receipt, intent: intent, busy: true) {
                completion(.failure(code: "recovery_refused", message: "Checkpoint recovery was refused (\(receipt["error"]?.stringValue ?? "invalid checkpoint")). Nothing was resent."))
                return
            }
            if case .success(let response) = result, response.success, let receipt = response.data?["receipt"],
               self.matchesRecoveryReceipt(receipt, intent: intent),
               let state = receipt["state"]?.stringValue, state == "settled" || state == "accepted" && self.running {
                completion(.accepted(operationID: intent.operationID))
            } else {
                completion(.failure(code: "outcome_unknown", message: "Recovery delivery is unknown or interrupted. Nothing will be resent automatically."))
            }
            self.commit()
        }
    }
}
