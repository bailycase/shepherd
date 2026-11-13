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
    private static let bolt = "Predates SHGlyph: the outline automation bolt as a plain symbol string. Pass SHGlyph.automation.symbolName when the file is next changed."

    private static let document = "Predates SHGlyph.document: the outline file glyph as a plain symbol string. Pass SHGlyph.document.symbolName when the file is next changed, with an iOS build to check it."
    private static let resolved = "Predates SHGlyph.resolved: the outline checkmark.circle as a plain symbol string. Pass SHGlyph.resolved.symbolName when the file is next changed, with an iOS build to check it."

    private static let chevrons = "Predates SHGlyph.popupChevrons: the up-down popup chevrons as a plain symbol string. Pass SHGlyph.popupChevrons when the file is next changed."

    private static let menu = "A menu or toolbar item: AppKit and UIKit draw it and rebuild it each time it opens, so no SwiftUI animation renames it."
    private static let kind = "Follows what the item is (its kind), which is fixed while it is on screen, so nothing renames it."
    private static func unanimated(_ what: String) -> String {
        "Follows \(what). No shAnimation or withSHAnimation reaches it, so it changes at once and loads no drawing pool. If an animation is added here, the pair must turn or fade instead."
    }

    static let entries: [DesignRuleException] = [
        // Raw colors: each is something other than app chrome, or a known fix.
        .init(.rawColor, "App/iOS/DesignPad/PadDesignMarkup.swift", 1, "Flattens an exported drawing onto a white page: image content, not chrome."),
        .init(.rawColor, "App/iOS/Designs/DesignHost.swift", 1, "Builds a UIColor from a pixel sampled from a board's snapshot: content, not chrome."),
        .init(.rawColor, "App/iOS/Terminal/TerminalSurface.swift", 1, "Converts the terminal theme's palette into SwiftTerm's own color type: the palette is the theme's."),
        .init(.rawColor, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/DesignCanvas.swift", 1, "An AppKit menu item's destructive title takes an NSColor: use NSColor(Color.sh.failed) when the file is next changed."),
        .init(.rawColor, "Sources/ShepherdApp/DesignSystemPageModel.swift", 1, "A design system that names no background draws on white, as its boards do: the design's content, not chrome."),
        .init(.rawColor, "Sources/ShepherdApp/ShepherdApp.swift", 2, "The Debug build's DEV badge, drawn into the Dock icon at runtime: not shipped UI."),
        // Status colors tinted by an alpha.
        .init(.statusTintByOpacity, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/AgentAuthParts.swift", 2, tint),
        .init(.statusTintByOpacity, "Packages/ShepherdUI/Sources/ShepherdUI/Components/PiSignIn/SheetParts.swift", 2, tint),
        // Shared glyphs named as raw symbols.
        .init(.rawGlyphName, "App/iOS/Automations/AutomationsScreen.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Review/DiffScreen.swift", 1, resolved),
        .init(.rawGlyphName, "App/iOS/Search/AgentActionSheets.swift", 1, resolved),
        .init(.rawGlyphName, "App/iOS/Settings/InstructionsScreens.swift", 1, document),
        .init(.rawGlyphName, "App/iOS/Settings/SettingsRoute.swift", 1, document),
        .init(.rawGlyphName, "App/iOS/Settings/SkillsScreens.swift", 1, document),
        .init(.rawGlyphName, "App/iOS/Composer/ComposerControls.swift", 1, "The iOS composer draws its own Fast bolt, which SHFastBolt and SHGlyph.fastBolt exist to prevent. Move it to SHGlyph.fastBolt, with an iOS build to check it."),
        .init(.rawGlyphName, "App/iOS/Home/AutomationRow.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Home/HomeRows.swift", 2, bolt),
        .init(.rawGlyphName, "App/iOS/Home/PadSidebar.swift", 1, bolt),
        .init(.rawGlyphName, "App/iOS/Settings/ExperimentsScreens.swift", 2, bolt),
        .init(.rawGlyphName, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Automations/Automations.swift", 1, bolt),
        .init(.rawGlyphName, "Sources/ShepherdApp/SettingsExperiments.swift", 1, bolt),
        .init(.rawGlyphName, "Sources/ShepherdApp/SidebarModel.swift", 7, bolt),
        .init(.rawGlyphName, "App/iOS/Settings/HostSettingsScreens.swift", 1, chevrons),
        .init(.rawGlyphName, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Pickers.swift", 1, chevrons),
        .init(.rawGlyphName, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Review/TouchDiff.swift", 1, chevrons),
        // Symbols that follow state where no animation reaches them. Each file says why; a disclosure
        // chevron that does animate is an SHTurningChevron, and any other pair that animates fades.
        .init(.symbolRenameUnderAnimation, "App/Widgets/ShepherdWidgets.swift", 1, "A widget draws one snapshot per timeline entry, so a symbol is never renamed on screen."),
        .init(.symbolRenameUnderAnimation, "App/iOS/Browser/ThreadBrowserPane.swift", 1, unanimated("the page's loading state; nothing in the browser pane animates it")),
        .init(.symbolRenameUnderAnimation, "App/iOS/Composer/ComposerControls.swift", 1, unanimated("the chosen speed; nothing in the composer's chips animates it")),
        .init(.symbolRenameUnderAnimation, "App/iOS/Files/ThreadFilesSplit.swift", 1, unanimated("a folder's open state; nothing in the files tree or its store animates it")),
        .init(.symbolRenameUnderAnimation, "App/iOS/Forge/ForgeDiffScreen.swift", 1, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Forge/ForgeListScreen.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "App/iOS/Home/ThreadRowMenu.swift", 2, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Projects/ProjectFilesScreen.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "App/iOS/Projects/ProjectScreen.swift", 1, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Review/DiffScreen.swift", 1, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Review/PadReviewScreen.swift", 3, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Review/ScopeMenu.swift", 2, "A menu item (rebuilt each time the menu opens), and the toolbar title's scope glyph, which follows the store's scope and which nothing in the review screens animates."),
        .init(.symbolRenameUnderAnimation, "App/iOS/Search/AgentActionsMenu.swift", 1, menu),
        .init(.symbolRenameUnderAnimation, "App/iOS/Search/SearchPalette.swift", 1, "Follows whether a listed step failed, which is fixed once the line is listed, so nothing renames it."),
        .init(.symbolRenameUnderAnimation, "App/iOS/Settings/ExperimentsScreens.swift", 2, kind),
        .init(.symbolRenameUnderAnimation, "App/iOS/Settings/SkillsScreens.swift", 1, unanimated("whether a skill is picked; the screen animates its list and search, not the pick")),
        .init(.symbolRenameUnderAnimation, "App/iOS/Thread/ThreadApps.swift", 2, "A menu item, and the menu's label in the thread's toolbar, which follows whether the app runs and which nothing in this file animates."),
        .init(.symbolRenameUnderAnimation, "App/iOS/Thread/ThreadScreen.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Browser/Browser.swift", 1, unanimated("whether the console drawer is open; BrowserPane flips it with no animation")),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/ContextMeter.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/ModelSettings.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/Lifecycle.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/References.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/SidePane.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Settings/MCPServerRow.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/Compaction.swift", 1, "Follows the compaction's tone, drawn only once it has ended and fixed from then on, so nothing renames it."),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ProseBlocks.swift", 1, "A task item of a finished Markdown block: its box is fixed by the text, so nothing renames it."),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/SentCommand.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Thread/ThreadParts.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/DesignSystemReferencePage.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/FilesTab.swift", 2, unanimated("the tree's hidden-files toggle and a folder's open state; the file tree model changes with no animation")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/Forge/ForgePage.swift", 1, unanimated("whether the page is pinned; the page animates its notices, not the pin")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/MCP/AddMCPServerSheet.swift", 1, unanimated("whether a variable is secret; the sheet animates its check and advanced sections, not this")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/Pages/AutomationsPage.swift", 1, unanimated("Pause and Resume; nothing in the page animates it")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/RemoteDirectoryPicker.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/SettingsExperiments.swift", 1, kind),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/SettingsProjects.swift", 1, unanimated("a project's open state; the tree flips it with no animation")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/SettingsSkills.swift", 2, kind),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/SkillsSheets.swift", 1, unanimated("the typed source; the sheet animates the skill detail, not the field")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/TerminalPanelViews.swift", 1, unanimated("the terminal panel's maximized state, which lands at once")),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/Thread/HookRows.swift", 1, "Follows a hook test's outcome; the file's one animation is the row's disclosure, which does not change it."),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/Thread/QueueStack.swift", 1, menu),
        .init(.symbolRenameUnderAnimation, "Sources/ShepherdApp/ThreadHeaderApps.swift", 1, menu),
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
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/Queue.swift", 8, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Composer/TouchQueue.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Buttons.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Pickers.swift", 6, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/SmallParts.swift", 2, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/TextFields.swift", 4, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Controls/Toggles.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/DesignTool/ReferenceSpecimens.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Fleet/HostPageCard.swift", 1, font),
        .init(.rawFontSize, "Packages/ShepherdUI/Sources/ShepherdUI/Components/Navigation/SHDensity.swift", 1, font),
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
