import Foundation
import ShepherdCore

/// One tab of an agent's terminal panel: a stretch of its layout with no thread in it, drawn
/// with its own splits. Identified by its first pane, which a split inside the tab keeps.
public struct TerminalPanelTab: Equatable, Sendable, Identifiable {
    public let id: PaneID
    /// The tab's panes as the host lays them out.
    public let node: PaneNode

    public init(node: PaneNode) {
        self.node = node
        id = node.firstLeaf.id
    }

    public var panes: [LeafPane] { node.leaves }

    public func contains(_ pane: PaneID) -> Bool { node.contains(pane) }
}

/// The terminal panel under a thread (TerminalSplit, TerminalStates, iPadTerminal boards) is a
/// view of the agent's layout, which stays the host's: the thread is one pane, and every other
/// pane belongs to a tab. The host's pane requests are the only way to change it: + splits the
/// thread (a new tab), Split right splits a pane inside the tab, and Close closes a pane.
public enum TerminalPanel {
    /// The tabs of `layout` whose thread is `thread`: each largest subtree without the thread,
    /// oldest first. Every such subtree hangs beside the path from the root to the thread, and a
    /// pane split off the thread lands closest to it, so the shallowest subtree is the oldest.
    /// A layout with no thread (a host's utility terminal) is one tab.
    public static func tabs(in layout: PaneNode, thread: PaneID?) -> [TerminalPanelTab] {
        guard let thread, layout.contains(thread) else { return [TerminalPanelTab(node: layout)] }
        var tabs: [TerminalPanelTab] = []
        var node = layout
        while case .split(_, _, let first, let second) = node {
            if first.contains(thread) {
                tabs.append(TerminalPanelTab(node: second))
                node = first
            } else {
                tabs.append(TerminalPanelTab(node: first))
                node = second
            }
        }
        return tabs
    }

    /// The tab on screen: the one chosen while it exists, else the one holding the focused pane,
    /// else the newest. A tab whose first pane closed keeps its place through its other panes
    /// (`remembering`).
    public static func selected(_ tabs: [TerminalPanelTab], chosen: PaneID?, remembering panes: [PaneID] = [],
                                focused: PaneID? = nil) -> TerminalPanelTab? {
        if let chosen, let tab = tabs.first(where: { $0.id == chosen }) { return tab }
        if let tab = tabs.first(where: { tab in panes.contains { tab.contains($0) } }) { return tab }
        if let focused, let tab = tabs.first(where: { $0.contains(focused) }) { return tab }
        return tabs.last
    }

    /// Where + opens a pane: beside the thread, so it becomes a tab of its own; with no thread,
    /// beside the layout's last pane.
    public static func newTabAnchor(in layout: PaneNode, thread: PaneID?) -> (pane: PaneID, axis: SplitAxis) {
        if let thread, layout.contains(thread) { return (thread, .horizontal) }
        return (layout.leaves.last?.id ?? layout.firstLeaf.id, .vertical)
    }

    /// Where Split right (or down) opens a pane: beside the tab's focused pane, else its last.
    public static func splitAnchor(in tab: TerminalPanelTab, focused: PaneID?) -> PaneID {
        if let focused, tab.contains(focused) { return focused }
        return tab.panes.last?.id ?? tab.id
    }

    /// The pane a tab's keyboard goes to: the focused one while it is in the tab, else its first.
    public static func focusedPane(in tab: TerminalPanelTab, focused: PaneID?) -> PaneID {
        if let focused, tab.contains(focused) { return focused }
        return tab.id
    }

    /// What closing a tab closes: every pane in it, the focused one last so the tab stays put
    /// while the others go. Never the thread's pane, and never the layout's last pane (the host
    /// refuses both; a tab always leaves the thread behind).
    public static func panesToClose(_ tab: TerminalPanelTab, thread: PaneID?) -> [PaneID] {
        tab.panes.map(\.id).filter { $0 != thread }
    }
}

/// How tall the terminal panel is. It snaps to a third, half and two-thirds of the column while
/// dragged, keeps the thread above it at least `threadMinimum`, and resets to its default.
public enum TerminalPanelHeight {
    /// The fractions of the column the divider snaps to.
    public static let snaps: [Double] = [1.0 / 3.0, 0.5, 2.0 / 3.0]

