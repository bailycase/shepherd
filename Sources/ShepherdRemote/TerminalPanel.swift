import Foundation
import ShepherdCore
import ShepherdProtocol

/// One tab of an agent's terminal panel: one terminal, identified by its own id.
public struct TerminalPanelTab: Equatable, Sendable, Identifiable {
    public let id: PaneID
    public let leaf: LeafPane

    public init(leaf: LeafPane) {
        self.leaf = leaf
        id = leaf.id
    }
}

/// The terminal panel under a thread (TerminalSplit, TerminalStates, iPadTerminal boards) is a
/// view of the agent's layout, which stays the host's: the thread is one leaf, and every other
/// leaf is a terminal with a tab of its own. The host's requests are the only way to change it:
/// + asks for a new terminal and Close closes one.
public enum TerminalPanel {
    /// The tabs of `layout` whose thread is `thread`: one per terminal, oldest first
    /// (`PaneNode.terminals(besideThread:)`). A host that has not flattened its layouts yet may
    /// still hold several terminals split in one tab, which read as a tab each. A layout with no
    /// thread (a host's utility terminal) has one tab per leaf.
    public static func tabs(in layout: PaneNode, thread: PaneID?) -> [TerminalPanelTab] {
        let leaves = thread.map { layout.contains($0) ? layout.terminals(besideThread: $0) : layout.leaves } ?? layout.leaves
        return leaves.map { TerminalPanelTab(leaf: $0) }
    }

    /// The tab on screen: the one chosen while it exists, else the one holding the focused
    /// terminal, else the newest.
    public static func selected(_ tabs: [TerminalPanelTab], chosen: PaneID?, focused: PaneID? = nil) -> TerminalPanelTab? {
        if let chosen, let tab = tabs.first(where: { $0.id == chosen }) { return tab }
        if let focused, let tab = tabs.first(where: { $0.id == focused }) { return tab }
        return tabs.last
    }

    /// The tab `delta` places from the selected one, wrapping at the ends; nil with fewer than
    /// two tabs (there is nowhere to go).
    public static func adjacent(to selected: TerminalPanelTab?, in tabs: [TerminalPanelTab], delta: Int) -> TerminalPanelTab? {
        guard tabs.count > 1 else { return nil }
        let current = selected.flatMap { selected in tabs.firstIndex { $0.id == selected.id } } ?? (delta > 0 ? tabs.count - 1 : 0)
        return tabs[(current + delta + tabs.count) % tabs.count]
    }

    /// What the wire's open-terminal request names: the thread, which a host from before terminals
    /// were tabs only splits below itself to make the new tab and a current host ignores (it
    /// opens a tab whatever it is told); with no thread, the layout's last leaf.
    public static func newTabAnchor(in layout: PaneNode, thread: PaneID?) -> (pane: PaneID, axis: SplitAxis) {
        if let thread, layout.contains(thread) { return (thread, .horizontal) }
        return (layout.leaves.last?.id ?? layout.firstLeaf.id, .vertical)
    }

    /// The panel closes with its last terminal, however it went (its tab closed, the agent
    /// closed its terminal, its shell exited): true when a layout that had tabs has none left.
    public static func closesWithLastTerminal(before: Int, after: Int) -> Bool {
        before > 0 && after == 0
    }

    /// What is on screen to be marked seen: nothing while the panel is off screen, else the
    /// selected tab's session, and how far it has news (`RemoteTerminalActivity.news`).
    public static func seenMark(selected: TerminalPanelTab?, onScreen: Bool,
                                activity: [PaneID: RemoteTerminalActivity]) -> TerminalSeenMark {
        guard onScreen, let selected, let session = selected.leaf.sessionID else { return TerminalSeenMark() }
        return TerminalSeenMark(tab: selected.id, sessions: [session], news: [activity[selected.id]?.news])
    }
}

/// The selected tab's output while it is on screen. A client marks its session seen whenever
/// this changes: a tab picked (even one whose news matches the last tab's), or its news moving.
public struct TerminalSeenMark: Equatable, Sendable {
    public var tab: PaneID?
    public var sessions: [SessionID]
    public var news: [UInt64?]

    public init(tab: PaneID? = nil, sessions: [SessionID] = [], news: [UInt64?] = []) {
        self.tab = tab
        self.sessions = sessions
        self.news = news
    }
}

/// What closing a tab asks first on iOS (iPad panel, iPhone screen): which tab, and the shell
/// that stops on the host. A title another tab shares ("zsh" in every tab at its prompt) adds
/// the tab's place.
public struct TerminalCloseConfirmation: Equatable, Sendable {
    public let title: String
    public let message: String

    /// `titles` are the tabs' titles in the strip's order, one per tab of `tabs`.
    public init(_ tab: TerminalPanelTab, in tabs: [TerminalPanelTab], titles: [String], host: String) {
        let index = tabs.firstIndex { $0.id == tab.id }
        let name = index.flatMap { titles.indices.contains($0) ? titles[$0] : nil } ?? "terminal"
        if let index, titles.filter({ $0 == name }).count > 1 {
            title = "Close \(name) (tab \(index + 1))?"
        } else {
            title = "Close \(name)?"
        }
        message = tab.leaf.isReview == true ? "It closes on \(host)." : "Its shell on \(host) stops."
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
    /// In the row's order: the symbols before the arrows, so a row that wraps in two keeps the
    /// arrows together.
    case escape, tab, control, option, pipe, tilde, slash, dash, up, down, left, right

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
    /// How long a refused attach waits before it is tried again, while the link is wanted.
    private var retries = RemoteReconnectBackoff()

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
        guard phase == .attaching, attempt == self.attempt else { return }
        phase = .live
        retries.reset()
    }

    /// The host refused attach number `attempt`, or its request failed. While the link is still
    /// wanted, returns how long to wait before `retry(attempt:)`: a host that just relaunched may
    /// not serve the session yet, and nothing else would ask again while the view stays up.
    @discardableResult
    public mutating func attachFailed(_ reason: String, attempt: Int) -> Duration? {
        guard phase == .attaching, attempt == self.attempt else { return nil }
        phase = .failed(reason)
        sent = nil
        return wanted ? retries.next() : nil
    }

    /// Tries a refused attach again, unless something has happened since (a newer attach, the
    /// view left, the session exited).
    public mutating func retry(attempt: Int) -> [Command] {
        guard case .failed = phase, wanted, attempt == self.attempt else { return [] }
        phase = .detached
        return attachIfReady()
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
