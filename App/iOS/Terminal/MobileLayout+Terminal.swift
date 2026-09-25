import SwiftUI
import ShepherdUI

extension MobileLayout {
    /// The panel under an iPad thread (iPadTerminal board), until the divider moves it.
    static let terminalPanelHeight: CGFloat = NWTerminalMetrics.panelHeight
    /// Dynamic Type grows the terminal's font only this far: past it the grid gets too narrow for
    /// a shell.
    static let terminalMaximumFontSize: CGFloat = 20
    /// The divider's grabber on the panel's top edge.
    static let terminalGrabber = CGSize(width: 36, height: 4)
}
