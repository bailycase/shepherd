import AppKit
import Foundation
import Testing
@testable import ShepherdApp

@Suite("Keybindings")
@MainActor
struct KeybindingsTests {
    // MARK: Defaults

    /// DESIGN.md's keyboard table is the contract.
    @Test(arguments: [
        (ShortcutAction.newAgent, "⌘N"), (.newAgentOptions, "⇧⌘T"), (.newSpace, "⇧⌘N"),
        (.renameAgent, "⌘R"), (.deleteAgent, "⇧⌘W"), (.commandPalette, "⌘K"),
        (.nextAgent, "⌘↓"), (.previousAgent, "⌘↑"),
        (.newTerminal, "⌘D"), (.closeTerminal, "⌘W"),
        (.nextTerminal, "⇧⌘]"), (.previousTerminal, "⇧⌘["),
        (.toggleTerminal, "⌘J"), (.maximizeTerminal, "⇧⌘↩"),
        (.toggleSidebar, "⇧⌘S"), (.toggleRightPane, "⇧⌘B"), (.modelPicker, "⇧⌘M"),
        (.stopAgent, "⌘."), (.previousTurn, "⌥⌘↑"), (.nextTurn, "⌥⌘↓"), (.inspectSubagent, "⌘I"),
        (.alternateSend, "⌘↩"), (.importDesign, "⇧⌘I"), (.implementInThread, "⌘↩"), (.copyDesignReference, "⇧⌘C"),
        (.focusAddressBar, "⌘L"), (.selectElement, "⇧⌘C"),
    ])
    func defaultsMatchTheDesignTable(action: ShortcutAction, display: String) {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.display(action) == display)
        #expect(keys.isDefault(action))
    }

    /// Every default must itself pass validation: it includes ⌘, is not reserved, and no two
    /// actions that can be pressed in the same place share a chord.
    @Test func everyDefaultIsAValidDistinctChord() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        for action in ShortcutAction.allCases {
            #expect(keys.validate(action.defaultChord, for: action) == nil, "\(action) default is invalid")
            for other in ShortcutAction.allCases where other != action && other.sharesScope(with: action) {
                #expect(other.defaultChord != action.defaultChord, "\(action) and \(other)")
            }
        }
    }

    /// The canvas's ⌘↩ (Implement in a thread…) and the composer's (send the other way) never
    /// meet: a design's canvas has no composer. Neither may take an app-wide chord, and neither is
    /// unbound in a terminal.
    @Test func theCanvasAndTheComposerShareChordsButNotWithTheApp() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(ShortcutAction.implementInThread.scope == .canvas && ShortcutAction.alternateSend.scope == .composer)
        #expect(!ShortcutAction.implementInThread.sharesScope(with: .alternateSend))
        #expect(keys.validate(ShortcutAction.renameAgent.defaultChord, for: .implementInThread) == .conflict(.renameAgent))
        #expect(keys.validate(ShortcutAction.copyDesignReference.defaultChord, for: .renameAgent) == .conflict(.copyDesignReference))
        #expect(keys.assign(KeyChord(key: "e", command: true, shift: true), to: .copyDesignReference) == nil)
        #expect(keys.validate(KeyChord(key: "e", command: true, shift: true), for: .implementInThread) == .conflict(.copyDesignReference))
        #expect(keys.customGhosttyUnbinds.isEmpty, "a canvas chord never reaches a terminal")
    }

    /// The Browser's ⇧⌘C (Select an element) and the canvas's (Copy reference) never meet: a
    /// design's layout has no Browser. The Browser sits beside the composer, so those two can't
    /// share a chord, and a rebound Browser chord is unbound in a terminal beside it.
    @Test func theBrowsersChordsAreScopedApartFromTheCanvas() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(ShortcutAction.selectElement.scope == .browser && ShortcutAction.focusAddressBar.scope == .browser)
        #expect(!ShortcutAction.selectElement.sharesScope(with: .copyDesignReference))
        #expect(ShortcutAction.selectElement.sharesScope(with: .alternateSend))
        #expect(keys.validate(ShortcutAction.alternateSend.defaultChord, for: .focusAddressBar) == .conflict(.alternateSend))
        #expect(keys.validate(ShortcutAction.toggleRightPane.defaultChord, for: .selectElement) == .conflict(.toggleRightPane))
        #expect(keys.assign(KeyChord(key: "e", command: true, shift: true), to: .selectElement) == nil)
        #expect(keys.customGhosttyUnbinds == ["shift+cmd+e"])
    }

    /// Terminals are tabs only: there is no split to bind, every terminal chord is an app-wide
    /// action, and none of them says pane or split to the user.
    @Test func theTerminalChordsAreTabChordsAndNoneSaysPaneOrSplit() {
        let terminal: [ShortcutAction] = [.newTerminal, .closeTerminal, .nextTerminal, .previousTerminal, .toggleTerminal, .maximizeTerminal]
        #expect(ShortcutAction.allCases.map(\.title).allSatisfy { !$0.lowercased().contains("split") && !$0.lowercased().contains("pane") || $0.contains("Side Pane") })
        #expect(terminal.map(\.title) == ["New Terminal", "Close Terminal", "Next Terminal", "Previous Terminal",
                                          "Show or Hide Terminal", "Maximize or Restore Terminal"])
        for action in terminal {
            #expect(action.scope == .app && action.reachesPastTerminals, "\(action) reaches the app from a focused terminal")
        }
        #expect(ShortcutAction.nextTerminal.defaultChord.ghosttyChord == "shift+cmd+right_bracket")
        #expect(ShortcutAction.previousTerminal.defaultChord.ghosttyChord == "shift+cmd+left_bracket")
    }

    /// A chord saved under an earlier name keeps its meaning (New Terminal was Split Vertically), and
    /// the actions the splits had are simply gone from what is stored.
    @Test func chordsSavedUnderTheEarlierNamesStillApply() throws {
        let defaults = Fixture.defaults()
        let saved: [String: KeyChord] = [
            "splitVertical": KeyChord(key: "e", command: true, option: true),
            "closePane": KeyChord(key: "k", command: true, option: true),
            "focusNextPane": KeyChord(key: "x", command: true, option: true),
            "splitHorizontal": KeyChord(key: "h", command: true, option: true),
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: KeybindingsStore.defaultsKey)
        let keys = KeybindingsStore(store: defaults)
        #expect(keys.display(.newTerminal) == "⌥⌘E")
        #expect(keys.display(.closeTerminal) == "⌥⌘K")
        #expect(keys.display(.nextTerminal) == "⌥⌘X")
        #expect(keys.overrides.count == 3, "the stored chord of the removed Split Horizontally is ignored")
        #expect(keys.isDefault(.previousTerminal))
        #expect(ShortcutAction(rawValue: "splitHorizontal") == nil)
    }

    @Test func defaultsNeedNoCustomGhosttyUnbinds() {
        #expect(KeybindingsStore(store: Fixture.defaults()).customGhosttyUnbinds.isEmpty)
    }

    /// ↩ is a key like the arrows: shown as ↩, a return key equivalent, Ghostty's `enter`, and
    /// what the recorder reads from the Return and Enter keys.
    @Test func returnIsAChordKey() {
        let chord = KeyChord(key: "return", command: true)
        #expect(chord.display == "⌘↩")
        #expect(chord.keyEquivalent == .return)
        #expect(chord.ghosttyChord == "cmd+enter")
        #expect(KeyChord.token(keyCode: 36, characters: "\r") == "return")
        #expect(KeyChord.token(keyCode: 76, characters: "\u{3}") == "return")
        #expect(chord.matches(key: .return, modifiers: [.command, .numericPad]))
        #expect(!chord.matches(key: .return, modifiers: [.command, .shift]))
    }

    /// Send the other way belongs to the composer (and a focused queued message): rebound, it
    /// still leaves a focused terminal its keys.
    @Test func theAlternateSendNeverTakesATerminalsKeys() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(ShortcutAction.alternateSend.sentenceTitle == "Send and steer now")
        #expect(keys.assign(KeyChord(key: "j", command: true, option: true), to: .alternateSend) == nil)
        #expect(keys.display(.alternateSend) == "⌥⌘J")
        #expect(keys.customGhosttyUnbinds.isEmpty)
    }

    /// The queue's fixed keys, as the Keyboard board lists them and Settings shows them.
    @Test func theQueuesFixedKeysMatchTheBoard() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(FixedChord.allCases.map(\.title) == ["Edit the last queued message", "Move the focused message",
                                                     "Delete the focused message", "Stop the agent"])
        #expect(FixedChord.allCases.map(\.keys) == [["↑"], ["⌥", "↑ ↓"], ["⌫"], ["Esc"]])
        #expect(keys.display(.deleteQueued) == "⌫")
        #expect(keys.display(.moveQueued) == "⌥↑ ⌥↓")
        #expect(keys.sendDisplay == "↩")
    }

    /// Settings ▸ Keyboard's While the agent is working group is the board's Keyboard card, in its
    /// order: ↩ queues, ⌘↩ steers now, and neither follows a setting.
    @Test func whileWorkingKeysFollowTheBoard() {
        #expect(WhileWorkingKey.all.map(\.title) == [
            "Queue it, the agent takes it when the turn ends", "Send and steer now",
            "Edit the last queued message", "Move the focused message", "Delete the focused message",
            "Steer the focused message now", "Stop the agent",
        ])
    }

    @Test func settingsRowsUseSentenceCase() {
        #expect(ShortcutAction.toggleSidebar.sentenceTitle == "Show or hide sidebar")
        #expect(ShortcutAction.newAgent.sentenceTitle == "New thread")
    }

    /// Settings copy that names a rebindable chord reads it from the store, so a rebind never
    /// leaves the copy naming the old chord.
    @Test func settingsCopyNamesChordsAsTheyAreBound() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(AgentSettings.explanation(keys).contains("⌘N"))
        #expect(TerminalSettings.shellSubtitle(keys).contains("⌘D"))

        #expect(keys.assign(KeyChord(key: "j", command: true, option: true), to: .newAgent) == nil)
        #expect(keys.assign(KeyChord(key: "e", command: true, option: true), to: .newTerminal) == nil)
        let agents = AgentSettings.explanation(keys), shell = TerminalSettings.shellSubtitle(keys)
        #expect(agents.contains(keys.display(.newAgent)) && !agents.contains("⌘N"))
        #expect(shell.contains(keys.display(.newTerminal)) && !shell.contains("⌘D"))

        let before = keys.display(.alternateSend)
        #expect(keys.assign(KeyChord(key: "s", command: true, option: true), to: .alternateSend) == nil)
        let help = Composer.sendHelp(working: true, send: keys.sendDisplay, alternate: keys.display(.alternateSend))
        #expect(help.contains(keys.display(.alternateSend)) && !help.contains(before))
    }

    // MARK: Validation

    @Test func chordsWithoutCommandAreRejected() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "k", shift: true, option: true), to: .closeTerminal) == .missingCommand)
        #expect(keys.isDefault(.closeTerminal))
    }

    /// ⌘1–9 select agents, ⌘, opens Settings, and plain-⌘ system and terminal chords belong
    /// to macOS and ghostty.
    @Test(arguments: [
        KeyChord(key: "3", command: true),
        KeyChord(key: "3", command: true, shift: true),
        KeyChord(key: "0", command: true, option: true),
        KeyChord(key: ",", command: true),
        KeyChord(key: "q", command: true), KeyChord(key: "h", command: true), KeyChord(key: "m", command: true),
        KeyChord(key: "c", command: true), KeyChord(key: "v", command: true), KeyChord(key: "x", command: true),
        KeyChord(key: "a", command: true), KeyChord(key: "z", command: true),
    ])
    func reservedChordsAreRejected(chord: KeyChord) {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(chord, to: .closeTerminal) == .reservedChord)
        #expect(keys.isDefault(.closeTerminal))
    }

    /// Another modifier opens the reserved letters back up (digits stay reserved).
    @Test func reservedLettersAreFreeWithAnExtraModifier() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "c", command: true, option: true), to: .closeTerminal) == nil)
        #expect(keys.display(.closeTerminal) == "⌥⌘C")
    }

    @Test func aChordInUseNamesTheActionThatOwnsIt() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "d", command: true), to: .closeTerminal) == .conflict(.newTerminal))
    }

    @Test func conflictsAreCheckedAgainstOverridesNotJustDefaults() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        let custom = KeyChord(key: "j", command: true, option: true)
        #expect(keys.assign(custom, to: .renameAgent) == nil)
        #expect(keys.assign(custom, to: .closeTerminal) == .conflict(.renameAgent))
        // The default it vacated is free again.
        #expect(keys.assign(ShortcutAction.renameAgent.defaultChord, to: .closeTerminal) == nil)
    }

    @Test func reassigningAnActionItsOwnChordIsNotAConflict() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.validate(ShortcutAction.closeTerminal.defaultChord, for: .closeTerminal) == nil)
    }

    // MARK: Persistence

    @Test func overridesPersistAcrossStores() {
        let store = Fixture.defaults()
        let chord = KeyChord(key: "k", command: true, shift: true)
        KeybindingsStore(store: store).assign(chord, to: .renameAgent)

        let reloaded = KeybindingsStore(store: store)
        #expect(reloaded.chord(for: .renameAgent) == chord)
        #expect(reloaded.display(.renameAgent) == "⇧⌘K")
        #expect(!reloaded.isDefault(.renameAgent))
    }

    /// Shells were removed; an override saved for their shortcut must not break loading.
    @Test func overridesForRemovedActionsAreIgnored() throws {
        let store = Fixture.defaults()
        let saved = [
            "shellDigits": KeyChord(key: "1", option: true),
            "renameAgent": KeyChord(key: "k", command: true, shift: true),
        ]
        store.set(try JSONEncoder().encode(saved), forKey: KeybindingsStore.defaultsKey)

        let keys = KeybindingsStore(store: store)
        #expect(keys.overrides == [.renameAgent: KeyChord(key: "k", command: true, shift: true)])
    }

    @Test func unreadableStoredOverridesFallBackToDefaults() {
        let store = Fixture.defaults()
        store.set(Data("not json".utf8), forKey: KeybindingsStore.defaultsKey)
        #expect(KeybindingsStore(store: store).overrides.isEmpty)
    }

    @Test func assigningTheDefaultClearsTheOverrideAndTheStoredKey() {
        let store = Fixture.defaults()
        let keys = KeybindingsStore(store: store)
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closeTerminal)
        keys.assign(ShortcutAction.closeTerminal.defaultChord, to: .closeTerminal)
        #expect(keys.isDefault(.closeTerminal))
        #expect(store.data(forKey: KeybindingsStore.defaultsKey) == nil)
    }

    @Test func resettingRefusesADefaultNowAssignedToAnotherAction() {
        let store = Fixture.defaults()
        let keys = KeybindingsStore(store: store)
        let custom = KeyChord(key: "k", command: true, shift: true)
        #expect(keys.assign(custom, to: .renameAgent) == nil)
        #expect(keys.assign(ShortcutAction.renameAgent.defaultChord, to: .closeTerminal) == nil)
        #expect(keys.reset(.renameAgent) == .conflict(.closeTerminal))
        #expect(keys.chord(for: .renameAgent) == custom)
        let reloaded = KeybindingsStore(store: store)
        #expect(reloaded.chord(for: .renameAgent) == custom)
        #expect(reloaded.chord(for: .closeTerminal) == ShortcutAction.renameAgent.defaultChord)
    }

    @Test func resettingOneActionKeepsTheOthers() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closeTerminal)
        keys.assign(KeyChord(key: "u", command: true), to: .newAgent)
        keys.reset(.closeTerminal)
        #expect(keys.isDefault(.closeTerminal))
        #expect(!keys.isDefault(.newAgent))
    }

    @Test func resetAllRestoresEveryDefault() {
        let store = Fixture.defaults()
        let keys = KeybindingsStore(store: store)
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closeTerminal)
        keys.assign(KeyChord(key: "u", command: true), to: .newAgent)
        keys.resetAll()
        #expect(ShortcutAction.allCases.allSatisfy { keys.isDefault($0) })
        #expect(store.data(forKey: KeybindingsStore.defaultsKey) == nil)
    }

    // MARK: Ghostty unbinds

    /// Custom chords reach ghostty in its keybind syntax so a focused terminal lets them through.
    @Test func customChordsBecomeSortedGhosttyUnbinds() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        keys.assign(KeyChord(key: "]", command: true), to: .renameAgent)
        keys.assign(KeyChord(key: "up", command: true, option: true, control: true), to: .nextTerminal)
        #expect(keys.customGhosttyUnbinds == ["cmd+right_bracket", "ctrl+alt+cmd+up"])
    }
}

