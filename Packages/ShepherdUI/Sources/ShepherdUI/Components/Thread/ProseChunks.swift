import SwiftUI

/// A long reply drawn a chunk at a time: every chunk but the last `eagerTail` in a lazy stack, so
/// only the ones in view are built (and the ones scrolled far away are let go), and the last
/// chunks laid out for real, where a streaming reply grows and the thread follows it. A chunk
/// holds blocks 12pt apart (`SHAgentProse`); here it sits `SH.Space.l` under the chunk before it,
/// or `SH.Space.xs` (a list's item gap) when it carries on a list the chunk before it ended in.
///
/// Identity is the keyed `ForEach`: a chunk keeps its `@State` (an inline gate, a fence's colors,
/// an open disclosure) while it stays in the same stack, and a new chunk starts fresh. One that
/// moves from the eager tail into the lazy stack as the reply grows is built again. `content`
/// returns one view per element: each `ForEach` row of a lazy stack must be a single view.
public struct SHProseChunks<Element, ID: Hashable, Content: View>: View {
    let elements: [Element]
    let id: KeyPath<Element, ID>
    let continuesList: KeyPath<Element, Bool>
    let eagerTail: Int
    let content: (Element) -> Content

    /// `eagerTail` is how many chunks at the end are laid out for real; the ones before them are
    /// lazy. The default lays every chunk out, as one view would. A lazy stack nested in a host's own
    /// lazy rows estimates the height of the chunks it has not built, and a reader scrolling up
    /// through them sees the text move under them when it corrects: so a host asks for it only where
    /// the chunks are too many to build at once, and where its scroll view has been shown to place
    /// one (iOS's transcript has not: its bottom anchor drew a long reply blank on iOS 27.0, and its
    /// row-id anchor can move text when a chunk is built).
    public init(_ elements: [Element], id: KeyPath<Element, ID>, continuesList: KeyPath<Element, Bool>, eagerTail: Int = .max,
                content: @escaping (Element) -> Content) {
        self.elements = elements
        self.id = id
        self.continuesList = continuesList
        self.eagerTail = eagerTail
        self.content = content
    }

    public var body: some View {
        let split = max(0, elements.count - max(1, eagerTail))
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

    private func gap(_ element: Element) -> CGFloat {
        guard let first = elements.first, element[keyPath: id] != first[keyPath: id] else { return 0 }
        return element[keyPath: continuesList] ? SH.Space.xs : SH.Space.l
    }
}
