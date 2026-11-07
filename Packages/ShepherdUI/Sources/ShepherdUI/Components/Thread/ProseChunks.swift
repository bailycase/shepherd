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
    let content: (Element) -> Content

    public init(_ elements: [Element], id: KeyPath<Element, ID>, continuesList: KeyPath<Element, Bool>,
                @ViewBuilder content: @escaping (Element) -> Content) {
        self.elements = elements
        self.id = id
        self.continuesList = continuesList
        self.content = content
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if elements.count > 1 {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(elements.dropLast(), id: id) { element in
                        content(element).padding(.top, gap(element))
                    }
                }
            }
            if let last = elements.last {
                content(last).padding(.top, gap(last)).id(last[keyPath: id])
            }
        }
    }

    private func gap(_ element: Element) -> CGFloat {
        guard let first = elements.first, element[keyPath: id] != first[keyPath: id] else { return 0 }
        return element[keyPath: continuesList] ? SH.Space.xs : SH.Space.l
    }
}
