import SwiftUI

/// The design canvas (NWDesignCanvas; DZCanvas): `bgBase` with 1px `lineStrong` dots every
/// 22pt, the boards at their canvas positions in their frames, and the canvas toolbar in the
/// bottom-leading corner. It pans (two-finger scroll, the Pan tool, space-drag) and zooms (pinch,
/// ⌘-scroll) about the pointer. With Select or Comment, a click reports what it landed on (`pick`:
/// a point on a board, a board's label, or the empty canvas; shift extends), and the pointer's
/// moves over the boards are reported too (`point`); the selected and hovered elements are ringed
/// over their boards (`NWSelectionRing`) from the rects the boards reported.
///
/// Comments' pins (`NWCommentPin`) sit on their elements' top-trailing corners over the boards,
/// and one thing may open beside a pin, under its element (`popover`: a comment's thread, or the
/// editor for a new one), kept inside the canvas.
///
/// Notes (titles and stickies) sit on the canvas under the boards, read-only. With Select, a drag
/// that starts on a board's label, or on a board selected whole, moves the board (`move`: its
/// offset in canvas points as it goes, then once more when it ends); any other drag pans. The
/// board actions (`NWBoardActions`) float over one board, and "Ask for another direction"
/// (`NWDirectionTile`) follows the last board.
///
/// Only the boards on screen are built, each an `NWBoardFrame` compared by value, so a pan
/// moves frames without redrawing them and a change to one board redraws that board alone. The
/// slot draws a board's page (a live view or a snapshot); the canvas takes every event, so
/// nothing inside a board is interactive. Pins and the popover take their own.
public struct NWDesignCanvas<Slot: View, Popover: View>: View {
    let boards: [NWCanvasBoard]
    @Binding var viewport: NWCanvasViewport
    @Binding var tool: NWCanvasTool
    let disabledTools: Set<NWCanvasTool>
    let selection: [NWCanvasElement]
    let hover: NWCanvasElement?
    let pick: (NWCanvasPick) -> Void
    /// Where the pointer is over the canvas with Select, as it moves; nil once it leaves.
    let point: (NWCanvasPick?) -> Void
    /// The canvas's size, as it changes.
    let resized: (CGSize) -> Void
    /// True while a zoom gesture runs (a pinch, a burst of ⌘-scroll), false once it rests: live
    /// views stand still while the canvas scales, and re-render at the zoom it lands on.
    let zooming: (Bool) -> Void
    let pins: [NWCanvasPin]
    /// A pin was clicked: its comment's id.
    let openPin: (String) -> Void
    /// The element the popover opens under (its board and rect), or nil for none.
    let popoverAnchor: NWCanvasElement?
    let notes: [NWCanvasNote]
    /// The board the actions float over, and what they do; nil for none.
    let actions: NWCanvasActions?
    /// "Ask for another direction", after the last board; nil draws no tile.
    let anotherDirection: (() -> Void)?
    /// A board being dragged: nil when boards don't move.
    let move: ((NWBoardMove) -> Void)?
    let slot: (NWCanvasBoard) -> Slot
    let popover: () -> Popover
    @State private var size: CGSize = .zero
    @State private var popoverHeight: CGFloat = 0
    @State private var actionsSize: CGSize = .zero

    public init(boards: [NWCanvasBoard], viewport: Binding<NWCanvasViewport>, tool: Binding<NWCanvasTool>,
                disabledTools: Set<NWCanvasTool> = [], selection: [NWCanvasElement] = [], hover: NWCanvasElement? = nil,
                pins: [NWCanvasPin] = [], openPin: @escaping (String) -> Void = { _ in }, popoverAnchor: NWCanvasElement? = nil,
                notes: [NWCanvasNote] = [], actions: NWCanvasActions? = nil, anotherDirection: (() -> Void)? = nil,
                move: ((NWBoardMove) -> Void)? = nil,
                pick: @escaping (NWCanvasPick) -> Void, point: @escaping (NWCanvasPick?) -> Void = { _ in },
                resized: @escaping (CGSize) -> Void = { _ in }, zooming: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder slot: @escaping (NWCanvasBoard) -> Slot, @ViewBuilder popover: @escaping () -> Popover) {
        self.boards = boards
        _viewport = viewport
        _tool = tool
        self.disabledTools = disabledTools
        self.selection = selection
        self.hover = hover
        self.pins = pins
        self.openPin = openPin
        self.popoverAnchor = popoverAnchor
        self.notes = notes
        self.actions = actions
        self.anotherDirection = anotherDirection
        self.move = move
        self.pick = pick
        self.point = point
        self.resized = resized
        self.zooming = zooming
        self.slot = slot
        self.popover = popover
    }

