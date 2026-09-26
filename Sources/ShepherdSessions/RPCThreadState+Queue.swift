import Dispatch
import Foundation
import ShepherdProtocol
import ShepherdRemote

/// The queue: messages sent while pi works wait here, on the host, until pi settles, so every
/// client sees and edits one queue and nothing reaches pi before its turn. pi 0.87.1's own
/// queues are text-only, cannot be edited or reordered, and `set_follow_up_mode` writes the
/// user's pi settings, so Shepherd keeps its own and hands pi one prompt at a time:
///
/// - **Queued** items go when pi settles (`agent_settled`): the head alone (one per turn), or
///   everything that can go together joined into one message (all at once;
///   `NativeQueueRules.batchCount`). pi then runs exactly one turn for them, and the message
///   records its parts (`NativeMessageOrigin.queue`) so the thread shows each with its own
///   send time.
/// - **Steering** items are handed to pi at once as `prompt` with `streamingBehavior: steer`.
///   pi reads them after the current batch of tool calls; its `queue_update` names the text it
///   queued, and the user message it later starts with that text is the item landing.
/// - A user message joins the thread only when pi starts it (`message_start`), at pi's
///   position, with pi's id. Until then a prompt Shepherd sent shows as a pending row.
extension RPCThreadState {
    /// Images in one prompt, before base64 (RPCSession's stdin queue holds 8 MiB).
    static let imageBytesLimit = NativeImage.maxBytesPerSend
    /// The queue's text in one snapshot; a send past it is refused.
    static let queueTextLimit = 64 * 1024
    static let queueItemLimit = 32
    /// A hold (an editor open on an item) lapses after this unless renewed, so a client that
    /// went away cannot keep the queue from going.
    static let holdLease: TimeInterval = 120
    /// A delete or clear can be undone this long.
    static let deletedLimit = 64

    struct QueueItem: NativeQueueEntry {
        var entry: NativeQueuedMessage
        var images: [NativeImage]
        /// The text pi queued for a steering item (its `queue_update`), which is what its user
        /// message will carry: pi expands templates and skills before queueing.
        var piText: String?
        var holdUntil: Date?
        /// Sent by an older remote client, which finds its message in the thread by the text it
        /// sent: it goes to pi on its own, never joined with others.
        var goesAlone = false
        /// The sender's design view record, fenced (`DesignViewRecord.fenced`): pi reads it
        /// ahead of the message, and the thread and the queue show the message alone.
        var context: String?

        /// What pi is handed for it: the fenced record, then the message.
        var promptText: String { RPCThreadState.prompt(entry.text, context: context) }
    }

    /// A prompt handed to pi that it has not started as a user message yet.
    struct Dispatch {
        /// The send's operation id, or the first queued item's.
        let id: UUID
        /// What pi was handed: a design record's fence, if any, then the message.
        let text: String
        /// From the queue: its parts, and the items to put back if pi refuses it.
        let parts: [NativeQueuePart]?
        let items: [QueueItem]
        /// pi answered the prompt (accepted, or no answer in time).
        var responded = false
        /// An extension command runs at once and starts no user message of its own.
        let expectsMessage: Bool
    }

    var effectiveMode: NativeQueueMode { modeOverride ?? defaultQueueMode }

    /// pi is working, or about to be on a prompt it has not answered: a send now waits in the
    /// queue (or steers).
    var piBusy: Bool { running || !dispatches.isEmpty }

    /// pi settling does not leave the agent idle: a prompt of ours is on its way, or the
    /// queue goes next.
    var continuesAfterSettle: Bool {
        !dispatches.isEmpty || (!paused && !runFailed && dialogs.isEmpty && session.isAlive && !items.isEmpty
            && !items.contains { $0.entry.held })
    }

    /// pi is idle after all, and a "done" report was held for the queue: report it now.
    func idleAfterQueue() {
        guard doneHeld, !piBusy else { return }
        doneHeld = false
        onIdleAfterQueue?()
    }

    var queueValue: NativeQueue {
        NativeQueue(items: items.map(\.entry), mode: effectiveMode, paused: paused && !items.isEmpty, notice: items.isEmpty ? nil : queueNotice)
    }

    // MARK: - Sending

