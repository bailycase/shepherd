import Foundation
import ShepherdProtocol

extension RPCThreadState {
    func recoveryCheckpoint(sessionID: String) -> AgentRecoveryStore.Checkpoint? {
        let waiting = recoveryWaiting
        var pending = stopRequested ? [] : dispatches.filter(\.expectsMessage).map { dispatch in
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
        let active = (running && !runFailed || retry != nil || recoveryResumePending) && !stopRequested && !waiting
        guard active || !items.isEmpty || !pending.isEmpty || recoveryDispatchID != nil else { return nil }
        return .init(sessionID: piSessionID ?? sessionID, active: active, items: items, pending: pending,
                     paused: paused || waiting || stopRequested || (runFailed && retry == nil)
                        || items.contains(where: { $0.entry.held }) || startingQueueChild != nil || !unknownQueueChildren.isEmpty,
                     mode: effectiveMode, attempts: recoveryAttempts, operationID: recoveryDispatchID, token: recoveryToken, fence: recoveryFence)
    }

    func restoreRecovery(_ checkpoint: AgentRecoveryStore.Checkpoint) {
        recoveryAttempts = checkpoint.attempts
        recoveryDispatchID = checkpoint.operationID
        recoveryToken = checkpoint.token
        recoveryFence = checkpoint.fence
        modeOverride = checkpoint.mode
        paused = checkpoint.paused
        var interrupted = checkpoint.active
        var uncertain = false
        for var item in checkpoint.pending + checkpoint.items where !items.contains(where: { $0.entry.id == item.entry.id }) {
            let pending = checkpoint.pending.contains { $0.entry.id == item.entry.id } || item.entry.state == .steering
            // An operation id is authoritative. Text alone cannot distinguish repeated user
            // requests, expanded skills or image-only sends after a lost transport response.
            let consumed = pending && history.contains { $0.role == "user" && $0.operationID == item.entry.id }
            if consumed {
                if !checkpoint.paused { interrupted = true }
                continue
            }
            if pending { uncertain = true }
            item.entry.state = .queued
            item.entry.held = false
            item.holdUntil = nil
            item.piText = nil
            items.append(item)
        }
        if checkpoint.attempts > AgentRecoveryStore.attemptLimit {
            pauseRecovery("Automatic recovery stopped after repeated interruptions. Send a message to continue.")
        } else if uncertain {
            pauseRecovery("An input's delivery before restart is uncertain. Check the conversation before sending the queued input.")
        } else if checkpoint.operationID != nil {
            reconcileRestartOperation()
        } else if interrupted {
            beginRestartRecovery()
        } else {
            commit()
            if !paused { drainIfReady() }
        }
    }

    private func pauseRecovery(_ notice: String) {
        recoveryResumePending = false
        paused = true
        queueNotice = notice
        commit()
    }

    private func reconcileRestartOperation() {
        guard let id = recoveryDispatchID else { return }
        recoveryResumePending = true
        commit()
        let generation = generation
        let requestID = UUID()
        restartRequestID = requestID
        session.request(.getRecoveryOperation(operationID: id)) { [weak self] result in
            guard let self, self.generation == generation, self.restartRequestID == requestID, !self.stopRequested else { return }
            guard case .success(let response) = result, response.success else {
                self.pauseRecovery("Recovery delivery could not be checked. Nothing was resent.")
                return
            }
            if let receipt = response.data?["receipt"], receipt["operationID"]?.stringValue?.lowercased() == id.uuidString.lowercased(),
               receipt["sessionID"]?.stringValue == self.piSessionID, receipt["token"]?.stringValue == self.recoveryToken {
                if receipt["state"]?.stringValue == "settled" {
                    self.recoveryResumePending = false
                    self.recoveryDispatchID = nil
                    self.recoveryToken = nil
                    self.recoveryFence = nil
                    self.commit()
                    if !self.paused { self.drainIfReady() }
                } else {
                    self.pauseRecovery("Recovery delivery was interrupted or is uncertain. Nothing was resent.")
                }
            } else if response.data?["receipt"] == .null {
                // No accepted engine operation: reusing the same fenced identity is safe.
                self.beginRestartRecovery(reacquiring: true)
            } else {
                self.pauseRecovery("Recovery's recorded outcome does not match this session. Nothing was resent.")
            }
        }
    }

    private func beginRestartRecovery(reacquiring: Bool = false) {
        recoveryResumePending = true
        commit()
        let generation = generation
        let requestID = UUID()
        restartRequestID = requestID
        session.request(.getRestartRecovery) { [weak self] result in
            guard let self, self.generation == generation, self.restartRequestID == requestID, !self.stopRequested else { return }
            guard case .success(let response) = result, response.success else {
                self.pauseRecovery("This engine cannot safely continue the interrupted turn. Nothing was resent.")
                return
            }
            if response.data?["refusal"]?.stringValue == "recovery_completed", self.recoveryDispatchID == nil {
                // The final assistant message reached disk before Shepherd observed settlement.
                self.recoveryResumePending = false
                self.commit()
                if !self.paused { self.drainIfReady() }
                return
            }
            guard let token = response.data?["checkpoint"]?["token"]?.stringValue,
                  let fence = response.data?["checkpoint"]?["fence"]?.stringValue else {
                self.pauseRecovery("This interrupted turn has no safe engine continuation. Check the conversation before continuing.")
                return
            }
            if reacquiring {
                // Only an authoritative null receipt permits a new runtime seal, and only
                // when the saved branch and declarative authority are exactly unchanged.
                guard let previous = self.recoveryFence, previous == fence else {
                    self.pauseRecovery("The saved recovery context changed or has no durable fence. Nothing was resent.")
                    return
                }
            } else if let previous = self.recoveryToken, previous != token {
                self.pauseRecovery("The recovery checkpoint changed. Nothing was resent.")
                return
            }
            let id = self.recoveryDispatchID ?? UUID()
            self.recoveryDispatchID = id
            self.recoveryToken = token
            self.recoveryFence = fence
            // Reserve both operation identity and checkpoint before the engine can call a model.
            guard self.onRecoveryChanged?() != false else {
                self.pauseRecovery("Recovery could not be saved. Nothing was continued.")
                return
            }
            let send = { [weak self] in
                guard let self else { return }
                guard self.generation == generation, self.restartRequestID == requestID, !self.stopRequested else {
                    // A newer send may already own the prepared snapshot. Only Stop may
                    // discard it here; a superseded callback must leave the newer turn alone.
                    if self.stopRequested { self.discardPreparedTurn?() }
                    return
                }
                self.session.request(.resumeSession(token: token, operationID: id)) { [weak self] result in
                    guard let self, self.generation == generation, self.restartRequestID == requestID, !self.stopRequested else { return }
                    guard case .success(let response) = result, response.success,
                          response.data?["operationID"]?.stringValue?.lowercased() == id.uuidString.lowercased(),
                          response.data?["token"]?.stringValue == token,
                          response.data?["sessionID"]?.stringValue == self.piSessionID,
                          ["accepted", "settled"].contains(response.data?["state"]?.stringValue ?? "") else {
                        self.discardPreparedTurn?()
                        self.pauseRecovery("The engine could not confirm continuation. Nothing will be resent automatically.")
                        return
                    }
                    self.commit()
                }
            }
            if let beforePrompt = self.beforePrompt { beforePrompt(send) } else { send() }
        }
    }
}
