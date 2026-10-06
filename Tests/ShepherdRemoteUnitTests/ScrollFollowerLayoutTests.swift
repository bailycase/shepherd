import Testing
import ShepherdRemote

/// The follower between two scroll readings, as the Mac and iOS threads both feed it: layout
/// changes (rows arriving or re-wrapping, the composer or keyboard resizing the inset) never
/// detach a stuck thread and bring it back to its tail; only a gesture moving it up does.
@Suite("Scroll follower: layout")
struct ScrollFollowerLayoutTests {
    /// At the tail of 2000pt of content in a 700pt viewport, a 60pt bar above and a 120pt composer below.
    static let tail = NativeScrollProbe(content: 2000, offset: 2000 + 120 - 700, container: 700 - 60 - 120, insetTop: 60, insetBottom: 120)

    static func probe(content: Double = 2000, offset: Double = 1420, container: Double = 520, inset: Double = 120) -> NativeScrollProbe {
        NativeScrollProbe(content: content, offset: offset, container: container, insetTop: 60, insetBottom: inset)
    }

    struct Case: Sendable, CustomTestStringConvertible {
        var testDescription: String
        var start = NativeScrollFollower()
        var new: NativeScrollProbe
        var gesture = false
        /// The scroll view keeps the tail itself too (iOS); false for the Mac thread, which follows by scrolling alone.
        var nativeAnchor = true
        var sticky: Bool
        var repins: Bool
        var unseen = false
    }

    static let cases: [Case] = [
        Case(testDescription: "a reply and its changes card arriving at once keep it stuck and land on the tail",
             new: probe(content: 2400), sticky: true, repins: true),
        Case(testDescription: "a taller composer or the keyboard keeps it stuck and lands on the tail",
             new: probe(container: 300, inset: 340), sticky: true, repins: true),
        Case(testDescription: "rows re-wrapping beside a docked review keep it stuck and land on the tail",
             new: probe(content: 2600, container: 520), sticky: true, repins: true),
        Case(testDescription: "a layout change during a drag is layout, not the reader, and leaves the finger's place alone",
             new: probe(content: 2400), gesture: true, sticky: true, repins: false),
        Case(testDescription: "a drag moving it up with the layout unchanged detaches",
             new: probe(offset: 1120), gesture: true, sticky: false, repins: false),
        Case(testDescription: "moving up without a gesture never detaches",
             new: probe(offset: 1120), sticky: true, repins: false),
        Case(testDescription: "detached, growth is left where it is and is not output by itself",
             start: NativeScrollFollower(sticky: false), new: probe(content: 2400, offset: 1120), sticky: false, repins: false),
        Case(testDescription: "with a native anchor (iOS), history shrinking lets it settle first",
             new: probe(content: 1000), sticky: true, repins: false),
        Case(testDescription: "with a native anchor (iOS), a composer collapse lets it settle first",
             new: probe(container: 620, inset: 20), sticky: true, repins: false),
        Case(testDescription: "a layout change that leaves it at the tail needs no scroll",
             new: probe(content: 2002, offset: 1422), sticky: true, repins: false),
        // Without a native anchor nothing else moves the offset, so a reading past the end is final.
        Case(testDescription: "history shrinking under a view that scrolls alone lands on the tail at once",
             new: probe(content: 1000), nativeAnchor: false, sticky: true, repins: true),
        Case(testDescription: "a composer collapse under a view that scrolls alone lands on the tail at once",
             new: probe(container: 620, inset: 20), nativeAnchor: false, sticky: true, repins: true),
        Case(testDescription: "rows settling shorter by a few points leave a view that scrolls alone where it is",
             new: probe(content: 1990), nativeAnchor: false, sticky: true, repins: false),
        Case(testDescription: "content that fits, changing, is not overscroll for a view that scrolls alone",
             start: NativeScrollFollower(), new: probe(content: 300, offset: -60), nativeAnchor: false, sticky: true, repins: false),
        Case(testDescription: "a view that scrolls alone leaves a finger's place alone while layout shrinks under it",
             new: probe(content: 1000), gesture: true, nativeAnchor: false, sticky: true, repins: false),
    ]

    @Test(arguments: cases)
    func layoutAndGestures(_ c: Case) {
        var follower = c.start
        let old = c.start.sticky ? Self.tail : Self.probe(offset: 1120)
        let repins = follower.observe(from: old, to: c.new, gesture: c.gesture, nativeAnchor: c.nativeAnchor)
        #expect(repins == c.repins)
        #expect(follower.sticky == c.sticky)
        #expect(follower.unseen == c.unseen)
    }

    /// A drag up from the tail measures the rows it reveals: that reading stays stuck without
    /// pulling the thread back, and the drag's next reading detaches it.
    @Test func aDragThatMeasuresRowsAboveStillLeavesTheTail() {
        var follower = NativeScrollFollower()
        let dragged = Self.probe(offset: 1370)
        let measured = Self.probe(content: 2159, offset: 1370)
        let repins = [
            follower.observe(from: Self.tail, to: dragged, gesture: true),
            follower.observe(from: dragged, to: measured, gesture: true),
        ]
        #expect(repins == [false, false])
        #expect(follower.sticky)
        let further = follower.observe(from: measured, to: Self.probe(content: 2159, offset: 1320), gesture: true)
        #expect(!further)
        #expect(!follower.sticky)
    }