    public var body: some View {
        let zoom = viewport.zoom
        let lift = NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap
        ZStack(alignment: .topLeading) {
            NWDotGrid(spacing: NWDesignMetrics.gridSpacing, phase: viewport.offset)
            noteLayer
            ForEach(boards.visible(in: viewport, size: size)) { board in
                let origin = viewport.screen(board.frame.origin)
                NWBoardFrame(board: board, zoom: zoom) { slot(board) }
                    .equatable()
                    .fixedSize()
                    .offset(x: origin.x, y: origin.y - lift)
            }
            rings
            input
            directionTile
            pinLayer
            actionsLayer
            popoverLayer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottomLeading) {
            NWCanvasToolbar(tool: $tool, zoom: viewport.percent, disabled: disabledTools)
                .padding(NWDesignMetrics.toolbarInset)
        }
        .clipped()
        .background(Color.nw.bgBase)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { new in
            size = new
            resized(new)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Canvas")
    }

    private struct Ring: Identifiable {
        let element: NWCanvasElement
        let style: NWSelectionRing.Style
        var id: String { element.id }
    }

    /// The selected elements, then the hovered one unless it is selected, over their boards.
    private var rings: some View {
        let frames = Dictionary(boards.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let selected = Set(selection.map(\.id))
        var rings = selection.map { Ring(element: $0, style: .selected) }
        if let hover, !selected.contains(hover.id) { rings.append(Ring(element: hover, style: .hover)) }
        return ForEach(rings) { ring in
            let board = frames[ring.element.board] ?? .null
            let rect = board.isNull ? .zero : viewport.screen(ring.element.rect.offsetBy(dx: board.minX, dy: board.minY))
            NWSelectionRing(ring.style, tag: ring.element.tag)
                .frame(width: max(rect.width, 1), height: max(rect.height, 1))
                .offset(x: rect.minX, y: rect.minY)
                .opacity(board.isNull ? 0 : 1)
        }
    }

    /// The notes on screen, under the boards; they take no events.
    private var noteLayer: some View {
        let bounds = CGRect(origin: .zero, size: size)
        let shown = notes.filter { viewport.screen($0.bounds).intersects(bounds) }
        return ForEach(shown) { note in
            let origin = viewport.screen(note.origin)
            NWCanvasNoteView(note: note, zoom: viewport.zoom)
                .equatable()
                .offset(x: origin.x, y: origin.y)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// "Ask for another direction", 36pt after the last board, while it is on screen.
    @ViewBuilder private var directionTile: some View {
        if let anotherDirection, let last = boards.last {
            let origin = NWDirectionTile.origin(after: viewport.screen(last.frame))
            let rect = CGRect(origin: origin, size: NWDesignMetrics.directionTileSize)
            if rect.intersects(CGRect(origin: .zero, size: size)) {
                NWDirectionTile(action: anotherDirection)
                    .offset(x: origin.x, y: origin.y)
            }
        }
    }

    /// The board actions over their board, kept inside the canvas.
    @ViewBuilder private var actionsLayer: some View {
        if let actions, let board = boards.first(where: { $0.id == actions.board }),
           let origin = NWBoardActions.origin(over: viewport.screen(board.frame), bar: actionsSize, canvas: size) {
            NWBoardActions(size: .compact, actions: actions.actions)
                .fixedSize()
                .onGeometryChange(for: CGSize.self) { $0.size } action: { actionsSize = $0 }
                .offset(x: origin.x, y: origin.y)
        }
    }

    /// Where a board's element is on screen; nil when its board isn't on the canvas.
    private func screenRect(of rect: CGRect, on board: String, frames: [String: CGRect]) -> CGRect? {
        guard let frame = frames[board] else { return nil }
        return viewport.screen(rect.offsetBy(dx: frame.minX, dy: frame.minY))
    }

    /// Each pin centered on its element's top-trailing corner, over boards on screen.
    private var pinLayer: some View {
        let frames = Dictionary(boards.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        let half = NWDesignMetrics.pinSize / 2
        let bounds = CGRect(origin: .zero, size: size).insetBy(dx: -half, dy: -half)
        let shown = pins.compactMap { pin -> (NWCanvasPin, CGPoint)? in
            guard let rect = screenRect(of: pin.rect, on: pin.board, frames: frames) else { return nil }
            let corner = CGPoint(x: rect.maxX, y: rect.minY)
            return bounds.contains(corner) ? (pin, corner) : nil
        }
        return ForEach(shown, id: \.0.id) { pin, corner in
            Button { openPin(pin.id) } label: { NWCommentPin(pin.number) }
                .buttonStyle(.plain)
                .offset(x: corner.x - half, y: corner.y - half)
                .help("Comment \(pin.number)")
        }
    }

    /// The popover under its element, its trailing edge at the pin's, inside the canvas.
    @ViewBuilder private var popoverLayer: some View {
        let frames = Dictionary(boards.map { ($0.id, $0.frame) }, uniquingKeysWith: { a, _ in a })
        if let anchor = popoverAnchor, let rect = screenRect(of: anchor.rect, on: anchor.board, frames: frames) {
            let width = NWDesignMetrics.threadWidth
            let inset = NWDesignMetrics.toolbarInset
            let trailing = rect.maxX + NWDesignMetrics.pinSize / 2
            let x = min(max(trailing - width, inset), max(inset, size.width - width - inset))
            let below = rect.maxY + NWDesignMetrics.threadGap
            let y = min(below, max(inset, size.height - popoverHeight - inset))
            popover()
                .fixedSize(horizontal: false, vertical: true)
                .frame(width: width)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { popoverHeight = $0 }
                .offset(x: x, y: max(inset, y))
        }
    }

    @ViewBuilder private var input: some View {
        #if os(macOS)
        NWCanvasInput(tool: tool, handlers: NWCanvasInput.Handlers(
            pan: { viewport.pan(by: $0) },
            zoom: { factor, anchor in viewport.zoom(by: factor, about: anchor) },
            click: { location, extending in pick(boards.pick(at: location, viewport: viewport, extending: extending)) },
            grab: { location in
                // A board moves by its label, or wherever it is while it is selected whole.
                guard move != nil else { return nil }
                let found = boards.pick(at: location, viewport: viewport)
                guard let id = found.board, let board = boards.first(where: { $0.id == id }) else { return nil }
                return found.point == nil || board.isSelected ? id : nil
            },
            drag: { id, translation, ended in
                move?(NWBoardMove(board: id, offset: CGSize(width: translation.width / viewport.zoom,
                                                            height: translation.height / viewport.zoom), ended: ended))
            },
            move: { location in
                guard let location else { point(nil); return }
                let found = boards.pick(at: location, viewport: viewport)
                point(found.board == nil ? nil : found)
            },
            zooming: zooming))
        #else
        Color.clear
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 4).onChanged { value in
                viewport.pan(by: CGSize(width: value.velocity.width / 60, height: value.velocity.height / 60))
            })
            .simultaneousGesture(MagnifyGesture().onChanged { value in
                viewport.zoom(by: value.magnification, about: value.startLocation)
            })
            .onTapGesture { location in pick(boards.pick(at: location, viewport: viewport)) }
        #endif
    }
}

/// The canvas's dots: one device pixel each, every `spacing` points, moving with the canvas.
extension NWDesignCanvas where Popover == EmptyView {
    public init(boards: [NWCanvasBoard], viewport: Binding<NWCanvasViewport>, tool: Binding<NWCanvasTool>,
                disabledTools: Set<NWCanvasTool> = [], selection: [NWCanvasElement] = [], hover: NWCanvasElement? = nil,
                pins: [NWCanvasPin] = [], openPin: @escaping (String) -> Void = { _ in },
                notes: [NWCanvasNote] = [], actions: NWCanvasActions? = nil, anotherDirection: (() -> Void)? = nil,
                move: ((NWBoardMove) -> Void)? = nil,
                pick: @escaping (NWCanvasPick) -> Void, point: @escaping (NWCanvasPick?) -> Void = { _ in },
                resized: @escaping (CGSize) -> Void = { _ in }, zooming: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder slot: @escaping (NWCanvasBoard) -> Slot) {
        self.init(boards: boards, viewport: viewport, tool: tool, disabledTools: disabledTools, selection: selection,
                  hover: hover, pins: pins, openPin: openPin, popoverAnchor: nil, notes: notes, actions: actions,
                  anotherDirection: anotherDirection, move: move, pick: pick, point: point, resized: resized,
                  zooming: zooming, slot: slot) { EmptyView() }
    }
}

public struct NWDotGrid: View {
    let spacing: CGFloat
    let phase: CGPoint
    @Environment(\.displayScale) private var displayScale

    public init(spacing: CGFloat, phase: CGPoint = .zero) {
        self.spacing = spacing
        self.phase = phase
    }

    public var body: some View {
        let dot = NW.hairline(displayScale)
        let color = Color.nw.lineStrong
        Canvas { context, size in
            let start = CGPoint(x: Self.remainder(phase.x, spacing), y: Self.remainder(phase.y, spacing))
            var path = Path()
            var y = start.y
            while y < size.height {
                var x = start.x
                while x < size.width {
                    path.addRect(CGRect(x: x, y: y, width: dot, height: dot))
                    x += spacing
                }
                y += spacing
            }
            context.fill(path, with: .color(color))
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private static func remainder(_ value: CGFloat, _ step: CGFloat) -> CGFloat {
        let r = value.truncatingRemainder(dividingBy: step)
        return r < 0 ? r + step : r
    }
}

#if os(macOS)
import AppKit

/// Every event over the canvas: scroll pans (⌘ zooms), a pinch zooms, a drag pans with the Pan
/// tool or while space is held, and a click selects. On top of the boards, so none of their
/// pages ever takes an event.
struct NWCanvasInput: NSViewRepresentable {
    struct Handlers {
        var pan: (CGSize) -> Void
        var zoom: (CGFloat, CGPoint) -> Void
        /// A click with Select or Comment, and whether shift was held.
        var click: (CGPoint, Bool) -> Void
        /// With Select, the board a drag starting here moves; nil pans.
        var grab: (CGPoint) -> String? = { _ in nil }
        /// A board being moved: how far the pointer has gone since the drag started, and whether it
        /// has ended.
        var drag: (String, CGSize, Bool) -> Void = { _, _, _ in }
        /// The pointer moving with Select or Comment (nil once it leaves the canvas, or a drag starts).
        var move: (CGPoint?) -> Void
        var zooming: (Bool) -> Void
    }

    let tool: NWCanvasTool
    let handlers: Handlers

    func makeNSView(context: Context) -> InputView { InputView() }

    func updateNSView(_ view: InputView, context: Context) {
        view.handlers = handlers
        if view.tool != tool {
            view.tool = tool
            view.window?.invalidateCursorRects(for: view)
        }
    }

    static func dismantleNSView(_ view: InputView, coordinator: ()) {
        view.stopMonitoring()
    }

    final class InputView: NSView {
        var handlers: Handlers?
        var tool: NWCanvasTool = .select
        private var dragOrigin: CGPoint?
        /// Where a drag began, and the board it moves (nil: it pans).
        private var dragStart: CGPoint?
        private var grabbed: String?
        private var dragged = false
        private var spaceHeld = false
        private var keyMonitor: Any?
        private var zoomRest: DispatchWorkItem?
        private var pinching = false
        private var tracking: NSTrackingArea?

        override var isFlipped: Bool { true }
        override var acceptsFirstResponder: Bool { false }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        private var panning: Bool { tool == .pan || spaceHeld }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() } else { startMonitoring() }
        }

        override func resetCursorRects() {
            if panning { addCursorRect(bounds, cursor: dragOrigin == nil ? .openHand : .closedHand) }
        }

        // MARK: The pointer

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                      owner: self, userInfo: nil)
            addTrackingArea(area)
            tracking = area
        }

        override func mouseMoved(with event: NSEvent) {
            guard tool != .pan, !panning, dragOrigin == nil else { return }
            handlers?.move(location(event))
        }

        override func mouseExited(with event: NSEvent) {
            handlers?.move(nil)
        }

        // MARK: Scroll and pinch

        override func scrollWheel(with event: NSEvent) {
            let scale: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 8
            if event.modifierFlags.contains(.command) {
                let factor = exp(event.scrollingDeltaY * scale * 0.01)
                handlers?.zoom(factor, location(event))
                zoomBurst()
            } else {
                handlers?.pan(CGSize(width: event.scrollingDeltaX * scale, height: event.scrollingDeltaY * scale))
            }
        }

        override func magnify(with event: NSEvent) {
            switch event.phase {
            case .began:
                pinching = true
                handlers?.zooming(true)
            case .ended, .cancelled:
                pinching = false
                handlers?.zooming(false)
            default:
                break
            }
            handlers?.zoom(1 + event.magnification, location(event))
        }

        /// ⌘-scroll has no phases: it rests once a moment passes without another step.
        private func zoomBurst() {
            if zoomRest == nil, !pinching { handlers?.zooming(true) }
            zoomRest?.cancel()
            let rest = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.zoomRest = nil
                if !self.pinching { self.handlers?.zooming(false) }
            }
            zoomRest = rest
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2, execute: rest)
        }

