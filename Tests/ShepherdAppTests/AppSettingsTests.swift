import Foundation
import ShepherdCore
import Testing
@testable import ShepherdApp

/// Settings are per-user chrome, so every test runs against its own defaults
/// suite — never `.standard`, which belongs to the running app.
@MainActor
private func scratchDefaults() -> UserDefaults {
    let name = "shepherd.tests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: name)!
    defaults.removePersistentDomain(forName: name)
    return defaults
}

@Suite("App settings")
@MainActor
struct AppSettingsTests {
    @Test func freshSettingsUsePublishedDefaults() {
        let settings = AppSettings(store: scratchDefaults())

        #expect(settings.terminalFontFamily == AppSettings.Defaults.terminalFontFamily)
        #expect(settings.terminalFontSize == AppSettings.Defaults.terminalFontSize)
        #expect(settings.defaultModel.isEmpty)
        #expect(settings.defaultThinking == AppSettings.Defaults.thinking)
        #expect(settings.autoNameAgents)
        #expect(settings.autoUpdatePi == AppSettings.Defaults.autoUpdatePi)
        #expect(settings.autoUpdateExtensions == AppSettings.Defaults.autoUpdateExtensions)
        #expect(settings.worktreeGeneratePRDescription)
    }

    @Test func valuesPersistAndReload() {
        let store = scratchDefaults()
        let settings = AppSettings(store: store)

        settings.terminalFontFamily = "Menlo"
        settings.terminalFontSize = 15
        settings.defaultModel = "anthropic/claude-sonnet-4"
        settings.defaultThinking = .high
        settings.autoNameAgents = false
        settings.autoUpdatePi = true
        settings.autoUpdateExtensions = true
        settings.shellPath = "/bin/bash"
        settings.sidebarWidth = 275
        settings.worktreeGeneratePRDescription = false

        let reloaded = AppSettings(store: store)
        #expect(reloaded.terminalFontFamily == "Menlo")
        #expect(reloaded.terminalFontSize == 15)
        #expect(reloaded.defaultModel == "anthropic/claude-sonnet-4")
        #expect(reloaded.defaultThinking == .high)
        #expect(reloaded.autoNameAgents == false)
        #expect(reloaded.autoUpdatePi)
        #expect(reloaded.autoUpdateExtensions)
        #expect(reloaded.shellPath == "/bin/bash")
        #expect(reloaded.sidebarWidth == 275)
        #expect(reloaded.worktreeGeneratePRDescription == false)
    }

    @Test func sidebarWidthIsClampedToItsDragRange() {
        #expect(AppSettings.clampSidebarWidth(100) == AppSettings.sidebarWidthRange.lowerBound)
        #expect(AppSettings.clampSidebarWidth(275) == 275)
        #expect(AppSettings.clampSidebarWidth(500) == AppSettings.sidebarWidthRange.upperBound)
    }

    /// A stored size outside the slider's range (hand-edited defaults) must
    /// not reach ghostty as an unusable font size.
    @Test func storedFontSizeIsClamped() {
        let store = scratchDefaults()
        store.set(400.0, forKey: AppSettings.Key.terminalFontSize)
        #expect(AppSettings(store: store).terminalFontSize == AppSettings.fontSizeRange.upperBound)

        store.set(1.0, forKey: AppSettings.Key.terminalFontSize)
        #expect(AppSettings(store: store).terminalFontSize == AppSettings.fontSizeRange.lowerBound)
    }

    @Test func resetClearsEveryStoredKey() {
        let store = scratchDefaults()
        let settings = AppSettings(store: store)
        settings.terminalFontSize = 20
        settings.defaultModel = "openai/gpt-5"
        settings.autoNameAgents = false
        settings.autoUpdatePi = true
        settings.autoUpdateExtensions = true
        settings.worktreeGeneratePRDescription = false

        settings.resetToDefaults()

        #expect(settings.terminalFontSize == AppSettings.Defaults.terminalFontSize)
        #expect(settings.defaultModel.isEmpty)
        #expect(settings.autoNameAgents)
        #expect(settings.autoUpdatePi == AppSettings.Defaults.autoUpdatePi)
        #expect(settings.autoUpdateExtensions == AppSettings.Defaults.autoUpdateExtensions)
        #expect(settings.worktreeGeneratePRDescription)
        for key in AppSettings.Key.all {
            #expect(store.object(forKey: key) == nil)
        }
    }

