import Foundation
import ShepherdCore

/// What a terminal panel shows ahead of its host (the optimistic part of + and Close): a tab that
/// opens at once, selected and Starting, and a tab that closes at once. The host's layout stays
/// the truth. This only decides which tabs to draw while a request is in flight, and takes itself
/// back out when the host's push or its refusal arrives. Pure, so the races are unit-tested
/// (`TerminalTabOverlayTests`); the Mac panel and the iOS panel both hold one per thread.
///
/// - An opening tab is a placeholder with its own id. It has no session, so nothing can be typed
///   into it. The host's reply names the real pane; once the layout holds that pane the real tab
///   takes the placeholder's place, and the selection and keyboard follow it only if they were
///   still on the placeholder.
/// - The host's push may carry the new pane before its reply does. A pane that appears while a
///   placeholder waits, and was not in the layout when it opened, is held back until the reply says
///   whose it is, so the tab never shows twice.
/// - A closing tab is hidden until the layout drops it. If the host refuses, it comes back where it
///   was: nothing is selected or focused again.
public struct TerminalTabOverlay: Equatable, Sendable {
    /// A tab that was asked for and has no pane to show yet.
    public struct Pending: Equatable, Sendable, Identifiable {
        /// The placeholder's id: never a pane of the layout.
        public let id: PaneID
        public let cwd: String
        /// What the layout held when it was asked for.
        let baseline: Set<PaneID>
        /// The pane the host made, once it has replied.
        public internal(set) var real: PaneID?
        /// Closed while it was still starting: the pane the host makes is closed again.
        public internal(set) var abandoned = false
        /// What was selected and focused before, to go back to if the host refuses.
        public let previousChosen: PaneID?
        public let previousFocus: PaneID?
    }

    /// A tab leaving the layout.
    struct Closing: Equatable, Sendable {
        /// The layout has held it since it was asked to go.
        var seen: Bool
        /// The host said it closed it.
        var confirmed = false
    }

    public struct Promotion: Hashable, Sendable {
        public let pending: PaneID
        public let real: PaneID
    }

    /// What closing a tab that was still starting asks of the caller.
    public enum Abandon: Equatable, Sendable {
        /// Nothing to ask the host yet: its reply, when it comes, is told to close the new pane.
        case waiting
        /// The host already made this pane: close it.
        case close(PaneID)
        /// Not a placeholder of this overlay.
        case unknown
    }

    /// What a host's reply that it opened a pane asks of the caller.
    public enum Opened: Equatable, Sendable {
        /// The tab is that pane once the layout has it.
        case adopted
        /// The tab was closed while it started: close this pane.
        case close(PaneID)
        case unknown
    }

    public static let startingTitle = "Starting…"

    public private(set) var pending: [Pending] = []
    private(set) var closing: [PaneID: Closing] = [:]

    public init() {}

    public var isEmpty: Bool { pending.isEmpty && closing.isEmpty }

    public func isPending(_ id: PaneID?) -> Bool {
        guard let id else { return false }
        return pending.contains { $0.id == id && !$0.abandoned }
    }

    public func isClosing(_ id: PaneID) -> Bool { closing[id] != nil }

    // MARK: Reading

    /// Which pane of `layout` each placeholder is, by the placeholder: the pane the host named
    /// once it has replied, else (before its reply) the first new pane that no other placeholder
    /// has.
    private func matches(in layout: [PaneID]) -> [PaneID: (real: PaneID, replied: Bool)] {
        var out: [PaneID: (real: PaneID, replied: Bool)] = [:]
        var taken = Set<PaneID>()
        for p in pending {
            if let real = p.real, layout.contains(real) {
                out[p.id] = (real, true)
                taken.insert(real)
            }
        }
        for p in pending where p.real == nil {
            guard let real = layout.first(where: { !p.baseline.contains($0) && !taken.contains($0) && closing[$0] == nil }) else { continue }
            out[p.id] = (real, false)
            taken.insert(real)
        }
        return out
    }