    /// A new message: to pi now when it is idle, else into the queue (or steered in). `alone`
    /// keeps a queued message from being joined with others (`QueueItem.goesAlone`). `context`
    /// is a fenced design view record that goes to pi ahead of the message (`QueueItem.context`).
    func send(id: UUID, text: String, delivery: NativeThreadDelivery, images: [NativeImage], alone: Bool = false,
              context: String? = nil, completion: @escaping (NativeThreadResult) -> Void) {
        guard piBusy else {
            // A new message resumes a paused queue: it drains after this turn.
            paused = false
            queueNotice = nil
            dispatch(id: id, text: text, context: context, images: images, parts: nil, items: [], completion: completion)
            return
        }
        guard items.count < Self.queueItemLimit,
              items.reduce(0, { $0 + $1.entry.text.utf8.count }) + text.utf8.count <= Self.queueTextLimit else {
            completion(.failure(code: "queue_full", message: "The queue is full. Send it or clear some of it first."))
            return
        }
        let item = QueueItem(
            entry: NativeQueuedMessage(id: id, text: text, images: images.map { NativeQueuedImage(mimeType: $0.mimeType, name: $0.name) },
                                       sentAt: Date().timeIntervalSince1970 * 1000),
            images: images, goesAlone: alone, context: context)
        items.append(item)
        // Only a running pi can take a steer: one of our prompts still on its way has not
        // started a run, so the message goes first after it instead.
        guard delivery == .steer, running else {
            if delivery == .steer { NativeQueueRules.move(id, toQueuedIndex: 0, in: &items) }
            commit()
            completion(.accepted(operationID: id))
            return
        }
        NativeQueueRules.steer([id], in: &items)
        commit()
        steerDispatch(id) { [weak self] failure in
            // pi refused it: the message was never queued, and the draft stays with the client.
            if failure != nil { self?.items.removeAll { $0.entry.id == id } }
            completion(failure ?? .accepted(operationID: id))
        }
    }

    func perform(_ action: NativeQueueAction, operationID: UUID, completion: @escaping (NativeThreadResult) -> Void) {
        let accepted = NativeThreadResult.accepted(operationID: operationID)
        let missing = NativeThreadResult.failure(code: "queue_item_unavailable", message: "That message is no longer queued.")
        switch action {
        case .edit(let id, let text):
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= Self.textLimit else {
                completion(.failure(code: "invalid", message: "A queued message needs text up to 16 KiB."))
                return
            }
            guard NativeQueueRules.edit(id, text: text, in: &items) else { completion(missing); return }
            if let index = items.firstIndex(where: { $0.entry.id == id }) { items[index].holdUntil = nil }
            completion(accepted)
            drainIfReady()
        case .delete(let id):
            let removed = NativeQueueRules.remove([id], from: &items)
            guard !removed.isEmpty else { completion(missing); return }
            remember(removed)
            completion(accepted)
        case .clear:
            remember(NativeQueueRules.remove(items.filter { $0.entry.state == .queued }.map(\.entry.id), from: &items))
            completion(accepted)
        case .restore(let ids, let index):
            let restoring = ids.compactMap { id in deleted.first { $0.item.entry.id == id }?.item }
            guard !restoring.isEmpty else { completion(missing); return }
            deleted.removeAll { entry in ids.contains(entry.item.entry.id) }
            NativeQueueRules.insert(restoring.map { var item = $0; item.entry.held = false; item.holdUntil = nil; return item },
                                    atQueuedIndex: index, into: &items)
            completion(accepted)
            drainIfReady()
        case .move(let id, let index):
            guard NativeQueueRules.move(id, toQueuedIndex: index, in: &items) else { completion(missing); return }
            completion(accepted)
        case .hold(let id, let held):
            guard let index = items.firstIndex(where: { $0.entry.id == id }) else { completion(missing); return }
            items[index].entry.held = held
            items[index].holdUntil = held ? Date().addingTimeInterval(Self.holdLease) : nil
            if held {
                queue.asyncAfter(deadline: .now() + Self.holdLease + 0.05) { [weak self] in
                    guard let self else { return }
                    self.releaseLapsedHolds()
                    self.drainIfReady()
                    self.commit()
                }
            }
            completion(accepted)
            if !held { drainIfReady() }
        case .setMode(let mode):
            modeOverride = mode
            completion(accepted)
        case .steer(let ids):
            guard piBusy else { sendNow(ids, completion: completion, operationID: operationID); return }
            guard running else {
                // A prompt of ours is on its way and pi has not started it: these go right after it.
                for (offset, id) in ids.enumerated() { NativeQueueRules.move(id, toQueuedIndex: offset, in: &items) }
                completion(accepted)
                return
            }
            let steered = NativeQueueRules.steer(ids, in: &items)
            guard !steered.isEmpty else { completion(missing); return }
            for id in steered {
                steerDispatch(id) { [weak self] failure in
                    // Back to the head of the queue, and say why.
                    guard let self, let failure, case .failure(_, let message) = failure else { return }
                    NativeQueueRules.unsteer(id, in: &self.items)
                    self.queueNotice = message
                    self.commit()
                }
            }
            completion(accepted)
        case .unsteer(let id):
            guard items.contains(where: { $0.entry.id == id && $0.entry.state == .steering }) else { completion(missing); return }
            unsteer(id) { completion($0 ?? accepted) }
        case .sendNow(let ids):
            guard !piBusy else {
                perform(.steer(ids: ids), operationID: operationID, completion: completion)
                return
            }
            sendNow(ids, completion: completion, operationID: operationID)
        }
    }