    /// An empty model must stay nil so pi is launched without `--model` at
    /// all, rather than with an empty argument.
    @Test func emptyDefaultModelMeansPiDecides() {
        let settings = AppSettings(store: scratchDefaults())
        settings.defaultModel = "   "
        #expect(settings.agentDefaults.model == nil)

        settings.defaultModel = " openai/gpt-5 "
        #expect(settings.agentDefaults.model == "openai/gpt-5")
    }

    @Test func legacyCombinedPiSettingMigratesToExtensionUpdates() {
        let store = scratchDefaults()
        store.set(true, forKey: AppSettings.Key.autoUpdatePi)

        #expect(AppSettings(store: store).autoUpdateExtensions)
    }

    @Test func automaticPiCommandsRespectIndependentSettings() {
        #expect(PiUpdateManager.automaticUpdateArguments(updatePi: false, updateExtensions: false).isEmpty)
        #expect(PiUpdateManager.automaticUpdateArguments(updatePi: true, updateExtensions: false) == [["update"]])
        #expect(PiUpdateManager.automaticUpdateArguments(updatePi: false, updateExtensions: true) == [["update", "--extensions"]])
        #expect(PiUpdateManager.automaticUpdateArguments(updatePi: true, updateExtensions: true) == [
            ["update"], ["update", "--extensions"],
        ])
    }

    @Test func piUpdateButtonDisablesWhenCurrentOrBusy() {
        #expect(PiUpdateManager.canUpdatePi(lastChecked: nil, isOutdated: false, isBusy: false))
        #expect(PiUpdateManager.canUpdatePi(lastChecked: Date(), isOutdated: true, isBusy: false))
        #expect(!PiUpdateManager.canUpdatePi(lastChecked: Date(), isOutdated: false, isBusy: false))
        #expect(!PiUpdateManager.canUpdatePi(lastChecked: nil, isOutdated: true, isBusy: true))
    }

    @Test func piVersionComparisonHandlesPrefixesAndMissingComponents() {
        #expect(PiUpdateManager.isVersion("1.2.3", olderThan: "1.2.4"))
        #expect(PiUpdateManager.isVersion("v1.2", olderThan: "1.2.0" ) == false)
        #expect(!PiUpdateManager.isVersion("1.3.0", olderThan: "1.2.9"))
        #expect(!PiUpdateManager.isVersion("not-a-version", olderThan: "1.2.0"))
    }

    @Test func shellCommandFallsBackWhenThePathIsNotExecutable() {
        let settings = AppSettings(store: scratchDefaults())
        settings.shellPath = "/definitely/not/a/shell"
        #expect(settings.shellCommand == [AppSettings.Defaults.shellPath, "-l"])

        settings.shellPath = "/bin/zsh"
        #expect(settings.shellCommand == ["/bin/zsh", "-l"])
    }

    /// The picker must always be able to show the configured family, even if
    /// that font is not installed — ghostty falls back silently otherwise.
    @Test func fontFamilyListIncludesTheConfiguredFamily() {
        let families = AppSettings.monospacedFamilies(including: "Nonexistent Mono")
        #expect(families.contains("Nonexistent Mono"))
        #expect(families == families.sorted())
    }

    @Test func shellListIsDeduplicatedAndIncludesTheCurrentShell() {
        let shells = AppSettings.knownShells(including: "/bin/zsh")
        #expect(shells.contains("/bin/zsh"))
        #expect(Set(shells).count == shells.count)
    }
}

@Suite("Settings-driven agent launch")
@MainActor
struct SettingsDrivenAgentTests {
    private var space: Space {
        Space(name: "Shepherd", path: "/tmp/Shepherd")
    }

    @Test func quickCreateInheritsTheConfiguredDefaults() {
        let defaults = AgentDefaults(model: "anthropic/claude-sonnet-4", thinking: .high)
        let config = ShepherdViewModel.quickAgentConfig(for: space, defaults: defaults)

        #expect(config.model == "anthropic/claude-sonnet-4")
        #expect(config.thinking == .high)
        #expect(config.workingDirectory == space.path)
    }

    /// Without configured defaults, ⌘N keeps its original contract: pi's own
    /// model and medium thinking.
    @Test func quickCreateWithoutDefaultsStillDefersToPi() {
        let config = ShepherdViewModel.quickAgentConfig(for: space)
        #expect(config.model == nil)
        #expect(config.thinking == .medium)
    }