    /// `proposed`, kept between `minimum` and what leaves the thread `threadMinimum` of
    /// `container`, then snapped to the nearest fraction within `tolerance`.
    public static func resolve(_ proposed: Double, container: Double, minimum: Double, threadMinimum: Double,
                               tolerance: Double) -> Double {
        let clamped = clamp(proposed, container: container, minimum: minimum, threadMinimum: threadMinimum)
        guard container > 0 else { return clamped }
        let nearest = snaps.map { $0 * container }.min { abs($0 - clamped) < abs($1 - clamped) }
        if let nearest, abs(nearest - clamped) <= tolerance {
            return clamp(nearest, container: container, minimum: minimum, threadMinimum: threadMinimum)
        }
        return clamped
    }

    /// The height a stored or default value takes in a column this tall.
    public static func clamp(_ proposed: Double, container: Double, minimum: Double, threadMinimum: Double) -> Double {
        let maximum = max(0, container - threadMinimum)
        guard maximum > minimum else { return max(0, min(proposed, maximum)) }
        return min(max(proposed, minimum), maximum)
    }
}

/// The touch key row over the software keyboard (iPadTerminal board): the keys a shell needs
/// that the keyboard lacks. Ctrl and ⌥ latch for the next key.
public enum TerminalKey: String, CaseIterable, Sendable, Identifiable {
    case escape, tab, control, option, up, down, left, right, pipe, tilde, slash, dash

    public var id: String { rawValue }

    /// The keycap's text.
    public var label: String {
        switch self {
        case .escape: "esc"
        case .tab: "tab"
        case .control: "ctrl"
        case .option: "⌥"
        case .up: "↑"
        case .down: "↓"
        case .left: "←"
        case .right: "→"
        case .pipe: "|"
        case .tilde: "~"
        case .slash: "/"
        case .dash: "-"
        }
    }

    /// What VoiceOver says.
    public var spokenLabel: String {
        switch self {
        case .escape: "Escape"
        case .tab: "Tab"
        case .control: "Control"
        case .option: "Option"
        case .up: "Up arrow"
        case .down: "Down arrow"
        case .left: "Left arrow"
        case .right: "Right arrow"
        case .pipe: "Vertical bar"
        case .tilde: "Tilde"
        case .slash: "Slash"
        case .dash: "Hyphen"
        }
    }

    /// Ctrl and ⌥ change the next key instead of sending anything.
    public var isModifier: Bool { self == .control || self == .option }

    /// The bytes for this key. Arrows follow the terminal's cursor-key mode (`applicationCursor`:
    /// `ESC O A`, else `ESC [ A`) and xterm's modifier form with Ctrl or ⌥ (`ESC [ 1 ; 5 A`).
    /// Ctrl turns a character into its control code, ⌥ sends Escape first.
    public func bytes(applicationCursor: Bool, control: Bool = false, option: Bool = false) -> [UInt8] {
        let escape: UInt8 = 0x1B
        switch self {
        case .control, .option: return []
        case .escape: return [escape]
        case .tab: return option ? [escape, 0x09] : [0x09]
        case .up, .down, .left, .right:
            let final: UInt8 = switch self {
            case .up: 0x41
            case .down: 0x42
            case .right: 0x43
            default: 0x44
            }
            let modifier = 1 + (option ? 2 : 0) + (control ? 4 : 0)
            if modifier > 1 { return [escape, 0x5B, 0x31, 0x3B, UInt8(0x30 + modifier), final] }
            return applicationCursor ? [escape, 0x4F, final] : [escape, 0x5B, final]
        case .pipe, .tilde, .slash, .dash:
            let character: UInt8 = switch self {
            case .pipe: 0x7C
            case .tilde: 0x7E
            case .slash: 0x2F
            default: 0x2D
            }
            let byte = control ? Self.controlCode(character) ?? character : character
            return option ? [escape, byte] : [byte]
        }
    }

