#if DEBUG
import AppKit
import ShepherdRemote
import ShepherdUI
import SwiftUI

@MainActor @Observable
final class ThreadMeasuredHistory {
    // Keep IDs rather than indices so a prepend does not move the built window onto the new page.
    private(set) var builtRange: Set<String> = []
    @ObservationIgnored private var table = ThreadRowHeights()
    @ObservationIgnored private var rows: ArraySlice<NativeThreadRow> = []
    @ObservationIgnored private var pending: [String: CGFloat] = [:]
    @ObservationIgnored private weak var stack: StackMarker?
    @ObservationIgnored private var windowQueued = false
    @ObservationIgnored private var anchor: Anchor?
    @ObservationIgnored private var layoutPass = 0
    @ObservationIgnored private var layingOut = false

    private struct Anchor {
        let id: String
        let offset: CGFloat
    }
    @ObservationIgnored private var settings: Settings?
    @ObservationIgnored weak var guardrail: ThreadTailGuard?

    struct Settings: Equatable {
        let session: String?
        let textScale: CGFloat
        let density: SHDensity
    }

    func update(_ rows: ArraySlice<NativeThreadRow>, spacing: CGFloat, settings: Settings) {
        guard self.settings != settings || self.rows != rows || table.spacing != spacing else { return }
        if self.settings?.session != settings.session {
            anchor = nil
            pending.removeAll()
            table.resetMeasurements()
        } else {
            captureAnchor()
            if self.settings != settings { table.resetMeasurements(keeping: builtRange) }
        }
        self.settings = settings
        self.rows = rows
        table.replace(rows.map { .init(id: $0.id, estimate: CGFloat(NativeRowHeight.row($0))) }, spacing: spacing, keeping: builtRange)
        if anchor != nil { stack?.needsLayout = true }
        queueWindow()
    }

    func height(of id: String) -> CGFloat? { table.height(for: id) }

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
        guard let stack, let scroll = stack.enclosingScrollView, guardrail?.active == true else { return }
        // Keep the old page's window until the clip has caught up with the new prefix.
        guard !layingOut, anchor == nil else { queueWindow(); return }
        let clip = scroll.contentView
        let top = stack.convert(stack.bounds, to: clip).minY
        let rect = clip.bounds.offsetBy(dx: 0, dy: -top)
        let window = table.range(for: rect, viewports: AppLayout.eagerTailViewports)
        let kept = builtRange.intersection(table.rows.map(\.id))
        let built = kept.union(table.rows[window].map(\.id))
        guard built != builtRange else { return }
        builtRange = built
        if synchronous {
            SHRenderProbe.scrollEvent("probe.heights.window", "clip bounds y=\(clip.bounds.minY) rows=\(window)",
                                      from: scroll, kind: "layout")
        }
    }

    func rowLaidOut(_ id: String, height: CGFloat, in scroll: NSScrollView?) {
        guard height > 0, let scroll, let stack, stack.enclosingScrollView === scroll,
              let previous = pending[id] ?? table.height(for: id), previous != height else { return }
        pending[id] = height
        stack.needsLayout = true
    }

    private func captureAnchor() {
        guard anchor == nil, let stack, let scroll = stack.enclosingScrollView, guardrail?.following == false else { return }
        let clip = scroll.contentView
        let top = stack.convert(stack.bounds, to: clip).minY
        let reading = clip.bounds.minY + scroll.contentInsets.top - top
        let index = table.range(for: CGRect(x: 0, y: reading, width: 0, height: 1), viewports: 0).lowerBound
        guard index < table.rows.count else { return }
        let id = table.rows[index].id
        if builtRange.contains(id) { anchor = Anchor(id: id, offset: table.offset(at: index)) }
    }

    private func flush(_ marker: StackMarker) {
        guard stack === marker, let scroll = marker.enclosingScrollView, !layingOut else { return }
        layingOut = true
        layoutPass += 1
        let pass = layoutPass
        defer { layingOut = false; queueWindow() }
        if !pending.isEmpty { captureAnchor() }
        let saved = anchor
        anchor = nil
        table.measure(pending, width: marker.bounds.width)
        pending.removeAll(keepingCapacity: true)
        guard let saved, let offset = table.offset(of: saved.id), offset != saved.offset,
              guardrail?.following == false, MacScrollValidationTrace.current?.physicalScrollerHeld != true else { return }
        let delta = offset - saved.offset
        ThreadHistoryAnchor.correct(delta, in: scroll, rowID: saved.id, actor: "thread.write.H1",
                                    caller: "stack marker layout pass=\(pass) delta=\(delta)")
    }

    struct Probe: NSViewRepresentable {
        let history: ThreadMeasuredHistory
        func makeNSView(context: Context) -> StackMarker { StackMarker() }
        func updateNSView(_ view: StackMarker, context: Context) {
            view.history = history
            history.stack = view
            if history.anchor != nil || !history.pending.isEmpty { view.needsLayout = true }
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
        override func layout() {
            super.layout()
            history?.flush(self)
        }
    }
}

struct ThreadRowSlot<Content: View>: View {
    let id: String
    let height: CGFloat
    let built: Bool
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            if built { content() }
            else { Color.clear.frame(height: height).accessibilityHidden(true) }
        }
        .id(id)
    }
}
#endif
