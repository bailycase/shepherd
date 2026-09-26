import CoreGraphics
import Foundation
import Testing
import ShepherdProtocol
@testable import ShepherdRemote

/// Fixed strokes, in canvas points, drawn the way iPadDesign draws its markup over acme's
/// checkout boards: A (1280 × 800) at the origin and A · phone (390 × 844) 100 points to its right.
enum MarkupStrokes {
    static let a = DesignPath("A.dc.html")!
    static let phone = DesignPath("A-phone.dc.html")!
    static let aFrame = CGRect(x: 0, y: 0, width: 1280, height: 800)
    static let phoneFrame = CGRect(x: 1380, y: 0, width: 390, height: 844)
    static let boards: [(path: DesignPath, frame: CGRect)] = [(a, aFrame), (phone, phoneFrame)]

    /// An ellipse, begun at its right and drawn a little past where it began.
    static func loop(center: CGPoint, rx: CGFloat, ry: CGFloat, overshoot: CGFloat = 0.12) -> DesignMarkupInk {
        let steps = 48
        return DesignMarkupInk(points: (0...steps).map { i in
            let t = (2 * .pi + overshoot) * CGFloat(i) / CGFloat(steps)
            return CGPoint(x: center.x + rx * cos(t), y: center.y + ry * sin(t))
        })
    }

    /// A line with a slight wobble, as a hand draws one.
    static func line(_ from: CGPoint, _ to: CGPoint, wobble: CGFloat = 2) -> DesignMarkupInk {
        let steps = 24
        return DesignMarkupInk(points: (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: from.x + (to.x - from.x) * t, y: from.y + (to.y - from.y) * t + wobble * sin(t * .pi))
        })
    }

    /// An arrowhead drawn on its own: from one barb, to the tip, to the other barb.
    static func head(at tip: CGPoint, from shaftStart: CGPoint, size: CGFloat = 22) -> DesignMarkupInk {
        let angle = atan2(tip.y - shaftStart.y, tip.x - shaftStart.x)
        let back = angle + .pi
        let left = CGPoint(x: tip.x + size * cos(back - 0.5), y: tip.y + size * sin(back - 0.5))
        let right = CGPoint(x: tip.x + size * cos(back + 0.5), y: tip.y + size * sin(back + 0.5))
        let one = line(left, tip, wobble: 0).points, two = line(tip, right, wobble: 0).points
        return DesignMarkupInk(points: one + two.dropFirst())
    }

    /// A handwritten word: a joined-up zigzag of letters `height` tall.
    static func word(at origin: CGPoint, width: CGFloat, height: CGFloat = 30) -> DesignMarkupInk {
        let steps = 60
        let letters = max(2, Int(width / (height * 0.55)))
        return DesignMarkupInk(points: (0...steps).map { i in
            let t = CGFloat(i) / CGFloat(steps)
            return CGPoint(x: origin.x + width * t, y: origin.y + height / 2 - height / 2 * cos(t * CGFloat(letters) * 2 * .pi))
        })
    }

    /// Words side by side, a space apart.
    static func note(at origin: CGPoint, widths: [CGFloat], height: CGFloat = 30) -> [DesignMarkupInk] {
        var x = origin.x
        return widths.map { width in
            defer { x += width + height * 0.4 }
            return word(at: CGPoint(x: x, y: origin.y), width: width, height: height)
        }
    }

    // The markup iPadDesign draws, in the order it was drawn.
    static let circle = loop(center: CGPoint(x: 1575, y: 400), rx: 205, ry: 172)
    static let arrowOneShaft = line(CGPoint(x: 1560, y: 578), CGPoint(x: 1500, y: 872), wobble: 6)
    static let arrowOneHead = head(at: CGPoint(x: 1500, y: 872), from: CGPoint(x: 1560, y: 578))
    static let noteOne = note(at: CGPoint(x: 1380, y: 885), widths: [96, 64, 36, 90])
    static let underline = line(CGPoint(x: 38, y: 272), CGPoint(x: 1236, y: 268), wobble: 3)
    static let arrowTwoShaft = line(CGPoint(x: 700, y: 872), CGPoint(x: 720, y: 290), wobble: 5)
    static let arrowTwoHead = head(at: CGPoint(x: 720, y: 290), from: CGPoint(x: 700, y: 872))
    static let noteTwo = note(at: CGPoint(x: 560, y: 880), widths: [84, 62, 70])

    static var all: [DesignMarkupInk] {
        [circle, arrowOneShaft, arrowOneHead] + noteOne + [underline, arrowTwoShaft, arrowTwoHead] + noteTwo
    }
}