@Suite("Key chords")
struct KeyChordTests {
    @Test func displayFollowsAppleModifierOrder() {
        let chord = KeyChord(key: "k", command: true, shift: true, option: true, control: true)
        #expect(chord.display == "⌃⌥⇧⌘K")
        #expect(chord.ghosttyChord == "ctrl+alt+shift+cmd+k")
    }

    @Test(arguments: [
        ("left", "←", "left"), ("right", "→", "right"), ("up", "↑", "up"), ("down", "↓", "down"),
        ("[", "[", "left_bracket"), ("]", "]", "right_bracket"), (",", ",", "comma"), (".", ".", "period"),
        ("/", "/", "slash"), (";", ";", "semicolon"), ("'", "'", "apostrophe"), ("\\", "\\", "backslash"),
        ("-", "-", "minus"), ("=", "=", "equal"), ("`", "`", "grave_accent"), ("k", "K", "k"), ("7", "7", "7"),
    ])
    func keysRenderForKeycapsAndGhostty(key: String, display: String, ghostty: String) {
        #expect(KeyChord.displayKey(key) == display)
        #expect(KeyChord.ghosttyKey(key) == ghostty)
    }

    @Test(arguments: [
        (UInt16(123), nil, "left"), (124, nil, "right"), (125, nil, "down"), (126, nil, "up"),
        (0, "A", "a"), (30, "]", "]"), (18, "1", "1"), (43, ",", ","),
        (49, " ", nil),            // space is not bindable
        (122, "\u{F704}", nil),    // F1
        (48, "\t", nil),           // tab
        (0, nil, nil),
    ] as [(UInt16, String?, String?)])
    func recorderTokensAcceptOnlyBindableKeys(keyCode: UInt16, characters: String?, token: String?) {
        #expect(KeyChord.token(keyCode: keyCode, characters: characters) == token)
    }

