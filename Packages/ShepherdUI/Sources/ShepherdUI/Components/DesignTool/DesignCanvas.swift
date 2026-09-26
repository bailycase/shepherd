import SwiftUI

/// The design canvas (NWDesignCanvas; DZCanvas): `bgBase` with 1px `lineStrong` dots every
/// 22pt, the boards at their canvas positions in their frames, and the canvas toolbar in the
/// bottom-leading corner. It pans (two-finger scroll, the Pan tool, space-drag) and zooms (pinch,
/// ⌘-scroll) about the pointer. With Select, a click reports what it landed on (`pick`: a point
/// on a board, a board's label, or the empty canvas; shift extends), and the pointer's moves over
/// the boards are reported too (`point`); the selected and hovered elements are ringed over their
/// boards (`NWSelectionRing`) from the rects the boards reported.
///
/// Only the boards on screen are built, each an `NWBoardFrame` compared by value, so a pan
/// moves frames without redrawing them and a change to one board redraws that board alone. The
/// slot draws a board's page (a live view or a snapshot); the canvas takes every event, so
/// nothing inside a board is interactive.
public struct NWDesignCanvas<Slot: View>: View {
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
    let slot: (NWCanvasBoard) -> Slot
    @State private var size: CGSize = .zero

    public init(boards: [NWCanvasBoard], viewport: Binding<NWCanvasViewport>, tool: Binding<NWCanvasTool>,
                disabledTools: Set<NWCanvasTool> = [], selection: [NWCanvasElement] = [], hover: NWCanvasElement? = nil,
                pick: @escaping (NWCanvasPick) -> Void, point: @escaping (NWCanvasPick?) -> Void = { _ in },
                resized: @escaping (CGSize) -> Void = { _ in }, zooming: @escaping (Bool) -> Void = { _ in },
                @ViewBuilder slot: @escaping (NWCanvasBoard) -> Slot) {
        self.boards = boards
        _viewport = viewport
        _tool = tool
        self.disabledTools = disabledTools
        self.selection = selection
        self.hover = hover
        self.pick = pick
        self.point = point
        self.resized = resized
        self.zooming = zooming
        self.slot = slot
    }

    public var body: some View {
        let zoom = viewport.zoom
        let lift = NWDesignMetrics.labelHeight + NWDesignMetrics.labelGap
        ZStack(alignment: .topLeading) {
            NWDotGrid(spacing: NWDesignMetrics.gridSpacing, phase: viewport.offset)
            ForEach(boards.visible(in: viewport, size: size)) { board in
                let origin = viewport.screen(board.frame.origin)
                NWBoardFrame(board: board, zoom: zoom) { slot(board) }
                    .equatable()
                    .fixedSize()
                    .offset(x: origin.x, y: origin.y - lift)
            }
            rings
            input
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

    @ViewBuilder private var input: some View {
        #if os(macOS)
        NWCanvasInput(tool: tool, handlers: NWCanvasInput.Handlers(
            pan: { viewport.pan(by: $0) },
            zoom: { factor, anchor in viewport.zoom(by: factor, about: anchor) },
            click: { location, extending in pick(boards.pick(at: location, viewport: viewport, extending: extending)) },
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
        /// A click with Select, and whether shift was held.
        var click: (CGPoint, Bool) -> Void
        /// The pointer moving with Select (nil once it leaves the canvas, or a drag starts).
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
            guard tool == .select, !panning, dragOrigin == nil else { return }
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
            dragged = false
            if panning { window?.invalidateCursorRects(for: self) }
        }

        override func mouseDragged(with event: NSEvent) {
            guard let origin = dragOrigin else { return }
            let point = location(event)
            let delta = CGSize(width: point.x - origin.x, height: point.y - origin.y)
            if !dragged, abs(delta.width) + abs(delta.height) < 3 { return }
            if !dragged { handlers?.move(nil) }
            dragged = true
            // Select drags the canvas too: there is nothing on it to move yet.
            handlers?.pan(delta)
            dragOrigin = point
        }

        override func mouseUp(with event: NSEvent) {
            defer {
                dragOrigin = nil
                dragged = false
                window?.invalidateCursorRects(for: self)
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
