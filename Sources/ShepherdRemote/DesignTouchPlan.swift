import CoreGraphics
import Foundation
import ShepherdProtocol

// The iPad Design tool's pure rules (docs/designs.md › iPad): which boards get the live web view
// the plan allows on iOS, and where designs sit among the threads in the sidebar's Recents.

/// Which boards get a live web view on iOS, and which views make room. The plan caps iOS at two
/// web views: this one live board and the one off-screen view that draws every other board's
/// snapshot. Beside the Mac's plan, a board a tap is asking about (its hit test needs a live
/// view) comes before the selected one, since one view can't hold both.
public enum DesignTouchLivePlan {
    /// Live views for the design on screen.
    public static let liveCap = 1
    /// Below this zoom boards draw from their snapshots; the selected board stays live down to
    /// `selectedThreshold`.
    public static let threshold: CGFloat = 0.25
    public static let selectedThreshold: CGFloat = 0.1

    /// The boards to keep live, most wanted first: the board a tap is asking about, the selected
    /// board, then the visible boards in the order given (nearest the middle first).
    public static func wanted(visible: [DesignPath], selected: DesignPath?, asked: DesignPath? = nil, zoom: CGFloat,
                              cap: Int = liveCap) -> [DesignPath] {
        var result: [DesignPath] = []
        if let asked { result.append(asked) }
        if let selected, zoom >= selectedThreshold, !result.contains(selected) { result.append(selected) }
        if zoom >= threshold {
            for path in visible where !result.contains(path) && result.count < cap { result.append(path) }
        }
        return Array(result.prefix(max(0, cap)))
    }

    public struct Assignment: Equatable, Sendable {
        /// Views to give up, least recently wanted first.
        public var evict: [DesignPath]
        /// Boards that need a view.
        public var create: [DesignPath]

        public init(evict: [DesignPath], create: [DesignPath]) {
            self.evict = evict
            self.create = create
        }
    }

    /// Makes room for the wanted boards among `slots` (each live board and when it was last
    /// wanted): a board keeps its view; a new one takes a free slot, else the least recently
    /// wanted slot no wanted board holds.
    public static func assign(slots: [DesignPath: UInt64], wanted: [DesignPath], cap: Int = liveCap) -> Assignment {
        let missing = wanted.filter { slots[$0] == nil }
        let free = max(0, cap - slots.count)
        let evictable = slots.filter { !wanted.contains($0.key) }
            .sorted { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }
            .map(\.key)
        return Assignment(evict: Array(evictable.prefix(max(0, missing.count - free))), create: missing)
    }
}

/// Split View's "Send to the thread" (iPadSplitView): the boards the viewer chose, as images for
/// another thread's composer, and a line that carries none of the design's own text. Board
/// titles, names and file names are the agent's (or an imported canvas's) words; the thread
/// they go to reads no fence, so none of them rides the message. The viewer sees both in the
/// composer and sends them, or not.
public enum DesignSpecHandoff {
    /// What the composer gets beside the images.
    public static let message = "Use the attached boards as the spec."

    /// The boards of the page shown that are picked (whole, or holding a picked element), else
    /// every board of that page; in canvas order, at most `limit` (what one message takes).
    public static func boards(order: [DesignPath], onPage: (DesignPath) -> Bool, picked: Set<DesignPath>,
                              limit: Int = NativeImage.maxPerSend) -> [DesignPath] {
        let page = order.filter(onPage)
        let chosen = page.filter(picked.contains)
        return Array((chosen.isEmpty ? page : chosen).prefix(max(0, limit)))
    }

    /// An image's name in the composer: the board's place, never its file name.
    public static func imageName(_ index: Int) -> String { "Board \(index + 1).png" }
}

/// The iPad sidebar's Recents with designs among the threads (iPadSidebar): a design is one row
/// with its boards, and its agent's thread is never listed (the design is its row).
public enum DesignRecents {
    public enum Entry<Design: Equatable & Sendable>: Equatable, Sendable {
        case thread(FleetThreadRow)
        case design(Design)
    }

    /// Designs merged into `threads` (already in Recents' order) by when each last moved (ms): a
    /// running thread keeps its place, and a design goes before the first quiet thread that moved
    /// before it. Designs come most recently active first; those older than every thread follow.
    public static func merge<Design: Equatable & Sendable>(threads: [FleetThreadRow], designs: [Design],
                                                            lastActive: (Design) -> Double) -> [Entry<Design>] {
        var result: [Entry<Design>] = []
        var pending = designs.enumerated()
            .sorted { lastActive($0.element) != lastActive($1.element) ? lastActive($0.element) > lastActive($1.element) : $0.offset < $1.offset }
            .map(\.element)[...]
        for thread in threads {
            if thread.status != .working, let moved = thread.lastMoved {
                while let design = pending.first, lastActive(design) > moved {
                    result.append(.design(design))
                    pending = pending.dropFirst()
                }
            }
            result.append(.thread(thread))
        }
        result.append(contentsOf: pending.map { Entry.design($0) })
        return result
    }
}

extension DesignRecents.Entry: Identifiable where Design: Identifiable {
    /// A thread's ref or a design's id: never the same whatever they hold.
    public var id: AnyHashable {
        switch self {
        case .thread(let row): AnyHashable(row.id)
        case .design(let design): AnyHashable(design.id)
        }
    }
}