@Suite("Reading Pencil markup")
struct DesignMarkupReadingTests {
    typealias S = MarkupStrokes

    // MARK: One stroke

    @Test func aLoopAroundSomethingIsALoop() {
        #expect(DesignMarkupReading.shape(S.circle) == .loop)
        #expect(DesignMarkupReading.shape(S.loop(center: .zero, rx: 60, ry: 20, overshoot: -0.3)) == .loop)
    }

    @Test func aStraightStrokeIsALineFromWhereItBeganToWhereItEnded() {
        guard case .line(let start, let end) = DesignMarkupReading.shape(S.underline) else {
            Issue.record("not a line")
            return
        }
        #expect(abs(start.x - 38) < 1 && abs(end.x - 1236) < 1)
    }

    @Test func aVIsAnArrowheadWithItsTipAtTheCorner() {
        guard case .hook(let apex) = DesignMarkupReading.shape(S.arrowTwoHead) else {
            Issue.record("not a hook")
            return
        }
        #expect(hypot(apex.x - 720, apex.y - 290) < 4)
    }

    @Test func anArrowDrawnInOneStrokeHasItsHeadWhereTheShaftTurnsBack() {
        let tip = CGPoint(x: 400, y: 100)
        let shaft = S.line(CGPoint(x: 100, y: 400), tip, wobble: 0).points
        let barb = S.line(tip, CGPoint(x: 370, y: 105), wobble: 0).points
        guard case .arrow(let tail, let head) = DesignMarkupReading.shape(DesignMarkupInk(points: shaft + barb.dropFirst())) else {
            Issue.record("not an arrow")
            return
        }
        #expect(hypot(head.x - tip.x, head.y - tip.y) < 8 && hypot(tail.x - 100, tail.y - 400) < 1)
    }

    @Test func handwritingHasNoShape() {
        for word in S.noteOne + S.noteTwo {
            #expect(DesignMarkupReading.shape(word) == .scribble)
        }
    }

    @Test func aDotOrAStrokeOfOnePointHasNoShape() {
        #expect(DesignMarkupReading.shape(DesignMarkupInk(points: [CGPoint(x: 4, y: 4)])) == .scribble)
        #expect(DesignMarkupReading.shape(DesignMarkupInk(points: [CGPoint(x: 4, y: 4), CGPoint(x: 4, y: 4)])) == .scribble)
    }

    // MARK: The markup

    @Test func iPadDesignsMarkupReadsAsFourMarksAndTwoNotes() {
        let reading = DesignMarkupReading.read(S.all)
        #expect(reading.marks.map(\.kind) == [.circle, .arrow, .underline, .arrow])
        #expect(reading.marks[1].strokes == [1, 2])
        #expect(reading.marks[3].strokes == [8, 9])
        let one = Array(3..<7), two = Array(10..<13)
        #expect(reading.writing == [one, two])
        // Each arrow points where its head is.
        #expect(hypot(reading.marks[1].head!.x - 1500, reading.marks[1].head!.y - 872) < 1)
        #expect(hypot(reading.marks[3].head!.x - 720, reading.marks[3].head!.y - 290) < 1)
    }

