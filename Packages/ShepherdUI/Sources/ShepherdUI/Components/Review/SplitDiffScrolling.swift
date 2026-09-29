import SwiftUI
#if os(macOS)
import AppKit
#endif

/// One file's two horizontal positions. Vertical scrolling remains the containing diff's.
@MainActor @Observable
public final class NWSplitDiffScroll {
    public var oldOffset: CGFloat = 0
    public var newOffset: CGFloat = 0
    public private(set) var oldLimit: CGFloat = 0
    public private(set) var newLimit: CGFloat = 0

    public init() {}

    public func resize(oldWidth: CGFloat, newWidth: CGFloat, viewport: CGFloat) {
        let old = max(0, oldWidth - viewport), new = max(0, newWidth - viewport)
        if oldLimit != old { oldLimit = old }
        if newLimit != new { newLimit = new }
        move(to: oldOffset, old: true)
        move(to: newOffset, old: false)
    }

    public func move(to offset: CGFloat, old: Bool) {
        let value = min(max(0, offset), old ? oldLimit : newLimit)
        if old { if oldOffset != value { oldOffset = value } }
        else if newOffset != value { newOffset = value }
    }
}

extension EnvironmentValues {
    @Entry public var splitDiffScroll: NWSplitDiffScroll? = nil
}

#if os(macOS)
/// Two native scrollbars per file, not a scroll view per line. Code canvases read their own
/// column's offset; gutters, comments and the center divider stay at the viewport's positions.
public struct NWSplitDiffScrollbars: View {
    let scroll: NWSplitDiffScroll
    public init(_ scroll: NWSplitDiffScroll) { self.scroll = scroll }
    public var body: some View {
        HStack(spacing: 0) {
            SplitScroller(scroll: scroll, old: true)
            Color.nw.lineSubtle.frame(width: 1)
            SplitScroller(scroll: scroll, old: false)
        }
        .frame(height: NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy))
    }
}

private struct SplitScroller: NSViewRepresentable {
    let scroll: NWSplitDiffScroll
    let old: Bool
    func makeNSView(context: Context) -> Control {
        let height = NSScroller.scrollerWidth(for: .small, scrollerStyle: .legacy)
        let view = Control(frame: CGRect(x: 0, y: 0, width: NWDiffMetrics.numberWidth * 2, height: height))
        view.controlSize = .small
        view.scrollerStyle = .legacy
        view.target = view
        view.action = #selector(Control.changed)
        view.setAccessibilityLabel(old ? "Scroll old code horizontally" : "Scroll new code horizontally")
        return view
    }
    func updateNSView(_ view: Control, context: Context) {
        view.scroll = scroll; view.old = old
        view.updatePosition()
    }
    final class Control: NSScroller {
        var scroll: NWSplitDiffScroll?
        var old = false
        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updatePosition()
        }
        func updatePosition() {
            guard let scroll else { return }
            let limit = old ? scroll.oldLimit : scroll.newLimit
            isEnabled = limit > 0
            doubleValue = limit > 0 ? Double((old ? scroll.oldOffset : scroll.newOffset) / limit) : 0
            let viewport = max(1, bounds.width - NWDiffMetrics.splitCodeLeading - NWDiffMetrics.commentSlotWidth)
            knobProportion = viewport / (viewport + limit)
        }
        @objc func changed() {
            guard let scroll else { return }
            let limit = old ? scroll.oldLimit : scroll.newLimit
            let current = old ? scroll.oldOffset : scroll.newOffset
            switch hitPart {
            case .decrementPage: scroll.move(to: current - bounds.width, old: old)
            case .incrementPage: scroll.move(to: current + bounds.width, old: old)
            default: scroll.move(to: CGFloat(doubleValue) * limit, old: old)
            }
        }
    }
}

#endif
