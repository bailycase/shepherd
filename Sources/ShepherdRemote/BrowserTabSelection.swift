import Foundation

/// The order and selection of a thread's local browser tabs. No WebKit or connection state.
public struct BrowserTabSelection {
    public static let limit = 8
    public private(set) var ids: [UUID]
    public private(set) var selected: UUID

    public init(first: UUID) {
        ids = [first]
        selected = first
    }

    public var canAdd: Bool { ids.count < Self.limit }

    @discardableResult
    public mutating func add(_ id: UUID) -> Bool {
        guard canAdd, !ids.contains(id) else { return false }
        ids.append(id)
        selected = id
        return true
    }

    public mutating func select(_ id: UUID) {
        if ids.contains(id) { selected = id }
    }

    /// The next tab takes over, or the previous one at the trailing edge. Keep an empty tab
    /// when the last one closes, so the Browser still has an address field.
    public mutating func close(_ id: UUID, replacement: @autoclosure () -> UUID) {
        guard let index = ids.firstIndex(of: id) else { return }
        ids.remove(at: index)
        if ids.isEmpty { ids = [replacement()] }
        if selected == id { selected = ids[min(index, ids.count - 1)] }
    }

    public mutating func closeOthers() { ids = [selected] }
}
