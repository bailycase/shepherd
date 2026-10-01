import AppKit
import Foundation
import ShepherdProtocol
import ShepherdTestSupport
import SwiftUI
import Testing
@testable import ShepherdApp
@testable import ShepherdUI

/// Settings ▸ Pi ▸ Slash commands over the most pi can list (`NativeCommand.maxCount`, 128): opening
/// builds the rows on screen and some ahead of them, never the whole list, and one switch redraws
/// its own row alone.
extension ListPerformanceTests {
    @MainActor
    @Test func oneSlashCommandSwitchingRedrawsOnlyItsRow() async throws {
        let commands = (0..<NativeCommand.maxCount).map { index in
            NativeCommand(name: "skill:command-\(index + 100)", description: "Command number \(index).", source: "skill")
        }
        let settings = AppSettings(store: ScratchDefaults())
        let model = SlashCommandsModel(catalog: commands)
        var window: OffscreenWindow!
        let opened = ListPerf.counting {
            window = OffscreenWindow(size: CGSize(width: 1200, height: 800), dark: true,
                                     ScrollView { SlashCommandsSettings(model: model, settings: settings).padding(32) }
                                         .background(Color.nw.bgWindow))
            ListPerf.settle(window)
        }
        defer { window.close() }
        // About ten rows fit under the header; the lazy stack builds a few ahead of them (12 here). All 128
        // would mean it isn't lazy.
        #expect(opened["slashCommands.row", default: 0] > 0, "\(opened)")
        #expect(opened["slashCommands.row", default: 0] <= 40, "\(opened)")

        let changed = ListPerf.counting {
            ListPerf.time(window) { settings.setSlashCommand("skill:command-100", on: false) }
        }
        #expect(changed["slashCommands.row", default: 0] > 0, "\(changed)")
        #expect(changed["slashCommands.row", default: 0] <= 2, "\(changed)")
    }
}
