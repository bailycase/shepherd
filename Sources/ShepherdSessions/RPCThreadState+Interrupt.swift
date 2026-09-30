import Foundation
import ShepherdProtocol
import ShepherdRemote

/// Steer now (`NativeThreadDelivery.interrupt`, `NativeQueueAction.interrupt`): pi stops whatever
/// it is doing, as Stop does, and the message goes at once as the next turn in the same session.
/// The sequence while pi works, on the server queue:
///
/// 1. The message moves to the head of the queue and `interrupting` remembers it. Questions pi
///    waits on are refused (a turn waiting on an answer would not stop), and `stopRequested` makes
///    the run's ending read as stopped, never as a failure that pauses the queue.
/// 2. `clear_queue` takes back the steers pi still holds; they return to the queue behind the
///    interrupting messages (`reclaim`), so the abort cannot deliver them into the run it ends.
/// 3. `abort`. pi answers it once the run has settled (its `agent_settled` comes first).
/// 4. Once the settle has been seen (the turn's capture included) and the abort answered, the
///    interrupting messages go as one prompt (`drainIfReady`); the rest of the queue follows after
///    that turn, as it does after any other. Nothing is written to pi before its answer: a prompt
///    that reaches pi while it is still aborting is queued behind the run and does not run.
///
/// The queue never pauses for it, unlike Stop. The abort is only ever issued to the run the
/// interrupt began in: once the messages have gone (the run ended on its own first), `interrupting`
/// is empty and no abort follows, so it can never end the turn it made.
extension RPCThreadState {
    /// What the host does for an interrupt, from where pi is (`interruptPlan`).
    enum InterruptPlan: Equatable {
        /// pi is idle, or settled with its turn's end still being recorded: a plain send.
        case sendNow
        /// pi works: stop it, then the message opens the next turn.
        case abortThenSend
        /// An interrupt is already stopping pi: these go with it.
        case joinInterrupt
        /// The abort can't be issued: a plain steer, which waits at the head of the queue when
        /// pi can't take one either.
        case steer(InterruptFallback)
    }

    enum InterruptFallback: String, Equatable {
        /// pi compacts: an abort would end the compaction, and pi refuses a prompt meanwhile.
        case compacting
        /// A prompt of ours is on its way (or being prepared): there is no run to stop yet.
        case promptOnItsWay
        /// pi refused the abort.
        case abortRefused
    }

    /// The facts the plan depends on.
    struct InterruptState: Equatable {
        var running: Bool
        var compacting: Bool
        var promptOnItsWay: Bool
        var interrupting: Bool
    }

    var interruptState: InterruptState {
        InterruptState(running: running, compacting: compactingRun != nil,
                       promptOnItsWay: !dispatches.isEmpty || !preparingPrompts.isEmpty, interrupting: interrupting != nil)
    }

    static func interruptPlan(_ state: InterruptState) -> InterruptPlan {
        if state.interrupting { return .joinInterrupt }
        guard state.running else { return state.promptOnItsWay ? .steer(.promptOnItsWay) : .sendNow }
        if state.compacting { return .steer(.compacting) }
        if state.promptOnItsWay { return .steer(.promptOnItsWay) }
        return .abortThenSend
    }

    /// Interrupts pi for these queued messages, in order. `completion` is told as soon as they
    /// are first in the queue: a failure after that only ever turns the interrupt into a steer.
    func interrupt(_ ids: [UUID], operationID: UUID, completion: @escaping (NativeThreadResult) -> Void) {
        var chosen: [UUID] = []
        for id in ids where !chosen.contains(id) && items.contains(where: { $0.entry.id == id && $0.entry.state == .queued }) {
            chosen.append(id)
        }
        guard !chosen.isEmpty else {
            completion(.failure(code: "queue_item_unavailable", message: "That message is no longer queued."))
            return
        }
        let plan = Self.interruptPlan(interruptState)
        switch plan {
        case .sendNow:
            sendQueuedNow(chosen, operationID: operationID, completion: completion)
        case .steer(let reason):
            ShepherdLog.info("rpc session \(session.id) interrupt became a steer: \(reason.rawValue)")
            perform(.steer(ids: chosen), operationID: operationID, completion: completion)
        case .joinInterrupt:
            let ahead = interrupting ?? []
            interrupting = ahead + chosen.filter { !ahead.contains($0) }
            for (offset, id) in chosen.enumerated() where !ahead.contains(id) {
                NativeQueueRules.move(id, toQueuedIndex: ahead.count + offset, in: &items)
            }
            commit()
            completion(.accepted(operationID: operationID))
        case .abortThenSend:
            beginInterrupt(chosen)
            completion(.accepted(operationID: operationID))
        }
    }

    private func beginInterrupt(_ chosen: [UUID]) {
        refuseDialogs()
        stopRequested = true
        paused = false
        queueNotice = nil
        NativeQueueRules.interrupt(chosen, in: &items)
        interrupting = chosen
        commit()
        clearPiQueue { [weak self] steering, followUp, _ in
            // A failed `clear_queue` goes on to the abort, as Stop does.
            guard let self, let ids = self.interrupting else { return }
            self.reclaim(steering: steering, followUp: followUp)
            NativeQueueRules.interrupt(ids, in: &self.items)
            self.commit()
            // The run ended on its own while pi's queue was on its way out: the settle sends
            // the messages, and an abort now could only end the turn they open.
            guard self.running, self.interrupting != nil else { return }
            self.interruptAbortPending = true
            self.session.request(.abort) { [weak self] result in
                guard let self else { return }
                self.interruptAbortPending = false
                guard let ids = self.interrupting else { return }
                if let failure = Self.dispatchFailure(result), case .failure(let code, let message) = failure, code != "outcome_unknown" {
                    // pi would not stop: nothing was interrupted, so the messages steer instead.
                    ShepherdLog.info("rpc session \(self.session.id) interrupt became a steer: \(InterruptFallback.abortRefused.rawValue) (\(message))")
                    self.interrupting = nil
                    self.stopRequested = false
                    self.perform(.steer(ids: ids), operationID: UUID()) { _ in }
                    self.commit()
                    return
                }
                // pi is idle (or about to say so): the settle sends the messages.
                self.drainIfReady()
            }
        }
    }
}
