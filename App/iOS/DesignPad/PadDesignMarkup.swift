import SwiftUI
import UIKit
import PencilKit
import Vision
import ShepherdCore
import ShepherdProtocol
import ShepherdRemote
import ShepherdUI

// Pencil markup on the iPad canvas (iPadDesign): an Apple Pencil draws over the boards while a
// finger still pans and pinches; handwriting beside the marks is read as notes on this iPad
// (Vision, no network); Done reads each mark (its kind, the board and element under it, the note
// that goes with it) and sends the design agent one record of them through `designs.v1`
// (`sendMarkup`), which the host checks and hands on fenced as data, as a turn of its own. The
// agent's comments proposed from it come back in the chat (`NWMarkupProposals`), where Apply
// sends each to it as a comment and Keep as comments leaves them on the canvas.
// docs/designs.md › Pencil markup.

/// The markup on one design's canvas: the ink drawn since the last Done and the ink already sent,
/// both in canvas points so they stay on their boards as the canvas pans and zooms, and the
/// palette's tool and ink.
@MainActor
@Observable
final class PadDesignMarkup {
    /// Ink since the last Done.
    private(set) var draft = PKDrawing()
    /// Ink the design agent has been sent: it stays until its proposals are applied or kept.
    private(set) var sent = PKDrawing()
    var tool: NWMarkupPalette.Tool = .pen
    var ink: NWMarkupPalette.Ink = .lantern
    /// Done is reading the markup and sending it.
    private(set) var reading = false
    /// Moves when the ink changes other than by the viewer's hand (Done, a fixture), so the ink
    /// view takes it again.
    private(set) var revision = 0

    var hasInk: Bool { !draft.strokes.isEmpty }

    /// The viewer drew, erased or undid: the ink view's drawing, back in canvas points.
    func viewerDrew(_ drawing: PKDrawing) {
        draft = drawing
    }

    /// Replaces the ink since the last Done (fixtures draw with it).
    func setDraft(_ drawing: PKDrawing) {
        draft = drawing
        revision &+= 1
    }

    func beginReading() { reading = true }

    /// Done went through: the ink joins what was sent.
    func finishReading(sent: Bool) {
        reading = false
        guard sent else { return }
        self.sent.append(draft)
        draft = PKDrawing()
        revision &+= 1
    }

    /// The proposals were applied or kept: the ink has served.
    func clearSent() {
        guard !sent.strokes.isEmpty else { return }
        sent = PKDrawing()
        revision &+= 1
    }
}

// MARK: - The layer

/// The Pencil markup layer over the canvas: the ink, and the palette while there is ink. Only an
/// Apple Pencil draws; a finger's touches go on to the canvas under it, which pans and zooms, and
/// the ink goes with the boards. With the palette's Comment, a Pencil tap comments as a finger's
/// does with the canvas's Comment tool.
struct PadDesignMarkupLayer: View {
    @Bindable var canvas: PadDesignCanvas
    /// The host takes markup (`design.markup.v1`).
    let available: Bool

    var body: some View {
        let markup = canvas.markup
        let enabled = available && canvas.presented == nil
        ZStack(alignment: .bottom) {
            PadMarkupInk(markup: markup, draftRevision: markup.revision, viewport: canvas.viewport, tool: markup.tool,
                         ink: markup.ink, enabled: enabled,
                         pan: { canvas.viewport.pan(by: $0) },
                         zoom: { factor, anchor in canvas.viewport.zoom(by: factor, about: anchor) },
                         zooming: { canvas.setZooming($0) },
                         comment: { point in commentWithPencil(at: point) })
            if enabled, markup.hasInk || markup.reading {
                NWMarkupPalette(tool: Bindable(markup).tool, ink: Bindable(markup).ink, reading: markup.reading) {
                    canvas.finishMarkup()
                }
                .padding(.bottom, NWDesignMetrics.markupBottom)
                .nwTransition(.overlay)
            }
        }
        .nwAnimation(.content, value: markup.hasInk || markup.reading)
        .onChange(of: markup.tool) { _, tool in
            // The palette's Comment is the canvas's: a tap on an element opens the editor.
            if tool == .comment {
                canvas.tool = .comment
            } else if canvas.tool == .comment {
                canvas.tool = .select
            }
        }
    }

