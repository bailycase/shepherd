import CoreText
import Foundation
import PencilKit
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI
import SwiftUI
import UIKit

// Pencil markup on iPad (iPadDesign): ink over acme's checkout boards (a loop around the phone's
// steps with an arrow to "thicker bars on phone", a line under A's KPI row with an arrow from
// "counts here too?"), and the design agent's answer in the chat. The simulator has no Pencil, so
// the fixture puts the ink on the canvas as PencilKit strokes; the handwriting is a script
// face's letters traced as strokes. `design-pad-markup` then reads it as Done does (Vision reads
// the writing on the simulator, the boards say what is under each mark) and prints the record
// without sending it: the fixture host takes no writes. Run them on an iPad with `-r landscape`.
extension FixtureCatalog {
    static var designPadMarkup: [FixtureScreen] {
        let design = DesignPadFixtures.ref
        return [
            // The ink on the canvas and the palette, and Done's reading printed as a check.
            FixtureScreen(name: "design-pad-markup", hosts: DesignPadMarkupFixtures.hostsBeforeMarkup(),
                          routes: [.padDesign(.list), .padDesign(.design(design))],
                          prepare: { app in await DesignPadMarkupFixtures.draw(app, read: true) }),
            // The design agent's answer: "Read your markup · 2 strokes · 2 notes", its words, and
            // the two comments it proposes, with Apply both and Keep as comments.
            FixtureScreen(name: "design-pad-markup-reply", hosts: DesignPadMarkupFixtures.hosts(),
                          routes: [.padDesign(.list), .padDesign(.design(design))],
                          prepare: { app in await DesignPadMarkupFixtures.draw(app, read: false) }),
        ]
    }
}