    /// The tabs to draw: the layout's, less the ones closing and the ones a placeholder is about to
    /// be, then the placeholders still waiting. A pane the host named that the layout holds is a
    /// tab of its own already.
    public func tabs(_ layoutTabs: [TerminalPanelTab]) -> [TerminalPanelTab] {
        guard !isEmpty else { return layoutTabs }
        let matched = matches(in: layoutTabs.map(\.id))
        let held = Set(matched.values.filter { !$0.replied }.map(\.real))
        var out = layoutTabs.filter { closing[$0.id] == nil && !held.contains($0.id) }
        for p in pending where !p.abandoned && !(matched[p.id]?.replied ?? false) {
            out.append(TerminalPanelTab(leaf: LeafPane(id: p.id, cwd: p.cwd, title: Self.startingTitle)))
        }
        return out
    }

    /// A chosen or focused id as the layout has it: a placeholder whose pane has arrived is that pane.
    public func resolved(_ id: PaneID?, in layout: [PaneID]) -> PaneID? {
        guard let id, let p = pending.first(where: { $0.id == id }), let real = p.real, layout.contains(real) else { return id }
        return real
    }

    /// The panes of `layout` a placeholder holds or has just become: a new pane among them is the
    /// one that was asked for, never another device's.
    public func claimed(in layout: [PaneID]) -> Set<PaneID> {
        Set(matches(in: layout).values.map(\.real))
    }

    // MARK: Opening

    /// + was pressed: a placeholder opens (selected by the caller), which is its id.
    public mutating func beginOpen(layout: [PaneID], cwd: String, previousChosen: PaneID?, previousFocus: PaneID?) -> PaneID {
        let p = Pending(id: PaneID(), cwd: cwd, baseline: Set(layout), previousChosen: previousChosen,
                        previousFocus: previousFocus)
        pending.append(p)
        return p.id
    }

    /// The host opened `real` for `placeholder`.
    public mutating func opened(_ placeholder: PaneID, real: PaneID) -> Opened {
        guard let index = pending.firstIndex(where: { $0.id == placeholder }) else { return .unknown }
        if pending[index].abandoned {
            pending.remove(at: index)
            closing[real] = Closing(seen: false)
            return .close(real)
        }
        pending[index].real = real
        return .adopted
    }

    /// The host refused: the placeholder goes. Returns it, to give back what it took.
    @discardableResult
    public mutating func openFailed(_ placeholder: PaneID) -> Pending? {
        guard let index = pending.firstIndex(where: { $0.id == placeholder }) else { return nil }
        return pending.remove(at: index)
    }

    /// Closing a tab that is still starting: it goes at once.
    public mutating func abandon(_ placeholder: PaneID) -> Abandon {
        guard let index = pending.firstIndex(where: { $0.id == placeholder && !$0.abandoned }) else { return .unknown }
        if let real = pending[index].real {
            pending.remove(at: index)
            closing[real] = Closing(seen: false)
            return .close(real)
        }
        pending[index].abandoned = true
        return .waiting
    }

    // MARK: Closing

    /// Close was pressed on a pane of the layout: false if it was already closing.
    public mutating func beginClose(_ id: PaneID) -> Bool {
        guard closing[id] == nil else { return false }
        closing[id] = Closing(seen: true)
        return true
    }

    /// The host refused: the tab comes back.
    public mutating func closeFailed(_ id: PaneID) {
        closing[id] = nil
    }

    /// The host closed it: it stays hidden until the layout drops it.
    public mutating func closeConfirmed(_ id: PaneID) {
        closing[id]?.confirmed = true
    }

    // MARK: Following the layout

    /// The layout changed: placeholders whose pane has arrived are done, and closing tabs the
    /// layout dropped are gone. Returns the promotions, for the caller to move selection and
    /// the keyboard from the placeholder to the pane (only if they were on it).
    @discardableResult
    public mutating func settle(layout: [PaneID]) -> [Promotion] {
        var promotions: [Promotion] = []
        for p in pending {
            guard let real = p.real, layout.contains(real) else { continue }
            promotions.append(Promotion(pending: p.id, real: real))
        }
        if !promotions.isEmpty {
            let done = Set(promotions.map(\.pending))
            pending.removeAll { done.contains($0.id) }
        }
        for (id, state) in closing {
            if layout.contains(id) {
                closing[id]?.seen = true
            } else if state.seen || state.confirmed {
                closing[id] = nil
            }
        }
        return promotions
    }
}

public extension TerminalPanel {
    /// `tabs(in:thread:)` as the panel shows them while requests are in flight.
    static func tabs(in layout: PaneNode, thread: PaneID?, overlay: TerminalTabOverlay) -> [TerminalPanelTab] {
        overlay.tabs(tabs(in: layout, thread: thread))
    }
}