    /// The control code Ctrl makes of an ASCII character, as xterm sends it: letters and
    /// `@[\]^_` to 0–31, `?` to DEL, and the usual stand-ins (`/` and `-` for `_`, `~` for `^`,
    /// `|` for `\`). Nil for a character with none.
    public static func controlCode(_ character: UInt8) -> UInt8? {
        switch character {
        case 0x61...0x7A: return character - 0x60
        case 0x40...0x5F: return character - 0x40
        case 0x3F: return 0x7F
        case 0x2F, 0x2D: return 0x1F
        case 0x7E: return 0x1E
        case 0x7C: return 0x1C
        case 0x20: return 0x00
        default: return nil
        }
    }
}

/// One remote terminal's attachment to its host session, as a value: the client says what it
/// wants (on screen and connected, and the grid its view has) and the link answers with the
/// requests to send. The host resizes the PTY to the smallest attached viewer and replays its
/// screen on every attach, so a detached link is simply reattached when it comes back.
public struct RemoteTerminalLink: Equatable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// Not attached: off screen, backgrounded, or not attached yet.
        case detached
        /// Attach sent; output that arrives now is the host's replay.
        case attaching
        case live
        case exited(Int32?)
        case failed(String)
    }

    public enum Command: Equatable, Sendable {
        /// Attach at this grid. The view clears itself first: the host replays its screen.
        case attach(cols: Int, rows: Int)
        case resize(cols: Int, rows: Int)
        case detach
    }

    public struct Grid: Equatable, Sendable {
        public var cols: Int
        public var rows: Int
        public init(cols: Int, rows: Int) { self.cols = cols; self.rows = rows }
    }

    public private(set) var phase: Phase = .detached
    /// The view's settled grid.
    public private(set) var grid: Grid?
    /// Numbers each attach sent, so a late answer to an earlier one (the view left and came back
    /// while it was in flight) never settles the current one.
    public private(set) var attempt = 0
    private var wanted = false
    /// The grid the host last had from this viewer.
    private var sent: Grid?

    public init() {}

    /// Output is fed to the view only while attached (the replay, then live output).
    public var acceptsOutput: Bool { phase == .attaching || phase == .live }

    /// The link should be attached (its view is on screen, the app active, the host connected)
    /// or not.
    public mutating func want(_ on: Bool) -> [Command] {
        wanted = on
        switch phase {
        case .detached where on: return attachIfReady()
        case .attaching where !on, .live where !on:
            phase = .detached
            sent = nil
            return [.detach]
        case .failed where on:
            // A failed attach is retried when the view comes back.
            phase = .detached
            return attachIfReady()
        default: return []
        }
    }

    /// The view settled on a grid.
    public mutating func noteGrid(cols: Int, rows: Int) -> [Command] {
        guard cols > 0, rows > 0 else { return [] }
        let grid = Grid(cols: cols, rows: rows)
        self.grid = grid
        switch phase {
        case .detached: return wanted ? attachIfReady() : []
        case .attaching, .live:
            guard grid != sent else { return [] }
            sent = grid
            return [.resize(cols: cols, rows: rows)]
        case .exited, .failed: return []
        }
    }

    /// The host accepted attach number `attempt`.
    public mutating func attached(attempt: Int) {
        if phase == .attaching, attempt == self.attempt { phase = .live }
    }

    /// The host refused attach number `attempt`, or its request failed.
    public mutating func attachFailed(_ reason: String, attempt: Int) {
        guard phase == .attaching, attempt == self.attempt else { return }
        phase = .failed(reason)
        sent = nil
    }

    /// The session's process exited; its last screen stays.
    public mutating func exited(_ code: Int32?) {
        phase = .exited(code)
        sent = nil
    }

    /// The connection dropped: the host forgot this viewer. A new connection attaches again.
    public mutating func disconnected() {
        switch phase {
        case .attaching, .live:
            phase = .detached
            sent = nil
        default: break
        }
    }

    private mutating func attachIfReady() -> [Command] {
        guard wanted, let grid else { return [] }
        phase = .attaching
        attempt += 1
        sent = grid
        return [.attach(cols: grid.cols, rows: grid.rows)]
    }
}