    @Test func namerRunsOnlyForProvisionalNamesWithAutoNamingOn() {
        let provisional = Agent(
            name: "fix the sidebar",
            spaceID: space.id,
            tabID: TabID(),
            nameIsFinal: false
        )
        let named = Agent(
            name: "Fix sidebar layout",
            spaceID: space.id,
            tabID: TabID(),
            nameIsFinal: true
        )

        #expect(TerminalSessionStore.wantsNamer(for: provisional, autoName: true))
        #expect(!TerminalSessionStore.wantsNamer(for: provisional, autoName: false))
        #expect(!TerminalSessionStore.wantsNamer(for: named, autoName: true))
        #expect(!TerminalSessionStore.wantsNamer(for: named, autoName: false))
    }
}

@Suite("Sidebar space tree")
@MainActor
struct SpaceTreeTests {
    private func makeState() -> (ShepherdState, SpaceID, SpaceID) {
        let a = Space(name: "alpha", path: "/tmp/a")
        let b = Space(name: "beta", path: "/tmp/b")
        var state = ShepherdState(spaces: [a, b])
        state.agents = [
            Agent(name: "one", spaceID: a.id, tabID: TabID()),
            Agent(name: "two", spaceID: b.id, tabID: TabID()),
            Agent(name: "three", spaceID: a.id, tabID: TabID()),
        ]
        return (state, a.id, b.id)
    }

    /// Each space section lists exactly its own agents, in declaration order.
    @Test func spaceSectionsListTheirOwnAgents() {
        let (state, a, b) = makeState()
        #expect(ShepherdViewModel.agents(in: state, space: a).map(\.name) == ["one", "three"])
        #expect(ShepherdViewModel.agents(in: state, space: b).map(\.name) == ["two"])
    }

    /// A space whose path lives under another space's path nests beneath it
    /// automatically; unrelated spaces stay roots in declaration order.
    @Test func spacesNestByPathContainment() {
        let mono = Space(name: "mono", path: "/Users/x/mono")
        let child = Space(name: "sub-project", path: "/Users/x/mono/sub-project")
        let deep = Space(name: "svc", path: "/Users/x/mono/sub-project/svc")
        let other = Space(name: "web", path: "/Users/x/web")
        // Declaration order scrambled: nesting must not depend on add order.
        let forest = ShepherdViewModel.spaceForest([other, deep, mono, child])
        #expect(forest.map(\.space.name) == ["web", "mono", "sub-project", "svc"])
        #expect(forest.map(\.depth) == [0, 0, 1, 2])
    }

    /// Sibling prefixes are not containment: /tmp/app2 is not under /tmp/app.
    @Test func pathPrefixWithoutSeparatorDoesNotNest() {
        let app = Space(name: "app", path: "/tmp/app")
        let app2 = Space(name: "app2", path: "/tmp/app2")
        let forest = ShepherdViewModel.spaceForest([app, app2])
        #expect(forest.map(\.depth) == [0, 0])
    }

    @Test func anUnknownSpaceListsNothing() {
        let (state, _, _) = makeState()
        #expect(ShepherdViewModel.agents(in: state, space: SpaceID()).isEmpty)
    }
}

@Suite("Keybindings")
@MainActor
struct KeybindingsTests {
    @Test func defaultsMatchTheOriginalChords() {
        let keys = KeybindingsStore(store: scratchDefaults())
        #expect(keys.display(.newAgent) == "⌘N")
        #expect(keys.display(.newAgentOptions) == "⇧⌘T")
        #expect(keys.display(.newSpace) == "⇧⌘N")
        #expect(keys.display(.nextAgent) == "⌘↓")
        #expect(keys.display(.previousAgent) == "⌘↑")
        #expect(keys.display(.shellDigits) == "⌃1–9")
        #expect(keys.chord(for: .shellDigits) == KeyChord(key: "1", control: true))
        #expect(keys.display(.splitVertical) == "⌘D")
        #expect(keys.display(.splitHorizontal) == "⇧⌘D")
        #expect(keys.display(.closePane) == "⌘W")
        #expect(keys.display(.deleteAgent) == "⇧⌘W")
        #expect(keys.display(.focusNextPane) == "⌥⌘→")
        #expect(keys.display(.focusPreviousPane) == "⌥⌘←")
        #expect(keys.customGhosttyUnbinds.isEmpty)
    }

