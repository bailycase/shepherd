import Foundation

// Night Watch, the only shipped theme. The UI and syntax roles are the Foundations board's
// values verbatim (translucent roles as #RRGGBBAA). The terminal and pi palettes are derived
// from those roles: terminal panes sit on bgWindow, and the pi theme uses the same brand, state,
// and syntax colors, with translucent tints flattened onto bgWindow because pi and Ghostty want
// opaque colors.
extension ThemeDefinition {
    public static let nightWatch = ThemeDefinition(
        id: "night-watch",
        name: "Night Watch",
        light: .nightWatch(
            colors: ThemeColors(
                bgBase: "#f2f2f0",
                bgWindow: "#fbfbfa",
                bgRaised: "#ffffff",
                bgSunken: "#f5f5f3",
                bgBubble: "#efefec",
                bgHover: "#0000000a",
                bgSelected: "#00000011",
                lineSubtle: "#e7e7e3",
                lineStrong: "#d6d6d1",
                textPrimary: "#151618",
                textSecondary: "#5f636b",
                textTertiary: "#9a9ea5",
                textOnLantern: "#1a1206",
                lantern: "#e39a26",
                lanternText: "#945b00",
                lanternTint: "#d98a1221",
                running: "#2f6fe0",
                runningTint: "#2f6fe01a",
                done: "#1f9d5b",
                doneTint: "#1f9d5b1a",
                failed: "#d9443f",
                failedTint: "#d9443f17"
            ),
            syntax: SyntaxColors(
                keyword: "#8a3fb5", type: "#1a7f55", string: "#9a6400", number: "#2f6fe0",
                function: "#2a62c9", comment: "#9a9ea5",
                variable: "#151618", operators: "#5f636b", punctuation: "#5f636b"
            ),
            // Normal colors are darkened so ANSI text stays readable on the light window.
            ansi: [
                "#151618", "#c7362f", "#17804a", "#945b00", "#2a62c9", "#8a3fb5", "#0f7c8a", "#5f636b",
                "#9a9ea5", "#d9443f", "#1f9d5b", "#e39a26", "#2f6fe0", "#a45fd0", "#1a9aa8", "#151618",
            ],
            selectionAlpha: 0.18
        ),
        dark: .nightWatch(
            colors: ThemeColors(
                bgBase: "#0a0b0c",
                bgWindow: "#0d0e10",
                bgRaised: "#15171a",
                bgSunken: "#111316",
                bgBubble: "#1a1d21",
                bgHover: "#ffffff0b",
                bgSelected: "#ffffff14",
                lineSubtle: "#1f2226",
                lineStrong: "#2c3035",
                textPrimary: "#e8e9ec",
                textSecondary: "#9aa0a9",
                textTertiary: "#5f656e",
                textOnLantern: "#17120a",
                lantern: "#f2a93b",
                lanternText: "#f7c16e",
                lanternTint: "#f2a93b21",
                running: "#7aa7ff",
                runningTint: "#7aa7ff21",
                done: "#46c37b",
                doneTint: "#46c37b1f",
                failed: "#f0625e",
                failedTint: "#f0625e1f"
            ),
            syntax: SyntaxColors(
                keyword: "#d7a6ff", type: "#7ee0b5", string: "#e8c07a", number: "#9ec2ff",
                function: "#8fc1ff", comment: "#5f656e",
                variable: "#e8e9ec", operators: "#9aa0a9", punctuation: "#9aa0a9"
            ),
            ansi: [
                "#1f2226", "#f0625e", "#46c37b", "#f2a93b", "#7aa7ff", "#d7a6ff", "#5fcfdb", "#9aa0a9",
                "#5f656e", "#ff8a86", "#6fdc9b", "#f7c16e", "#9ec2ff", "#e5c2ff", "#8fe6ee", "#e8e9ec",
            ],
            selectionAlpha: 0.28
        )
    )
}

extension ThemeVariant {
    /// A Night Watch variant: the given roles, with the terminal and pi palettes derived from them.
    static func nightWatch(colors c: ThemeColors, syntax s: SyntaxColors, ansi: [String], selectionAlpha: Double) -> ThemeVariant {
        /// A translucent role (or `tint` at `alpha`) flattened onto the window surface.
        func flat(_ tint: String, alpha: Double? = nil) -> String {
            guard let color = HexColor(tint), let window = HexColor(c.bgWindow) else { return tint }
            let source = alpha.map { HexColor(red: color.red, green: color.green, blue: color.blue, alpha: $0) } ?? color
            return source.composited(over: window).hexString
        }
        return ThemeVariant(
            colors: c,
            syntax: s,
            terminal: TerminalColors(
                background: c.bgWindow,
                foreground: c.textPrimary,
                cursor: c.lantern,
                selectionBackground: flat(c.running, alpha: selectionAlpha),
                selectionForeground: c.textPrimary,
                palette: ansi
            ),
            pi: PiColors(
                accent: c.lantern,
                border: c.lineStrong,
                borderAccent: c.lantern,
                borderMuted: c.lineSubtle,
                success: c.done,
                error: c.failed,
                warning: c.lantern,
                muted: c.textSecondary,
                dim: c.textTertiary,
                text: c.textPrimary,
                thinkingText: c.textSecondary,
                selectedBg: flat(c.bgSelected),
                scrollbarThumb: c.lineStrong,
                searchMatchBg: flat(c.lanternTint),
                searchMatchText: c.textPrimary,
                userMessageBg: c.bgBubble,
                userMessageText: c.textPrimary,
                customMessageBg: c.bgSunken,
                customMessageText: c.textSecondary,
                customMessageLabel: c.lantern,
                toolPendingBg: c.bgSunken,
                toolSuccessBg: flat(c.doneTint),
                toolErrorBg: flat(c.failedTint),
                toolTitle: c.textPrimary,
                toolOutput: c.textSecondary,
                mdHeading: c.lanternText,
                mdLink: c.running,
                mdLinkUrl: c.textTertiary,
                mdCode: c.lanternText,
                mdCodeBlock: c.textPrimary,
                mdCodeBlockBorder: c.lineStrong,
                mdQuote: c.textSecondary,
                mdQuoteBorder: c.lineStrong,
                mdHr: c.lineStrong,
                mdListBullet: c.lantern,
                toolDiffAdded: c.done,
                toolDiffRemoved: c.failed,
                toolDiffContext: c.textTertiary,
                syntaxComment: s.comment,
                syntaxKeyword: s.keyword,
                syntaxFunction: s.function,
                syntaxVariable: s.variable,
                syntaxString: s.string,
                syntaxNumber: s.number,
                syntaxType: s.type,
                syntaxOperator: s.operators,
                syntaxPunctuation: s.punctuation,
                thinkingOff: c.lineStrong,
                thinkingMinimal: c.textTertiary,
                thinkingLow: c.running,
                thinkingMedium: s.keyword,
                thinkingHigh: c.lantern,
                thinkingXhigh: c.done,
                thinkingMax: c.textPrimary,
                bashMode: c.done
            )
        )
    }
}
