import Testing
@testable import ShepherdApp

@Suite("Thinking level cycling")
struct CycleThinkingShortcutTests {
    @Test(arguments: [
        ("medium", ["low", "medium", "high", "xhigh"], "high"),
        ("xhigh", ["low", "medium", "high", "xhigh"], "low"),
        ("off", ["off", "minimal", "low", "medium", "high", "xhigh", "max"], "minimal"),
        ("max", ["off", "minimal", "low", "medium", "high", "xhigh", "max"], "off"),
        ("medium", ["low", "medium", "future"], "future"),
        ("unavailable", ["low", "high"], "low"),
        ("off", ["off"], nil),
        ("medium", [], nil),
        (nil, ["low", "medium", "high"], nil),
    ] as [(String?, [String], String?)])
    func cyclingUsesOnlyOfferedLevelsInOrderAndWraps(current: String?, levels: [String], expected: String?) {
        #expect(CycleThinkingShortcut.next(current: current, levels: levels) == expected)
    }

    @Test(arguments: [
        ("low", 2, "high"), ("high", 2, "medium"), ("medium", 3, "medium"),
        ("low", Int.max, "medium"), ("unavailable", 2, "medium"),
        ("medium", 0, nil), ("medium", -1, nil),
    ] as [(String, Int, String?)])
    func pressesCombinedIntoOneUpdateStillAdvanceEveryLevel(current: String, steps: Int, expected: String?) {
        #expect(CycleThinkingShortcut.next(current: current, levels: ["low", "medium", "high"], steps: steps) == expected)
    }
}

@Suite("A Project's reasoning level follows its model")
struct ProjectThinkingClampTests {
    /// A new model keeps the level when it takes it, else gets the one pi would use; an unknown model's or no level changes nothing.
    @Test(arguments: [
        ("xhigh", ["off", "low", "medium", "high"], "high"),
        ("minimal", ["off", "low", "medium", "high", "xhigh"], "low"),
        ("high", ["off", "low", "medium", "high"], "high"),
        ("high", [], "high"),
        ("high", nil, "high"),
        (nil, ["low"], nil),
    ] as [(String?, [String]?, String?)])
    func aLevelTheNewModelLacksBecomesTheOnePiWouldUse(level: String?, levels: [String]?, expected: String?) {
        #expect(Composer.clampedThinking(level, to: levels) == expected)
    }
}

extension CycleThinkingShortcutTests {
    /// The chord changes a setting with cost behind it: VoiceOver hears the level it landed on.
    @Test func theChosenLevelIsAnnouncedByItsTitle() {
        #expect(CycleThinkingShortcut.announcement("xhigh") == "Thinking: Extra high")
        #expect(CycleThinkingShortcut.announcement("future") == "Thinking: Future")
    }
}
