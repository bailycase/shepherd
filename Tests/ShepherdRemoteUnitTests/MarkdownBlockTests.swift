import Testing
@testable import ShepherdRemote

@Suite("Markdown blocks")
struct MarkdownBlockTests {
    typealias Item = NativeMarkdownListItem

    @Test func aDocumentSplitsIntoItsBlocks() {
        let text = """
        # Plan
        Intro line
        continues here.

        - first **bold**
        - second
          - nested `code`
          - nested two
        - third

        1. one
        2. two
           ```swift
           let x = "```"
           - not a list
           ```

        > quoted
        > more

        ---

        ## Sub
        tail
        """
        #expect(nativeMarkdownBlocks(text) == [
            .heading(level: 1, text: "Plan"),
            .paragraph("Intro line\ncontinues here."),
            .list(ordered: false, start: 1, items: [
                Item(text: "first **bold**"),
                Item(text: "second", children: [.list(ordered: false, start: 1, items: [Item(text: "nested `code`"), Item(text: "nested two")])]),
                Item(text: "third"),
            ]),
            .list(ordered: true, start: 1, items: [
                Item(text: "one"),
                Item(text: "two", children: [.code("let x = \"```\"\n- not a list", language: "swift")]),
            ]),
            .quote("quoted\nmore"),
            .rule,
            .heading(level: 2, text: "Sub"),
            .paragraph("tail"),
        ])
    }

    /// Whether the text ends inside a fence still open: the block a streaming reply is writing.
    @Test(arguments: [
        ("```swift\nlet a = 1", true),
        ("Here:\n\n```swift\nlet a = 1\n", true),
        ("- item\n  ```sh\n  ls", true),
        ("```swift\nlet a = 1\n```", false),
        ("```\nx\n```\n\nafter", false),
        ("```\nx\n```\n```\ny", true),
        ("no code at all", false),
    ])
    func aTextEndsInAnOpenFenceOnlyWhileTheFenceRunsToTheEnd(text: String, open: Bool) {
        #expect(nativeMarkdownParse(text).endsInOpenFence == open)
        #expect(nativeMarkdownParse(text).blocks == nativeMarkdownBlocks(text))
    }

    @Test(arguments: [
        ("", [NativeMarkdownBlock]()),
        ("3) c\n4) d", [.list(ordered: true, start: 3, items: [Item(text: "c"), Item(text: "d")])]),
        ("```\npartial", [.code("partial", language: nil)]),
        ("```sh extra\nls\n```", [.code("ls", language: "sh")]),
        ("#hashtag and -dash", [.paragraph("#hashtag and -dash")]),
        ("####### seven", [.paragraph("####### seven")]),
        ("###### six", [.heading(level: 6, text: "six")]),
        ("* * *", [.rule]),
        ("__", [.paragraph("__")]),
        (">bare quote", [.quote("bare quote")]),
        ("+ plus", [.list(ordered: false, start: 1, items: [Item(text: "plus")])]),
        ("1234567890. too long", [.paragraph("1234567890. too long")]),
    ])
    func singleConstructs(text: String, expected: [NativeMarkdownBlock]) {
        #expect(nativeMarkdownBlocks(text) == expected)
    }

    @Test func aBlankLineEndsAListUnlessTheNextLineIsIndented() {
        #expect(nativeMarkdownBlocks("- a\n\nafter") == [.list(ordered: false, start: 1, items: [Item(text: "a")]), .paragraph("after")])
        #expect(nativeMarkdownBlocks("- a\n\n  still a") == [.list(ordered: false, start: 1, items: [Item(text: "a\n\nstill a")])])
    }

    @Test func aLazyContinuationLineJoinsTheItem() {
        #expect(nativeMarkdownBlocks("- a\nmore") == [.list(ordered: false, start: 1, items: [Item(text: "a\nmore")])])
    }

    @Test func switchingMarkerKindStartsANewList() {
        #expect(nativeMarkdownBlocks("- a\n1. b") == [
            .list(ordered: false, start: 1, items: [Item(text: "a")]),
            .list(ordered: true, start: 1, items: [Item(text: "b")]),
        ])
    }

    @Test func fencesKeepTheirContentsLiteral() {
        #expect(nativeMarkdownBlocks("```\n# not a heading\n- not a list\n```\nafter") == [
            .code("# not a heading\n- not a list", language: nil), .paragraph("after"),
        ])
    }
}

@Suite("Scroll follower")
struct ScrollFollowerTests {
    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var start: NativeScrollFollower
        var distance: Double
        var intent = false
        var gesture = false
        var sticky: Bool
        var unseen: Bool
    }

    static let cases: [Case] = [
        Case(testDescription: "programmatic growth keeps a sticky view sticky", start: .init(), distance: 300, sticky: true, unseen: false),
        Case(testDescription: "user intent away from the bottom detaches", start: .init(), distance: 300, intent: true, sticky: false, unseen: false),
        Case(testDescription: "a gesture without an upward move stays stuck", start: .init(), distance: 40, gesture: true, sticky: true, unseen: false),
        Case(testDescription: "layout jitter without intent never detaches", start: .init(), distance: 500, sticky: true, unseen: false),
        Case(testDescription: "a detached view moving is not output arriving", start: .init(sticky: false), distance: 300, sticky: false, unseen: false),
        Case(testDescription: "returning near the bottom re-sticks and clears unseen", start: .init(sticky: false, unseen: true), distance: 3, sticky: true, unseen: false),
        Case(testDescription: "exactly the threshold counts as the bottom", start: .init(sticky: false, unseen: true), distance: NativeScrollFollower.threshold, sticky: true, unseen: false),
        Case(testDescription: "intent inside the threshold does not detach", start: .init(), distance: 10, intent: true, sticky: true, unseen: false),
    ]

    @Test(arguments: cases)
    func observation(_ c: Case) {
        var follower = c.start
        follower.userScrolling = c.gesture
        follower.observe(distanceFromBottom: c.distance, userIntent: c.intent)
        #expect(follower.sticky == c.sticky)
        #expect(follower.unseen == c.unseen)
    }

    @Test func theJumpPillShowsWhileDetachedAndSomethingIsHappeningBelow() {
        var detached = NativeScrollFollower(sticky: false, unseen: true)
        #expect(detached.showsJump(running: false) && detached.showsJump(running: true))
        detached.unseen = false
        #expect(!detached.showsJump(running: false) && detached.showsJump(running: true))
        #expect(!NativeScrollFollower().showsJump(running: true))
    }

    @Test func jumpingToLatestSticksAndForgetsWhatWasMissed() {
        var follower = NativeScrollFollower(sticky: false, unseen: true)
        follower.jumpToLatest()
        #expect(follower.sticky && !follower.unseen && !follower.showsJump(running: true))
    }

    @Test func theThresholdIsEightyPoints() {
        #expect(NativeScrollFollower.threshold == 80)
    }
}
