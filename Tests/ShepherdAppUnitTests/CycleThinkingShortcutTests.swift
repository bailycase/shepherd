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