enum DesignPadMarkupFixtures {
    /// The fixture hosts before the markup: DZCanvas's one comment, none of the markup's yet.
    static func hostsBeforeMarkup() -> [FixtureHostData] {
        var hosts = DesignPadFixtures.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }),
              var designs = hosts[index].designs, let item = designs.designs.firstIndex(where: { $0.design.id == DesignPadFixtures.designID })
        else { return hosts }
        designs.designs[item].comments.comments.removeAll { $0.number != 1 }
        hosts[index].designs = designs
        return hosts
    }

    /// The fixture hosts with the design agent's chat ending in its answer to the markup, whose
    /// proposals the host kept as comments 2 and 3 (iPadDesign: "Comments 3"), still to apply.
    static func hosts() -> [FixtureHostData] {
        var hosts = DesignPadFixtures.hosts()
        guard let index = hosts.firstIndex(where: { $0.id == FixtureData.studio }),
              var designs = hosts[index].designs, let item = designs.designs.firstIndex(where: { $0.design.id == DesignPadFixtures.designID })
        else { return hosts }
        var comments = designs.designs[item].comments
        for (offset, number) in [2, 3].enumerated() {
            guard let at = comments.comments.firstIndex(where: { $0.number == number }) else { continue }
            comments.comments[at].proposal = "call-m1#\(offset)"
            comments.comments[at].rect = nil
        }
        designs.designs[item].comments = comments
        hosts[index].designs = designs
        hosts[index].threads[DesignPadFixtures.agentID] = chat()
        return hosts
    }

    /// The comments the design agent proposed from the markup, as its `markup_propose` result
    /// carries them.
    static var proposed: [DesignCommentDraft] {
        let steps = DesignPadFixtures.element("Steps list", in: DesignPadBoards.phone)
        let kpis = DesignPadFixtures.element("KPI row", in: DesignPadBoards.funnel)
        return [
            DesignCommentDraft(board: DesignPath("A-phone.dc.html")!, tid: steps.tid, path: steps.path, target: "Steps list",
                               text: "Thicker bars on phone.", proposal: "call-m1#0"),
            DesignCommentDraft(board: DesignPath("A.dc.html")!, tid: kpis.tid, path: kpis.path, target: "KPI row",
                               text: "Show counts next to the percentages here too.", proposal: "call-m1#1"),
        ]
    }

    /// DZCanvas's chat, then the markup and the agent's answer to it.
    static func chat() -> NativeThreadSnapshot {
        let now = Date().timeIntervalSince1970 * 1000 - FixtureData.start
        var thread = DesignPadFixtures.chat()
        let proposals = DesignMarkupProposals(proposals: proposed)
        var markup = NativeThreadMessage(entryID: "m1", role: "user",
                                         blocks: [NativeThreadBlock(kind: .text, text: "Pencil markup · 2 strokes · 2 notes")],
                                         timestamp: FixtureData.start + now - 60_000)
        markup.origin = .designMarkup(strokes: 2, notes: 2)
        thread.messages += [
            markup,
            FixtureData.tool("m2", "markup_propose", args: #"{"proposals":[{"element":"A-phone.dc.html#0:0","text":"Thicker bars on phone."}]}"#,
                             output: "Proposed 2 comments from the viewer's markup.\n" + proposals.block, at: now - 40_000),
            FixtureData.assistant("m3", "I turned the Pencil marks into two comments. The circle is on the steps list of the phone board; "
                                  + "the underline is the KPI row on A.", at: now - 30_000),
        ]
        return thread
    }

    /// Puts iPadDesign's ink on the canvas, then (`read`) reads it as Done does and prints the
    /// record, or (not `read`) sends it as far as the canvas can without a host that takes it:
    /// the ink stays as sent ink, with the palette, while the chat shows the answer and the
    /// proposals' pins, kept with no place drawn, find their elements on the boards.
    @MainActor static func draw(_ app: MobileApp, read: Bool) async {
        let canvas = await DesignPadFixtures.settle(app)
        let drawing = markupDrawing()
        canvas.markup.setDraft(drawing)
        guard read else {
            canvas.markup.finishReading(sent: true)
            await FixtureWindows.wait(seconds: 15) { !canvas.comments.isEmpty }
            // The proposals are comments 2 and 3 already, still to apply, and the pins of those on
            // boards on screen, kept with no place drawn, find their elements.
            let placed = { (number: Int) in canvas.pins.first { $0.number == number }.map { $0.rect != .zero } ?? false }
            let shown = { canvas.openComments.filter { [2, 3].contains($0.number) && canvas.visibleBoards.contains($0.board) }.map(\.number) }
            await FixtureWindows.wait(seconds: 30) { canvas.isDrawn && shown().allSatisfy(placed) }
            let card = canvas.markupCard(NativeMarkupProposals(proposals: proposed))
            let through = touchesReachTheCanvas()
            let ok = card.cards.map(\.number) == [2, 3] && card.state == .open && canvas.openComments.count == 3
                && shown().allSatisfy(placed) && canvas.markup.showsPalette && through
            print("FIXTURE CHECK \(ok ? "ok" : "FAILED:") design-pad-markup-reply: cards \(card.cards.map(\.number)) \(card.state), "
                  + "\(canvas.openComments.count) comments, pins on screen \(shown()) placed \(shown().map(placed)), "
                  + "palette \(canvas.markup.showsPalette), a touch the ink doesn't take reaches the canvas \(through)")
            return
        }
        let boards = canvas.boards.compactMap { board in DesignPath(board.id).map { (path: $0, frame: board.frame) } }
        let source = canvas.source
        let record = await PadDesignMarkupReader.read(drawing, boards: boards, host: canvas.host, source: { try await source.source($0) })
        await FixtureWindows.wait(seconds: 30) { canvas.isDrawn }
        guard let record else {
            print("FIXTURE CHECK FAILED: design-pad-markup read no marks")
            return
        }
        let marks = record.strokes.map { stroke in
            "\(stroke.kind.rawValue) on \(stroke.board)#\(stroke.element.map { "\($0.tid):\($0.path.map(String.init).joined(separator: "/"))" } ?? "-")"
                + " \"\(stroke.note ?? "")\""
        }
        let steps = DesignPadFixtures.element("Steps list", in: DesignPadBoards.phone)
        let kpis = DesignPadFixtures.element("KPI row", in: DesignPadBoards.funnel)
        let circle = record.strokes.first { $0.kind == .circle }
        let underline = record.strokes.first { $0.kind == .underline }
        let ok = record.isValid && record.strokes.count == 2 && record.noteCount == 2
            && circle?.board == "A-phone.dc.html" && circle?.element?.tid == steps.tid
            && underline?.board == "A.dc.html" && underline?.element?.tid == kpis.tid
        print("FIXTURE CHECK \(ok ? "ok" : "FAILED:") design-pad-markup read \(DesignMarkup.countsText(strokes: record.strokes.count, notes: record.noteCount)): "
              + marks.joined(separator: "; "))
    }

    /// A touch the markup layer leaves (a finger's, or one UIKit names no kind for while no new
    /// ink is on the canvas) goes on through SwiftUI to the canvas's touch view under it, which
    /// pans and pinches: hit-tested in the window at the ink's middle.
    @MainActor static func touchesReachTheCanvas() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        func ink(in view: UIView) -> PadMarkupInkView? {
            if let ink = view as? PadMarkupInkView { return ink }
            for subview in view.subviews { if let found = ink(in: subview) { return found } }
            return nil
        }
        guard let window = windows.first(where: { ink(in: $0) != nil }), let layer = ink(in: window) else { return false }
        let point = layer.convert(CGPoint(x: layer.bounds.midX, y: layer.bounds.midY), to: window)
        guard let hit = window.hitTest(point, with: nil) else { return false }
        return !hit.isDescendant(of: layer) && String(describing: type(of: hit)).contains("InputView")
    }

    // MARK: The ink

    /// iPadDesign's marks in canvas points over the fixture canvas (A at the origin, A · phone at
    /// x 1380): the loop around the phone's steps, its arrow down to the first note, the line
    /// under A's KPI row, and the arrow up to it from the second note.
    static func markupDrawing() -> PKDrawing {
        var strokes: [PKStroke] = []
        let width: CGFloat = 7
        strokes.append(stroke(loop(center: CGPoint(x: 1575, y: 400), rx: 205, ry: 185), width: width))
        strokes.append(stroke(line(CGPoint(x: 1590, y: 590), CGPoint(x: 1520, y: 880), bend: 14), width: width))
        strokes.append(stroke(head(at: CGPoint(x: 1520, y: 880), from: CGPoint(x: 1590, y: 590)), width: width))
        strokes += writing("thicker bars on phone", at: CGPoint(x: 1330, y: 900), size: 70, width: width * 0.7)
        strokes.append(stroke(line(CGPoint(x: 40, y: 292), CGPoint(x: 1240, y: 288), bend: 4), width: width))
        strokes.append(stroke(line(CGPoint(x: 820, y: 880), CGPoint(x: 840, y: 304), bend: 10), width: width))
        strokes.append(stroke(head(at: CGPoint(x: 840, y: 304), from: CGPoint(x: 820, y: 880)), width: width))
        strokes += writing("counts here too?", at: CGPoint(x: 560, y: 900), size: 70, width: width * 0.7)
        return PKDrawing(strokes: strokes)
    }

    /// Lantern as the window draws it, stored the way PencilKit keeps ink (light colors).
    @MainActor static var inkColor: UIColor {
        let traits = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first?.traitCollection ?? .current
        let lantern = UIColor(Color.nw.lantern).resolvedColor(with: traits)
        return traits.userInterfaceStyle == .dark ? PKInkingTool.convertColor(lantern, from: .dark, to: .light) : lantern
    }

    static func stroke(_ points: [CGPoint], width: CGFloat) -> PKStroke {
        let color = MainActor.assumeIsolated { inkColor }
        let controls = points.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.01, size: CGSize(width: width, height: width), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: controls, creationDate: Date()))
    }

    static func loop(center: CGPoint, rx: CGFloat, ry: CGFloat) -> [CGPoint] {
        (0...64).map { i in
            let t = -0.5 + (2 * .pi + 0.18) * CGFloat(i) / 64
            let wobble = 1 + 0.025 * sin(t * 3)
            return CGPoint(x: center.x + rx * wobble * cos(t), y: center.y + ry * wobble * sin(t))
        }
    }

    static func line(_ from: CGPoint, _ to: CGPoint, bend: CGFloat) -> [CGPoint] {
        let length = hypot(to.x - from.x, to.y - from.y)
        let normal = CGPoint(x: -(to.y - from.y) / length, y: (to.x - from.x) / length)
        return (0...32).map { i in
            let t = CGFloat(i) / 32
            let offset = bend * sin(t * .pi)
            return CGPoint(x: from.x + (to.x - from.x) * t + normal.x * offset, y: from.y + (to.y - from.y) * t + normal.y * offset)
        }
    }

    static func head(at tip: CGPoint, from start: CGPoint) -> [CGPoint] {
        let angle = atan2(tip.y - start.y, tip.x - start.x) + .pi
        let size: CGFloat = 46
        let left = CGPoint(x: tip.x + size * cos(angle - 0.5), y: tip.y + size * sin(angle - 0.5))
        let right = CGPoint(x: tip.x + size * cos(angle + 0.5), y: tip.y + size * sin(angle + 0.5))
        return line(left, tip, bend: 0) + line(tip, right, bend: 0).dropFirst()
    }

    /// Words in a handwriting face, each letter's outline traced as strokes.
    static func writing(_ text: String, at origin: CGPoint, size: CGFloat, width: CGFloat) -> [PKStroke] {
        let font = CTFontCreateWithName("Noteworthy-Light" as CFString, size, nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: font]))
        var strokes: [PKStroke] = []
        for run in (CTLineGetGlyphRuns(line) as? [CTRun]) ?? [] {
            let count = CTRunGetGlyphCount(run)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: count), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: count), &positions)
            for (glyph, position) in zip(glyphs, positions) {
                guard let path = CTFontCreatePathForGlyph(font, glyph, nil) else { continue }
                // Glyphs rise from a baseline; the canvas grows downward.
                var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: origin.x + position.x, ty: origin.y + size * 0.8)
                guard let placed = path.copy(using: &transform) else { continue }
                for contour in contours(placed) where contour.count > 1 {
                    strokes.append(stroke(contour, width: width))
                }
            }
        }
        return strokes
    }

    /// A path's subpaths as points, curves flattened.
    static func contours(_ path: CGPath) -> [[CGPoint]] {
        var result: [[CGPoint]] = []
        var current: [CGPoint] = []
        path.applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { result.append(current) }
                current = [e.points[0]]
            case .addLineToPoint:
                current.append(e.points[0])
            case .addQuadCurveToPoint:
                let start = current.last ?? e.points[1]
                for step in 1...6 {
                    let t = CGFloat(step) / 6
                    let a = (1 - t) * (1 - t), b = 2 * (1 - t) * t, c = t * t
                    current.append(CGPoint(x: a * start.x + b * e.points[0].x + c * e.points[1].x,
                                           y: a * start.y + b * e.points[0].y + c * e.points[1].y))
                }
            case .addCurveToPoint:
                let start = current.last ?? e.points[2]
                for step in 1...8 {
                    let t = CGFloat(step) / 8
                    let a = pow(1 - t, 3), b = 3 * pow(1 - t, 2) * t, c = 3 * (1 - t) * t * t, d = t * t * t
                    current.append(CGPoint(x: a * start.x + b * e.points[0].x + c * e.points[1].x + d * e.points[2].x,
                                           y: a * start.y + b * e.points[0].y + c * e.points[1].y + d * e.points[2].y))
                }
            case .closeSubpath:
                if let first = current.first { current.append(first) }
            @unknown default:
                break
            }
        }
        if current.count > 1 { result.append(current) }
        return result
    }
}
