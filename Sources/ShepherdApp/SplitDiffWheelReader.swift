import AppKit
import SwiftUI

/// One wheel observer per Changes viewport. Only horizontal gestures over split code are
/// consumed; vertical input remains owned by the native scroll view.
struct SplitDiffWheelReader: NSViewRepresentable {
    let model: ReviewPaneModel
    func makeNSView(context: Context) -> Region { Region(model: model) }
    func updateNSView(_ view: Region, context: Context) { view.model = model }
    static func dismantleNSView(_ view: Region, coordinator: ()) { view.stop() }

    final class Region: NSView {
        var model: ReviewPaneModel
        private var monitor: Any?
        override var isFlipped: Bool { true }
        init(model: ReviewPaneModel) { self.model = model; super.init(frame: .zero) }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            stop()
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let window = self.window, event.window === window,
                      !self.isHiddenOrHasHiddenAncestor, self.model.layout == .split,
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) else { return event }
                let point = self.convert(event.locationInWindow, from: nil)
                guard self.visibleRect.contains(point) else { return event }
                self.model.scrollSplitCode(at: point, delta: event.scrollingDeltaX, viewportWidth: self.bounds.width)
                return nil
            }
        }
        func stop() { if let monitor { NSEvent.removeMonitor(monitor) }; monitor = nil }
    }
}
