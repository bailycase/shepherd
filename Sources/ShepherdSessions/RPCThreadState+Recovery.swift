import Foundation
import ShepherdProtocol

extension RPCThreadState {
    func recoveryCheckpoint(sessionID: String) -> AgentRecoveryStore.Checkpoint? {
        let waiting = recoveryWaiting
        var pending = stopRequested ? [] : dispatches.filter { $0.expectsMessage && $0.id != recoveryDispatchID }.map { dispatch in
            QueueItem(entry: NativeQueuedMessage(id: dispatch.id, text: dispatch.text,
                                                images: dispatch.images.map { NativeQueuedImage(mimeType: $0.mimeType, name: $0.name) },
                                                sentAt: dispatch.sentAt), images: dispatch.images,
                      designPayloads: dispatch.designPayloads)
        }
        if let opening = unreadOpeningPrompt {
            pending.append(QueueItem(entry: NativeQueuedMessage(id: opening.id, text: opening.text,
                                                                images: opening.images.map { NativeQueuedImage(mimeType: $0.mimeType, name: $0.name) },
                                                                sentAt: opening.at), images: opening.images))
        }
        // Native Continue owns its exact-operation receipt. A reservation is not a running turn.
        let active = (running && !runFailed || retry != nil
                      || dispatches.contains { $0.id == recoveryDispatchID }) && !stopRequested && !waiting
        guard active || !items.isEmpty || !pending.isEmpty else { return nil }
        return .init(sessionID: piSessionID ?? sessionID, active: active, items: items, pending: pending,
                     paused: paused || waiting || stopRequested || (runFailed && retry == nil)
                        || items.contains(where: { $0.entry.held }) || startingQueueChild != nil || !unknownQueueChildren.isEmpty,
                     mode: effectiveMode, attempts: recoveryAttempts)
    }

    /// Called only after the resumed history is available. Pending prompts may have reached pi
    /// before the crash but not this host; reconcile them against its durable user messages.
    func restoreRecovery(_ checkpoint: AgentRecoveryStore.Checkpoint) {
        recoveryAttempts = checkpoint.attempts
        modeOverride = checkpoint.mode
        paused = checkpoint.paused
        var interrupted = checkpoint.active
        let recovered = checkpoint.pending + checkpoint.items
        for var item in recovered where !items.contains(where: { $0.entry.id == item.entry.id }) {
            let uncertain = checkpoint.pending.contains { $0.entry.id == item.entry.id } || item.entry.state == .steering
            let consumed = uncertain && history.contains { row in
                row.role == "user" && (row.operationID == item.entry.id
                    || ((row.timestamp ?? 0) >= item.entry.sentAt - 1000
                        && row.blocks.map(\.text).joined() == DesignViewRecord.strippingFence(from: item.promptText)))
            }
            if consumed {
                if !checkpoint.paused { interrupted = true }
                continue
            }
            // A template/skill may have expanded before pi persisted the user message, so
            // an unmatched pending input is not proof it never ran. Reconcile, don't replay.
            if uncertain {
                item.entry.text = Self.pendingRecoveryPrefix + "\n\n" + item.entry.text
            }
            item.entry.state = .queued
            item.entry.held = false
            item.holdUntil = nil
            item.piText = nil
            items.append(item)
        }
        if checkpoint.attempts > AgentRecoveryStore.attemptLimit {
            paused = true
            queueNotice = "Automatic recovery stopped after repeated interruptions. Send a message to continue."
            commit()
            return
        }
        if interrupted {
            // A paused queue does not pause the turn that was already working.
            let id = UUID()
            recoveryDispatchID = id
            dispatch(id: id, text: Self.recoveryPrompt, images: [], parts: nil, items: []) { _ in }
        } else {
            commit()
            if !paused { drainIfReady() }
        }
    }

    static let pendingRecoveryPrefix = "An input submitted before Shepherd restarted may already have been accepted or expanded in this conversation. Reconcile the request below against history and actual results; continue only unfinished authorized work, do not repeat completed actions, and ask the user if a consequential outcome is uncertain."

    static let recoveryPrompt = """
    Shepherd restarted while your previously authorized work was unfinished. Continue that work from this conversation. First reconcile the interrupted turn against the current files, running processes, and any external results. A tool or action may already have succeeded; do not blindly repeat it or duplicate completed actions. Respect the user's existing scope, stops, approvals, and execution limits. If a consequential action's outcome cannot be established safely, ask the user rather than repeating it. Queued user messages will follow normally.
    """
}