    private func commentWithPencil(at point: CGPoint) {
        let pick = canvas.boards.pick(at: point, viewport: canvas.viewport)
        guard pick.board != nil else { return }
        canvas.tool = .comment
        canvas.pick(pick)
    }
}

/// The ink over the canvas: a PencilKit canvas that draws with the Pencil alone, showing the
/// markup's canvas-point ink through the viewport, with the ink already sent under it.
private struct PadMarkupInk: UIViewRepresentable {
    let markup: PadDesignMarkup
    let draftRevision: Int
    let viewport: NWCanvasViewport
    let tool: NWMarkupPalette.Tool
    let ink: NWMarkupPalette.Ink
    let enabled: Bool
    let pan: (CGSize) -> Void
    let zoom: (CGFloat, CGPoint) -> Void
    let zooming: (Bool) -> Void
    let comment: (CGPoint) -> Void

    func makeUIView(context: Context) -> PadMarkupInkView {
        PadMarkupInkView(markup: markup)
    }

    func updateUIView(_ view: PadMarkupInkView, context: Context) {
        view.handlers = PadMarkupInkView.Handlers(pan: pan, zoom: zoom, zooming: zooming, comment: comment)
        view.enabled = enabled
        view.show(viewport: DesignMarkupViewport(offset: viewport.offset, zoom: viewport.zoom), revision: draftRevision)
        view.use(tool: tool, ink: ink)
    }
}

/// The ink's UIKit side. Hit-testing decides per touch: a Pencil's touch draws here (or, with
/// Comment, taps here), any other goes on to the canvas under it. Where UIKit doesn't say which
/// kind a touch is, the layer takes it while there is ink, and pans and pinches with a finger
/// itself, so a finger still moves the canvas.
final class PadMarkupInkView: UIView, PKCanvasViewDelegate, UIGestureRecognizerDelegate {
    struct Handlers {
        var pan: (CGSize) -> Void
        var zoom: (CGFloat, CGPoint) -> Void
        var zooming: (Bool) -> Void
        var comment: (CGPoint) -> Void
    }

    let draftView = PKCanvasView()
    let sentView = PKCanvasView()
    var handlers: Handlers?
    var enabled = true {
        didSet { if enabled != oldValue { isHidden = !enabled } }
    }
    private let markup: PadDesignMarkup
    private var toScreen = CGAffineTransform.identity
    private var shownRevision = -1
    private var applying = false
    private var tool: NWMarkupPalette.Tool = .pen
    private var ink: NWMarkupPalette.Ink = .lantern
    /// The ink view's tool is the palette's (unset until first shown, and again when the
    /// appearance changes the ink's color).
    private var configured = false
    private var lastTranslation: CGPoint = .zero
    private var lastScale: CGFloat = 1