    private func remember(_ removed: [(item: QueueItem, index: Int)]) {
        deleted.append(contentsOf: removed)
        if deleted.count > Self.deletedLimit { deleted.removeFirst(deleted.count - Self.deletedLimit) }
    }

    private func releaseLapsedHolds() {
        let now = Date()
        for index in items.indices where items[index].entry.held && (items[index].holdUntil ?? .distantPast) <= now {
            items[index].entry.held = false
            items[index].holdUntil = nil
        }
    }

    // MARK: - Delivery

    /// pi is idle and the user asked for these now: they open the next turn (joined when there
    /// are several), and the rest of a paused queue resumes after it.
    private func sendNow(_ ids: [UUID], completion: @escaping (NativeThreadResult) -> Void, operationID: UUID) {
        let chosen = ids.compactMap { id in items.first { $0.entry.id == id && $0.entry.state == .queued } }
        guard !chosen.isEmpty else {
            completion(.failure(code: "queue_item_unavailable", message: "That message is no longer queued."))
            return
        }
        paused = false
        queueNotice = nil
        // The chosen items go first, in the order given.
        let rest = items.filter { item in !chosen.contains { $0.entry.id == item.entry.id } }
        items = chosen + rest
        NativeQueueRules.normalize(&items)
        deliver(count: NativeQueueRules.batchCount(chosen, mode: .all))
        completion(.accepted(operationID: operationID))
    }

    /// The queue goes when pi is idle, not paused, holds no question, and no editor holds it.
    func drainIfReady() {
        releaseLapsedHolds()
        guard !piBusy, !paused, session.isAlive, isServable, dialogs.isEmpty,
              !items.contains(where: { $0.entry.held }) else { return }
        let queued = items.filter { $0.entry.state == .queued }
        let count = NativeQueueRules.batchCount(queued, mode: effectiveMode)
        guard count > 0 else { return }
        deliver(count: count)
    }

    /// Hands the first `count` queued items to pi as one prompt.
    private func deliver(count: Int) {
        var batch: [QueueItem] = []
        var bytes = 0
        for item in items.filter({ $0.entry.state == .queued }).prefix(count) {
            let size = item.images.reduce(0) { $0 + $1.data.count }
            if !batch.isEmpty, bytes + size > Self.imageBytesLimit { break }
            bytes += size
            batch.append(item)
        }
        guard !batch.isEmpty else { return }
        items.removeAll { item in batch.contains { $0.entry.id == item.entry.id } }
        let parts = NativeQueueRules.parts(batch)
        // The latest record among them is the viewer's screen as the batch leaves.
        let context = batch.last { $0.context != nil }?.context
        dispatch(id: batch[0].entry.id, text: NativeQueueRules.joined(batch), context: context, images: batch.flatMap(\.images),
                 parts: parts, items: batch) { [weak self] result in
            // pi refused the delivery: the items return to the head, and the queue waits.
            guard let self, case .failure(let code, let message) = result, code != "outcome_unknown" else { return }
            NativeQueueRules.insert(batch, atQueuedIndex: 0, into: &self.items)
            self.paused = true
            self.queueNotice = message
            self.commit()
            self.idleAfterQueue()
        }
        commit()
    }

