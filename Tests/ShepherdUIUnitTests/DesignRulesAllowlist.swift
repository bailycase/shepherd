/// A file that may break a design rule, and how often. The list is the debt that predates
/// `DesignRulesTests`: it only ever shrinks. A change adds no entry for code it writes: it fixes
/// the violation (the failure says how). An entry is for something that is not a mistake, such as
/// a color that is a user's own data, and says so in `reason`.
struct DesignRuleException: Sendable {
    let rule: DesignRule
    /// Relative to the repository root.
    let path: String
    /// How many violations of `rule` the file may hold. More than that fails the test; fewer is
    /// progress, and an entry for a file with none must be deleted.
    let upTo: Int
    let reason: String

    init(_ rule: DesignRule, _ path: String, _ upTo: Int, _ reason: String) {
        self.rule = rule
        self.path = path
        self.upTo = upTo
        self.reason = reason
    }
}

enum DesignRuleAllowlist {
    private static let font = "Predates the rule: a literal font size in a view. Name it in the component's metrics enum, or use a ramp style, when the file is next changed."
    private static let tint = "Predates the rule: a status color tinted with an alpha. Take it from AgentState's tint and text roles when the file is next changed."
    private static let bolt = "Predates NWGlyph: the outline automation bolt as a plain symbol string. Pass NWGlyph.automation.symbolName when the file is next changed."

    static let entries: [DesignRuleException] = [
        // Raw colors: each is something other than app chrome, or a known fix.
        .init(.rawColor, "App/iOS/DesignPad/PadDesignMarkup.swift", 1, "Flattens an exported drawing onto a white page: image content, not chrome."),
        .init(.rawColor, "App/iOS/Designs/DesignHost.swift", 1, "Builds a UIColor from a pixel sampled from a board's snapshot: content, not chrome."),
        .init(.rawColor, "App/iOS/Terminal/TerminalSurface.swift", 1, "Converts the terminal theme's palette into SwiftTerm's own color type: the palette is the theme's."),
        .init(.rawColor, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/DesignCanvas.swift", 1, "An AppKit menu item's destructive title takes an NSColor: use NSColor(Color.nw.failed) when the file is next changed."),
        .init(.rawColor, "Sources/ShepherdApp/DesignExtension.swift", 1, "An example in a tool description inside the embedded extension's TypeScript string: not UI."),
        .init(.rawColor, "Sources/ShepherdApp/DesignSystemPageModel.swift", 1, "A design system that names no background draws on white, as its boards do: the design's content, not chrome."),
        .init(.rawColor, "Sources/ShepherdApp/ShepherdApp.swift", 2, "The Debug build's DEV badge, drawn into the Dock icon at runtime: not shipped UI."),
        // Status colors tinted by an alpha.
        .init(.statusTintByOpacity, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/AgentAuthParts.swift", 2, tint),
        .init(.statusTintByOpacity, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/SheetParts.swift", 2, tint),
        // Shared glyphs named as raw symbols.
        .init(.rawGlyphName, "App/iOS/Automations/AutomationsScreen.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Composer/ComposerControls.swift", 1, "The iOS composer draws its own Fast bolt, which NWFastBolt and NWGlyph.fastBolt exist to prevent. Move it to NWGlyph.fastBolt, with an iOS build to check it."),
        .init(.rawGlyphName, "App/iOS/Home/AutomationRow.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Home/HomeRows.swift", 2, bolt),
        .init(.rawGlyphName, "App/iOS/Home/HomeScreen.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Home/PadSidebar.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Hosts/PadHostsScreen.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Settings/ExperimentsScreens.swift", 2, bolt),
        .init(.rawGlyphName, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/Automations.swift", 1, bolt),
        .init(.rawGlyphName, "Sources/ShepherdApp/SettingsExperiments.swift", 1, bolt),
        .init(.rawGlyphName, "Sources/ShepherdApp/SidebarModel.swift", 7, bolt),
        // Literal font sizes.
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Agents/AgentParts.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Agents/Inspector.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Agents/SubagentTray.swift", 5, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/AutomationTable.swift", 7, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Browser/Browser.swift", 18, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Browser/BrowserAgent.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/ComposerParts.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/ContextMeter.swift", 19, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/Menus.swift", 13, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/ModelSettings.swift", 5, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/PlaceMenu.swift", 8, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/QuestionDock.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/QuestionHead.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/Queue.swift", 8, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/TouchQueue.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Buttons.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Pickers.swift", 6, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/SmallParts.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/TextFields.swift", 4, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Toggles.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/ReferenceSpecimens.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Fleet/HostPageCard.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/NWDensity.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/Pages.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/Palette.swift", 5, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/SidePane.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/Sidebar.swift", 13, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/SidebarProjects.swift", 5, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/Toolbar.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/AgentAuthParts.swift", 5, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/FromYourPiParts.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/SheetParts.swift", 10, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/ChangesMenu.swift", 11, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/ChangesToolbar.swift", 18, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/DiffLines.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/FileHeader.swift", 4, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/FileStrip.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/InlineComment.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/ReviewComposer.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Settings/MCPSignInSheet.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Status/Feedback.swift", 6, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Status/StateIndicators.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Terminal/TerminalPanel.swift", 4, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/Activity.swift", 20, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/Compaction.swift", 10, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/Messages.swift", 10, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ProseParts.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ThreadParts.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/TurnChangesCard.swift", 3, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/TurnError.swift", 5, font),
        .init(.rawFontSize, "Sources/ShepherdApp/ChangesMenus.swift", 2, font),
        .init(.rawFontSize, "Sources/ShepherdApp/DiffReviewView.swift", 1, font),
        .init(.rawFontSize, "Sources/ShepherdApp/NewThreadPage.swift", 7, font),
        .init(.rawFontSize, "Sources/ShepherdApp/Pages/AutomationsPage.swift", 1, font),
        .init(.rawFontSize, "Sources/ShepherdApp/SettingsComponents.swift", 1, font),
        .init(.rawFontSize, "Sources/ShepherdApp/Thread/SubagentInspector.swift", 9, font),
    ]
}
