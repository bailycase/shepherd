import Foundation
import ShepherdCore
import ShepherdProtocol

/// What the person does about dispatches from this Mac's app (`FleetAction.sendThread`, `retryDispatch`,
/// `cancelDispatch`; server queue): start a thread on the Mac Auto picks, and decide what becomes of a dispatch that
/// waits, is held or wasn't sent. A thread the person starts is a `userThread` dispatch: no parent thread, its result
/// is the thread, and it shows in the Dispatches log as "sent by you".
extension FleetDispatch {
    /// The code a first placement answers with when the work stays on this Mac: not a failure, the app starts the thread.
    static let keptHere = "kept_here"

    /// Sends a thread from New thread. Answers once the target took it (or was found unable to), at once when it waits, or
    /// with `nil` when the work stays on this Mac (named or chosen by Auto), which the app starts itself as it always did.
    func dispatchUserThread(_ thread: FleetUserThread, reply: @escaping (Result<FleetDispatchRecord?, FleetDispatchRefusal>) -> Void) {
        guard membership() else {
            return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil)))
        }
        let id = thread.dispatchID
        // A retry of a send that already went answers what it made.
        if let existing = outbound[id] { return reply(.success(existing.summary)) }
        let task = thread.task.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !task.isEmpty, task.utf8.count <= FleetDispatchProtocol.maxTaskBytes else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "The task is empty or longer than \(FleetDispatchProtocol.maxTaskBytes / 1024) KiB.")))
        }
        let requested = FleetPlacement.isAuto(thread.host) ? nil : thread.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Named for this very Mac: nothing to send.
        if let requested, requested.lowercased() == hostName().lowercased() || requested.lowercased() == hostID.uuidString.lowercased() {
            return reply(.success(nil))
        }
        guard let space = host.state().spaces.first(where: { $0.id == thread.spaceID }), let repoKey = space.repoKey else {
            // A folder with no origin has no key another Mac could find it by: Auto keeps it here, a named Mac is refused.
            return requested == nil ? reply(.success(nil))
                : reply(.failure(.init(code: FleetDispatchCode.repoMissing, message: "This space has no origin remote, so no other Mac can find its repository.")))
        }
        var record = FleetDispatchRecord(
            id: id, kind: .userThread, parentHostID: hostID, parentHostName: hostName(), requestedHost: requested, state: .placing,
            title: Self.title(thread.title, task: task), task: task, repoKey: repoKey, model: thread.model?.fleetNonEmpty,
            thinking: thread.thinking?.fleetNonEmpty, createdAt: now)
        record.updatedAt = record.createdAt
        outbound[id] = record
        firstPlacements.insert(id)
        save()
        place(id) { [weak self] result in
            self?.firstPlacements.remove(id)
            switch result {
            case .success(let record): reply(.success(record.summary))
            case .failure(let refusal) where refusal.code == Self.keptHere: reply(.success(nil))
            case .failure(let refusal): reply(.failure(refusal))
            }
        }
    }

    /// Sends a dispatch that waits, is held or wasn't sent, to `target` (a Mac's id, this one included) or as it was
    /// asked. A record that failed starts again under a new id: the Mac that refused it may hold its copy of the first
    /// try, which would answer for the second.
    func retry(_ id: UUID, host target: UUID?, reply: @escaping (Result<FleetDispatchRecord, FleetDispatchRefusal>) -> Void) {
        guard membership() else { return reply(.failure(Self.refusal(FleetDispatchCode.fleetOff, nil))) }
        guard var record = outbound[id] else {
            return reply(.failure(.init(code: FleetDispatchProtocol.Code.unknownDispatch, message: "This Mac has no such dispatch.")))
        }
        guard [.waitingRoom, .waitingWake, .heldLimit, .heldRestart, .failed].contains(record.state), !placing.contains(id), !sending.contains(id) else {
            return reply(.failure(.init(code: FleetDispatchCode.invalid, message: "That dispatch isn't waiting for anything (it is \(record.state.rawValue)).")))
        }
        if record.state == .failed {
            outbound[id] = nil
            record.id = UUID()
        }
        record.state = .placing
        record.failure = nil
        record.failureDetail = nil
        record.targetHostID = nil
        record.targetHostName = nil
        record.remoteAgentID = nil
        record.reasonCodes = []
        record.activity = nil
        if let target { record.requestedHost = target.uuidString }
        record.updatedAt = now
        let next = record.id
        outbound[next] = record
        save()
        guard canStart(record) else {
            outbound[next]?.state = .heldLimit
            save()
            return reply(.success((outbound[next] ?? record).summary))
        }
        place(next) { result in reply(result.map(\.summary)) }
    }
}
