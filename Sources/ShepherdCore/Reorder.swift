extension Array where Element: Identifiable {
    /// The array with the element `id` moved to sit immediately before `target`, which is where
    /// the sidebar draws its drop line. Nil when either is missing or they are the same element.
    public func moving(_ id: Element.ID, before target: Element.ID) -> [Element]? {
        guard id != target, let from = firstIndex(where: { $0.id == id }) else { return nil }
        var result = self
        let moved = result.remove(at: from)
        guard let to = result.firstIndex(where: { $0.id == target }) else { return nil }
        result.insert(moved, at: to)
        return result
    }
}
