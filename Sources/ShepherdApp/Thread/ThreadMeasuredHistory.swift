#if DEBUG
import AppKit
import ShepherdRemote
import ShepherdUI
import SwiftUI

@MainActor @Observable
final class ThreadMeasuredHistory {
    // Keep the endpoints by ID so a prepend leaves the window over the same rows.
    private struct Bounds: Equatable {
        let first: String
        let last: String
    }

    private var builtBounds: Bounds?
    @ObservationIgnored private var table = ThreadRowHeights()
    @ObservationIgnored private var rows: ArraySlice<NativeThreadRow> = []
    @ObservationIgnored private var pending: [String: CGFloat] = [:]
    @ObservationIgnored private weak var stack: StackMarker?
    @ObservationIgnored private var windowQueued = false
    @ObservationIgnored private var landingJump = false
    @ObservationIgnored private var buildingJumpWindow = false
    @ObservationIgnored private var lastDocumentHeight: CGFloat?
    @ObservationIgnored private var stackSize: CGSize = .zero
    @ObservationIgnored private var settings: Settings?
    @ObservationIgnored weak var guardrail: ThreadTailGuard?
    @ObservationIgnored weak var paging: ThreadHistoryAnchor?
    @ObservationIgnored private var prependedAt: CGRect?
    @ObservationIgnored private var scrollIntent = ScrollIntent()
    @ObservationIgnored private var scrollerTracking: Task<Void, Never>?
    @ObservationIgnored private var heldPrepend: (rows: ArraySlice<NativeThreadRow>, spacing: CGFloat, settings: Settings)?

    var physicalScrollerHeld: Bool { scrollIntent.physicalScrollerHeld }

    func holdScroller() { scrollIntent.scrollerGrab(physical: true) }

    func releaseScroller() {
        guard physicalScrollerHeld else { return }
        scrollIntent.scrollerRelease()
        if let heldPrepend {
            self.heldPrepend = nil
            update(heldPrepend.rows, spacing: heldPrepend.spacing, settings: heldPrepend.settings)
            // The cached column has the same inputs. Invalidate the mounted window after the
            // deferred table replacement even when its endpoint IDs have not changed.
            windowRevision &+= 1
        }
        _ = tryPrepend(in: stack?.enclosingScrollView, pass: "scroller release")
    }

