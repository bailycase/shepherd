import SwiftUI
import ShepherdUI

/// Settings ▸ Fleet and its sheets (FleetPair, FleetStates' Join a fleet, Add a device).
extension AppLayout {
    /// Add a Mac: 520pt wide (FleetPair).
    static let fleetPairWidth: CGFloat = 520
    /// A digit of the code: 40 by 48pt, the display size in mono.
    static let fleetDigitWidth: CGFloat = 40
    static let fleetDigitHeight: CGFloat = 48
    /// The gap between the code's two groups of three.
    static let fleetDigitGroupGap: CGFloat = SH.Space.l
    /// The sheet's rows of Macs found: a 16pt monitor glyph, then the name over its address.
    static let fleetFoundGlyphSize: CGFloat = 16
    /// What the new Mac gets: a 16pt column holding a 14pt tick or cross.
    static let fleetGetsColumn: CGFloat = 16
    static let fleetGetsGlyphSize: CGFloat = 14
    /// Join a fleet (FleetStates): the code in mono at 40pt, its two groups of three a space apart.
    static let fleetJoinWidth: CGFloat = 460
    static let fleetJoinCodeSize: CGFloat = 40
    /// Add a device: the QR of the same code, a square this many points a side.
    static let fleetQRSize: CGFloat = 168
    /// A Macs row's status dot.
    static let fleetDotSize: CGFloat = 6

    // The Fleet page (FleetA).
    /// A Mac card's tile: 32pt with a 16pt display glyph.
    static let fleetTileSize: CGFloat = 32
    static let fleetTileGlyph: CGFloat = 16
    /// The cards' columns, and the least width a card keeps before the grid drops a column.
    static let fleetColumns = 3
    /// A fact row's label column, and the readings' value column.
    static let fleetFactLabelWidth: CGFloat = 76
    static let fleetFactValueWidth: CGFloat = 84
    /// Room's gauge is 6pt tall, the CPU and memory gauges 4pt.
    static let fleetRoomBarHeight: CGFloat = 6
    static let fleetMetricBarHeight: CGFloat = 4
    /// The Dispatches log's columns: the Mac's chip, why, the state pill and the age.
    static let fleetDispatchHostWidth: CGFloat = 120
    static let fleetDispatchReasonWidth: CGFloat = 300
    static let fleetDispatchStateWidth: CGFloat = 96
    static let fleetDispatchAgeWidth: CGFloat = 64
    /// The card's status pill.
    static let fleetPillHeight: CGFloat = 20
    /// The sending card's progress bar.
    static let fleetSendBarHeight: CGFloat = 6
    /// Ignored files · Per space…: the list of paths a space keeps home or sends.
    static let fleetExcludeEditorHeight: CGFloat = 88
    /// Send work here: its four buttons are 24pt tall.
    static let fleetWeightHeight: CGFloat = 24
    /// A repo tag.
    static let fleetTagHeight: CGFloat = 16
    /// A Mac's tag ("mini") is mono 10 (FleetDispatch, FleetSidebar).
    static let fleetTagFont: CGFloat = 10
    /// A card of a Mac that isn't answering fades.
    static let fleetAsleepOpacity: Double = 0.72
    /// The sidebar's Fleet row: 36pt tall, its glyph 16pt.
    static let fleetFooterRowHeight: CGFloat = 36
    static let fleetFooterGlyph: CGFloat = 16
    static let fleetFooterDotGap: CGFloat = SH.Space.xs

    // The Check tab (FleetCheck): the grid beside a panel.
    /// The panel's width, the grid's head and its rows' least height.
    static let fleetCheckPanelWidth: CGFloat = 400
    static let fleetCheckHeadHeight: CGFloat = 36
    static let fleetCheckRowHeight: CGFloat = 34
    /// The grid's columns: the thing's name is this many times a Mac's column.
    static let fleetCheckNameWeight: CGFloat = 1.5
    /// A group's label is tracked wide (the board's .05em of 10.5pt).
    static let fleetCheckGroupTracking: CGFloat = 0.5
    /// A line of the panel's prose sits at the board's 1.5 line height.
    static let fleetCheckProseSpacing: CGFloat = 4

    // Dispatch cards in a thread (FleetDispatch, FleetStates) and the dispatched thread (FleetRemote).
    /// A dispatch row's tile: 28pt.
    static let fleetRowTile: CGFloat = 28
    /// The From box's dash, and the result card's tick.
    static let fleetFromDash: [CGFloat] = [4, 3]
    static let fleetResultTick: CGFloat = 12
    /// The header's host pill is 24pt tall; its dot is the Fleet page's.
    static let fleetHeaderPillHeight: CGFloat = 24
    /// A card's buttons are 26pt tall.
    static let fleetCardButtonHeight: CGFloat = 26
    /// The thread behind an offline banner fades to this.
    static let fleetOfflineOpacity: Double = 0.6
    /// New thread's Where it runs popover hangs 33pt in from the card's trailing edge (FleetNewThread).
    static let fleetPlaceTrailingInset: CGFloat = 33

    // Moving a thread to another Mac (FleetMove).
    /// The header chip's menu and its confirmation are 400pt wide; a Mac's room bar is 56 by 4pt.
    static let fleetMoveMenuWidth: CGFloat = 400
    static let fleetMoveBarWidth: CGFloat = 56
    static let fleetMoveBarHeight: CGFloat = 4
    /// A step's mark column in the progress card.
    static let fleetMoveMarkWidth: CGFloat = 14
}
