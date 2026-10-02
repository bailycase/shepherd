import AppKit
import Foundation

extension ShepherdViewModel {
    static func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Settings ▸ MCP servers.
    func openMCPSettings() {
        settingsSection = .mcp
        showSettings = true
    }
}