    init(markup: PadDesignMarkup) {
        self.markup = markup
        super.init(frame: .zero)
        backgroundColor = .clear
        for view in [sentView, draftView] {
            view.backgroundColor = .clear
            view.isOpaque = false
            view.isScrollEnabled = false
            view.showsVerticalScrollIndicator = false
            view.showsHorizontalScrollIndicator = false
            view.contentInsetAdjustmentBehavior = .never
            view.drawingPolicy = .pencilOnly
            view.translatesAutoresizingMaskIntoConstraints = true
            view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            addSubview(view)
        }
        sentView.isUserInteractionEnabled = false
        draftView.delegate = self
        draftView.drawingGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]

        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        tap.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        addGestureRecognizer(tap)
        let fingers = [UITouch.TouchType.direct, .indirect, .indirectPointer].map { NSNumber(value: $0.rawValue) }
        let panner = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
        panner.allowedTouchTypes = fingers
        panner.maximumNumberOfTouches = 2
        panner.delegate = self
        addGestureRecognizer(panner)
        let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
        pinch.allowedTouchTypes = fingers
        pinch.delegate = self
        addGestureRecognizer(pinch)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: PadMarkupInkView, _: UITraitCollection) in
            view.configured = false
            view.use(tool: view.tool, ink: view.ink)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for view in [sentView, draftView] where view.frame != bounds { view.frame = bounds }
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard enabled, !isHidden, self.point(inside: point, with: event) else { return nil }
        let touches = event?.allTouches ?? []
        if touches.contains(where: { $0.type == .pencil }) { return tool == .comment ? self : draftView }
        // A finger or a pointer: the canvas's.
        if !touches.isEmpty { return nil }
        // UIKit didn't say: while markup is under way, take it; a finger then pans here.
        return markup.hasInk ? draftView : nil
    }

    /// Shows the markup through the viewport: canvas points to screen points.
    func show(viewport: DesignMarkupViewport, revision: Int) {
        let transform = viewport.toScreen
        guard transform != toScreen || revision != shownRevision else { return }
        toScreen = transform
        shownRevision = revision
        applying = true
        draftView.drawing = markup.draft.transformed(using: transform)
        sentView.drawing = markup.sent.transformed(using: transform)
        applying = false
    }

    func use(tool: NWMarkupPalette.Tool, ink: NWMarkupPalette.Ink) {
        guard !configured || tool != self.tool || ink != self.ink else { return }
        configured = true
        self.tool = tool
        self.ink = ink
        switch tool {
        case .pen:
            draftView.tool = PKInkingTool(.pen, color: inkColor(ink), width: NWDesignMetrics.markupPenWidth)
        case .marker:
            draftView.tool = PKInkingTool(.marker, color: inkColor(ink), width: NWDesignMetrics.markupMarkerWidth)
        case .eraser:
            draftView.tool = PKEraserTool(.vector)
        case .comment:
            break
        }
        draftView.drawingGestureRecognizer.isEnabled = tool != .comment
    }

    /// PencilKit keeps ink in light-appearance colors and shows it adapted in dark: the ink's
    /// token as this appearance draws it, stored the way PencilKit reads it.
    private func inkColor(_ ink: NWMarkupPalette.Ink) -> UIColor {
        let color = UIColor(ink.color).resolvedColor(with: traitCollection)
        return traitCollection.userInterfaceStyle == .dark ? PKInkingTool.convertColor(color, from: .dark, to: .light) : color
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !applying else { return }
        markup.viewerDrew(canvasView.drawing.transformed(using: toScreen.inverted()))
    }

    // MARK: Touches

    func gestureRecognizer(_ a: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith b: UIGestureRecognizer) -> Bool {
        (a is UIPanGestureRecognizer && b is UIPinchGestureRecognizer) || (a is UIPinchGestureRecognizer && b is UIPanGestureRecognizer)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
        guard recognizer.state == .ended, tool == .comment else { return }
        handlers?.comment(recognizer.location(in: self))
    }

    @objc private func panned(_ recognizer: UIPanGestureRecognizer) {
        let translation = recognizer.translation(in: self)
        switch recognizer.state {
        case .began, .changed:
            handlers?.pan(CGSize(width: translation.x - lastTranslation.x, height: translation.y - lastTranslation.y))
            lastTranslation = translation
        default:
            lastTranslation = .zero
        }
    }

    @objc private func pinched(_ recognizer: UIPinchGestureRecognizer) {
        switch recognizer.state {
        case .began:
            lastScale = 1
            handlers?.zooming(true)
            fallthrough
        case .changed:
            handlers?.zoom(recognizer.scale / lastScale, recognizer.location(in: self))
            lastScale = recognizer.scale
        case .ended, .cancelled, .failed:
            lastScale = 1
            handlers?.zooming(false)
        default:
            break
        }
    }
}

