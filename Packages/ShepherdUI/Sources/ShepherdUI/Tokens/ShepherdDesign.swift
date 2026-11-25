import Foundation

// Shepherd Design, the only shipped theme: the redesign boards' palette (Apple's system greys,
// orange for needs-you, ink for the primary action), translucent roles as #RRGGBBAA. Roles the
// boards do not draw (running, the tints, syntax) keep the Foundations values, retuned to sit
// on these greys. Terminal panes sit on bgWindow (bgRaised on the Mac, in the panel's card), with translucent selection colors flattened
// onto it because Ghostty wants opaque colors.
extension ThemeDefinition {
    public static let shepherdDesign = ThemeDefinition(
        id: "shepherd-design",
        name: "Shepherd Design",
        light: .shepherdDesign(
            colors: ThemeColors(
                bgBase: "#f7f7f8",
                bgWindow: "#f7f7f8",
                bgRaised: "#ffffff",
                bgSunken: "#eeeeef",
                bgBubble: "#e7e7e8",
                bgHover: "#00000009",
                bgSelected: "#00000011",
                bgGlass: "#e9e9ecdb",
                lineSubtle: "#0000000f",
                lineStrong: "#00000014",
                textPrimary: "#1d1d1f",
                textSecondary: "#6e6e73",
                textTertiary: "#a1a1a6",
                // The boards' light attention (--mac-attention), darkened from #FF9500 so a dot reads on the window;
                // white on it now passes where the dark ink no longer does.
                textOnLantern: "#ffffff",
                primary: "#1d1d1f",
                textOnPrimary: "#ffffff",
                lantern: "#b55400",
                // A touch darker than before so its words keep 4.5:1 on the darker tint.
                lanternText: "#8a5300",
                lanternTint: "#b5540021",
                running: "#2f6fe0",
                runningTint: "#2f6fe01a",
                textOnRunning: "#ffffff",
                done: "#1e8e3e",
                doneTint: "#1e8e3e1a",
                failed: "#d93025",
                failedTint: "#d9302517"
            ),
            syntax: SyntaxColors(
                keyword: "#9b3ba6", type: "#1a7f55", string: "#2d6a9f", number: "#2f6fe0",
                function: "#2a62c9", comment: "#a1a1a6",
                variable: "#1d1d1f", operators: "#6e6e73", punctuation: "#6e6e73"
            ),
            // Normal colors are darkened so ANSI text stays readable on the light window.
            ansi: [
                "#1d1d1f", "#c7362f", "#17804a", "#945b00", "#2a62c9", "#8a3fb5", "#0f7c8a", "#6e6e73",
                "#a1a1a6", "#d93025", "#1e8e3e", "#ff9500", "#2f6fe0", "#a45fd0", "#1a9aa8", "#1d1d1f",
            ],
            selectionAlpha: 0.13
        ),
        dark: .shepherdDesign(
            colors: ThemeColors(
                bgBase: "#1c1c1e",
                bgWindow: "#1c1c1e",
                bgRaised: "#262628",
                bgSunken: "#252527",
                bgBubble: "#2e2e30",
                bgHover: "#ffffff0a",
                bgSelected: "#ffffff14",
                bgGlass: "#2e2e31e6",
                lineSubtle: "#ffffff12",
                lineStrong: "#ffffff17",
                textPrimary: "#f2f2f4",
                textSecondary: "#a1a1a6",
                textTertiary: "#6e6e73",
                textOnLantern: "#17120a",
                primary: "#f2f2f4",
                textOnPrimary: "#1c1c1e",
                lantern: "#ff9f0a",
                lanternText: "#f7c16e",
                lanternTint: "#ff9f0a21",
                running: "#7aa7ff",
                runningTint: "#7aa7ff21",
                textOnRunning: "#ffffff",
                done: "#34c759",
                doneTint: "#34c7591f",
                failed: "#ff6961",
                failedTint: "#ff69611f"
            ),
            syntax: SyntaxColors(
                keyword: "#d49be6", type: "#7ee0b5", string: "#86b7e6", number: "#9ec2ff",
                function: "#8fc1ff", comment: "#6e6e73",
                variable: "#f2f2f4", operators: "#a1a1a6", punctuation: "#a1a1a6"
            ),
            ansi: [
                "#2e2e31", "#ff6961", "#34c759", "#ff9f0a", "#7aa7ff", "#d7a6ff", "#5fcfdb", "#a1a1a6",
                "#6e6e73", "#ff8a86", "#6fdc9b", "#f7c16e", "#9ec2ff", "#e5c2ff", "#8fe6ee", "#f2f2f4",
            ],
            selectionAlpha: 0.13
        )
    )
}

extension ThemeVariant {
    /// A Shepherd Design variant: the given roles, with the terminal palette derived from them.
    static func shepherdDesign(colors c: ThemeColors, syntax s: SyntaxColors, ansi: [String], selectionAlpha: Double) -> ThemeVariant {
        /// A translucent role (or `tint` at `alpha`) flattened onto the window surface.
        func flat(_ tint: String, alpha: Double? = nil) -> String {
            guard let color = HexColor(tint), let window = HexColor(c.bgWindow) else { return tint }
            let source = alpha.map { HexColor(red: color.red, green: color.green, blue: color.blue, alpha: $0) } ?? color
            return source.composited(over: window).hexString
        }
        // On the Mac the terminal sits in the panel's raised card (GXTerminal), so it takes the card's fill.
        #if os(macOS)
        let terminalSurface = c.bgRaised
        #else
        let terminalSurface = c.bgWindow
        #endif
        return ThemeVariant(
            colors: c,
            syntax: s,
            terminal: TerminalColors(
                background: terminalSurface,
                foreground: c.textPrimary,
                cursor: c.textPrimary,
                selectionBackground: flat(c.running, alpha: selectionAlpha),
                selectionForeground: c.textPrimary,
                palette: ansi
            )
        )
    }
}
