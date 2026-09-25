import Foundation
import ShepherdProtocol
import ShepherdRemote

/// A thread served from a fixed snapshot whose queue behaves as the host's does: a send while it
/// runs joins the queue (or steers), and every queue action changes it by the host's own rules
/// (`NativeQueueRules`). No pi, no server: for views and the store's queue in UI tests and
/// previews. Everything it was asked is recorded.
@MainActor
public final class QueueFixture {
    public var snapshot: NativeThreadSnapshot
    public private(set) var actions: [NativeQueueAction] = []
    public private(set) var sends: [(text: String, delivery: NativeThreadDelivery)] = []
    public private(set) var aborts = 0
    private var deleted: [UUID: NativeQueuedMessage] = [:]

    public init(_ snapshot: NativeThreadSnapshot) {
        var snapshot = snapshot
        if snapshot.queue == nil { snapshot.queue = NativeQueue(mode: .all) }
        if !snapshot.supportedActions.contains("queue") { snapshot.supportedActions.append("queue") }
        self.snapshot = snapshot
    }

    /// Queued messages sent `minutes` ago, in order; `steering` of them first, as steering.
    public static func messages(_ texts: [String], steering: Int = 0, images: [Int: [String]] = [:]) -> [NativeQueuedMessage] {
        let now = Date().timeIntervalSince1970 * 1000
        return texts.enumerated().map { index, text in
            NativeQueuedMessage(id: UUID(), text: text, images: (images[index] ?? []).map { NativeQueuedImage(mimeType: "image/png", name: $0) },
                                sentAt: now - Double(texts.count - index) * 60_000, state: index < steering ? .steering : .queued)
        }
    }

    public var queue: [NativeQueuedMessage] { snapshot.queue?.items ?? [] }

    /// Serves `request` as the host would.
    public func answer(_ request: NativeThreadRequest) -> NativeThreadResult {
        switch request {
        case .snapshot:
            return .snapshot(value: snapshot)
        case .send(_, _, let operation, let text, let delivery, let images):
            sends.append((text, delivery))
            if snapshot.running {
                var items = queue
                items.append(NativeQueuedMessage(id: operation, text: text,
                                                 images: (images ?? []).map { NativeQueuedImage(mimeType: $0.mimeType, name: $0.name) },
                                                 sentAt: Date().timeIntervalSince1970 * 1000,
                                                 state: delivery == .steer ? .steering : .queued))
                NativeQueueRules.normalize(&items)
                change(items)
            }
            return .accepted(operationID: operation)
        case .queue(_, _, let operation, let action):
            actions.append(action)
            apply(action)
            return .accepted(operationID: operation)
        case .abort(_, _, let operation):
            aborts += 1
            return .accepted(operationID: operation)
        default:
            return .snapshot(value: snapshot)
        }
    }

    private func apply(_ action: NativeQueueAction) {
        var items = queue
        var mode = snapshot.queue?.mode
        switch action {
        case .edit(let id, let text): NativeQueueRules.edit(id, text: text, in: &items)
        case .delete(let id):
            for removed in NativeQueueRules.remove([id], from: &items) { deleted[removed.item.id] = removed.item }
        case .clear:
            for removed in NativeQueueRules.remove(items.filter { $0.state == .queued }.map(\.id), from: &items) {
                deleted[removed.item.id] = removed.item
            }
        case .restore(let ids, let index): NativeQueueRules.insert(ids.compactMap { deleted[$0] }, atQueuedIndex: index, into: &items)
        case .move(let id, let index): NativeQueueRules.move(id, toQueuedIndex: index, in: &items)
        case .steer(let ids):
            if snapshot.running { NativeQueueRules.steer(ids, in: &items) } else { items.removeAll { ids.contains($0.id) } }
        case .unsteer(let id): NativeQueueRules.unsteer(id, in: &items)
        case .hold(let id, let held): NativeQueueRules.hold(id, held, in: &items)
        case .setMode(let chosen): mode = chosen ?? .all
        case .sendNow(let ids): items.removeAll { ids.contains($0.id) }
        }
        change(items, mode: mode)
    }

    /// Replaces the queue, as a new revision.
    public func change(_ items: [NativeQueuedMessage], mode: NativeQueueMode? = nil, paused: Bool? = nil) {
        var queue = snapshot.queue ?? NativeQueue()
        queue.items = items
        if let mode { queue.mode = mode }
        if let paused { queue.paused = paused }
        snapshot.queue = queue
        snapshot.revision += 1
    }
}