    @Test func aSmallLoopOrBarAmongWritingIsALetter() {
        let words = S.note(at: CGPoint(x: 100, y: 100), widths: [80, 80])
        let o = S.loop(center: CGPoint(x: 290, y: 115), rx: 12, ry: 14)
        let bar = S.line(CGPoint(x: 305, y: 104), CGPoint(x: 330, y: 104), wobble: 0)
        let reading = DesignMarkupReading.read(words + [o, bar])
        #expect(reading.marks.isEmpty)
        #expect(reading.writing == [[0, 1, 2, 3]])
    }

    @Test func aLineThatDoesntRunLevelIsAMarkAndAHeadWithNoShaftIsToo() {
        let slash = S.line(CGPoint(x: 0, y: 0), CGPoint(x: 200, y: 300))
        let lone = S.head(at: CGPoint(x: 900, y: 900), from: CGPoint(x: 600, y: 600), size: 40)
        let reading = DesignMarkupReading.read([slash, lone])
        #expect(reading.marks.map(\.kind) == [.mark, .mark])
    }

    // MARK: Notes

    static let noteOne = DesignMarkupReading.Note(text: "thicker bars on phone", bounds: CGRect(x: 1380, y: 885, width: 330, height: 30))
    static let noteTwo = DesignMarkupReading.Note(text: "counts here too?", bounds: CGRect(x: 560, y: 880, width: 240, height: 30))

    @Test func anArrowBetweenANoteAndAMarkTiesThemAndDrawsNothingOfItsOwn() {
        let reading = DesignMarkupReading.read(S.all)
        let placed = DesignMarkupReading.attach([Self.noteOne, Self.noteTwo], to: reading.marks)
        #expect(placed.map(\.mark.kind) == [.circle, .underline])
        #expect(placed.map(\.note) == ["thicker bars on phone", "counts here too?"])
    }

    @Test func anArrowFromANoteToNothingMarkedIsTheMarkAndPointsAwayFromIt() {
        let shaft = S.line(CGPoint(x: 700, y: 872), CGPoint(x: 720, y: 290))
        let head = S.head(at: CGPoint(x: 700, y: 872), from: CGPoint(x: 720, y: 290))
        let reading = DesignMarkupReading.read([shaft, head])
        let placed = DesignMarkupReading.attach([Self.noteTwo], to: reading.marks)
        #expect(placed.count == 1 && placed[0].mark.kind == .arrow && placed[0].note == "counts here too?")
        // Drawn toward the note, it still points at what it marks, away from the words.
        #expect(hypot(placed[0].mark.head!.x - 720, placed[0].mark.head!.y - 290) < 1)
    }

    @Test func aNoteWithNoArrowGoesWithTheNearestMarkThatHasNone() {
        let near = DesignMarkupReading.Mark(kind: .circle, strokes: [0], bounds: CGRect(x: 1380, y: 300, width: 390, height: 540))
        let far = DesignMarkupReading.Mark(kind: .underline, strokes: [1], bounds: CGRect(x: 0, y: 268, width: 1240, height: 4))
        let placed = DesignMarkupReading.attach([Self.noteOne, Self.noteTwo], to: [near, far])
        #expect(placed.map(\.note) == ["thicker bars on phone", "counts here too?"])
        // With every mark noted, a third note joins the nearest.
        let third = DesignMarkupReading.Note(text: "and here", bounds: CGRect(x: 1400, y: 940, width: 80, height: 30))
        #expect(DesignMarkupReading.attach([Self.noteOne, Self.noteTwo, third], to: [near, far])[0].note == "thicker bars on phone; and here")
    }

    @Test func aNoteWithNoMarkIsAMarkWhereItIsWritten() {
        let placed = DesignMarkupReading.attach([Self.noteTwo], to: [])
        #expect(placed.count == 1 && placed[0].mark.kind == .mark && placed[0].mark.bounds == Self.noteTwo.bounds)
    }