// MARK: - Reading the markup

/// Done's reading on this iPad: the strokes sorted into marks and writing
/// (`DesignMarkupReading`), the writing read by Vision on the device, each note given to its mark,
/// and each mark's element found by asking its board what is under it.
@MainActor
enum PadDesignMarkupReader {
    /// The markup as the record names it, or nil when no mark is on or beside a board.
    static func read(_ drawing: PKDrawing, boards: [(path: DesignPath, frame: CGRect)], host: PadDesignHost,
                     source: @escaping (DesignPath) async throws -> String) async -> DesignMarkup? {
        let strokes = drawing.strokes
        let inks = strokes.map(ink)
        let reading = DesignMarkupReading.read(inks)
        var notes: [DesignMarkupReading.Note] = []
        var marks = reading.marks
        for group in reading.writing {
            let bounds = group.map { inks[$0].bounds }.reduce(CGRect.null) { $0.union($1) }
            if let text = await recognize(group.map { strokes[$0] }) {
                notes.append(DesignMarkupReading.Note(text: text, bounds: bounds))
            } else {
                marks.append(DesignMarkupReading.Mark(kind: .mark, strokes: group, bounds: bounds))
            }
        }
        marks.sort { ($0.strokes.first ?? 0) < ($1.strokes.first ?? 0) }
        var templates: [DesignPath: DesignTemplate] = [:]
        var result: [DesignMarkupStroke] = []
        for placed in DesignMarkupReading.attach(notes, to: marks).prefix(DesignMarkup.maxStrokes) {
            guard let board = DesignMarkupReading.board(for: placed.mark.bounds, in: boards),
                  let frame = boards.first(where: { $0.path == board })?.frame else { continue }
            if templates[board] == nil, let text = try? await source(board) { templates[board] = DesignTemplate(board: text) }
            let found = await element(for: placed.mark, board: board, frame: frame, template: templates[board], host: host)
            result.append(DesignMarkupStroke(kind: placed.mark.kind, board: board.viewName, element: found?.id,
                                             label: found?.label.flatMap(DesignViewRecord.label), note: placed.note.flatMap(DesignMarkup.note)))
        }
        return result.isEmpty ? nil : DesignMarkup(strokes: result)
    }

    /// A stroke's points in canvas points, along the path PencilKit draws.
    static func ink(_ stroke: PKStroke) -> DesignMarkupInk {
        let transform = stroke.transform
        return DesignMarkupInk(points: stroke.path.interpolatedPoints(by: .distance(3)).map { $0.location.applying(transform) })
    }

    /// The element a mark is on: the board's elements under its probes and their ancestors
    /// (from the board's template), located on the live board, then chosen by the mark's kind.
    private static func element(for mark: DesignMarkupReading.Mark, board: DesignPath, frame: CGRect, template: DesignTemplate?,
                                 host: PadDesignHost) async -> PadDesignPick? {
        guard let template else { return nil }
        var tids = Set<Int>()
        for probe in DesignMarkupReading.probes(for: mark, frame: frame) {
            guard let hit = await host.hitTest(board, at: probe) else { continue }
            var tid: Int? = hit.id.tid
            while let current = tid, current < template.elements.count, tids.insert(current).inserted {
                tid = template.elements[current].parent
            }
        }
        guard !tids.isEmpty, let located = await host.measure(board, tids: Array(tids)) else { return nil }
        let candidates = located.map { tid, pick in
            DesignMarkupReading.Candidate(tid: tid, rect: pick.rect, depth: template.elements[tid].path.count - 1)
        }
        guard let chosen = DesignMarkupReading.element(for: mark, frame: frame, among: candidates) else { return nil }
        return located[chosen.tid]
    }