    /// Digit families match by physical key: `charactersIgnoringModifiers` reads ⇧1 as "!".
    @Test func digitRowKeyCodesMapToDigitsLayoutIndependently() {
        let expected: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]
        for (code, digit) in expected {
            #expect(KeyChord.digit(keyCode: code) == digit)
        }
        #expect(KeyChord.digit(keyCode: 29) == nil, "0 belongs to no digit family")
        #expect(KeyChord.digit(keyCode: 125) == nil)
        #expect(KeyChord.digit(keyCode: 0) == nil)
    }

    @Test func modifierFlagsCoverExactlyTheFourAppModifiers() {
        #expect(KeyChord(key: "1", control: true).modifierFlags == [.control])
        #expect(KeyChord(key: "d", command: true, shift: true, option: true, control: true).modifierFlags
            == [.command, .shift, .option, .control])
        #expect(KeyChord(key: "x").modifierFlags == [])
    }

    @Test func chordsRoundTripThroughJSON() throws {
        let chord = KeyChord(key: "up", command: true, option: true)
        #expect(try JSONDecoder().decode(KeyChord.self, from: JSONEncoder().encode(chord)) == chord)
    }
}

/// The navigation keyDown fast path bypasses the main menu: a wrong match either swallows a
/// keystroke meant for the terminal or steals a chord from it.
@Suite("Navigation key fast path")
@MainActor
struct NavigationKeyTests {
    private func classify(
        digit: Int? = nil,
        chord: KeyChord? = nil,
        modifiers: NSEvent.ModifierFlags = []
    ) -> ShepherdViewModel.NavigationKeyAction? {
        ShepherdViewModel.navigationKeyAction(
            digit: digit, chord: chord, modifiers: modifiers,
            next: ShortcutAction.nextAgent.defaultChord,
            previous: ShortcutAction.previousAgent.defaultChord
        )
    }

