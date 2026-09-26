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
        (.splitVertical, "⌘D"), (.splitHorizontal, "⇧⌘D"), (.closePane, "⌘W"),
        (.focusNextPane, "⌥⌘→"), (.focusPreviousPane, "⌥⌘←"),
        (.toggleSidebar, "⇧⌘S"), (.toggleRightPane, "⇧⌘B"), (.modelPicker, "⇧⌘M"),
        (.stopAgent, "⌘."), (.previousTurn, "⌥⌘↑"), (.nextTurn, "⌥⌘↓"), (.inspectSubagent, "⌘I"),
        (.alternateSend, "⌘↩"),
    ])
    func defaultsMatchTheDesignTable(action: ShortcutAction, display: String) {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.display(action) == display)
        #expect(keys.isDefault(action))
    }

    /// Every default must itself pass validation: it includes ⌘, is not reserved, and no two
    /// actions share a chord.
    @Test func everyDefaultIsAValidDistinctChord() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        for action in ShortcutAction.allCases {
            #expect(keys.validate(action.defaultChord, for: action) == nil, "\(action) default is invalid")
        }
        #expect(Set(ShortcutAction.allCases.map(\.defaultChord)).count == ShortcutAction.allCases.count)
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
        #expect(ShortcutAction.alternateSend.sentenceTitle == "Send the other way (steer or queue)")
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
    /// order; ↩ and the alternate send say what they do under the Return setting.
    @Test(arguments: [
        (ReturnWhileWorking.queue, ["Send, queued", "Send and steer now"]),
        (.steer, ["Send and steer now", "Send, queued"]),
    ])
    func whileWorkingKeysFollowTheBoardAndTheReturnSetting(setting: ReturnWhileWorking, sendTitles: [String]) {
        #expect(WhileWorkingKey.all.map { $0.title(setting) } == sendTitles + [
            "Edit the last queued message", "Move the focused message", "Delete the focused message",
            "Steer the focused message", "Stop the agent",
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
        #expect(AgentSettings.returnDescription(keys).hasSuffix("\(keys.display(.alternateSend)) always does the other one."))

        #expect(keys.assign(KeyChord(key: "j", command: true, option: true), to: .newAgent) == nil)
        #expect(keys.assign(KeyChord(key: "e", command: true, option: true), to: .splitVertical) == nil)
        let agents = AgentSettings.explanation(keys), shell = TerminalSettings.shellSubtitle(keys)
        #expect(agents.contains(keys.display(.newAgent)) && !agents.contains("⌘N"))
        #expect(shell.contains(keys.display(.splitVertical)) && !shell.contains("⌘D"))

        let before = keys.display(.alternateSend)
        #expect(keys.assign(KeyChord(key: "s", command: true, option: true), to: .alternateSend) == nil)
        let queue = AgentSettings.returnDescription(keys)
        #expect(queue.contains(keys.display(.alternateSend)) && !queue.contains(before))
    }

    // MARK: Validation

    @Test func chordsWithoutCommandAreRejected() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "k", shift: true, option: true), to: .closePane) == .missingCommand)
        #expect(keys.isDefault(.closePane))
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
        #expect(keys.assign(chord, to: .closePane) == .reservedChord)
        #expect(keys.isDefault(.closePane))
    }

    /// Another modifier opens the reserved letters back up (digits stay reserved).
    @Test func reservedLettersAreFreeWithAnExtraModifier() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "c", command: true, option: true), to: .closePane) == nil)
        #expect(keys.display(.closePane) == "⌥⌘C")
    }

    @Test func aChordInUseNamesTheActionThatOwnsIt() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.assign(KeyChord(key: "d", command: true), to: .closePane) == .conflict(.splitVertical))
    }

    @Test func conflictsAreCheckedAgainstOverridesNotJustDefaults() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        let custom = KeyChord(key: "j", command: true, option: true)
        #expect(keys.assign(custom, to: .renameAgent) == nil)
        #expect(keys.assign(custom, to: .closePane) == .conflict(.renameAgent))
        // The default it vacated is free again.
        #expect(keys.assign(ShortcutAction.renameAgent.defaultChord, to: .closePane) == nil)
    }

    @Test func reassigningAnActionItsOwnChordIsNotAConflict() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        #expect(keys.validate(ShortcutAction.closePane.defaultChord, for: .closePane) == nil)
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
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closePane)
        keys.assign(ShortcutAction.closePane.defaultChord, to: .closePane)
        #expect(keys.isDefault(.closePane))
        #expect(store.data(forKey: KeybindingsStore.defaultsKey) == nil)
    }

    @Test func resettingOneActionKeepsTheOthers() {
        let keys = KeybindingsStore(store: Fixture.defaults())
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closePane)
        keys.assign(KeyChord(key: "u", command: true), to: .newAgent)
        keys.reset(.closePane)
        #expect(keys.isDefault(.closePane))
        #expect(!keys.isDefault(.newAgent))
    }

    @Test func resetAllRestoresEveryDefault() {
        let store = Fixture.defaults()
        let keys = KeybindingsStore(store: store)
        keys.assign(KeyChord(key: "k", command: true, option: true), to: .closePane)
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
        keys.assign(KeyChord(key: "up", command: true, option: true, control: true), to: .focusNextPane)
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