    /// Handwriting read on this iPad (Vision's text recognition runs on the device; nothing goes
    /// over the network): the strokes drawn black on white at a size Vision reads well.
    static func recognize(_ strokes: [PKStroke]) async -> String? {
        guard let image = writingImage(strokes) else { return nil }
        var request = RecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        guard let observations = try? await request.perform(on: image) else { return nil }
        let words = observations.compactMap { $0.topCandidates(1).first }.filter { $0.confidence >= 0.3 }.map(\.string)
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Letters about 64 pixels tall read best.
    static let writingHeight: CGFloat = 64

    static func writingImage(_ strokes: [PKStroke]) -> CGImage? {
        let black = strokes.map { PKStroke(ink: PKInk(.pen, color: .black), path: $0.path, transform: $0.transform, mask: $0.mask) }
        let drawing = PKDrawing(strokes: black)
        let bounds = drawing.bounds
        guard !bounds.isEmpty else { return nil }
        let pad = bounds.height * 0.5
        let rect = bounds.insetBy(dx: -pad, dy: -pad)
        let scale = min(max(writingHeight / max(bounds.height, 1), 0.25), 8)
        var ink = UIImage()
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: rect, scale: scale)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = ink.scale
        format.opaque = true
        let flat = UIGraphicsImageRenderer(size: ink.size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: ink.size))
            ink.draw(at: .zero)
        }
        return flat.cgImage
    }
}

// MARK: - The canvas's side

extension PadDesignCanvas {
    /// Done: reads the markup and sends it to the design agent. What couldn't go stays on the
    /// canvas, and the dialog says why.
    @discardableResult
    func finishMarkup() -> Task<Void, Never>? {
        guard !markup.reading, markup.hasInk else { return nil }
        markup.beginReading()
        let drawing = markup.draft
        let boards = boards.compactMap { board in DesignPath(board.id).map { (path: $0, frame: board.frame) } }
        let source = self.source
        let design = ref.design
        return Task {
            guard let record = await PadDesignMarkupReader.read(drawing, boards: boards, host: host,
                                                                source: { try await source.source($0) }) else {
                markup.finishReading(sent: false)
                problem = "Nothing in the markup is on a board. Draw on a board, then press Done."
                return
            }
            do {
                guard case .markupSent(let undelivered) = try await library.request(.sendMarkup(designID: design, markup: record)) else {
                    throw Self.unexpected
                }
                if let undelivered {
                    markup.finishReading(sent: false)
                    problem = "The markup didn't reach the design agent: \(undelivered)"
                } else {
                    markup.finishReading(sent: true)
                    paneTab = .chat
                }
            } catch {
                markup.finishReading(sent: false)
                problem = "Couldn't send the markup: \(Self.message(error))"
            }
        }
    }

    /// The proposals card for a reply: each proposal numbered as its pin is (kept) or will be
    /// (the next numbers, in order), named as the comment cards name boards ("A · phone › Steps
    /// list"), and whether they are kept.
    func markupCard(_ proposals: NativeMarkupProposals) -> (cards: [NWMarkupProposals.Card], state: NWMarkupProposals.State) {
        let kept = Dictionary(comments.compactMap { comment in comment.proposal.map { ($0, comment) } }, uniquingKeysWith: { a, _ in a })
        var next = (comments.map(\.number).max() ?? 0) + 1
        let cards = proposals.proposals.compactMap { draft -> NWMarkupProposals.Card? in
            guard let id = draft.proposal else { return nil }
            let number: Int
            if let comment = kept[id] {
                number = comment.number
            } else {
                number = next
                next += 1
            }
            let name = draft.target ?? draft.label
            let board = nativeBoardName(draft.board.rawValue)
            return NWMarkupProposals.Card(id: id, number: number, target: name.map { "\(board) › \($0)" } ?? board, text: draft.text)
        }
        let key = proposals.ids.joined(separator: "|")
        if applyingProposals.contains(key) { return (cards, .working) }
        if !cards.isEmpty, cards.allSatisfy({ kept[$0.id] != nil }) {
            let numbers = cards.map { String($0.number) }
            let list = numbers.count == 1 ? "comment \(numbers[0])"
                : "comments " + numbers.dropLast().joined(separator: ", ") + " and " + numbers[numbers.count - 1]
            return (cards, .settled("On the canvas as \(list)."))
        }
        return (cards, .open)
    }