    @Test func commandDigitJumpsToAnAgent() {
        #expect(classify(digit: 3, modifiers: .command) == .agentDigit(3))
    }

    /// ⌃1–9 selected shells and ⌃⇧1–9 jumped between machines; with shells and the machine
    /// sections gone, both are the focused view's again.
    @Test(arguments: [
        NSEvent.ModifierFlags(), [.control], [.control, .shift], [.command, .option], [.command, .shift],
        [.control, .shift, .option], [.control, .shift, .command],
    ])
    func digitsWithOtherModifiersFallThrough(modifiers: NSEvent.ModifierFlags) {
        #expect(classify(digit: 1, modifiers: modifiers) == nil)
    }

    @Test func theAdjacentAgentChordsStepThroughTheSidebar() {
        #expect(classify(chord: ShortcutAction.nextAgent.defaultChord, modifiers: .command) == .adjacentAgent(1))
        #expect(classify(chord: ShortcutAction.previousAgent.defaultChord, modifiers: .command) == .adjacentAgent(-1))
    }

    @Test func reboundAdjacentChordsAreHonored() {
        let next = KeyChord(key: "j", command: true, option: true)
        let action = ShepherdViewModel.navigationKeyAction(
            digit: nil, chord: next, modifiers: [.command, .option],
            next: next, previous: ShortcutAction.previousAgent.defaultChord
        )
        #expect(action == .adjacentAgent(1))
        #expect(classify(chord: next, modifiers: [.command, .option]) == nil)
    }

    @Test(arguments: [
        KeyChord(key: "down"),
        KeyChord(key: "down", command: true, shift: true),
        KeyChord(key: "a", command: true),
    ])
    func unrelatedChordsFallThrough(chord: KeyChord) {
        #expect(classify(chord: chord, modifiers: chord.modifierFlags) == nil)
    }

    @Test func noKeyAtAllFallsThrough() {
        #expect(classify() == nil)
    }
}
