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
        Case(testDescription: "a layout change that leaves it at the tail needs no scroll",
             new: probe(content: 2002, offset: 1422), sticky: true, repins: false),
    ]

    @Test(arguments: cases)
    func layoutAndGestures(_ c: Case) {
        var follower = c.start
        let old = c.start.sticky ? Self.tail : Self.probe(offset: 1120)
        let repins = follower.observe(from: old, to: c.new, gesture: c.gesture)
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

    @Test func theTailIsZeroAndFittingContentIsNegative() {
        #expect(Self.tail.distance == 0)
        #expect(NativeScrollProbe(content: 300, offset: -60, container: 520, insetTop: 60, insetBottom: 120).distance < 0)
    }
}