    func observeScroller(_ event: NSEvent, in scroll: NSScrollView) {
        if event.type == .leftMouseUp { releaseScroller(); return }
        guard event.window === scroll.window, let knob = scroll.verticalScroller,
              knob.isEnabled, !knob.isHiddenOrHasHiddenAncestor, knob.testPart(event.locationInWindow) == .knob else { return }
        holdScroller()
        scrollerTracking?.cancel()
        // NSScroller's tracking loop can consume the up event. Check again once tracking ends.
        scrollerTracking = Task { @MainActor [weak self] in
            while !Task.isCancelled, self?.physicalScrollerHeld == true {
                if NSEvent.pressedMouseButtons & 1 == 0 { self?.releaseScroller(); return }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private var windowRevision = 0

    struct Settings: Equatable {
        let session: String?
        let textScale: CGFloat
        let density: SHDensity
    }

    func update(_ rows: ArraySlice<NativeThreadRow>, spacing: CGFloat, settings: Settings) {
        if self.settings != settings {
            table.resetMeasurements()
            pending.removeAll()
            prependedAt = nil
            self.settings = settings
        }
        guard self.rows != rows || table.spacing != spacing else { return }
        let oldFirst = self.rows.first?.id
        if physicalScrollerHeld, let oldFirst, oldFirst == paging?.rowID,
           rows.first?.id != oldFirst, rows.contains(where: { $0.id == oldFirst }) {
            heldPrepend = (rows, spacing, settings)
            return
        }
        self.rows = rows
        table.replace(rows.map { .init(id: $0.id, estimate: CGFloat(NativeRowHeight.row($0))) }, spacing: spacing)
        if let oldFirst, let index = table.index(for: oldFirst), index > 0 {
            paging?.preparePrepend(before: oldFirst, delta: table.offset(at: index))
        }
        if paging?.hasPrepend != true { queueWindow() }
    }

    var retainedRowCount: Int { rows.count }

    func release() {
        rows = []
        table = ThreadRowHeights()
        pending.removeAll()
        builtBounds = nil
        prependedAt = nil
        lastDocumentHeight = nil
        heldPrepend = nil
        scrollerTracking?.cancel()
        scrollIntent.scrollerRelease()
    }

    func window() -> (rows: ArraySlice<NativeThreadRow>, leading: CGFloat, trailing: CGFloat) {
        _ = windowRevision
        guard let bounds = builtBounds, let first = table.index(for: bounds.first),
              let last = table.index(for: bounds.last), first <= last else {
            return (rows.prefix(0), table.height, 0)
        }
        let end = last + 1
        // VStack contributes the gap between the spacer and the first/last built row.
        return (rows.dropFirst(first).prefix(end - first),
                first == 0 ? 0 : table.offset(at: first) - table.spacing,
                end == rows.count ? 0 : table.height - table.offset(at: end))
    }

    func landJump<Result>(_ layout: () throws -> Result) rethrows -> Result {
        landingJump = true
        defer { landingJump = false }
        return try layout()
    }

    /// Lay out the destination rows before moving the clip. The table locates the window;
    /// the marker accounts for actual heights inside the newly built window.
    func jump(to id: String, caller: String, in scroll: NSScrollView) -> Bool {
        guard let host = scroll.window?.contentView else { return false }
        return landJump {
            host.layoutSubtreeIfNeeded()
            guard let index = table.index(for: id), let stack, stack.enclosingScrollView === scroll,
                  guardrail?.active == true else { return false }
            let clip = scroll.contentView
            let previous = builtBounds
            buildingJumpWindow = true
            defer { buildingJumpWindow = false }
            let destination = clip.bounds.offsetBy(dx: 0, dy: table.offset(at: index) - clip.bounds.minY)
            selectWindow(for: destination)
            host.layoutSubtreeIfNeeded()
            guard let top = guardrail?.rowTop(id, in: scroll) else {
                builtBounds = previous
                return false
            }
            ThreadHistoryAnchor.correct(top - scroll.contentInsets.top, in: scroll, rowID: id,
                                        actor: "thread.write.M11", caller: caller)
            host.layoutSubtreeIfNeeded()
            prependedAt = clip.bounds
            return true
        }
    }

    private func queueWindow() {
        guard !windowQueued else { return }
        windowQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.windowQueued = false
            self.publishWindow()
        }
    }

    private func publishWindow(synchronous: Bool = false) {
        if ThreadScrollValidation.timingWheel { SHRenderProbe.tick("thread.wheel.publishWindow") }
        // Preserve the mounted rows across the prepend. Its compensating clip move is not input.
        guard !buildingJumpWindow, paging?.hasPrepend != true, let stack, let scroll = stack.enclosingScrollView,
              guardrail?.active == true else { return }
        let clip = scroll.contentView
        // Keep the compensated window until the reader moves or the viewport resizes.
        guard clip.bounds != prependedAt else { return }
        prependedAt = nil
        let top = stack.convert(stack.bounds, to: clip).minY
        if let window = selectWindow(for: clip.bounds.offsetBy(dx: 0, dy: -top)), synchronous {
            SHRenderProbe.scrollEvent("probe.heights.window", "clip bounds y=\(clip.bounds.minY) rows=\(window)",
                                      from: scroll, kind: "layout")
        }
    }

    @discardableResult
    private func selectWindow(for rect: CGRect) -> Range<Int>? {
        let window = table.range(for: rect, viewports: AppLayout.eagerTailViewports)
        let built = window.isEmpty ? nil : Bounds(first: table.rows[window.lowerBound].id,
                                                  last: table.rows[window.upperBound - 1].id)
        guard built != builtBounds else { return nil }
        builtBounds = built
        if ThreadScrollValidation.timingWheel { SHRenderProbe.tick("thread.wheel.windowMove") }
        return window
    }

    func rowLaidOut(_ id: String, height: CGFloat, in scroll: NSScrollView?) {
        guard height > 0, table.index(for: id) != nil, table.height(for: id) != height else { return }
        pending[id] = height
        commit(in: scroll, pass: "row marker layout")
    }

    func columnLaidOut(in scroll: NSScrollView?) {
        guard !tryPrepend(in: scroll, pass: "column finder frame change") else { return }
        commit(in: scroll, pass: "column finder frame change")
        queueWindow()
    }

    private func tryPrepend(in scroll: NSScrollView?, pass: String) -> Bool {
        guard let paging, paging.hasPrepend else { return false }
        if paging.correctPrepend(in: scroll, pass: pass) { prependedAt = scroll?.contentView.bounds }
        return true
    }

    private func commit(in scroll: NSScrollView?, pass: String) {
        if ThreadScrollValidation.timingWheel { SHRenderProbe.tick("thread.wheel.commit") }
        guard let scroll, let stack, stack.enclosingScrollView === scroll else { return }
        let clip = scroll.contentView
        let height = clip.documentRect.height
        defer { lastDocumentHeight = height }
        guard !pending.isEmpty, stackSize.width > 0 else { return }
        let top = stack.convert(stack.bounds, to: clip).minY
        let reading = clip.bounds.minY + scroll.contentInsets.top - top
        let anchor = table.range(for: CGRect(x: 0, y: reading, width: 0, height: 1), viewports: 0).lowerBound
        var updated = table
        let delta = updated.measure(pending, width: stackSize.width, above: anchor)
        // The markers and column can be placed in either order. Don't apply a prefix change
        // while the stack still has its old height or only some of the rows have reported.
        guard abs(updated.height - stackSize.height) <= 1 / (stack.window?.backingScaleFactor ?? 1) else {
            SHRenderProbe.scrollEvent("probe.heights.pending", "\(pass) stack=\(stackSize.height) measured=\(updated.height) document=\(height)",
                                      from: scroll, kind: "layout")
            return
        }
        table = updated
        pending.removeAll(keepingCapacity: true)
        // At an explicit landing there is no previous reader position to preserve. Keep
        // the measurements, and let the next layout anchor to the landed clip instead.
        guard !landingJump, paging?.hasPrepend != true, delta != 0, lastDocumentHeight != nil, guardrail?.following == false,
              !physicalScrollerHeld else { return }
        ThreadHistoryAnchor.correct(delta, in: scroll, rowID: anchor < table.rows.count ? table.rows[anchor].id : nil,
                                    actor: "thread.write.H1", caller: "\(pass) delta=\(delta) document=\(height)")
    }

    struct Probe: NSViewRepresentable {
        let history: ThreadMeasuredHistory
        func makeNSView(context: Context) -> StackMarker { StackMarker() }
        func updateNSView(_ view: StackMarker, context: Context) {
            view.history = history
            history.stack = view
            history.stackSize = view.frame.size
            view.observeClip()
        }
    }

    final class StackMarker: NSView {
        weak var history: ThreadMeasuredHistory?
        private weak var observedClip: NSClipView?
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeClip()
        }

        func observeClip() {
            let clip = window == nil ? nil : enclosingScrollView?.contentView
            guard clip !== observedClip else { return }
            let center = NotificationCenter.default
            if let observedClip { center.removeObserver(self, name: NSView.boundsDidChangeNotification, object: observedClip) }
            observedClip = clip
            if let clip {
                clip.postsBoundsChangedNotifications = true
                center.addObserver(self, selector: #selector(boundsChanged), name: NSView.boundsDidChangeNotification, object: clip)
            }
        }

        @objc private func boundsChanged() {
            guard let history, history.stack === self else { return }
            history.publishWindow(synchronous: true)
        }
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            guard let history, history.stack === self else { return }
            history.stackSize = newSize
            if !history.tryPrepend(in: enclosingScrollView, pass: "stack frame change") {
                history.queueWindow()
            }
        }
    }
}

struct ThreadMeasuredColumn<Content: View>: View {
    let history: ThreadMeasuredHistory
    let spacing: CGFloat
    @ViewBuilder let content: (NativeThreadRow) -> Content
    // The history cache keeps this value until the inputs captured by content change.
    private let revision = UUID()

    var body: some View {
        let window = history.window()
        VStack(alignment: .leading, spacing: spacing) {
            if window.leading > 0 {
                Color.clear.frame(height: window.leading).accessibilityHidden(true)
            }
            ForEach(window.rows) { row in
                BuiltRow(row: row, revision: revision, content: content).equatable().id(row.id)
            }
            if window.trailing > 0 {
                Color.clear.frame(height: window.trailing).accessibilityHidden(true)
            }
        }
        .background { ThreadMeasuredHistory.Probe(history: history) }
        .scrollTargetLayout()
    }

    private struct BuiltRow: View, Equatable {
        let row: NativeThreadRow
        let revision: UUID
        let content: (NativeThreadRow) -> Content

        static func == (lhs: Self, rhs: Self) -> Bool { lhs.revision == rhs.revision && lhs.row == rhs.row }
        var body: some View { content(row) }
    }
}
#endif