    // MARK: Boards and elements across zoom and pan

    /// The canvas as the screen showed it when the ink was drawn: stored in canvas points, the
    /// ink maps to the same board points whatever the zoom and pan were.
    static let viewports = [
        DesignMarkupViewport(offset: CGPoint(x: 28, y: 46), zoom: 0.4),
        DesignMarkupViewport(offset: CGPoint(x: -512, y: 90), zoom: 1),
        DesignMarkupViewport(offset: CGPoint(x: 300.5, y: -1200.25), zoom: 2.75),
    ]

    @Test(arguments: viewports)
    func inkMapsToTheSameBoardPointsWhereverTheCanvasLooked(_ viewport: DesignMarkupViewport) throws {
        // What the Pencil touched on screen, and back to the canvas.
        let screen = S.circle.points.map { $0.applying(viewport.toScreen) }
        let ink = DesignMarkupInk(points: screen.map(viewport.canvas))
        for (a, b) in zip(ink.points, S.circle.points) {
            #expect(abs(a.x - b.x) < 0.001 && abs(a.y - b.y) < 0.001)
        }
        let mark = try #require(DesignMarkupReading.read([ink]).marks.first)
        #expect(DesignMarkupReading.board(for: mark.bounds, in: S.boards) == S.phone)
        let probe = try #require(DesignMarkupReading.probes(for: mark, frame: S.phoneFrame).first)
        #expect(abs(probe.x - 195) < 0.5 && abs(probe.y - 400) < 0.5)
        let chosen = DesignMarkupReading.element(for: mark, frame: S.phoneFrame, among: Self.phoneChain)
        #expect(chosen?.tid == 31)
    }

    /// Under the phone's steps: a bar's label, its row, the Steps card, the page's content and
    /// the board's root, deepest last, in the phone board's points.
    static let phoneChain = [
        DesignMarkupReading.Candidate(tid: 0, rect: CGRect(x: 0, y: 0, width: 390, height: 844), depth: 0),
        DesignMarkupReading.Candidate(tid: 8, rect: CGRect(x: 0, y: 54, width: 390, height: 790), depth: 1),
        DesignMarkupReading.Candidate(tid: 31, rect: CGRect(x: 18, y: 250, width: 354, height: 300), depth: 2),
        DesignMarkupReading.Candidate(tid: 40, rect: CGRect(x: 34, y: 390, width: 322, height: 36), depth: 3),
        DesignMarkupReading.Candidate(tid: 41, rect: CGRect(x: 34, y: 390, width: 110, height: 18), depth: 4),
    ]

    /// Under A's KPI row: a card's number, the card, the row of four cards, the content column,
    /// the board's root.
    static let kpiChain = [
        DesignMarkupReading.Candidate(tid: 0, rect: CGRect(x: 0, y: 0, width: 1280, height: 800), depth: 0),
        DesignMarkupReading.Candidate(tid: 12, rect: CGRect(x: 0, y: 60, width: 1280, height: 740), depth: 1),
        DesignMarkupReading.Candidate(tid: 18, rect: CGRect(x: 32, y: 166, width: 1216, height: 104), depth: 2),
        DesignMarkupReading.Candidate(tid: 19, rect: CGRect(x: 32, y: 166, width: 292, height: 104), depth: 3),
        DesignMarkupReading.Candidate(tid: 21, rect: CGRect(x: 52, y: 206, width: 90, height: 34), depth: 4),
    ]

