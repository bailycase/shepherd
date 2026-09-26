import SwiftUI

/// Settings ▸ MCP servers' own measures (SettingsMCP, MCPStates).
public enum NWMCPMetrics {
    public static let dotSize: CGFloat = 7
    public static let dotStroke: CGFloat = 1.5
    /// An off server's row fades to this.
    public static let offOpacity: Double = 0.55
    public static let rowMinHeight: CGFloat = 54
    public static let headerHeight: CGFloat = 30
    public static let switchColumn: CGFloat = 30
    public static let signInColumn: CGFloat = 188
    public static let toolsColumn: CGFloat = 56
    public static let chevronColumn: CGFloat = 14
    public static let columnGap: CGFloat = 16
    public static let rowSides: CGFloat = 16
    public static let rowVertical: CGFloat = 8
    public static let nameSize: CGFloat = 13
    public static let endpointSize: CGFloat = 11.5
    public static let cellSize: CGFloat = 12
    public static let tagHeight: CGFloat = 18
    public static let tagTextSize: CGFloat = 11
    public static let tagIconSize: CGFloat = 9.5
    public static let tagSides: CGFloat = 6
    public static let chipHeight: CGFloat = 22
    public static let chipSides: CGFloat = 7
    public static let chipRadius: CGFloat = 5
    public static let detailColumnGap: CGFloat = 24
    public static let detailBlockGap: CGFloat = 8
    public static let detailTextSize: CGFloat = 13
    public static let detailOptionSize: CGFloat = 12.5
    public static let detailNoteSize: CGFloat = 12
    public static let detailPadding: CGFloat = 12
    /// The detail lines up under the server's name: the switch column and its gap past the row's side.
    public static var detailLeading: CGFloat { rowSides + switchColumn + columnGap }
    public static let hostNameWidth: CGFloat = 70
    public static let hostRowHeight: CGFloat = 26
    public static let visibleToolChips = 4
    public static let budgetHeight: CGFloat = 4
    public static let cardRadius: CGFloat = 10
    public static let sheetStepIcon: CGFloat = 16
    public static let sheetStepGap: CGFloat = 12
    public static let sheetIconTile: CGFloat = 36
    public static let sheetWidth: CGFloat = 520
    public static let sheetTitleSize: CGFloat = 16
    public static let sheetSubtitleSize: CGFloat = 12.5
    public static let sheetStepTitleSize: CGFloat = 13
    public static let sheetStepNoteSize: CGFloat = 12
}

/// A server's state as its dot: green connected, blue starting, hollow when it connects on first
/// use, amber when it needs you, red when it failed, a faint ring when it's off.
public enum MCPDotState: String, Sendable, Hashable, CaseIterable {
    case connected, starting, idle, needsYou, error, off

    public var label: String {
        switch self {
        case .connected: "Connected"
        case .starting: "Starting"
        case .idle: "Connects when used"
        case .needsYou: "Needs you"
        case .error: "Failed"
        case .off: "Off"
        }
    }
}

public struct MCPStatusDot: View {
    let state: MCPDotState
    let size: CGFloat

    public init(_ state: MCPDotState, size: CGFloat = NWMCPMetrics.dotSize) {
        self.state = state
        self.size = size
    }

    public var body: some View {
        let nw = Color.nw
        Group {
            switch state {
            case .connected: Circle().fill(nw.done)
            case .starting: Circle().fill(nw.running)
            case .needsYou: Circle().fill(nw.lantern)
            case .error: Circle().fill(nw.failed)
            case .idle: Circle().strokeBorder(nw.textTertiary, lineWidth: NWMCPMetrics.dotStroke)
            case .off: Circle().strokeBorder(nw.lineStrong, lineWidth: NWMCPMetrics.dotStroke)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(state.label)
    }
}
