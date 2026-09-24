import Foundation
import ShepherdProtocol

/// Something that sits in a thread's queue: the wire item itself (a client's copy), or the
/// host's, which also keeps the images' bytes.
public protocol NativeQueueEntry {
    var entry: NativeQueuedMessage { get set }
}

extension NativeQueuedMessage: NativeQueueEntry {
    public var entry: NativeQueuedMessage {
        get { self }
        set { self = newValue }
    }
}

/// The queue's rules, shared by the host (which owns the queue) and the store (which shows a
/// change at once, before the host's next snapshot confirms it). Steering items come first, in
/// the order they were steered; queued items follow in delivery order. Indexes given to these
/// functions count queued items only.
public enum NativeQueueRules {
    /// What one "everything at once" delivery may carry: pi takes one message per prompt, so
    /// the parts are joined, and this keeps the joined message within reason.
    public static let joinedTextLimit = 64 * 1024
    /// Parts are joined with a blank line between them.
    public static let separator = "\n\n"

    /// How many queued items (from the head) the next delivery takes. One per turn takes the
    /// head. All at once takes the run of items from the head up to one that begins with "/"
    /// (pi runs a command or expands a template only at the start of a message, so such an item
    /// always goes alone), within `NativeImage.maxPerSend` images and `joinedTextLimit`.
    public static func batchCount<T: NativeQueueEntry>(_ queued: [T], mode: NativeQueueMode) -> Int {
        guard let head = queued.first else { return 0 }
        if mode == .oneAtATime || head.entry.text.hasPrefix("/") { return 1 }
        var count = 1
        var images = head.entry.images.count
        var bytes = head.entry.text.utf8.count
        for item in queued.dropFirst() {
            let text = item.entry.text
            images += item.entry.images.count
            bytes += separator.utf8.count + text.utf8.count
            if text.hasPrefix("/") || images > NativeImage.maxPerSend || bytes > joinedTextLimit { break }
            count += 1
        }
        return count
    }

    public static func joined<T: NativeQueueEntry>(_ items: [T]) -> String {
        items.map(\.entry.text).joined(separator: separator)
    }

    public static func parts<T: NativeQueueEntry>(_ items: [T]) -> [NativeQueuePart] {
        items.map { NativeQueuePart(id: $0.entry.id, text: $0.entry.text, sentAt: $0.entry.sentAt, images: $0.entry.images.count) }
    }

    /// Steering items first (keeping their order), then queued ones (keeping theirs).
    public static func normalize<T: NativeQueueEntry>(_ items: inout [T]) {
        let steering = items.filter { $0.entry.state == .steering }
        guard !steering.isEmpty else { return }
        items = steering + items.filter { $0.entry.state != .steering }
    }

    /// The position in `items` of queued index `index` (clamped): where an item inserted there
    /// lands.
    static func position<T: NativeQueueEntry>(ofQueuedIndex index: Int, in items: [T]) -> Int {
        let steering = items.count { $0.entry.state == .steering }
        return steering + min(max(0, index), items.count - steering)
    }

    /// The item's index among queued items, or nil when it is not queued.
    public static func queuedIndex<T: NativeQueueEntry>(of id: UUID, in items: [T]) -> Int? {
        items.filter { $0.entry.state == .queued }.firstIndex { $0.entry.id == id }
    }

    /// Replaces a queued item's text. Steering items cannot change: pi already has them.
    @discardableResult
    public static func edit<T: NativeQueueEntry>(_ id: UUID, text: String, in items: inout [T]) -> Bool {
        guard let index = items.firstIndex(where: { $0.entry.id == id && $0.entry.state == .queued }) else { return false }
        items[index].entry.text = text
        items[index].entry.held = false
        return true
    }

    /// Removes queued items, returning each with the queued index it had (for an undo).
    @discardableResult
    public static func remove<T: NativeQueueEntry>(_ ids: [UUID], from items: inout [T]) -> [(item: T, index: Int)] {
        var removed: [(item: T, index: Int)] = []
        for id in ids {
            guard let queuedIndex = queuedIndex(of: id, in: items),
                  let index = items.firstIndex(where: { $0.entry.id == id }) else { continue }
            removed.append((items.remove(at: index), queuedIndex))
        }
        return removed
    }

    /// Puts items back at queued index `index`, in order, as queued. Ids already present stay
    /// where they are.
    public static func insert<T: NativeQueueEntry>(_ new: [T], atQueuedIndex index: Int, into items: inout [T]) {
        let present = Set(items.map(\.entry.id))
        var at = position(ofQueuedIndex: index, in: items)
        for var item in new where !present.contains(item.entry.id) {
            item.entry.state = .queued
            items.insert(item, at: at)
            at += 1
        }
    }

    @discardableResult
    public static func move<T: NativeQueueEntry>(_ id: UUID, toQueuedIndex index: Int, in items: inout [T]) -> Bool {
        guard let from = items.firstIndex(where: { $0.entry.id == id && $0.entry.state == .queued }) else { return false }
        let item = items.remove(at: from)
        items.insert(item, at: position(ofQueuedIndex: index, in: items))
        return true
    }

    @discardableResult
    public static func hold<T: NativeQueueEntry>(_ id: UUID, _ held: Bool, in items: inout [T]) -> Bool {
        guard let index = items.firstIndex(where: { $0.entry.id == id }) else { return false }
        items[index].entry.held = held
        return true
    }

    /// Marks queued items as steering, after any already steering, in the order given.
    /// Returns the ids that changed.
    @discardableResult
    public static func steer<T: NativeQueueEntry>(_ ids: [UUID], in items: inout [T]) -> [UUID] {
        var moved: [T] = []
        for id in ids {
            guard let index = items.firstIndex(where: { $0.entry.id == id && $0.entry.state == .queued }) else { continue }
            var item = items.remove(at: index)
            item.entry.state = .steering
            item.entry.held = false
            moved.append(item)
        }
        let steering = items.count { $0.entry.state == .steering }
        items.insert(contentsOf: moved, at: steering)
        return moved.map(\.entry.id)
    }

    /// A steering item goes back to the head of the queue.
    @discardableResult
    public static func unsteer<T: NativeQueueEntry>(_ id: UUID, in items: inout [T]) -> Bool {
        guard let index = items.firstIndex(where: { $0.entry.id == id && $0.entry.state == .steering }) else { return false }
        var item = items.remove(at: index)
        item.entry.state = .queued
        items.insert(item, at: position(ofQueuedIndex: 0, in: items))
        return true
    }
}