    @Test(arguments: viewports)
    func anUnderlineIsOnTheRowWhoseBottomItRunsAlong(_ viewport: DesignMarkupViewport) throws {
        let ink = DesignMarkupInk(points: S.underline.points.map { viewport.canvas($0.applying(viewport.toScreen)) })
        let mark = try #require(DesignMarkupReading.read([ink]).marks.first)
        #expect(mark.kind == .underline)
        #expect(DesignMarkupReading.board(for: mark.bounds, in: S.boards) == S.a)
        let probes = DesignMarkupReading.probes(for: mark, frame: S.aFrame)
        #expect(probes.count == 3 && probes.allSatisfy { $0.y < 270 && $0.y > 250 })
        #expect(DesignMarkupReading.element(for: mark, frame: S.aFrame, among: Self.kpiChain)?.tid == 18)
    }

    @Test func anArrowIsOnTheDeepestElementUnderItsHead() throws {
        let mark = try #require(DesignMarkupReading.read([S.arrowTwoShaft, S.arrowTwoHead]).marks.first)
        #expect(mark.kind == .arrow)
        // Its head is 20 points inside the row, over the first card's number.
        let chain = Self.kpiChain.map { candidate in
            var moved = candidate
            if candidate.tid == 21 { moved.rect = CGRect(x: 700, y: 280, width: 60, height: 30) }
            return moved
        }
        #expect(DesignMarkupReading.element(for: mark, frame: S.aFrame, among: chain)?.tid == 21)
    }

    @Test func aMarkBesideTheBoardsIsOnTheNearest() {
        let beside = CGRect(x: 1300, y: 900, width: 40, height: 40)
        #expect(DesignMarkupReading.board(for: beside, in: S.boards) == S.phone)
        #expect(DesignMarkupReading.board(for: CGRect(x: -300, y: 100, width: 20, height: 20), in: S.boards) == S.a)
        #expect(DesignMarkupReading.board(for: beside, in: []) == nil)
    }

    @Test func aBoardInAColumnMapsFromWhereTheColumnPutsIt() {
        // Split View stacks the boards: the phone below A, its frame moved but its size its own.
        let stacked = CGRect(x: 0, y: 920, width: 390, height: 844)
        let point = DesignMarkupReading.boardPoint(CGPoint(x: 195, y: 1320), frame: stacked)
        #expect(point == CGPoint(x: 195, y: 400))
    }

    @Test func nothingUnderAMarkChoosesNothing() {
        let mark = DesignMarkupReading.Mark(kind: .circle, strokes: [0], bounds: CGRect(x: 5000, y: 5000, width: 10, height: 10))
        #expect(DesignMarkupReading.element(for: mark, frame: S.aFrame, among: []) == nil)
        #expect(DesignMarkupReading.element(for: mark, frame: S.aFrame, among: Self.kpiChain) == nil)
    }

    // MARK: The chat

    @Test func aTurnsProposalsAreItsLastAnsweredMarkupProposeCall() {
        let block = DesignMarkupProposals(proposals: [
            DesignCommentDraft(board: S.phone, tid: 31, path: [1, 1, 2], target: "Steps list", text: "Thicker bars on phone.", proposal: "c#0"),
        ]).block
        func tool(_ id: String, _ output: String, error: Bool = false) -> NativeThreadMessage {
            NativeThreadMessage(entryID: id, role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: output)],
                                toolName: "markup_propose", toolCallID: id, isError: error)
        }
        let turn = NativeTurn(id: "t", isUser: false, messages: [tool("a", "Proposed 1 comment\n" + block), tool("b", "refused", error: true)])
        #expect(NativeMarkupProposals(turn)?.ids == ["c#0"])
        #expect(NativeMarkupProposals(NativeTurn(id: "u", isUser: false, messages: [tool("b", "refused")])) == nil)
        let other = NativeThreadMessage(entryID: "x", role: "toolResult", blocks: [NativeThreadBlock(kind: .text, text: block)], toolName: "bash")
        #expect(NativeMarkupProposals(NativeTurn(id: "v", isUser: false, messages: [other])) == nil)
    }

    @Test func markupCountsReadAsTheLineSays() {
        #expect(NativeMarkupCounts(strokes: 2, notes: 2).text == "2 strokes · 2 notes")
    }
}
