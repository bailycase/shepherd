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
    @ObservationIgnored private var lastDocumentHeight: CGFloat?
    @ObservationIgnored private var stackSize: CGSize = .zero
    @ObservationIgnored private var settings: Settings?
    @ObservationIgnored weak var guardrail: ThreadTailGuard?

    struct Settings: Equatable {
        let session: String?
        let textScale: CGFloat
        let density: SHDensity
    }

    func update(_ rows: ArraySlice<NativeThreadRow>, spacing: CGFloat, settings: Settings) {
        if self.settings != settings {
            table.resetMeasurements()
            pending.removeAll()
            self.settings = settings
        }
        guard self.rows != rows || table.spacing != spacing else { return }
        self.rows = rows
        table.replace(rows.map { .init(id: $0.id, estimate: CGFloat(NativeRowHeight.row($0))) }, spacing: spacing)
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
        guard height > 0, table.index(for: id) != nil, table.height(for: id) != height else { return }
        pending[id] = height
        commit(in: scroll, pass: "row marker layout")
    }

    func columnLaidOut(in scroll: NSScrollView?, prepended: Bool) {
        commit(in: scroll, pass: "column finder frame change", prepended: prepended)
        queueWindow()
    }

    private func commit(in scroll: NSScrollView?, pass: String, prepended: Bool = false) {
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
        guard !prepended, delta != 0, lastDocumentHeight != nil, guardrail?.following == false,
              MacScrollValidationTrace.current?.physicalScrollerHeld != true else { return }
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
            history?.stackSize = newSize
            history?.queueWindow()
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