    @Test func overridesPersistAndReload() {
        let store = scratchDefaults()
        let keys = KeybindingsStore(store: store)
        let chord = KeyChord(key: "k", command: true, shift: true)

        #expect(keys.assign(chord, to: .renameAgent) == nil)
        #expect(keys.display(.renameAgent) == "⇧⌘K")

        let reloaded = KeybindingsStore(store: store)
        #expect(reloaded.chord(for: .renameAgent) == chord)
        #expect(!reloaded.isDefault(.renameAgent))
    }

    @Test func chordsWithoutCommandAreRejected() {
        let keys = KeybindingsStore(store: scratchDefaults())
        let error = keys.assign(KeyChord(key: "k", shift: true), to: .closePane)
        #expect(error == .missingCommand)
        #expect(keys.isDefault(.closePane))
    }

    /// ⌘1–9 selects agents and ⌘C belongs to the terminal — neither may be
    /// stolen by a rebind.
    @Test func reservedChordsAreRejected() {
        let keys = KeybindingsStore(store: scratchDefaults())
        #expect(keys.assign(KeyChord(key: "3", command: true), to: .closePane) == .reservedChord)
        #expect(keys.assign(KeyChord(key: "c", command: true), to: .closePane) == .reservedChord)
        #expect(keys.assign(KeyChord(key: ",", command: true), to: .closePane) == .reservedChord)
        // With another modifier the alphabet opens back up.
        #expect(keys.assign(KeyChord(key: "c", command: true, option: true), to: .closePane) == nil)
    }

    @Test func machineDigitsAreReservedFromShellSelection() {
        let keys = KeybindingsStore(store: scratchDefaults())
        #expect(keys.assign(KeyChord(key: "1", shift: true, control: true), to: .shellDigits) == .reservedChord)
    }

    @Test func conflictingChordsAreRejectedAcrossActions() {
        let keys = KeybindingsStore(store: scratchDefaults())
        let error = keys.assign(KeyChord(key: "d", command: true), to: .closePane)
        #expect(error == .conflict(.splitVertical))
    }

    @Test func assigningTheDefaultClearsTheOverride() {
        let store = scratchDefaults()
        let keys = KeybindingsStore(store: store)
        keys.assign(KeyChord(key: "k", command: true), to: .closePane)
        keys.assign(ShortcutAction.closePane.defaultChord, to: .closePane)
        #expect(keys.isDefault(.closePane))
        #expect(store.data(forKey: KeybindingsStore.defaultsKey) == nil)
    }

    @Test func resetAllRestoresEveryDefault() {
        let store = scratchDefaults()
        let keys = KeybindingsStore(store: store)
        keys.assign(KeyChord(key: "k", command: true), to: .closePane)
        keys.assign(KeyChord(key: "u", command: true), to: .newAgent)
        keys.resetAll()
        #expect(ShortcutAction.allCases.allSatisfy { keys.isDefault($0) })
        #expect(store.data(forKey: KeybindingsStore.defaultsKey) == nil)
    }

    /// Custom chords must reach ghostty in its keybind syntax so focused
    /// terminals let them through.
    @Test func customChordsTranslateToGhosttySyntax() {
        let keys = KeybindingsStore(store: scratchDefaults())
        keys.assign(KeyChord(key: "]", command: true), to: .renameAgent)
        keys.assign(KeyChord(key: "up", command: true, option: true), to: .focusNextPane)
        #expect(keys.customGhosttyUnbinds == ["alt+cmd+up", "cmd+right_bracket"])
    }

    @Test func chordDisplayFollowsAppleModifierOrder() {
        let chord = KeyChord(key: "k", command: true, shift: true, option: true, control: true)
        #expect(chord.display == "⌃⌥⇧⌘K")
        #expect(chord.ghosttyChord == "ctrl+alt+shift+cmd+k")
    }

    @Test func recorderTokensMapArrowsAndReasonableKeys() {
        #expect(KeyChord.token(keyCode: 123, characters: nil) == "left")
        #expect(KeyChord.token(keyCode: 124, characters: nil) == "right")
        #expect(KeyChord.token(keyCode: 0, characters: "A") == "a")
        #expect(KeyChord.token(keyCode: 30, characters: "]") == "]")
        // Space and function keys are not bindable.
        #expect(KeyChord.token(keyCode: 49, characters: " ") == nil)
        #expect(KeyChord.token(keyCode: 122, characters: "\u{F704}") == nil)
    }
}
