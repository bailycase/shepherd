import SwiftUI

/// A long reply drawn a chunk at a time: every chunk but the last in a lazy stack, so only the
/// ones in view are built (and the ones scrolled far away are let go), and the last chunk laid
/// out for real, where a streaming reply grows and the thread follows it. A chunk holds blocks
/// 12pt apart (`SHAgentProse`); here it sits `SH.Space.l` under the chunk before it, or
/// `SH.Space.xs` (a list's item gap) when it carries on a list the chunk before it ended in.
///
/// The last chunk is keyed by its id, so the chunk that takes its place as the reply grows
/// starts with fresh `@State` (an inline gate, a fence's colors, an open disclosure) rather than
/// inheriting the previous chunk's. Each `ForEach` row is one view.
public struct SHProseChunks<Element, ID: Hashable, Content: View>: View {
    let elements: [Element]
    let id: KeyPath<Element, ID>
    let continuesList: KeyPath<Element, Bool>
    let lazyPrefix: Bool
    let content: (Element) -> Content

    /// `lazyPrefix` false lays every chunk out for real: for a host whose own scroll view cannot
    /// place a lazy stack nested in its lazy rows (iOS 27.0's bottom anchor draws a long reply blank).
    public init(_ elements: [Element], id: KeyPath<Element, ID>, continuesList: KeyPath<Element, Bool>, lazyPrefix: Bool = true,
                @ViewBuilder content: @escaping (Element) -> Content) {
        self.elements = elements
        self.id = id
        self.continuesList = continuesList
        self.lazyPrefix = lazyPrefix
        self.content = content
    }

    public var body: some View {
        let split = lazyPrefix ? max(0, elements.count - Self.eagerTail) : 0
        VStack(alignment: .leading, spacing: 0) {
            if split > 0 {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(elements.prefix(split), id: id) { element in
                        content(element).padding(.top, gap(element))
                    }
                }
            }
            ForEach(elements.dropFirst(split), id: id) { element in
                content(element).padding(.top, gap(element))
            }
        }
    }

    /// The chunks at the end that are laid out for real.
    static var eagerTail: Int { 2 }

    private func gap(_ element: Element) -> CGFloat {
        guard let first = elements.first, element[keyPath: id] != first[keyPath: id] else { return 0 }
        return element[keyPath: continuesList] ? SH.Space.xs : SH.Space.l
    }
}
