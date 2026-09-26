import AppKit
import Foundation
import Testing
@testable import TerminalSurfaceKit

/// Links a terminal program prints are opened by the app, so only browser and mail schemes
/// may leave the surface.
@Suite("Terminal links")
struct TerminalLinkTests {
    @Test(arguments: [
        "https://example.com/path",
        "http://example.com",
        "HTTPS://EXAMPLE.COM",
        "mailto:test@example.com",
    ])
    func browserAndMailLinksOpen(link: String) {
        #expect(terminalOpenURL(link)?.absoluteString == link)
    }

    @Test(arguments: [
        "file:///etc/passwd",
        "javascript:alert(1)",
        "ssh://host",
        "not a link",
        "",
    ])
    func everythingElseIsRefused(link: String) {
        #expect(terminalOpenURL(link) == nil)
    }

    /// Shift bypasses mouse capture in fullscreen TUIs; ⌘-click takes that path too.
    @Test func commandClickAddsShiftAndOtherClicksAreUntouched() {
        #expect(terminalLinkModifiers([.command]) == [.command, .shift])
        #expect(terminalLinkModifiers([.command, .option]) == [.command, .option, .shift])
        #expect(terminalLinkModifiers([.control]) == [.control])
        #expect(terminalLinkModifiers([]) == [])
    }
}

/// A focused Ghostty surface consumes key equivalents matching its own bindings, so every
/// chord the app chrome owns must be unbound in the surface config — and reconfiguring
/// (a rebind, a theme flip) must happen in place, never by replacing the surface.
@Suite("Terminal surface configuration")
@MainActor
struct TerminalSurfaceConfigTests {
    private func unbinds(_ model: TerminalSurfaceModel) -> Set<String> {
        Set(model.viewState.renderedConfig.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, parts[0] == "keybind", parts[1].hasSuffix("=unbind") else { return nil }
            return String(parts[1].dropLast("=unbind".count))
        })
    }

    /// DESIGN.md's default shortcut table, in ghostty syntax. (ShortcutAction lives in the app,
    /// so the table is spelled out here; a rebound chord arrives through `extraUnbinds`.)
    private static let defaultAppChords = [
        "cmd+n", "shift+cmd+t", "shift+cmd+n", "cmd+r", "shift+cmd+w", "cmd+k", "cmd+down", "cmd+up",
        "cmd+d", "shift+cmd+d", "cmd+w", "alt+cmd+right", "alt+cmd+left", "shift+cmd+s", "shift+cmd+b",
        "shift+cmd+m", "cmd+period", "alt+cmd+up", "alt+cmd+down", "cmd+i", "cmd+j", "shift+cmd+enter",
    ]

    @Test func everyDefaultAppShortcutIsUnbound() {
        let bound = unbinds(TerminalSurfaceModel())
        for chord in Self.defaultAppChords {
            #expect(bound.contains(chord), "a focused terminal would swallow \(chord)")
        }
    }

    /// The fixed chords: ⌘1–9 Recents (by character and physical key), ⌘, Settings in both
    /// spellings ghostty parses, and ⌘Q. ⌃⇧1–9 jumped between machines, which the sidebar no
    /// longer has, so a focused terminal keeps them.
    @Test func fixedAppChordsAreUnbound() {
        let bound = unbinds(TerminalSurfaceModel())
        let digits = ["one", "two", "three", "four", "five", "six", "seven", "eight", "nine"]
        for digit in digits {
            for chord in ["cmd+\(digit)", "cmd+physical:\(digit)"] {
                #expect(bound.contains(chord), "\(chord) must reach the app")
            }
            for chord in ["ctrl+shift+\(digit)", "ctrl+shift+physical:\(digit)"] {
                #expect(!bound.contains(chord), "\(chord) is the terminal's now")
            }
        }
        for chord in ["cmd+comma", "cmd+,", "cmd+q"] {
            #expect(bound.contains(chord), "\(chord) must reach the app")
        }
    }

    /// Ghostty keeps copy and paste; the app never takes them.
    @Test func copyAndPasteStayWithTheTerminal() {
        let bound = unbinds(TerminalSurfaceModel())
        #expect(!bound.contains("cmd+c"))
        #expect(!bound.contains("cmd+v"))
    }

    @Test func customChordsAreUnboundOnceAlongsideTheBuiltIns() {
        let model = TerminalSurfaceModel(extraUnbinds: ["cmd+right_bracket", "cmd+k"])
        let lines = model.viewState.renderedConfig.split(separator: "\n")
        #expect(unbinds(model).contains("cmd+right_bracket"))
        #expect(lines.filter { $0.contains("cmd+k=unbind") }.count == 1)
    }

    @Test func rebindingReconfiguresTheLiveSurfaceInPlace() {
        let model = TerminalSurfaceModel(fontSize: 12, extraUnbinds: [])
        let viewState = model.viewState

        model.updateConfiguration(fontSize: 15, fontFamily: "Menlo", extraUnbinds: ["alt+cmd+j"])

        #expect(model.viewState === viewState)
        #expect(unbinds(model).contains("alt+cmd+j"))
        #expect(viewState.renderedConfig.contains("font-family = Menlo"))
        #expect(viewState.renderedConfig.contains("font-size = 15"))
    }

    @Test func appearanceChangesApplyInPlace() {
        let model = TerminalSurfaceModel(appearance: TerminalAppearance(background: "111215", foreground: "CDD0D7", cursorColor: "CDD0D7"))
        let viewState = model.viewState

        let changed = model.updateAppearance(TerminalAppearance(
            background: "F3F1ED", foreground: "2E3032", cursorColor: "8F4E37",
            selectionBackground: "D9D4CC", palette: ["#000000", "#FF0000"]
        ))

        #expect(changed)
        #expect(model.viewState === viewState)
        let config = viewState.renderedConfig
        #expect(config.contains("background = F3F1ED"))
        #expect(config.contains("foreground = 2E3032"))
        #expect(config.contains("cursor-color = 8F4E37"))
        #expect(config.contains("selection-background = D9D4CC"))
        #expect(config.contains("palette = 1=#FF0000"))
    }
}