    @Test func aPinnedViewRepairsOffsetsPastTheContentWithoutFightingGestures() {
        let beyondTail = Self.probe(offset: 2300)
        var follower = NativeScrollFollower()
        let repair = follower.observe(from: Self.tail, to: beyondTail, gesture: false)
        #expect(repair, "an offset-only jump past the end must recover without another wheel event")
        let duringGesture = follower.observe(from: Self.tail, to: beyondTail, gesture: true)
        #expect(!duringGesture)
        let short = Self.probe(content: 300, offset: -60)
        let fits = follower.observe(from: Self.tail, to: short, gesture: false)
        #expect(!fits, "short content above its tail is not overscroll")
        let pastShortContent = Self.probe(content: 300, offset: 400)
        let repairShort = follower.observe(from: short, to: pastShortContent, gesture: false)
        #expect(repairShort)
    }

    @Test func nativeMarginsAndIntermediateLayoutDoNotTriggerOverscrollRepair() {
        var follower = NativeScrollFollower()
        let margin = Self.probe(offset: 1448)
        let marginRepair = follower.observe(from: Self.tail, to: margin, gesture: false)
        #expect(!marginRepair)
        let shrinking = Self.probe(content: 1000)
        let shrinkRepair = follower.observe(from: Self.tail, to: shrinking, gesture: false)
        #expect(!shrinkRepair)
        let staleOffset = Self.probe(content: 1000, offset: 1500)
        let staleRepair = follower.observe(from: shrinking, to: staleOffset, gesture: false)
        #expect(staleRepair)
        let collapsed = Self.probe(container: 720, inset: 0)
        let collapseRepair = follower.observe(from: Self.tail, to: collapsed, gesture: false)
        #expect(!collapseRepair)
        let staleCollapseOffset = Self.probe(offset: 1500, container: 720, inset: 0)
        let staleCollapseRepair = follower.observe(from: collapsed, to: staleCollapseOffset, gesture: false)
        #expect(staleCollapseRepair)
    }

    @Test func aComposerCollapseFollowedByAnOffsetReboundKeepsFollowing() {
        var follower = NativeScrollFollower()
        follower.sent(queued: false)
        let collapsed = Self.probe(offset: 1220, container: 720, inset: 0)
        let atTail = follower.observe(from: Self.tail, to: collapsed, gesture: false)
        #expect(!atTail)
        let rebound = Self.probe(offset: 1020, container: 720, inset: 0)
        let repair = follower.observe(from: collapsed, to: rebound, gesture: false)
        #expect(repair, "the native offset can change after the composer inset has settled")
        let repaired = follower.observe(from: rebound, to: collapsed, gesture: false)
        #expect(!repaired)
        var reader = NativeScrollFollower(sticky: false)
        let detached = reader.observe(from: collapsed, to: rebound, gesture: false)
        #expect(!detached)
        let dragged = follower.observe(from: collapsed, to: rebound, gesture: true)
        #expect(!dragged)
        #expect(!follower.sticky)
        #expect(!follower.followingSentTurn)
        follower.sent(queued: false)
        follower.beginJump()
        let afterNavigation = follower.observe(from: collapsed, to: rebound, gesture: false)
        #expect(!afterNavigation)
        #expect(!follower.followingSentTurn)
    }

    @Test(arguments: [false, true])
    func layoutCannotReattachAReaderButScrollingBackToTheTailCan(nativeAnchor: Bool) {
        var follower = NativeScrollFollower(sticky: false, unseen: true)
        let above = Self.probe(offset: 1120)
        let shrinking = Self.probe(content: 1000)
        let clamped = Self.probe(content: 1000, offset: 420)
        let resized = Self.probe(content: 1020, offset: 420)
        let nearTail = Self.probe(content: 1020, offset: 430)
        // Replacement shrinks past the reader, then clamps the offset in a separate reading.
        let shrinkRepair = follower.observe(from: above, to: shrinking, gesture: false, nativeAnchor: nativeAnchor)
        let clampRepair = follower.observe(from: shrinking, to: clamped, gesture: false, nativeAnchor: nativeAnchor)
        #expect(!shrinkRepair && !clampRepair)
        #expect(!follower.sticky && follower.unseen)
        // Even a live gesture does not turn a layout adjustment into reader intent.
        let layoutRepair = follower.observe(from: clamped, to: resized, gesture: true, nativeAnchor: nativeAnchor)
        #expect(!layoutRepair && !follower.sticky && follower.unseen)
        // A reader returning inside the band with the layout unchanged re-attaches.
        let readerRepair = follower.observe(from: resized, to: nearTail, gesture: true, nativeAnchor: nativeAnchor)
        #expect(!readerRepair)
        #expect(follower.sticky && !follower.unseen)
    }

    @Test(arguments: [1800.0, 2200.0])
    func aReadersReturnToTheTailCanRemeasureLazyRows(content: Double) {
        var follower = NativeScrollFollower(sticky: false, unseen: true)
        let above = Self.probe(offset: 1120)
        let tail = Self.probe(content: content, offset: content - 580)
        #expect(tail.layoutDiffers(from: above))
        let repaired = follower.observe(from: above, to: tail, gesture: true)
        #expect(!repaired)
        #expect(follower.sticky && !follower.unseen)
    }

    @Test func theTailIsZeroAndFittingContentIsNegative() {
        #expect(Self.tail.distance == 0)
        #expect(NativeScrollProbe(content: 300, offset: -60, container: 520, insetTop: 60, insetBottom: 120).distance < 0)
    }
}