    /// Apply (each proposal kept as a comment and sent to the design agent as one) or Keep as
    /// comments (kept, not sent): one change at the comments' revision, through the host's checks.
    /// The pins go where the boards draw the elements. The ink that led to them leaves the canvas.
    @discardableResult
    func applyProposals(_ proposals: NativeMarkupProposals, deliver: Bool) -> Task<Void, Never>? {
        let key = proposals.ids.joined(separator: "|")
        guard !applyingProposals.contains(key) else { return nil }
        applyingProposals.insert(key)
        let design = ref.design
        return Task {
            defer { applyingProposals.remove(key) }
            var drafts = proposals.proposals
            for board in Set(drafts.map(\.board)) {
                let tids = drafts.filter { $0.board == board }.map(\.tid)
                guard let found = await host.measure(board, tids: tids) else { continue }
                for index in drafts.indices where drafts[index].board == board {
                    guard let pick = found[drafts[index].tid], pick.id.path == drafts[index].path else { continue }
                    drafts[index].rect = DesignCommentRect(x: pick.rect.minX, y: pick.rect.minY, w: pick.rect.width, h: pick.rect.height)
                }
            }
            do {
                let result: RemoteDesignResult
                do {
                    result = try await library.request(.addProposedComments(designID: design, drafts: drafts, deliver: deliver,
                                                                            baseRevision: commentsRevision))
                } catch let error where Self.isStale(error) {
                    guard case .comments(let fresh) = try await library.request(.comments(designID: design)) else { throw Self.unexpected }
                    applyComments(fresh)
                    result = try await library.request(.addProposedComments(designID: design, drafts: drafts, deliver: deliver,
                                                                            baseRevision: fresh.revision))
                }
                guard case .proposedCommentsAdded(_, let undelivered) = result else { throw Self.unexpected }
                markup.clearSent()
                if let undelivered { problem = "The comments are kept, but they didn't reach the design agent: \(undelivered)" }
            } catch {
                problem = "Couldn't keep the comments: \(Self.message(error))"
            }
            await refreshComments()
        }
    }
}

extension EnvironmentValues {
    /// The design whose chat this is (iPadDesign): the chat draws its markup line and the design
    /// agent's proposals from it with the canvas's comments.
    @Entry var designMarkupCanvas: PadDesignCanvas? = nil
}

/// "Read your markup · 2 strokes · 2 notes": a user turn that carried Pencil markup, as a design's
/// chat draws it (iPadDesign), with the nib.
struct PadMarkupReadLine: View, Equatable {
    let counts: NativeMarkupCounts

    var body: some View {
        NWActivityLine(kind: .drew, label: "Read your markup", meta: counts.text)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The design agent's proposals under its reply (iPadDesign), with Apply and Keep as comments.
struct PadMarkupProposalsView: View {
    let canvas: PadDesignCanvas
    let proposals: NativeMarkupProposals

    static let footnote = "Handwriting in the chat box works too: Scribble turns it into text."

    var body: some View {
        let card = canvas.markupCard(proposals)
        NWMarkupProposals(cards: card.cards, state: card.state, footnote: card.state == .open ? Self.footnote : nil,
                          apply: { canvas.applyProposals(proposals, deliver: true) },
                          keep: { canvas.applyProposals(proposals, deliver: false) })
            .equatable()
    }
}