        // MARK: Clicks and drags

        override func mouseDown(with event: NSEvent) {
            dragOrigin = location(event)
            dragStart = dragOrigin
            dragged = false
            grabbed = tool == .select && !panning ? dragOrigin.flatMap { handlers?.grab($0) } : nil
            if panning { window?.invalidateCursorRects(for: self) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin, let start = dragStart else { return }
            let point = location(event)
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            if !dragged, abs(delta.width) + abs(delta.height) < 3 { return }
            if !dragged { handlers?.move(nil) }
            dragged = true
            if let grabbed {
                handlers?.drag(grabbed, CGSize(width: point.x - start.x, height: point.y - start.y), false)
            } else {
                // Select drags the canvas where it holds no board to move.
                handlers?.pan(delta)
                dragOrigin = point
            }
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                dragOrigin = nil
                dragStart = nil
                dragged = false
                grabbed = nil
                window?.invalidateCursorRects(for: self)
            }
            if dragged, let grabbed, let start = dragStart {
                let point = location(event)
                handlers?.drag(grabbed, CGSize(width: point.x - start.x, height: point.y - start.y), true)
                return
            }
            guard !dragged, !panning else { return }
            handlers?.click(location(event), event.modifierFlags.contains(.shift))
        }

        private func location(_ event: NSEvent) -> CGPoint {
            convert(event.locationInWindow, from: nil)
        }

        // MARK: Space

        /// Space held over the canvas pans, unless a text field has the keyboard.
        private func startMonitoring() {
            guard keyMonitor == nil else { return }
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp]) { [weak self] event in
                guard let self, event.window === self.window, event.charactersIgnoringModifiers == " ",
                      event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.capsLock).isEmpty else { return event }
                if event.window?.firstResponder is NSText { return event }
                let inside = self.bounds.contains(self.convert(event.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil))
                if event.type == .keyDown {
                    guard inside || self.spaceHeld else { return event }
                    if !self.spaceHeld {
                        self.spaceHeld = true
                        self.window?.invalidateCursorRects(for: self)
                    }
                    return nil
                }
                guard self.spaceHeld else { return event }
                self.spaceHeld = false
                self.window?.invalidateCursorRects(for: self)
                return nil
            }
        }

        func stopMonitoring() {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
            zoomRest?.cancel()
            zoomRest = nil
        }
    }
}
#endif