    /// Sends one prompt pi is expected to start as a user message, showing it as a pending row
    /// until pi does. `streamingBehavior` is always given, so a pi that started a run on its
    /// own (an extension, a child's report) queues it instead of refusing it; while idle pi
    /// treats it as a plain prompt. A fenced design record (`context`) goes ahead of the text.
    func dispatch(id: UUID, text: String, context: String? = nil, images: [NativeImage], parts: [NativeQueuePart]?, items batch: [QueueItem],
                  completion: @escaping (NativeThreadResult) -> Void) {
        let expectsMessage = !isExtensionCommand(text)
        let prompt = Self.prompt(text, context: context)
        dispatches.append(Dispatch(id: id, text: prompt, parts: parts, items: batch, expectsMessage: expectsMessage))
        if expectsMessage {
            var row = NativeThreadMessage.pendingSend(operationID: id, text: text, images: images.count,
                                                      timestamp: Date().timeIntervalSince1970 * 1000)
            row.origin = parts.map { Self.clipped(.queue(parts: $0)) }
            live.append(LiveItem(kind: .pending(id), value: row, raw: nil, ended: false))
        }
        commit()
        let rpcImages = images.map { RPCImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType) }
        session.request(.prompt(message: prompt, images: rpcImages, streamingBehavior: .followUp), timeout: Self.promptTimeout) { [weak self] result in
            guard let self else { return }
            let failure = Self.dispatchFailure(result)
            if let failure, case .failure(let code, _) = failure, code != "outcome_unknown" {
                self.dropDispatch(id)
            } else if let index = self.dispatches.firstIndex(where: { $0.id == id }) {
                self.dispatches[index].responded = true
                self.confirmDispatch(id)
            }
            self.commit()
            completion(failure ?? .accepted(operationID: id))
        }
    }

    /// pi answered a prompt that has not started a message yet: if pi is not working, it never
    /// will (an input handler took it, or it ran as a command), so its row goes.
    private func confirmDispatch(_ id: UUID) {
        guard dispatches.contains(where: { $0.id == id }) else { return }
        session.request(.getState) { [weak self] result in
            guard let self, case .success(let response) = result, response.success,
                  response.data?["isStreaming"]?.boolValue == false,
                  self.dispatches.contains(where: { $0.id == id && $0.responded }) else { return }
            self.dropDispatch(id)
            self.commit()
            self.drainIfReady()
            self.idleAfterQueue()
        }
    }

    private func dropDispatch(_ id: UUID) {
        dispatches.removeAll { $0.id == id }
        live.removeAll { $0.kind == .pending(id) }
    }

    /// The fenced design record ahead of the text, except for a command, which pi reads only at
    /// the start of a message.
    static func prompt(_ text: String, context: String?) -> String {
        guard let context, !text.hasPrefix("/") else { return text }
        return context + text
    }

    private func isExtensionCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let name = text.dropFirst().prefix { !$0.isWhitespace }
        return commands?.contains { $0.name == name && $0.source == "extension" } == true
    }

    // MARK: - Steering

    /// Hands a steering item to pi. `done` gets nil once pi queued it (or ran it at once as a
    /// command, which leaves nothing to land), else the failure.
    func steerDispatch(_ id: UUID, done: @escaping (NativeThreadResult?) -> Void) {
        guard let item = items.first(where: { $0.entry.id == id }) else { done(nil); return }
        unboundSteers.append(id)
        steersInFlight += 1
        let rpcImages = item.images.map { RPCImage(data: $0.data.base64EncodedString(), mimeType: $0.mimeType) }
        session.request(.prompt(message: item.promptText, images: rpcImages, streamingBehavior: .steer), timeout: Self.promptTimeout) { [weak self] result in
            guard let self else { return }
            self.unboundSteers.removeAll { $0 == id }
            self.steersInFlight -= 1
            let failure = Self.dispatchFailure(result)
            if failure == nil, let index = self.items.firstIndex(where: { $0.entry.id == id && $0.entry.state == .steering }),
               self.items[index].piText == nil {
                // pi answered without queueing anything: it ran the message at once (an
                // extension command), or an input handler took it.
                self.items.remove(at: index)
            }
            self.commit()
            // It may yet be queued when pi did not answer in time; settling sorts out one that
            // never lands.
            done(failure)
            if self.steersInFlight == 0, self.settleAwaitingSteers, !self.running {
                self.settleAwaitingSteers = false
                self.settled()
                self.commit()
            }
        }
    }

    /// pi's `queue_update`: binds steering items to the text pi queued for them.
    func piQueueChanged(steering: [String], followUp: [String]) {
        var previous = piSteering
        var added: [String] = []
        for text in steering {
            if let index = previous.firstIndex(of: text) { previous.remove(at: index) } else { added.append(text) }
        }
        for text in added {
            let exact = unboundSteers.first { id in items.first { $0.entry.id == id }?.promptText == text }
            // pi expands a template or skill before queueing it.
            let expanded = unboundSteers.first { id in items.first { $0.entry.id == id }?.entry.text.hasPrefix("/") == true }
            guard let id = exact ?? expanded, let index = items.firstIndex(where: { $0.entry.id == id }) else { continue }
            items[index].piText = text
            unboundSteers.removeAll { $0 == id }
        }
        piSteering = steering
        piFollowUp = followUp
    }

    /// Takes a steering item back: pi's queue is emptied and everything else in it handed back.
    /// When pi's queue no longer held it, pi read it before the clear arrived: it lands where
    /// pi read it, and the request is refused.
    private func unsteer(_ id: UUID, done: @escaping (NativeThreadResult?) -> Void) {
        clearPiQueue { [weak self] steering, followUp, failure in
            guard let self else { return }
            if let failure { done(failure); return }
            var remaining = steering
            var returned = false
            // The item is still pi's to read: it returns to the head of the queue.
            if let item = self.items.first(where: { $0.entry.id == id }), let index = remaining.firstIndex(of: item.piText ?? item.promptText) {
                remaining.remove(at: index)
                if let at = self.items.firstIndex(where: { $0.entry.id == id }) { self.items[at].piText = nil }
                NativeQueueRules.unsteer(id, in: &self.items)
                returned = true
            }
            self.restorePiQueue(steering: remaining, followUp: followUp)
            self.commit()
            done(returned ? nil : .failure(code: "queue_item_unavailable", message: "The agent has already read that message."))
        }
    }

    /// Everything `clear_queue` returned goes back to pi in order: this host's steering items
    /// are steered again, anything else pi had queued (an extension's) is re-sent as it was.
    private func restorePiQueue(steering: [String], followUp: [String]) {
        for text in steering {
            if let item = items.first(where: { $0.entry.state == .steering && ($0.piText ?? $0.promptText) == text }) {
                let id = item.entry.id
                if let index = items.firstIndex(where: { $0.entry.id == id }) { items[index].piText = nil }
                steerDispatch(id) { _ in }
            } else {
                session.send(.prompt(message: text, streamingBehavior: .steer))
            }
        }
        for text in followUp { session.send(.prompt(message: text, streamingBehavior: .followUp)) }
    }

    /// `clear_queue`, answering with what pi had queued.
    func clearPiQueue(_ done: @escaping (_ steering: [String], _ followUp: [String], _ failure: NativeThreadResult?) -> Void) {
        session.request(.clearQueue) { result in
            if let failure = Self.dispatchFailure(result) { done([], [], failure); return }
            guard case .success(let response) = result else { done([], [], nil); return }
            let steering = response.data?["steering"]?.arrayValue?.compactMap(\.stringValue) ?? []
            let followUp = response.data?["followUp"]?.arrayValue?.compactMap(\.stringValue) ?? []
            done(steering, followUp, nil)
        }
    }

    /// Steering items pi still holds go back to the queue's head, in order; anything else pi
    /// had queued joins the queue after them, so nothing is lost. Items pi no longer holds have
    /// landed (or are landing).
    private func reclaim(steering: [String], followUp: [String]) {
        var remaining = steering
        var back: [QueueItem] = []
        for item in items where item.entry.state == .steering {
            guard let index = remaining.firstIndex(of: item.piText ?? item.promptText) else { continue }
            remaining.remove(at: index)
            var returned = item
            returned.piText = nil
            back.append(returned)
        }
        items.removeAll { item in back.contains { $0.entry.id == item.entry.id } }
        let now = Date().timeIntervalSince1970 * 1000
        let adopted = (remaining + followUp).map {
            QueueItem(entry: NativeQueuedMessage(id: UUID(), text: $0, sentAt: now), images: [])
        }
        NativeQueueRules.insert(back + adopted, atQueuedIndex: 0, into: &items)
        unboundSteers.removeAll()
    }

    // MARK: - Stop and settle

    /// Stop: pi's queue is emptied first (pi's recipe; `abort` alone still delivers it), steering
    /// items return to the queue, and the queue pauses until the user resumes it.
    func stop(_ done: @escaping (Result<RPCResponse, RPCError>) -> Void) {
        stopRequested = true
        clearPiQueue { [weak self] steering, followUp, _ in
            guard let self else { return }
            self.reclaim(steering: steering, followUp: followUp)
            if !self.items.isEmpty {
                self.paused = true
                self.queueNotice = nil
            }
            self.commit()
            self.session.request(.abort, completion: done)
        }
    }

    /// `agent_settled`: pi is idle. Prompts it accepted but never started are over; steering it
    /// never read (queued after its last look) is reclaimed; then the queue goes.
    func settled() {
        for dispatch in dispatches where dispatch.responded { dropDispatch(dispatch.id) }
        if runFailed, !stopRequested, !items.isEmpty {
            paused = true
            queueNotice = "The agent's turn ended with an error, so the queue is waiting."
        }
        // A steer pi has not answered may not be in its queue yet: clearing now would miss it.
        guard steersInFlight == 0 else {
            settleAwaitingSteers = true
            return
        }
        guard items.contains(where: { $0.entry.state == .steering }) || !piSteering.isEmpty || !piFollowUp.isEmpty else {
            drainIfReady()
            idleAfterQueue()
            return
        }
        clearPiQueue { [weak self] steering, followUp, _ in
            guard let self else { return }
            self.reclaim(steering: steering, followUp: followUp)
            // Steering that landed while the clear was on its way left no text behind.
            self.items.removeAll { $0.entry.state == .steering }
            self.commit()
            self.drainIfReady()
            self.idleAfterQueue()
        }
    }

    // MARK: - pi's user messages

    /// pi started a user message: it read it now, at this point in the run. It joins the thread
    /// here, carrying where it came from.
    func userMessageStarted(_ message: RPCMessage) {
        let text = message.content.compactMap { block -> String? in
            if case .text(let text) = block { return text }
            return nil
        }.joined()
        var origin: NativeMessageOrigin?
        var operationID: UUID?
        if let index = items.firstIndex(where: { $0.entry.state == .steering && ($0.piText ?? $0.promptText) == text }) {
            let item = items.remove(at: index)
            unboundSteers.removeAll { $0 == item.entry.id }
            origin = .steered
            operationID = item.entry.id
        } else if let index = boundDispatch(for: text) {
            let dispatch = dispatches[index]
            dropDispatch(dispatch.id)
            origin = dispatch.parts.map { .queue(parts: $0) }
            operationID = dispatch.id
        }
        let id = liveEntryID(for: message)
        var value = Self.project(entryID: id, message: message)
        value.origin = origin.map(Self.clipped)
        value.operationID = operationID
        live.append(LiveItem(kind: .user, value: value, raw: message, ended: false))
        if let origin { recordOrigin(origin, entryID: id) }
        if let operationID { operationsByEntry[id] = operationID }
    }

    /// The prompt this user message is: the same text (pi may append image notes after it),
    /// or, for a command or template pi expanded, the oldest such prompt pi has accepted.
    private func boundDispatch(for text: String) -> Int? {
        if let index = dispatches.firstIndex(where: { $0.expectsMessage && (text == $0.text || text.hasPrefix($0.text + "\n\n")) }) {
            return index
        }
        return dispatches.firstIndex { $0.expectsMessage && $0.responded && $0.text.hasPrefix("/") }
    }

    /// A new pi session: its queue is new, so steering items wait in the queue again.
    func resetQueueForNewSession() {
        for dispatch in dispatches { live.removeAll { $0.kind == .pending(dispatch.id) } }
        dispatches.removeAll()
        for index in items.indices where items[index].entry.state == .steering {
            items[index].entry.state = .queued
            items[index].piText = nil
        }
        NativeQueueRules.normalize(&items)
        unboundSteers.removeAll()
        piSteering = []
        piFollowUp = []
        origins = [:]
        originOrder = []
    }
}
